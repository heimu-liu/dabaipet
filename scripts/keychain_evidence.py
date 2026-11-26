"""Run the app's disposable Keychain round trip, then look for the exact value."""
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import sys
import tempfile


def contains(stream, needle):
    overlap = b""
    while chunk := stream.read(1024 * 1024):
        data = overlap + chunk
        if needle in data:
            return True
        overlap = data[-(len(needle) - 1):]
    return False


def audit(app, out):
    needle = ("sk-CANARY-" + secrets.token_hex(24)).encode()
    with tempfile.TemporaryDirectory() as staging:
        src = Path(staging) / "input"
        response = Path(staging) / "result.json"
        src.write_bytes(needle)
        src.chmod(0o600)
        subprocess.run(["open", "-W", "-n", app, "--args", "--keychain-canary", str(src),
                        "--out", str(response)], check=True, timeout=60)
        receipt = json.loads(response.read_text())
        if any(receipt.get(k) is not True for k in ("saved", "readMatched", "deleted")):
            sys.exit("app did not confirm disposable Keychain round trip")
    library = Path.home() / "Library"
    report = dict(hits=0, unreadable=0, files=0)

    def unavailable(error):
        report["unreadable"] += 1

    for root in [library / "Preferences", library / "Caches", library / "Application Support", Path("/private/tmp")]:
        for directory, _, names in os.walk(root, onerror=unavailable):
            for name in names:
                path = Path(directory, name)
                try:
                    if not stat.S_ISREG(path.lstat().st_mode):
                        continue
                    with path.open("rb") as stream:
                        report["hits"] += int(contains(stream, needle))
                    report["files"] += 1
                except FileNotFoundError:
                    continue
                except OSError as error:
                    unavailable(error)
    with subprocess.Popen(["/usr/bin/log", "show", "--last", "10m", "--predicate",
                           'process == "DabaiPet"'], stdout=subprocess.PIPE) as log:
        while contains(log.stdout, needle):
            report["hits"] += 1
        if log.wait() != 0:
            report["unreadable"] += 1
    (Path(out) / "canary.json").write_text(json.dumps(report) + "\n")
    return int(bool(report["hits"] or report["unreadable"]))


if __name__ == "__main__":
    sys.exit(audit(*sys.argv[1:]))
