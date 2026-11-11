"""Read only the explicitly selected test host; secrets stay in private stdin.

Run with the project's bundled Python, which already supplies cryptography.
No credentials, desktop pixels or private keys are written to the report.
"""
import base64
import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import uuid
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ROOT = pathlib.Path(__file__).resolve().parents[2]


def configuration(mode, host=None):
    host = host or os.environ.get("TERMPILOT_TEST_HOST", "").strip()
    if not host:
        raise RuntimeError("Select an authorized fixture with TERMPILOT_TEST_HOST or the host argument")
    base = pathlib.Path.home() / "Library/Application Support/TermPilot"
    db = sqlite3.connect(f"file:{base / 'vault.sqlite'}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    cipher = AESGCM((base / "credential.key").read_bytes())

    def unseal(value):
        if not value:
            return ""
        if value.startswith("enc:v1:"):
            payload = base64.b64decode(value[7:])
            return cipher.decrypt(payload[:12], payload[12:], b"").decode()
        return value

    kind = "ssh" if mode == "ssh" else "screenSharing"
    rows = db.execute("select * from hosts where hostname=? and connection_kind=?", (host, kind)).fetchall()
    row = next((dict(row) for row in rows if row["password"] or row["credential_reference"]), None)
    if row is None:
        raise RuntimeError("No configured credential for the selected test host")
    username, password = row["username"], unseal(row["password"])
    if row["credential_reference"]:
        cred = db.execute("select * from ssh_credentials where id=?", (row["credential_reference"],)).fetchone()
        if cred:
            username = username or cred["username"]
            password = unseal(cred["password"])
    if mode != "ssh":
        profile = db.execute("select * from screen_sharing_profiles where host_id=?", (row["id"],)).fetchone()
        if profile:
            username = profile["username"] or username
            password = unseal(profile["password"]) or password
    db.close()
    if not username or not password:
        raise RuntimeError("Selected test host lacks saved authentication")
    return dict(mode=mode, host=host, port=22 if mode == "ssh" else 5900,
                username=username, password=password, knownHosts=str(base / "known_hosts"),
                remoteDirectory="/tmp/TermPilot-migration-" + uuid.uuid4().hex)


if __name__ == "__main__":
    cfg = configuration(sys.argv[1])
    profile = "release" if sys.argv[1] == "vnc-loop" else "debug"
    binary = ROOT / f"target/migration-poc/{profile}/termpilot-migration-probe"
    result = subprocess.run([str(binary)], input=json.dumps(cfg).encode(), capture_output=True,
                            timeout=300 if sys.argv[1] == "vnc-loop" else 140)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    sys.exit(result.returncode)
