"""POSIX background batch supervisor; transferred in-memory through SSH.

Only task metadata and output survive completion. Authentication secrets never
enter this program. The SSH launcher and its PTY are not the task's parent.
"""
import base64
import fcntl
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid

TERMINAL = {"success", "failed", "cancelled", "unknown"}


def private_directory(path):
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise RuntimeError("Background result directory must be private and owned by the execution account")
    return path


def file_open(path, flags, mode=0o600):
    fd = os.open(path, flags | os.O_NOFOLLOW, mode)
    info = os.fstat(fd)
    # An atomic state replacement can unlink the old inode after a reader has
    # opened it. That read-only snapshot remains safe; hard links never are.
    safe_links = info.st_nlink == 1 or (flags & os.O_ACCMODE == os.O_RDONLY and info.st_nlink == 0)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or not safe_links or info.st_mode & 0o077:
        os.close(fd)
        raise RuntimeError("Unsafe background task record")
    return fd


def read_state(directory):
    try:
        with os.fdopen(file_open(directory + "/state.json", os.O_RDONLY)) as source:
            return json.load(source)
    except FileNotFoundError:
        return None


def save_state(directory, state):
    temporary = directory + "/.state-" + str(uuid.uuid4())
    try:
        with os.fdopen(file_open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL), "w") as output:
            json.dump(state, output, ensure_ascii=True)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, directory + "/state.json")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def clean_workspace(state):
    path = state["remoteWorkDirectory"]
    try:
        current = os.lstat(path)
    except FileNotFoundError:
        state["cleanupStatus"] = "success"
        return
    if [current.st_dev, current.st_ino] != state.get("workspaceIdentity") or not stat.S_ISDIR(current.st_mode):
        raise RuntimeError("Temporary directory identity changed; refusing cleanup")
    if not shutil.rmtree.avoids_symlink_attacks:
        raise RuntimeError("This Python runtime cannot safely remove the temporary directory")
    shutil.rmtree(path)
    state["cleanupStatus"] = "success"


def log_data(directory, name, offset=None, limit=65536):
    try:
        with os.fdopen(file_open(directory + "/" + name + ".log", os.O_RDONLY), "rb") as source:
            size = os.fstat(source.fileno()).st_size
            start = max(0, size - limit) if offset is None else min(offset, size)
            source.seek(start)
            data = source.read(limit)
            return {"data": base64.b64encode(data).decode("ascii"), "offset": start, "nextOffset": start + len(data), "size": size}
    except FileNotFoundError:
        return {"data": "", "offset": 0, "nextOffset": 0, "size": 0}


def status(directory):
    state = read_state(directory)
    if state is None:
        return {"status": "unknown", "message": "Background task was not found. It has not been resubmitted."}
    if state["status"] not in TERMINAL:
        lock = file_open(directory + "/lock", os.O_RDWR)
        try:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                # Never infer success from a PID (it may have been reused).
                state = read_state(directory) or state
                if state["status"] not in TERMINAL:
                    state.update(status="unknown", message="Background supervisor stopped without a final result")
                    try:
                        clean_workspace(state)
                    except Exception as error:
                        state.update(cleanupStatus="failed", message=str(error))
                    save_state(directory, state)
        finally:
            os.close(lock)
    value = dict(state)
    value.pop("workspaceIdentity", None)
    for stream in ("stdout", "stderr"):
        data = log_data(directory, stream)
        value[stream] = base64.b64decode(data["data"]).decode("utf-8", "replace")
        value[stream + "Truncated"] = data["offset"] > 0
    return value


