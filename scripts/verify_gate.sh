#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/gate_scan.py "${1:-}"
if [[ ${1:-} == --self-test ]]; then exit 0; fi
[[ $# == 0 ]] || { echo "usage: $0 [--self-test]" >&2; exit 64; }
python3 -B -m unittest discover -s scripts/tests

# Check working tree (including new files), index and any ticket commits against
# the ORCH handoff. The initial freeze is pinned by the reviewed SHA manifest.
base=${GATE_BASE_REF:-HEAD}
git rev-parse --verify "$base^{commit}" >/dev/null
lock=scripts/acceptance.sha256
for path in Tests/AcceptanceTests "$lock"; do
    if [[ -n $(git ls-tree -r "$base" -- "$path") ]]; then
        git diff --exit-code "$base" -- "$path"
        git diff --cached --exit-code "$base" -- "$path"
    fi
done
if [[ -f "$lock" ]]; then
    actual=$(find Tests/AcceptanceTests -type f | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done)
    [[ -n "$actual" && "$actual" == "$(cat "$lock")" ]] || { echo 'locked acceptance files changed' >&2; exit 1; }
elif [[ -d Tests/AcceptanceTests ]]; then
    echo 'missing acceptance lock' >&2; exit 1
fi

swift build --target DabaiPetCore -Xswiftc -warnings-as-errors
swift build
log=$(mktemp -t dabai-gate)
trap 'rm -f "$log"' EXIT
# Only the second run measures incremental time. Both must pass.
./scripts/test.sh
start=$SECONDS
./scripts/test.sh 2>&1 | tee "$log"
elapsed=$((SECONDS-start))
(( elapsed < 15 )) || { echo "incremental test took ${elapsed}s" >&2; exit 1; }
count=$(sed -nE 's/^.*Test run with ([0-9]+) tests? (in .* )?passed after .*$/\1/p' "$log" | tail -1)
baseline=$(cat .gate_test_baseline)
[[ $count =~ ^[0-9]+$ && $baseline =~ ^[0-9]+$ ]] || { echo 'missing Swift Testing count or baseline' >&2; exit 1; }
if git cat-file -e "$base:.gate_test_baseline" 2>/dev/null; then
    previous=$(git show "$base:.gate_test_baseline")
    (( baseline >= previous )) || { echo 'test baseline decreased' >&2; exit 1; }
fi
(( count >= baseline && count > 0 )) || { echo "test count $count below baseline $baseline" >&2; exit 1; }

./scripts/build_app.sh
app="${DABAI_DIST_DIR:-$PWD/dist}/DabaiPet.app"
plist="$app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app"
dr=$(codesign -d -r- "$app" 2>&1)
echo "$dr"
# A self-signed cert's synthesized DR can name the root by SHA-1, not by CN.
expected_cert=8FB31CF5305E65E32FDE12A5A1D0BB62A73888E5
codesign --verify -R="identifier \"com.dabaipet.app\" and certificate leaf = H\"$expected_cert\"" "$app"
credential_id="com.dabaipet.app.credentials"
codesign --verify --strict -R="identifier \"$credential_id\" and certificate leaf = H\"$expected_cert\"" \
    "$app/Contents/XPCServices/$credential_id.xpc"
if ! grep -Eiq "designated => .*certificate (root|leaf|[0-9]+) = H\"$expected_cert\"|designated => .*certificate leaf\[subject.CN\] = \"DabaiPet Local Dev\"|designated => .*anchor = H\"$expected_cert\"" <<< "$dr"; then
    echo 'designated requirement is missing the local signing identity' >&2; exit 1
fi
plutil -lint "$plist"
python3 - "$plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as stream:
    p = plistlib.load(stream)
for key, value in {
    'CFBundleIdentifier': 'com.dabaipet.app', 'CFBundleExecutable': 'DabaiPet',
    'CFBundleName': 'DabaiPet', 'CFBundleDisplayName': 'DabaiPet',
    'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.1.0',
    'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '26.0',
    'LSUIElement': True, 'NSPrincipalClass': 'NSApplication'
}.items():
    if type(p.get(key)) is not type(value) or p[key] != value:
        sys.exit(f'invalid plist key {key}')
for key in ('NSMicrophoneUsageDescription', 'NSCameraUsageDescription',
            'NSSpeechRecognitionUsageDescription', 'NSLocalNetworkUsageDescription'):
    if not isinstance(p.get(key), str) or not p[key].strip():
        sys.exit(f'missing privacy description: {key}')
if p.get('NSAppTransportSecurity', {}).get('NSAllowsLocalNetworking') is not True:
    sys.exit('missing NSAllowsLocalNetworking')
PY
if (( count > baseline )); then echo "$count" > .gate_test_baseline; fi
echo "PASS: $count Swift Testing tests; incremental run ${elapsed}s; signed bundle verified"
