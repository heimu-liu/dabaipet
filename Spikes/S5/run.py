"""Run one probe process and preserve logs even when a recognition request fails."""
import argparse
import json
import pathlib
import re
import os
import signal
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('input', type=pathlib.Path)
parser.add_argument('output', type=pathlib.Path)
parser.add_argument('mode', choices=['primary', 'legacy', 'primary-install', 'legacy-authorize'])
args = parser.parse_args()
folder = args.output.resolve()
folder.mkdir()
raw = folder / 'stdout.log'
began = time.monotonic()
timeout = 180 if args.mode in ('primary-install', 'legacy-authorize') else 45
command = ['open', '-g', '-W', '-n', '--stdout', raw, '--stderr', folder / 'stderr.log',
                         args.app.resolve(), '--args', args.mode, args.input.resolve()]
try:
    launch = subprocess.run(command, timeout=timeout)
except subprocess.TimeoutExpired:
    match = re.search(r'\bpid=(\d+)\b', raw.read_text()) if raw.exists() else None
    if match:
        pid = int(match[1])
        comm = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True).stdout.strip()
        if pathlib.Path(comm) == args.app.resolve() / 'Contents/MacOS/DabaiS5':
            os.kill(pid, signal.SIGTERM)
    (folder/'timeout.log').write_text(f'Probe supervisor reached {timeout} seconds.\n')
    raise
lines = raw.read_text()
pid = re.search(r'\bpid=(\d+)\b', lines)
exit_code = re.search(r'^probeExit=(\d+)$', lines, re.M)
elapsed = time.monotonic() - began
alive = bool(pid and subprocess.run(['ps', '-p', pid[1]], capture_output=True).returncode == 0)
result = dict(mode=args.mode, probeExit=int(exit_code[1]) if exit_code else None,
              input=str(args.input.resolve()), seconds=round(elapsed, 3),
              launchExit=launch.returncode, pid=int(pid[1]) if pid else None, processStillPresent=alive)
(folder / 'launch.json').write_text(json.dumps(result, indent=2)+'\n')
print(lines, end='')
print(result)
raise SystemExit(result['probeExit'] if exit_code and not alive else 1)
