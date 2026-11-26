#!/usr/bin/env python3
"""S1 runs signed release builds A and B at the same LaunchServices path.

Run scripts/spike_s1.py for a passive check. Run scripts/spike_s1.py
--ask-microphone --seconds 15 for the human trial. When a sample starts,
press a few ordinary keys in a different app. Only aggregate counts
are observed. The microphone dialog is shown only on an undetermined grant.
Use a fresh output directory for each run. See --help.
"""
import argparse
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
APP = DIST / "DabaiPet.app"
PROBE = Path("Sources/DabaiPetApp/Spikes/IdentityProbe.swift")
BUILD = Path("scripts/build_app.sh")


def signature(app):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", app], check=True)
    info = subprocess.check_output(["codesign", "-d", "-r-", "--verbose=4", app],
                                   stderr=subprocess.STDOUT, text=True)
    def field(pattern):
        return re.search(pattern, info, re.MULTILINE)[1]
    return dict(dr=field(r"^designated => (.+)$"), cdhash=field(r"^CDHash=(\w+)$"),
                authority=field(r"^Authority=(.+)$"), bundle=field(r"^Identifier=(.+)$"))


def build_second(directory, marker):
    for folder in ("Sources", "Resources", "Tests"):
        shutil.copytree(ROOT / folder, directory / folder)
    shutil.copy2(ROOT / "Package.swift", directory)
    (directory / "scripts").mkdir()
    shutil.copy2(ROOT / BUILD, directory / BUILD)
    source = directory / PROBE
    original = source.read_text()
    literal = 'let buildMarker = "canonical"'
    if original.count(literal) != 1:
        raise RuntimeError("S1 build marker unavailable")
    source.write_text(original.replace(literal, f'let buildMarker = "{marker}"'))
    subprocess.run([directory / BUILD], check=True,
                   env={**os.environ, "SWIFTPM_BUILD_DIR": str(directory / ".build")})
    return directory / "dist/DabaiPet.app"


def launch(phase, marker, account, out, reference, seconds, ask=False):
    receipt = out / f"{phase}.json"
    args = [phase, str(account), str(receipt), str(reference), str(seconds)]
    if ask:
        args.append("--ask-microphone")
    if phase != "delete":
        print(f"S1 {phase}: {seconds}-second counter sample; type in another app"
              + (" after the optional permission dialog" if ask else ""), flush=True)
    subprocess.run(["/usr/bin/open", "-W", "-n", "-g", APP, "--args", "--spike-s1", *args], check=True)
    report = json.loads(receipt.read_text())
    if (report["phase"], report["build"], report["account"], report["bundleID"]) != (
            phase, marker, str(account).upper(), "com.dabaipet.app"):
        raise RuntimeError(f"unexpected signed application receipt for {phase}")
    return report


def run(options, out):
    account = uuid.uuid4()
    marker = f"rebuilt-{account}"
    report = dict(startedUTC=datetime.now(timezone.utc).isoformat(), macOS=platform.mac_ver()[0],
                  machine=platform.machine(), account=str(account).upper())
    # Two new, empty SwiftPM scratch directories force two release compilations.
    # The publish lock and canonical backup stay on dist's filesystem for renames.
    with tempfile.TemporaryDirectory(prefix="dabai-s1-") as workspace:
        work = Path(workspace)
        subprocess.run([ROOT / BUILD], check=True,
                       env={**os.environ, "SWIFTPM_BUILD_DIR": str(work / "canonical-build")})
        report["A"] = signature(APP)
        second_tree = work / "second"
        second_tree.mkdir()
        second = build_second(second_tree, marker)
        report["B"] = signature(second)
        a, b = report["A"], report["B"]
        if not (a["dr"] == b["dr"] and a["cdhash"] != b["cdhash"]
                and a["authority"] == b["authority"] and a["bundle"] == b["bundle"] == "com.dabaipet.app"
                and 'certificate leaf = H"' in a["dr"] and a["authority"] == "DabaiPet Local Dev"):
            raise RuntimeError("S1 requires distinct code hashes and the same certificate-bound identity")
        reference = work / "reference.sha256"
        lock = DIST / ".DabaiPet.publish.lock"
        lock.mkdir()
        backup = lock / "canonical.app"
        staged = lock / "second.app"
        cleanup_needed = False
        try:
            if signature(APP) != a:
                raise RuntimeError("Canonical app changed during build")
            shutil.copytree(second, staged, symlinks=True)
            if signature(staged) != b:
                raise RuntimeError("Staged B signature mismatch")
            cleanup_needed = True
            first_run = launch("create", "canonical", account, out, reference,
                               options.seconds, options.ask_microphone)
            APP.rename(backup)
            staged.rename(APP)
            second_run = launch("read", marker, account, out, reference, options.seconds)
            report["sameKeychainValueWithoutUI"] = (first_run["keychain"].get("addStatus") == 0
                                                    and second_run["keychain"].get("readStatus") == 0
                                                    and second_run["keychain"].get("valueMatched") is True)
            report["micA"] = first_run["micAfter"]
            report["micB"] = second_run["micBefore"]
            if report["micA"] == "authorized":
                report["microphoneGrantRetained"] = report["micB"] == "authorized"
            else:
                report["microphoneGrantRetained"] = None
            untrusted = [r for r in (first_run, second_run)
                         if not r["axTrustedBefore"] and not r["axTrustedAfter"]]
            if any(r["counterDelta"] is not None and r["counterDelta"] > 0 for r in untrusted):
                report["keyDownWithoutAX"] = "observed"
            elif untrusted:
                report["keyDownWithoutAX"] = "inconclusive-no-positive-delta"
            else:
                report["keyDownWithoutAX"] = "inconclusive-AX-already-trusted-or-changed"
        finally:
            try:
                if backup.exists():
                    if APP.exists():
                        APP.rename(staged)
                    backup.rename(APP)
                report["restoredCanonicalSignature"] = signature(APP) == a
                if not report["restoredCanonicalSignature"]:
                    raise RuntimeError("Restored canonical signature mismatch")
                if cleanup_needed:
                    cleanup = launch("delete", "canonical", account, out, reference, 0)
                    report["deleteStatus"] = cleanup["keychain"].get("deleteStatus")
            finally:
                if staged.exists():
                    shutil.rmtree(staged)
                # Do not discard a canonical backup if restoration failed.
                if not backup.exists():
                    lock.rmdir()
                (out / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report["sameKeychainValueWithoutUI"] or report["deleteStatus"] != 0:
        raise RuntimeError("Keychain round trip or cleanup failed; inspect receipts")
    if report["microphoneGrantRetained"] is False:
        raise RuntimeError("Authorized microphone grant lost after rebuild")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seconds", type=int, default=8, choices=range(1, 121), metavar="1..120",
                        help="key-down counting window per launch (default 8s)")
    parser.add_argument("--ask-microphone", action="store_true", help="show the optional permission button in A")
    parser.add_argument("--out", type=Path, help="new evidence directory")
    options = parser.parse_args()
    # Unwind the bundle swap if the invoking terminal asks the harness to stop.
    def interrupt(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGHUP, interrupt)
    os.umask(0o077)
    out = (options.out or ROOT / ".local-evidence/spikes" / f"s1-{uuid.uuid4()}").resolve()
    out.mkdir(parents=True, exist_ok=False)
    print(f"S1 evidence: {out}", flush=True)
    run(options, out)
