#!/bin/bash
set -euo pipefail
leaf=$1
destination=$2
source_dir="$(cd "$(dirname "$0")/../Services/DabaiKeychain" && pwd)"
identifier=com.dabaipet.app.credentials
# The service is intentionally independent of host build IDs and timestamps.
digest=$(shasum -a 256 "$source_dir/main.m" "$0" | shasum -a 256 | cut -d' ' -f1)
cache="$source_dir/../../.build/credential-services/$leaf/$(uname -m)/$digest"
bundle="$cache/$identifier.xpc"
mkdir -p "$cache" "$destination"
requirement="identifier \"$identifier\" and certificate leaf = H\"$leaf\""
if [[ ! -d "$bundle" ]]; then
    stage=$(mktemp -d "$cache/build.XXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    item="$stage/$identifier.xpc"
    mkdir -p "$item/Contents/MacOS"
    python3 - "$item/Contents/Info.plist" "$identifier" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleIdentifier=sys.argv[2], CFBundleExecutable='DabaiKeychain',
        CFBundleName='DabaiKeychain', CFBundleVersion='1', CFBundlePackageType='XPC!',
        XPCService=dict(ServiceType='Application', JoinExistingSession=True, RunLoopType='dispatch_main')), f)
PY
    xcrun clang -fobjc-arc -O2 -Werror -Wno-deprecated-declarations -mmacosx-version-min=26         "-DHOST_REQUIREMENT=\"identifier \\\"com.dabaipet.app\\\" and certificate leaf = H\\\"$leaf\\\"\""         "$source_dir/main.m" -framework Foundation -framework Security -o "$item/Contents/MacOS/DabaiKeychain"
    codesign --force --sign "$leaf" --timestamp=none --identifier "$identifier"         --requirements "=designated => $requirement" "$item"
    # Publish a complete directory by rename. Another simultaneous producer may win.
    python3 - "$item" "$bundle" <<'PY'
import errno, os, sys
try:
    os.rename(*sys.argv[1:])
except OSError as error:
    if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
        raise
PY
fi
codesign --verify --strict "-R=$requirement" "$bundle"
ditto "$bundle" "$destination/$identifier.xpc"
