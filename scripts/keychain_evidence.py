"""Audit a one-use key across signed app launches. Persist counts and statuses only."""
from datetime import datetime
import json
import os
from pathlib import Path
import re
import plistlib
import secrets
import stat
import subprocess
import sys
import tempfile
import uuid


def inspect_stream(stream, needle):
    overlap = b""
    size = 0
    hit = False
    while chunk := stream.read(1024 * 1024):
        size += len(chunk)
        data = overlap + chunk
        hit |= needle in data
        overlap = data[-(len(needle) - 1):]
    return hit, size


def identity(bundle, identifier, signer):
    requirement = f'identifier "{identifier}" and certificate leaf = H"{signer}"'
    subprocess.run(["codesign", "--verify", "--strict", "--deep", "-R=" + requirement, str(bundle)], check=True)
    info = subprocess.run(["codesign", "-d", "--verbose=4", str(bundle)], capture_output=True, check=True).stderr.decode()
    return {k: re.search("^" + k + "=(.+)$", info, re.M)[1] for k in ("Identifier", "CDHash", "Authority")}


def launch(app, phase, account, src, response):
    if response.exists():
        raise ValueError("receipt destination already exists")
    subprocess.run(["open", "-W", "-n", str(app), "--args", "--keychain-canary", phase, account,
                    str(src), "--out", str(response)], check=True, timeout=35)
    receipt = json.loads(response.read_text())
    if (receipt["phase"] != phase or not isinstance(receipt.get("pid"), int)
            or Path(receipt.get("bundle", "")).resolve() != app.resolve()):
        raise ValueError("unexpected receipt")
    return receipt


def scan(root, needle):
    counts = dict(files=0, bytes=0, hits=0, unreadable=0, vanished=0, skippedNonRegular=0)
    def unavailable(error):
        counts["unreadable"] += 1

    for directory, _, names in os.walk(root, onerror=unavailable):
        for name in names:
            path = Path(directory, name)
            try:
                if not stat.S_ISREG(path.lstat().st_mode):
                    counts["skippedNonRegular"] += 1
                    continue
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as stream:
                    if not stat.S_ISREG(os.fstat(fd).st_mode):
                        counts["skippedNonRegular"] += 1
                        continue
                    hit, size = inspect_stream(stream, needle)
                counts["files"] += 1
                counts["bytes"] += size
                counts["hits"] += int(hit)
            except FileNotFoundError:
                counts["vanished"] += 1
            except OSError as error:
                unavailable(error)
    return counts


def audit(app, out):
    app, out = Path(app).resolve(), Path(out)
    start = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    service = app / "Contents/XPCServices/com.dabaipet.app.credentials.xpc"
    signer = plistlib.loads((app / "Contents/Info.plist").read_bytes())["DabaiCredentialSigner"]
    if not re.fullmatch("[0-9A-F]{40}", signer):
        raise ValueError("invalid app signer fingerprint")
    report = dict(app=identity(app, "com.dabaipet.app", signer),
                  service=identity(service, "com.dabaipet.app.credentials", signer),
                  signer=signer, phases=[], roots={}, logs={}, hits=0, unreadable=0)
    needle = ("sk-CANARY-" + secrets.token_hex(24)).encode()
    account = str(uuid.uuid4())
    with tempfile.TemporaryDirectory() as staging:
        src = Path(staging) / "input"
        with src.open("xb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(needle)
        try:
            for phase in ("create", "read", "update", "read-updated"):
                receipt = launch(app, phase, account, src, Path(staging) / str(len(report["phases"])))
                report["phases"].append(receipt)
                if not receipt["ok"]:
                    break
        finally:
            # Creation may have reached Keychain before its receipt was lost.
            # The app checks the UUID and the disposable value before deleting.
            report["phases"].append(launch(app, "delete", account, src, Path(staging) / "delete"))
    # Query before a potentially long filesystem scan so the time range stays bounded.
    for proc in ("DabaiPet", "DabaiKeychain"):
        with subprocess.Popen(["/usr/bin/log", "show", "--info", "--debug", "--start", start,
                               "--predicate", f'process == "{proc}"', "--style", "compact"],
                              stdout=subprocess.PIPE) as log:
            matches = rows = 0
            for line in log.stdout:
                matches += int(needle in line)
                rows += int((proc + "[").encode() in line)
            rc = log.wait()
            report["logs"][proc] = dict(exitCode=rc, rows=rows, hits=matches)
            report["hits"] += matches
            report["unreadable"] += int(rc != 0)
    for root in [Path.home() / "Library" / name for name in ("Preferences", "Caches", "Application Support")] + [Path("/private/tmp")]:
        stats = scan(root, needle)
        report["roots"][str(root)] = stats
        report["hits"] += stats["hits"]
        report["unreadable"] += stats["unreadable"]
    phases = report["phases"]
    completed = len(phases) == 5 and all(p["ok"] for p in phases) and len({p["pid"] for p in phases}) == 5
    report["exitCode"] = int(not completed or bool(report["hits"] or report["unreadable"]))
    (out / "canary.json").write_text(json.dumps(report, indent=2) + "\n")
    return report["exitCode"]


if __name__ == "__main__":
    sys.exit(audit(*sys.argv[1:]))
