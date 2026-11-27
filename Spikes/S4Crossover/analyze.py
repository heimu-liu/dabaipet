"""Offline recomputation. The only writes are derived CSV and JSON in the evidence folder."""
import csv
from datetime import datetime
import hashlib
import json
import math
from pathlib import Path
import re
from statistics import mean, stdev
import sys

root = Path(sys.argv[1]).resolve()
repo = Path(__file__).resolve().parents[2]
issues = []


def load(name):
    return json.loads((root / name).read_text())


def check(value, reason):
    if not value:
        issues.append(reason)


def p95(values):
    return sorted(values)[math.ceil(.95 * len(values)) - 1]


def interval(values):
    center = mean(values)
    radius = 2.3646242516 * stdev(values) / math.sqrt(len(values))
    return [center - radius, center + radius]


def stats(values):
    return dict(n=len(values), mean=mean(values), p95=p95(values))


def write_csv(name, rows):
    with (root / name).open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)


order = load("schedule.json")
ready = load("ready.json")
launch = load("launch.json")
ws = launch["windowServer"]
finished = load("finished.json")
check(finished["windowServer"] == ws, "WindowServer PID changed")
registered = load("registered.json")
check(datetime.fromisoformat(registered["utc"]).timestamp() <= launch["wall"], "Late registration")
for path, digest in registered["hashes"].items():
    check(hashlib.sha256((repo / path).read_bytes()).hexdigest() == digest, f"Hash mismatch: {path}")
check(registered["hashes"].get(str((repo / "Spikes/S4Crossover/protocol.md").relative_to(repo))), "Missing protocol hash")
keys = ["pid", "windowID", "cgPID", "cgID", "frame", "cgBounds", "displayID", "displayMode", "backingScale",
        "cgAlpha", "opaque", "bgWhite", "bgAlpha", "level", "hasShadow", "styleMask", "collectionBehavior", "ignoresMouse"]
samples = []
periods = []
presentations = []
previous_end = ready["wall"]
for i, condition in enumerate(order):
    begin = load(f"p{i}-begin.json")
    end = load(f"p{i}-end.json")
    candidate = condition == "C"
    for state in (begin, end):
        check(all(state[k] == ready[k] for k in keys), f"p{i} identity/geometry/material/display change")
        check(state["cgID"] == state["windowID"] and state["cgPID"] == state["pid"], f"p{i} CG identity")
        check(state["cgBounds"]["Width"] == state["cgBounds"]["Height"] == 192, f"p{i} CG bounds")
        check(state["visible"] and state["unoccluded"] and state["cgOnscreen"]
              and not state["asleep"] and not state["locked"], f"p{i} visibility/lock")
        check((state["scene"], state["shapeAttached"], state["rate"]) ==
              (("layer-limited", True, [15]*3) if candidate else ("empty", False, [0]*3)), f"p{i} content/animation")
        if candidate:
            presentations.append(state["presentationScaleY"])
    times = load(f"p{i}-timing.json")
    lo, hi = times["top_start"], times["top_end"]
    check(previous_end + 2 <= begin["wall"] <= times["footprint_start"] <= times["footprint_end"]
          <= lo - 1 <= hi - 1 < end["wall"], f"p{i} acquisition bounds")
    check(begin["uptime"] < end["uptime"] and
          abs((end["wall"]-begin["wall"]) - (end["uptime"]-begin["uptime"])) < .1, f"p{i} clock discontinuity")
    previous_end = end["wall"]
    footprint = (root / f"p{i}-footprint.txt").read_text()
    check(f"S4Crossover [{ready['pid']}]" in footprint, f"p{i} footprint PID mismatch")
    byte_readings = re.findall(r"^\s*phys_footprint:\s+([\d,]+) B\s*$", footprint, re.M)
    if len(byte_readings) != 1:
        raise ValueError(f"p{i}: expected one footprint")
    memory = int(byte_readings[0].replace(",", ""))
    frames = re.split(r"^Processes:", (root / f"p{i}-top.txt").read_text(), flags=re.M)[1:]
    check(len(frames) == 6, f"p{i} top frame count")
    last = None
    first = None
    app_cpu, ws_cpu = [], []
    for index, frame in enumerate(frames):
        stamp = re.search(r"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}$", frame, re.M).group()
        epoch = datetime.strptime(stamp, "%Y/%m/%d %H:%M:%S").timestamp()
        check(math.floor(lo) <= epoch <= math.floor(hi), f"p{i} top frame timestamp bounds")
        rows = re.findall(r"^ *(\d+)\s+([\d.]+)%? *$", frame, re.M)
        check(len(rows) == 2 and {int(pid) for pid, value in rows} == {ws, ready["pid"]}, f"p{i} PID mismatch")
        readings = {int(pid): float(value) for pid, value in rows}
        if index:
            check(1 <= epoch - last <= 2, f"p{i} top cadence")
            app_cpu.append(readings[ready["pid"]])
            ws_cpu.append(readings[ws])
            samples.append(dict(block=i//4+1, period=i, condition=condition, top_frame=index,
                                previous_local_second=last, end_local_second=epoch,
                                app_cpu=app_cpu[-1], ws_cpu=ws_cpu[-1]))
        else:
            first = epoch
        last = epoch
    check(5 <= last-first <= 7, f"p{i} top span")
    periods.append(dict(block=i//4+1, period=i, condition=condition, start=begin["wall"], end=end["wall"],
                        top_start=lo, top_end=hi, footprint_bytes=memory, app_mean=mean(app_cpu), ws_mean=mean(ws_cpu)))

