#!/bin/zsh
set -eu
d=${0:a:h}
out=${1:?Pass a new build directory}
mkdir "$out"
app="$out/DabaiS5.app"
mkdir -p "$app/Contents/MacOS"
swiftc -parse-as-library -swift-version 6 "$d/Probe.swift" -o "$app/Contents/MacOS/DabaiS5"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleIdentifier='local.dabaipet.spike.s5', CFBundleName='大白 S5 离线语音探针',
        CFBundleExecutable='DabaiS5', CFBundleVersion='1', CFBundlePackageType='APPL', LSUIElement=True,
        NSSpeechRecognitionUsageDescription='用合成的中文音频测试本机离线识别。'), f)
PY
codesign --sign "${DABAI_CODESIGN_IDENTITY:-DabaiPet Local Dev}" --timestamp=none "$app"
codesign --verify --deep --strict --verbose=2 "$app"
