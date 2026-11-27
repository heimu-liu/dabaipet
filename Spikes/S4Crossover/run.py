"""Register a balanced order once, then acquire one signed single-window run."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import signal
import subprocess
import sys
import time

here = Path(__file__).resolve().parent
repo = here.parents[1]
out = Path(sys.argv[2]).resolve()
bundle = out / "S4Crossover.app"
dist = repo / "dist/DabaiPet.app"


def save(path, data):
    with path.open("x") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def hashes():
    paths = [*here.glob("*.swift"), here / "protocol.md", here / "run.py", here / "build.py",
             out / "schedule.json", out / "main.swift", repo / "Sources/DabaiPetApp/Spikes/PerformanceProbe.swift",
             dist / "Contents/MacOS/DabaiPet", bundle / "Contents/MacOS/S4Crossover"]
    return {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def register():
    rng = random.SystemRandom()
    columns = []
    for _ in range(3):
        bits = [False, True] * 4
        rng.shuffle(bits)
        columns.append(bits)
    order = []
    for swap, reverse_active, reverse_null in zip(*columns):
        active = ["E", "C"] if reverse_active else ["C", "E"]
        null = ["N-", "N+"] if reverse_null else ["N+", "N-"]
        order.extend(null + active if swap else active + null)
    save(out / "schedule.json", order)
    save(out / "registered.json", dict(utc=datetime.now(timezone.utc).isoformat(), hashes=hashes()))


def receipt(name):
    path = out / name
    deadline = time.monotonic() + 12
    while not path.exists():
        if time.monotonic() > deadline:
            raise RuntimeError("Missing fixture acknowledgment " + name)
        time.sleep(.05)
    return json.loads(path.read_text())


def capture(name, args, timeout=20):
    with (out / name).open("x") as f:
        subprocess.run(args, stdout=f, stderr=subprocess.STDOUT, check=True, timeout=timeout,
                       env=dict(os.environ, LC_ALL="C"))


def acquire():
    assert json.loads((out / "registered.json").read_text())["hashes"] == hashes()
    for app in (dist, bundle):
        subprocess.run(["codesign", "--verify", "--deep", "--strict", app], check=True)
    for name in ["DabaiPet", "S4Crossover"]:
        if subprocess.run(["pgrep", "-x", name], stdout=subprocess.DEVNULL).returncode != 1:
            raise RuntimeError("A probe process is already running: " + name)
    ws, = subprocess.check_output(["pgrep", "-x", "WindowServer"], text=True).split()
    order = json.loads((out / "schedule.json").read_text())
    capture("fixture-signature.txt", ["codesign", "-dvvv", "-r-", bundle])
    capture("dist-signature.txt", ["codesign", "-dvvv", "-r-", dist])
    save(out / "launch.json", dict(wall=time.time(), windowServer=int(ws), system=os.uname().release))
    subprocess.run(["open", "-g", "-n", bundle, "--args", out], check=True)
    ready = receipt("ready.json")
    pid = ready["pid"]
    try:
        assert ready["visible"] and ready["unoccluded"] and not ready["locked"] and not ready["asleep"], ready
        for i, _ in enumerate(order):
            os.kill(pid, signal.SIGUSR1)
            receipt(f"p{i}-begin.json")
            footprint_start = time.time()
            capture(f"p{i}-footprint.txt", ["/usr/bin/footprint", "-p", str(pid), "-f", "bytes"])
            footprint_end = time.time()
            time.sleep(1)
            top_start = time.time()
            capture(f"p{i}-top.txt", ["/usr/bin/top", "-l", "6", "-s", "1",
                                      "-pid", str(pid), "-pid", ws, "-stats", "pid,cpu"])
            top_end = time.time()
            os.kill(pid, signal.SIGUSR1)
            receipt(f"p{i}-end.json")
            save(out / f"p{i}-timing.json", dict(footprint_start=footprint_start, footprint_end=footprint_end,
                                                 top_start=top_start, top_end=top_end))
    finally:
        os.kill(pid, signal.SIGTERM)
    save(out / "finished.json", dict(wall=time.time(), windowServer=int(subprocess.check_output(["pgrep", "-x", "WindowServer"]))))


if __name__ == "__main__":
    {"register": register, "acquire": acquire}[sys.argv[1]]()