for path in root.glob("event-*.json"):
    event = load(path.name)
    check(not (ready["wall"] <= event["wall"] <= periods[-1]["end"]), "Observed window/display event " + path.name)
check(len(order) == 32, "Expected 32 periods")
labels = ["E", "C", "N+", "N-"]
blocks = []
for i in range(8):
    rows = periods[4*i:4*i+4]
    paired = {row["condition"]: row for row in rows}
    check(set(paired) == set(labels) and abs(paired["E"]["period"] - paired["C"]["period"]) == 1 and
          abs(paired["N+"]["period"] - paired["N-"]["period"]) == 1, f"block {i+1}: pair provenance")
    blocks.append(dict(block=i+1, order=" ".join(row["condition"] for row in rows),
                       D=paired["C"]["ws_mean"] - paired["E"]["ws_mean"],
                       Z=paired["N+"]["ws_mean"] - paired["N-"]["ws_mean"],
                       app_delta=paired["C"]["app_mean"] - paired["E"]["app_mean"],
                       byte_delta=paired["C"]["footprint_bytes"] - paired["E"]["footprint_bytes"]))

conditions = {}
for label in labels:
    rows = [row for row in samples if row["condition"] == label]
    check(len(rows) == 40, f"{label} expected 40 seconds")
    conditions[label] = dict(app=stats([row["app_cpu"] for row in rows]),
                             ws=stats([row["ws_cpu"] for row in rows]),
                             footprint=stats([row["footprint_bytes"] for row in periods if row["condition"] == label]))

D = [row["D"] for row in blocks]
Z = [row["Z"] for row in blocks]
d_ci, z_ci = interval(D), interval(Z)
halves = [mean(D[:4]), mean(D[4:])]
noise = math.sqrt(mean(z*z for z in Z))
stable = noise <= 1.5 and z_ci[0] >= -1.5 and z_ci[1] <= 1.5
ws_result = "PENDING"
if not issues and stable:
    if d_ci[1] <= 1.5 and max(halves) <= 1.5:
        ws_result = "PASS"
    if d_ci[0] > 1.5 and min(halves) > 1.5:
        ws_result = "FAIL"
memory_delta = mean(row["byte_delta"] for row in blocks)
other_ok = memory_delta <= 25e6 and conditions["C"]["app"]["mean"] <= .8
overall = ws_result if ws_result == "PENDING" or other_ok else "FAIL"
summary = dict(issues=issues, conditions=conditions, windowServerPID=ws, appPID=ready["pid"], windowID=ready["windowID"],
               D=mean(D), D_ci95=d_ci, half_means=halves, Z=mean(Z), Z_ci95=z_ci, Z_rms=noise,
               empty_stable=stable, memory_delta_bytes=memory_delta, app_delta_points=mean(r["app_delta"] for r in blocks),
               descriptive_memory_delta_ci95_bytes=interval([r["byte_delta"] for r in blocks]),
               descriptive_app_delta_ci95_points=interval([r["app_delta"] for r in blocks]),
               presentation_scale_range=[min(presentations), max(presentations)],
               ws_result=ws_result, overall=overall)
write_csv("valid-intervals.csv", samples)
write_csv("periods.csv", periods)
write_csv("block-differences.csv", blocks)
(root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
