#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
    echo "usage: $0 --smoke-test OUTPUT.json | --snapshot OUTPUT.png [BASELINE.png] | --resources PID NEW_DIRECTORY [BASELINE_DIRECTORY] | --hardware | --canary NEW_DIRECTORY" >&2
    exit 64
}
app="${DABAI_EVIDENCE_APP:-$PWD/dist/DabaiPet.app}"
case ${1:-} in
--smoke-test|--snapshot)
    [[ $# == 2 || ( $1 == --snapshot && $# == 3 ) ]] || usage
    # LaunchServices does not propagate the app's exit code. Require a fresh,
    # validated artifact for this invocation before publishing it.
    out=$2
    stage=$(mktemp -d "$(dirname "$out")/.dabai-evidence.XXXXXX")
    trap 'rm -rf "$stage"' EXIT
    stage=$(cd "$stage" && pwd)
    if [[ $1 == --smoke-test ]]; then
        open -W -n "$app" --args "$1" --out "$stage/smoke.json"
        python3 - "$stage/smoke.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    actual = json.load(f)
for field, expected in dict(activationPolicy="accessory", isOpaque=False, level="floating",
                            hasShadow=False, initialState="idle", microphoneSession=None,
                            cameraSession=None).items():
    if field not in actual or type(actual[field]) != type(expected) or actual[field] != expected:
        sys.exit("smoke failed: " + field)
required = {"canJoinAllSpaces", "fullScreenAuxiliary", "stationary", "ignoresCycle"}
if not required.issubset(actual.get("collectionBehavior", [])):
    sys.exit("smoke failed: collectionBehavior")
PY
        mv "$stage/smoke.json" "$out"
    else
        open -W -n "$app" --args "$1" --out "$stage/contact.png"
        swift scripts/compare_snapshot.swift "$stage/contact.png" "${3:-}" > "$stage/report.json"
        mv "$stage/contact.png" "$out"
        mv "$stage/report.json" "$out.diff.json"
    fi
    ;;
--resources)
    [[ ( $# == 3 || $# == 4 ) && $2 =~ ^[1-9][0-9]*$ ]] || usage
    ps -p "$2" >/dev/null
    mkdir "$3"
    ws=$(pgrep -x WindowServer | head -1)
    [[ -n "$ws" ]]
    LC_ALL=C /usr/bin/footprint -p "$2" -f bytes > "$3/footprint.txt"
    LC_ALL=C /usr/bin/top -l 31 -s 1 -pid "$2" -pid "$ws" -stats pid,cpu > "$3/top.txt"
    python3 - "$2" "$ws" "$3" "${4:-}" <<'PY'
import json, math, pathlib, re, statistics, sys
app, ws, folder, baseline = sys.argv[1:]
root = pathlib.Path(folder)
raw_memory = (root / "footprint.txt").read_text()
matches = re.findall(r"^\s*phys_footprint:\s+([\d,]+) B\s*$", raw_memory, re.MULTILINE)
if len(matches) != 1:
    sys.exit("footprint: expected one phys_footprint in bytes")
summary = {"physFootprintBytes": int(matches[0].replace(",", ""))}
for name, pid in (("app", app), ("windowServer", ws)):
    samples = []
    for line in (root / "top.txt").read_text().splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] == pid:
            samples.append(float(fields[1].rstrip("%")))
    if len(samples) != 31:
        sys.exit(f"{name}: expected 31 samples, got {len(samples)}")
    samples = samples[1:]
    summary[name] = dict(pid=int(pid), samples=samples, mean=statistics.mean(samples),
                         p95=sorted(samples)[math.ceil(.95*len(samples))-1])
if baseline:
    previous = json.loads((pathlib.Path(baseline) / "cpu.json").read_text())
    summary["windowServerMeanDelta"] = summary["windowServer"]["mean"] - previous["windowServer"]["mean"]
(root / "cpu.json").write_text(json.dumps(summary, indent=2) + "\n")
PY
    ;;
--hardware)
    [[ $# == 1 ]] || usage
    swift scripts/device_activity.swift
    ;;
--canary)
    [[ $# == 2 ]] || usage
    mkdir "$2"
    output=$(cd "$2" && pwd)
    # The later Keychain service receives a disposable test secret via a mode-600
    # file; no key value in argv, OS logs, reports, or the scanned tmp tree.
    python3 scripts/keychain_evidence.py "$app" "$output"
    ;;
*) usage ;;
esac