def supervise(directory, state, payload, lock):
    child = None
    try:
        # A second session isolates the script's process group for timeout/cancel.
        script = payload["script"]
        environment = dict(os.environ)
        environment.update(script.get("environment", {}))
        environment.update(TASK_ID=payload["jobId"], HOST_IP=payload["ip"], REMOTE_WORK_DIR=state["remoteWorkDirectory"])
        cwd = script.get("cwd") or os.path.expanduser("~")
        cwd = cwd.replace("${REMOTE_WORK_DIR}", state["remoteWorkDirectory"])
        # Use a private script file to support the full 128 KiB script limit
        # without depending on the platform's per-argument execve limit.
        script_path = state["remoteWorkDirectory"] + "/execute.sh"
        with os.fdopen(file_open(script_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL), "w", encoding="utf-8") as source:
            source.write(script["body"].lstrip("\ufeff").replace("\r\n", "\n"))
        with os.fdopen(file_open(directory + "/stdout.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL), "wb") as stdout, os.fdopen(file_open(directory + "/stderr.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL), "wb") as stderr:
            child = subprocess.Popen([script.get("shell") or "/bin/bash", script_path] + script.get("args", []),
                                     cwd=cwd, env=environment, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True, close_fds=True)
            state.update(status="running", startedAt=time.time(), pid=child.pid)
            save_state(directory, state)
            deadline = time.monotonic() + payload["timeout"] if payload["timeout"] else None
            reason = None
            while child.poll() is None:
                if os.path.lexists(directory + "/cancel"):
                    reason = "cancelled"
                elif deadline is not None and time.monotonic() >= deadline:
                    reason = "timeout"
                if reason:
                    try:
                        os.killpg(child.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    # Keep the group leader unreaped until descendants receive KILL.
                    time.sleep(1)
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    except PermissionError:
                        # Darwin can return EPERM for a group containing only
                        # an exited, unreaped leader. A live leader is an error.
                        if child.poll() is None:
                            raise
                    break
                time.sleep(0.1)
            code = child.wait()
            state.update(exitCode=code if code >= 0 else 128 - code,
                         status="cancelled" if reason == "cancelled" else "success" if code == 0 and reason is None else "failed")
            if reason == "timeout":
                state.update(timedOut=True, message="Remote command timed out")
    except BaseException as error:
        state.update(status="failed", message=str(error))
        if child is not None and child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
    finally:
        try:
            clean_workspace(state)
        except Exception as error:
            state.update(cleanupStatus="failed", message=str(error))
            if state["status"] == "success":
                state["status"] = "failed"
        state.update(finishedAt=time.time(), elapsedMs=int((time.time() - state["submittedAt"]) * 1000))
        save_state(directory, state)
        os.close(lock)


def submit(directory, task_id, payload):
    lock = file_open(directory + "/lock", os.O_CREAT | os.O_RDWR)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return status(directory)
        existing = read_state(directory)
        if existing is not None:
            # An uncertain submission is queried, never automatically replayed.
            return status(directory)
        work = "/tmp/ssh-batch-" + task_id
        os.mkdir(work, 0o700)
        info = os.lstat(work)
        state = {"background": True, "remoteTaskId": task_id, "status": "pending", "submittedAt": time.time(),
                 "remoteWorkDirectory": work, "remoteLogDirectory": directory, "cleanupStatus": "pending", "workspaceIdentity": [info.st_dev, info.st_ino]}
        save_state(directory, state)
        sys.stdout.flush()
        sys.stderr.flush()
        pid = os.fork()
        if pid == 0:
            try:
                os.setsid()
                signal.signal(signal.SIGHUP, signal.SIG_IGN)
                if os.fork() != 0:
                    os._exit(0)
                os.chdir("/")
                null = os.open(os.devnull, os.O_RDWR)
                for fd in (0, 1, 2):
                    os.dup2(null, fd)
                if null > 2:
                    os.close(null)
                # No SSH pipes/sockets are inherited by the supervisor or script.
                ceiling = min(os.sysconf("SC_OPEN_MAX"), 1048576)
                if lock > 3:
                    os.closerange(3, lock)
                os.closerange(max(3, lock + 1), ceiling)
                supervise(directory, state, payload, lock)
            except BaseException as error:
                state.update(status="failed", message=str(error))
                try:
                    clean_workspace(state)
                    save_state(directory, state)
                except Exception:
                    pass
            os._exit(0)
        os.waitpid(pid, 0)
        return state
    finally:
        # The detached child retains the inherited flock descriptor.
        os.close(lock)


def main():
    if sys.version_info < (3, 8) or os.name != "posix":
        raise RuntimeError("Background execution requires Python 3.8+ on a POSIX server")
    action, task_id, encoded = sys.argv[1:4]
    if str(uuid.UUID(task_id)) != task_id:
        raise RuntimeError("Invalid background task ID")
    if encoded == "-":
        # su needs a PTY for authentication. Disable its line discipline before
        # accepting a long payload; the script itself never inherits this PTY.
        if os.isatty(sys.stdin.fileno()):
            import tty
            tty.setraw(sys.stdin.fileno())
        print("__TERMPILOT_BATCH_INPUT_" + task_id + "__", flush=True)
        encoded = sys.stdin.buffer.readline(2 * 1024 * 1024 + 1)
        if len(encoded) > 2 * 1024 * 1024 or not encoded.endswith(b"\n"):
            raise RuntimeError("Invalid background task input")
    payload = json.loads(base64.b64decode(encoded))
    root = os.path.join(os.path.expanduser("~"), ".ssh-batch-results")
    if not os.path.isabs(root):
        raise RuntimeError("Absolute home directory required")
    if action != "submit" and not os.path.lexists(os.path.join(root, task_id)):
        print(json.dumps({"status": "unknown", "remoteTaskId": task_id, "message": "Background task was not found. It has not been resubmitted."}))
        return
    directory = private_directory(os.path.join(private_directory(root), task_id))
    if action == "submit":
        value = submit(directory, task_id, payload)
    elif action in ("status", "cancel"):
        if action == "cancel":
            current = read_state(directory)
            if current and current["status"] not in TERMINAL:
                try:
                    os.close(file_open(directory + "/cancel", os.O_WRONLY | os.O_CREAT | os.O_EXCL))
                except FileExistsError:
                    pass
        value = status(directory)
    elif action == "logs":
        stream, offset = payload["stream"], payload["offset"]
        if stream not in ("stdout", "stderr") or not isinstance(offset, int) or offset < 0:
            raise RuntimeError("Invalid log request")
        value = log_data(directory, stream, offset, 131072)
    else:
        raise RuntimeError("Invalid background operation")
    print(json.dumps(value, ensure_ascii=True), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"error": str(error)}), flush=True)
        sys.exit(1)
