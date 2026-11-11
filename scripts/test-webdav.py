#!/usr/bin/env python3
"""Exercise the Rust sync engine against isolated, real Apache mod_dav on macOS.

Only test fixtures are written. No system Apache settings or user vaults are used.
Python is a development test runner, not an application runtime dependency.
"""
import hashlib
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time


def main():
    repo = Path(__file__).resolve().parents[1]
    httpd = Path("/usr/sbin/httpd")
    modules = Path("/usr/libexec/apache2")
    if not httpd.exists() or not modules.exists():
        raise SystemExit("This runner requires macOS system Apache/mod_dav.")
    with tempfile.TemporaryDirectory(prefix="termpilot-real-webdav-") as directory:
        root = Path(directory)
        for name in ("run", "www/basic/同步 空间", "www/digest/同步 空间"):
            (root / name).mkdir(parents=True)
        password = secrets.token_hex(24)
        subprocess.run(
            ["/usr/sbin/htpasswd", "-ci", str(root / "basic.users"), "fixture"],
            input=password + "\n", text=True, check=True, capture_output=True,
        )
        digest = hashlib.md5(f"fixture:TermPilotTest:{password}".encode()).hexdigest()
        (root / "digest.users").write_text(f"fixture:TermPilotTest:{digest}\n")
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        names = ["mpm_prefork", "unixd", "authn_core", "authn_file", "authz_core",
                 "authz_user", "auth_basic", "auth_digest", "dav", "dav_fs", "log_config"]
        config = [f'ServerRoot "{root}"', f'Listen 127.0.0.1:{port}',
                  f'ServerName 127.0.0.1:{port}', f'DefaultRuntimeDir "{root / "run"}"',
                  f'PidFile "{root / "run/httpd.pid"}"', f'ErrorLog "{root / "error.log"}"',
                  f'CustomLog "{root / "access.log"}" "%m %U %>s"',
                  f'User #{os.getuid()}', f'Group #{os.getgid()}',
                  'StartServers 2', 'MinSpareServers 2', 'MaxSpareServers 4',
                  'MaxRequestWorkers 8', 'ServerLimit 8',
                  f'DocumentRoot "{root / "www"}"', f'DavLockDB "{root / "run/dav"}"']
        loads = [f'LoadModule {name}_module "{modules / ("mod_" + name + ".so")}"' for name in names]
        for auth in ("basic", "digest"):
            config += [f'<Directory "{root / "www" / auth}">',
                       'Dav On', 'Options None', 'AllowOverride None',
                       f'AuthType {auth.title()}', 'AuthName TermPilotTest',
                       f'AuthUserFile "{root / (auth + ".users")}"',
                       'Require valid-user', '</Directory>']
        path = root / "httpd.conf"
        path.write_text("\n".join(loads + config) + "\n")
        subprocess.run([str(httpd), "-t", "-f", str(path)], check=True)
        with (root / "startup.log").open("w") as output:
            server = subprocess.Popen([str(httpd), "-f", str(path), "-DFOREGROUND"],
                                      stdout=output, stderr=output, start_new_session=True)
            try:
                deadline = time.monotonic() + 10
                while True:
                    if server.poll() is not None:
                        raise RuntimeError((root / "startup.log").read_text())
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=.2):
                            break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise RuntimeError("Apache loopback listener did not start.")
                        time.sleep(.1)
                env = dict(os.environ, TERMPILOT_TEST_WEBDAV_ROOT=f"http://127.0.0.1:{port}",
                           TERMPILOT_TEST_WEBDAV_PASSWORD=password)
                subprocess.run(["cargo", "test", "--offline", "-p", "termpilot-core", "--lib",
                                "real_apache_webdav", "--", "--ignored", "--nocapture"],
                               cwd=repo, env=env, check=True)
                files = list((root / "www").rglob("*.tps"))
                assert files, "No actual WebDAV objects were written."
                for file in files:
                    data = file.read_bytes()
                    assert b"never-on-wire" not in data
                    assert b"real-webdav-host" not in data
                access = (root / "access.log").read_text()
                assert "PROPFIND " in access and " 207" in access
                assert "PUT " in access and "GET " in access and " 401" in access
                print(f"Apache Basic/Digest verified; {len(files)} isolated objects; plaintext scan passed.", flush=True)
            except BaseException:
                for name in ("startup.log", "error.log"):
                    if (root / name).exists():
                        print((root / name).read_text())
                raise
            finally:
                if server.poll() is None:
                    server.terminate()
                    try:
                        server.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()


if __name__ == "__main__":
    main()
