#!/usr/bin/env python3
"""Build and run the fixed-service S1 candidate in a new, private round directory."""
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

SOURCE = Path(__file__).resolve().parent
EVIDENCE = SOURCE.parents[1] / ".local-evidence/orca-run-0373dd1cd67c"
HOST = "com.dabaipet.app"
SERVICE = "com.dabaipet.spikes.s1-xpc.witness"
CERT = "8FB31CF5305E65E32FDE12A5A1D0BB62A73888E5"
NESTED = Path("Contents/XPCServices") / (SERVICE + ".xpc")


def now():
    return datetime.now(timezone.utc).isoformat()


def require(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree(bundle):
    return {str(f.relative_to(bundle)): sha(f) for f in sorted(bundle.rglob("*")) if f.is_file()}


def save(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def requirement(identifier):
    return f'identifier "{identifier}" and certificate leaf = H"{CERT}"'


class Round:
    def __init__(self):
        self.uuid = str(uuid.uuid4())
        self.out = EVIDENCE / "s1-xpc" / self.uuid
        self.out.mkdir(parents=True, mode=0o700)
        self.build = self.out / "build"
        self.build.mkdir()
        self.app = self.out / "live/DabaiPet.app"
        self.app.parent.mkdir()
        self.stages = {}
        self.active = None
        self.results = {"round": self.uuid, "started": now(), "uid": os.getuid(),
                        "macOS": platform.mac_ver()[0], "arch": platform.machine(),
                        "launchPath": str(self.app), "signerSHA1": CERT,
                        "sourceSHA256": tree(SOURCE), "signatures": {}, "phases": {}}

    def command(self, *args, expected=0, timeout=60):
        argv = list(map(str, args))
        start = now()
        p = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, env={**os.environ, "TMPDIR": str(self.build)})
        with (self.out / "commands.jsonl").open("a") as log:
            print(json.dumps(dict(argv=argv, start=start, end=now(), rc=p.returncode,
                                  output=p.stdout)), file=log)
        require(p.returncode == expected, f"{argv[0]} exited {p.returncode}, expected {expected}: {p.stdout}")
        return p.stdout

    def compile(self, bundle, executable, identifier, source, marker=None):
        bin_dir = bundle / "Contents/MacOS"
        bin_dir.mkdir(parents=True)
        info = dict(CFBundleIdentifier=identifier, CFBundleExecutable=executable,
                    CFBundleName=executable, CFBundleVersion="1", CFBundleShortVersionString="1.0",
                    LSMinimumSystemVersion="26.0")
        if marker:
            info.update(CFBundlePackageType="APPL", LSUIElement=True)
        else:
            info.update(CFBundlePackageType="XPC!", XPCService=dict(ServiceType="Application",
                                                                     JoinExistingSession=True,
                                                                     RunLoopType="dispatch_main"))
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        flags = [f'-DBUILD_MARKER="{marker}"'] if marker else []
        self.command("/usr/bin/xcrun", "clang", "-fobjc-arc", "-fblocks", "-O2",
                     "-mmacosx-version-min=26.0", "-Werror", "-Wno-deprecated-declarations",
                     "-I", self.build, *flags, SOURCE / source, "-framework", "Security",
                     "-framework", "Foundation", "-o", bin_dir / executable)

    def sign(self, bundle, identifier):
        self.command("/usr/bin/codesign", "--force", "--sign", CERT,
                     "--timestamp=none", "--identifier", identifier, "--requirements",
                     "=designated => " + requirement(identifier), bundle, timeout=180)

    def signature(self, bundle, identifier):
        self.command("/usr/bin/codesign", "--verify", "--strict", "--deep",
                     "-R=" + requirement(identifier), bundle)
        desc = self.command("/usr/bin/codesign", "-d", "-r-", "--verbose=4", bundle)
        def field(key):
            return re.search("^" + key + "(.+)$", desc, re.MULTILINE)[1]
        return dict(dr=field("designated => "), cdhash=field("CDHash="),
                    identifier=field("Identifier="), authority=field("Authority="))

    def prepare(self):
        require(os.stat("/dev/console").st_uid == os.getuid(), "wrong console user")
        for n in [1, 2]:
            p = EVIDENCE / f"s4-paired/group-{n}/diagnostic.json"
            require(p.is_file(), f"S4 group {n} has no final diagnostic")
        samplers = subprocess.check_output(["ps", "-axo", "args="], text=True, errors="replace")
        require(not re.search(r"^\s*(?:\S*/)?python[\d.]*\s+(?:\S*/)?spike_s4\.py\b",
                              samplers, re.I | re.M), "S4 sampler still present")
        ids = self.command("/usr/bin/security", "find-identity", "-v", "-p", "codesigning")
        require(re.search(CERT + r' "DabaiPet Local Dev"', ids), "original signer unavailable")
        defs = {"ROUND_DIR": str(self.out), "ROUND_UUID": self.uuid, "SERVICE_ID": SERVICE,
                "HOST_REQ": requirement(HOST), "SERVICE_REQ": requirement(SERVICE)}
        (self.build / "Round.h").write_text("".join(
            f"#define {key} {json.dumps(value)}\n" for key, value in defs.items()))
        witness = self.build / NESTED.name
        self.compile(witness, "S1Witness", SERVICE, "Service.m")
        self.sign(witness, SERVICE)
        sigs = self.results["signatures"]
        sigs["witness"] = self.signature(witness, SERVICE)
        files = tree(witness)
        self.results["signedServiceFilesSHA256"] = files
        for variant in ["A", "B", "negative"]:
            identifier = HOST if variant != "negative" else "com.dabaipet.spikes.s1-xpc.rejected"
            app = self.build / variant / "DabaiPet.app"
            self.compile(app, "S1Host", identifier, "Host.m", variant)
            shutil.copytree(witness, app / NESTED)
            self.sign(app, identifier)
            host = self.signature(app, identifier)
            nested = self.signature(app / NESTED, SERVICE)
            require(nested == sigs["witness"] and tree(app / NESTED) == files, "service copy changed")
            sigs[variant] = dict(host=host, service=nested, serviceSHA256=files["Contents/MacOS/S1Witness"])
            if variant == "negative":
                self.command("/usr/bin/codesign", "--verify", "-R=" + requirement(HOST), app, expected=3)
            self.stages[variant] = app
        a, b = [sigs[v]["host"] for v in ["A", "B"]]
        require(a["dr"] == b["dr"] and a["cdhash"] != b["cdhash"], "invalid A/B change")

    def activate(self, variant):
        if self.active == variant:
            return
        if self.active:
            self.app.rename(self.stages[self.active])
        self.stages[variant].rename(self.app)
        self.active = variant
        signed = self.results["signatures"][variant]
        require(self.signature(self.app, signed["host"]["identifier"]) == signed["host"] and
                tree(self.app / NESTED) == self.results["signedServiceFilesSHA256"],
                "live app differs from verified stage")

    def phase(self, variant, op):
        self.activate(variant)
        self.command("/usr/bin/open", "-W", "-n", "-g", self.app, "--args", op, timeout=40)
        receipt = json.loads((self.out / (op + ".json")).read_text())
        phase = self.results["phases"][op] = dict(receipt=receipt, openExitCode=0)
        require(receipt["build"] == variant and receipt["phase"] == op and
                Path(receipt["bundle"]) == self.app, "unexpected LaunchServices target")
        result = receipt.get("result", {})
        pids = [receipt["hostPID"], result.get("servicePID", receipt.get("handshake", {}).get("servicePID"))]
        require(all(isinstance(pid, int) and pid > 1 for pid in pids), "missing peer PIDs")
        for pid in pids:
            for _ in range(100):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError(f"PID {pid} still present after host exit")
        phase["bothPIDsAbsentUTC"] = now()
        events = [json.loads(line) for line in (self.out / "service.jsonl").read_text().splitlines()]
        events = [e for e in events if e["servicePID"] == pids[1]]
        phase["serviceEvents"] = events
        require(receipt["securitySession"] > 0 and
                all(e["securitySession"] == receipt["securitySession"] and
                    e["uid"] == receipt["uid"] == os.getuid() for e in events),
                "host and service login sessions differ")
        require([e["event"] for e in events] ==
                ["start", "denied" if op == "reject" else "keychain", "exit"],
                f"unexpected service events in {op}")
        require(Path(events[0]["executable"]) == self.app / NESTED / "Contents/MacOS/S1Witness" and
                events[-1]["exitCode"] == 0 and result["clientPID"] == pids[0],
                "service path, controlled exit or client PID mismatch")
        require(receipt["exitCode"] == 0, f"{op} host reported exit {receipt['exitCode']}")
        return result

    def run(self):
        try:
            self.prepare()
            try:
                a = self.phase("A", "create")
                b = self.phase("B", "read")
                require(self.results["phases"]["create"]["receipt"]["securitySession"] ==
                        self.results["phases"]["read"]["receipt"]["securitySession"],
                        "login session changed between A and B")
                require(a["servicePID"] != b["servicePID"], "service did not cold-start")
                self.results["valueMatched"] = a["sha256"] == b["sha256"]
                require(self.results["valueMatched"], "digest mismatch")
                self.phase("negative", "reject")
            finally:
                if (self.out / "created.sha256").is_file():
                    self.phase("B", "cleanup")
            self.results["candidate"] = "PASS"
        except Exception as error:
            self.results.update(candidate="INCOMPLETE_OR_FAIL", error=str(error))
        finally:
            self.results["finished"] = now()
            save(self.out / "summary.json", self.results)
        print(self.out, self.results["candidate"], self.results.get("error", ""), flush=True)
        return int(self.results["candidate"] != "PASS")


if __name__ == "__main__":
    os.umask(0o077)
    sys.exit(Round().run())
