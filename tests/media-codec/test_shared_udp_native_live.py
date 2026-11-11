"""Run opt-in native recovery acceptance with a private credential FIFO."""
import argparse
import errno
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from test_shared_udp_live import ROOT, configuration


def main(args):
    payload = json.dumps([configuration("vnc", host=h) for h in args.hosts]).encode()
    with tempfile.TemporaryDirectory(prefix="TermPilot-native-media-") as directory:
        fifo = Path(directory) / "configuration"
        os.mkfifo(fifo, 0o600)
        env = dict(os.environ, TERMPILOT_LIVE_HP_CONFIG_PATH=str(fifo),
                   TERMPILOT_TEST_ENGINE=str(args.engine.resolve()))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("wb") as log:
            child = subprocess.Popen(["swift", "test", "--build-system", "native", "-c", "release",
                "--skip-build", "--filter", "MediaBrokerLiveTests"], cwd=ROOT / "apps/macos", env=env,
                stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 30
                while True:
                    if child.poll() is not None:
                        raise RuntimeError("Native test exited before receiving its configuration")
                    try:
                        fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
                        break
                    except OSError as error:
                        if error.errno != errno.ENXIO or time.monotonic() > deadline:
                            raise
                        time.sleep(.1)
                with os.fdopen(fd, "wb", buffering=0) as stream:
                    stream.write(payload)
                status = child.wait(timeout=240)
            finally:
                if child.poll() is None:
                    child.terminate()
                    try: child.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        child.kill(); child.wait()
    print(json.dumps(dict(passed=status == 0, log=str(args.output.resolve()))))
    return status


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--hosts", nargs=2, required=True)
    parser.add_argument("--engine", type=Path, default=ROOT / "target/release/termpilot-engine")
    parser.add_argument("--output", type=Path, required=True)
    sys.exit(main(parser.parse_args()))
