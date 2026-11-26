#!/usr/bin/env python3
"""Measure the three signed S4 windows serially in the current desktop session."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "dist/DabaiPet.app"
SCENES = ("empty", "canvas", "layer")
WARMUP_SECONDS = 5


def capture(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def read_json(path):
    return json.loads(path.read_text())


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def owned_pid(pid, token):
    if not isinstance(pid, int) or pid <= 1:
        return False
    proc = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="],
                          capture_output=True, text=True)
    cmd = proc.stdout.strip()
    exe = str(APP / "Contents/MacOS/DabaiPet")
    return cmd.startswith(exe + " --spike-s4 ") and cmd.endswith(" " + token)


def await_ready(folder, token, scene, launcher):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        ready = folder / "ready.json"
        if ready.exists():
            state = read_json(ready)
            if (state["scene"] != scene or state["token"] != token
                    or not owned_pid(state["pid"], token)):
                raise RuntimeError(f"{scene}: unexpected launch identity")
            return state
        if launcher.poll() is not None:
            raise RuntimeError(f"{scene}: app exited before reporting its PID")
        time.sleep(0.1)
    raise RuntimeError(f"{scene}: timed out waiting for the visible probe")


def stop(launcher, folder, token):
    # A fresh folder and unique argv token keep all signals scoped to our launch.
    ready = folder / "ready.json"
    pid = read_json(ready)["pid"] if ready.exists() else None
    if owned_pid(pid, token):
        os.kill(pid, signal.SIGUSR1)
    try:
        launcher.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if owned_pid(pid, token):
            os.kill(pid, signal.SIGTERM)
        # If startup never reached its handshake, the in-app watchdog also exits.
        launcher.terminate()
        launcher.wait(timeout=5)


def check_window(state):
    if not (state["visible"] and state["unoccluded"] and state["windowID"] > 0):
        raise RuntimeError(f"{state['scene']}: window hidden or occluded")
    if state["scene"] in ("layer", "layer-limited") and not state["breathingLayerAttached"]:
        raise RuntimeError("layer: no active breathing animation on a mounted layer")
    if state["scene"] == "layer-limited" and state["layerPreferredFrameRate"] != 15:
        raise RuntimeError("layer-limited: 15 Hz preference missing from the mounted animation")


def measure(scene, root, label=None):
    print(f"S4 {label or scene}", flush=True)
    folder = root / (label or scene)
    folder.mkdir()
    token = str(uuid.uuid4())
    launcher = subprocess.Popen(["/usr/bin/open", "-W", "-n", str(APP), "--args",
                                 "--spike-s4", scene, str(folder), token])
    try:
        initial = await_ready(folder, token, scene, launcher)
        check_window(initial)
        time.sleep(WARMUP_SECONDS)
        cmd = [str(ROOT / "scripts/evidence.sh"), "--resources", str(initial["pid"]),
               str(folder / "resources")]
        if scene != "empty":
            cmd.append(str(root / "empty/resources"))
        subprocess.run(cmd, check=True, timeout=80)
    finally:
        stop(launcher, folder, token)
    final = read_json(folder / "finished.json")
    if final["token"] != token or final["pid"] != initial["pid"] or final["scene"] != scene:
        raise RuntimeError(f"{scene}: invalid completion identity")
    check_window(final)
    if scene == "canvas" and not (27 <= final["canvasMeasuredFPS"] <= 33):
        raise RuntimeError(f"canvas: expected approximately 30 draws/s, measured {final['canvasMeasuredFPS']:.2f}")
    return read_json(folder / "resources/cpu.json"), final


def report(root, rows):
    baseline = rows["empty"][0]
    for scene, (row, _) in rows.items():
        row["physFootprintDeltaBytes"] = row["physFootprintBytes"] - baseline["physFootprintBytes"]
        row["windowServerMeanDelta"] = row["windowServer"]["mean"] - baseline["windowServer"]["mean"]
        if row["windowServer"]["pid"] != baseline["windowServer"]["pid"]:
            raise RuntimeError(f"{scene}: WindowServer changed during measurement")
    geometry = {(final["frame"], final["backingScale"]) for _, final in rows.values()}
    if len(geometry) != 1:
        raise RuntimeError("Window geometry or backing scale changed between scenes")
    limits = {"physFootprintBytes": baseline["physFootprintBytes"] + 25_000_000,
              "appMeanCPUPercent": 0.8, "windowServerMeanDeltaPercentagePoints": 1.5}
    layer = rows["layer"][0]
    meets = {"memory": layer["physFootprintBytes"] <= limits["physFootprintBytes"],
             "appCPU": layer["app"]["mean"] <= limits["appMeanCPUPercent"],
             "windowServerCPU": layer["windowServerMeanDelta"] <= limits["windowServerMeanDeltaPercentagePoints"]}
    write_json(root / "comparison.json", dict(
        warmupSecondsAfterReady=WARMUP_SECONDS, cpuSampleCount=30, cpuIntervalSeconds=1,
        firstTopFrameDiscarded=True, p95Method="nearest rank", memoryBytesPerMB=1_000_000,
        scenes={scene: dict(resources=row, window=state) for scene, (row, state) in rows.items()},
        proposedIdleLimits=limits, layerMeetsLimits=meets))
    lines = [
        "# S4 性能标定", "",
        "三个同位置、同尺寸的可见窗口依次采样。就绪后预热 5 秒，top 丢弃首帧，取后 30 个 1 秒样本。P95 使用最近秩，MB 按十进制计算。WindowServer 增量取场景均值减空壳均值，单位为百分点。",
        "", "| 场景 | 物理内存 MB | 内存增量 MB | App CPU 均值 / P95 % | WindowServer CPU 均值 / P95 % | WindowServer 增量 |",
        "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for scene, (row, _) in rows.items():
        lines.append(f"| {scene} | {row['physFootprintBytes']/1e6:.3f} | {row['physFootprintDeltaBytes']/1e6:+.3f} | "
                     f"{row['app']['mean']:.3f} / {row['app']['p95']:.3f} | "
                     f"{row['windowServer']['mean']:.3f} / {row['windowServer']['p95']:.3f} | {row['windowServerMeanDelta']:+.3f} |")
    fps = rows["canvas"][1]["canvasMeasuredFPS"]
    limit_mb = limits["physFootprintBytes"] / 1e6
    verdict = "CALayer 呼吸实测满足三项红线，可提交签收。" if all(meets.values()) else (
        "CALayer 呼吸超出以下目标，请先复测定位，再锁定红线。" + "、".join(key for key, ok in meets.items() if not ok))
    lines += ["", f"Canvas 实际绘制 {fps:.2f} 帧/秒。", "",
              f"建议 Iteration 1 待机红线沿用 §1.2 口径。本机物理内存上限 {limit_mb:.6f} MB（空壳 + 25 MB），"
              "App 平均 CPU ≤ 0.8%，WindowServer 平均 CPU 增量 ≤ 1.5 个百分点。", "", verdict]
    (root / "comparison.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines), flush=True)


def diagnose(root, scene):
    rows = {}
    for label, mode in (("empty", "empty"), (scene, scene), ("empty-after", "empty")):
        row, state = measure(mode, root, label)
        rows[label] = dict(resources=row, window=state)
    if len({(r["window"]["frame"], r["window"]["backingScale"], r["resources"]["windowServer"]["pid"])
            for r in rows.values()}) != 1:
        raise RuntimeError("Diagnostic window geometry, backing scale or WindowServer PID changed")
    ws = {label: row["resources"]["windowServer"] for label, row in rows.items()}
    comparisons = {}
    for metric in ("mean", "p95"):
        first, layer, last = (ws[label][metric] for label in ("empty", scene, "empty-after"))
        comparisons[metric] = dict(baselineDrift=last - first, layerMinusFirst=layer - first,
                                   layerMinusLast=layer - last, layerMinusMidpoint=layer - (first + last) / 2)
    write_json(root / "diagnostic.json", dict(scenes=rows, windowServerDeltaPoints=comparisons))
    lines = ["# S4 WindowServer 配对复测", "",
             "| 场景顺序 | 物理内存 MB | App CPU 均值 / P95 % | WindowServer CPU 均值 / P95 % |",
             "| --- | ---: | ---: | ---: |"]
    for label, record in rows.items():
        row = record["resources"]
        lines.append(f"| {label} | {row['physFootprintBytes']/1e6:.3f} | "
                     f"{row['app']['mean']:.3f} / {row['app']['p95']:.3f} | "
                     f"{ws[label]['mean']:.3f} / {ws[label]['p95']:.3f} |")
    lines += ["", "| WindowServer 差值（百分点） | 空壳末 − 初 | CALayer − 初 | CALayer − 末 | CALayer − 前后中点 |",
              "| --- | ---: | ---: | ---: | ---: |"]
    for metric, comp in comparisons.items():
        cells = [f"{comp[key]:+.3f}" for key in ("baselineDrift", "layerMinusFirst", "layerMinusLast", "layerMinusMidpoint")]
        lines.append(f"| {metric} | " + " | ".join(cells) + " |")
    lines += ["", "P95 差值为各窗口 P95 的差。本轮用于检查桌面背景负载漂移。"]
    if scene == "layer-limited":
        lines += ["", "本轮 CALayer 请求 15 Hz（最低、最高、首选均为 15 Hz）。窗口尺寸、图形、呼吸幅度和周期与默认 CALayer 相同。实际合成帧率由系统决定。"]
    (root / "diagnostic.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    bracket = parser.add_mutually_exclusive_group()
    bracket.add_argument("--diagnostic", action="store_true", help="repeat empty, layer, then empty")
    bracket.add_argument("--limited", action="store_true", help="measure empty, 15 Hz preference layer, then empty")
    parser.add_argument("new_output_directory", type=Path)
    args = parser.parse_args()
    root = args.new_output_directory.resolve()
    root.mkdir(parents=True, exist_ok=False)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(APP)], check=True)
    signature = capture("/usr/bin/codesign", "-dvvv", "-r-", str(APP))
    if "Authority=DabaiPet Local Dev" not in signature.splitlines():
        raise RuntimeError("Expected bundle signed by DabaiPet Local Dev")
    (root / "codesign.txt").write_text(signature + "\n")
    write_json(root / "environment.json", dict(
        macOS=capture("/usr/bin/sw_vers"), hardwareModel=capture("/usr/sbin/sysctl", "-n", "hw.model"),
        executable=str(APP), startUTC=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
    if args.diagnostic or args.limited:
        diagnose(root, "layer-limited" if args.limited else "layer")
    else:
        rows = {scene: measure(scene, root) for scene in SCENES}
        report(root, rows)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
