#!/bin/zsh
set -eu
cd "${0:a:h}/../.."
swift build --product DabaiPet
bin=$(swift build --show-bin-path)
out=$(mktemp -d "${TMPDIR:-/tmp}/dabai-settings.XXXXXX")
trap 'rm -f "$out/probe"; rmdir "$out"' EXIT
swiftc -parse-as-library -swift-version 6 -package-name dabaipet \
    -I "$bin/Modules" -I "$bin/CredentialIPC.build" \
    Spikes/SettingsRegression/Probe.swift Sources/DabaiPetApp/AppDelegate.swift \
    Sources/DabaiPetApp/{Window,Controller,Persistence,Services}/*.swift \
    "$bin"/{DabaiPetCore,DabaiPetUI}.build/*.swift.o "$bin"/CredentialIPC.build/*.m.o \
    -o "$out/probe"
"$out/probe"
