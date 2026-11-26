#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")/.."

developer_dir="$(xcode-select -p)"
frameworks_dir="$developer_dir/Library/Developer/Frameworks"

# SwiftPM 6.3.1 passes -I/-L for this CLT framework directory.
if [[ -d "$frameworks_dir/Testing.framework" ]]; then
    exec swift test --disable-xctest \
        -Xswiftc -F -Xswiftc "$frameworks_dir" \
        -Xlinker -rpath -Xlinker "$frameworks_dir" \
        -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib" \
        "$@"
fi

exec swift test --disable-xctest "$@"
