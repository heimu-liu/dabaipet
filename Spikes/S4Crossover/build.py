"""Create an isolated signed bundle in the evidence directory."""
import pathlib
import plistlib
import re
import subprocess
import sys

out = pathlib.Path(sys.argv[1]).resolve()
here = pathlib.Path(__file__).resolve().parent
app = out / "S4Crossover.app"
binary = app / "Contents/MacOS/S4Crossover"
binary.parent.mkdir(parents=True, exist_ok=True)
if binary.exists() or (out / "registered.json").exists():
    sys.exit("Already built or registered")
production = (here.parents[1] / "Sources/DabaiPetApp/Spikes/PerformanceProbe.swift").read_text()
definitions, boundary, _ = production.partition("@MainActor\nenum PerformanceProbe")
assert boundary
swift = out / "main.swift"
swift.write_text(definitions + (here / "Fixture.swift").read_text())
subprocess.run(["swiftc", "-O", "-swift-version", "6", str(swift), "-o", str(binary)], check=True)
with (app / "Contents/Info.plist").open("xb") as f:
    plistlib.dump(dict(CFBundleExecutable=binary.name, CFBundleIdentifier="local.dabaipet.s4crossover",
                       CFBundleName=binary.name, CFBundlePackageType="APPL", CFBundleVersion="1",
                       LSMinimumSystemVersion="26.0", LSUIElement=True, NSPrincipalClass="NSApplication"), f)
identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
signer, = re.findall(r'^\s*\d+\) ([A-F0-9]{40}) "DabaiPet Local Dev"\s*$', identities, re.M)
subprocess.run(["codesign", "--force", "--sign", signer, "--timestamp=none", app], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", app], check=True)
