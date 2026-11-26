#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")/.."

identity="${DABAI_CODESIGN_IDENTITY:-DabaiPet Local Dev}"
if [[ "$identity" == '-' ]]; then
    printf 'Set DABAI_CODESIGN_IDENTITY to a certificate-backed signing identity.\n' >&2
    exit 1
fi

bundle_id=com.dabaipet.app
plist=Resources/Info.plist
dist_dir="$PWD/dist"
output_app="$dist_dir/DabaiPet.app"
publish_lock="$dist_dir/.DabaiPet.publish.lock"

plutil -lint "$plist"
require_value() {
    local key="$1" type="$2" expected="$3" actual
    actual="$(plutil -extract "$key" raw -expect "$type" "$plist")"
    if [[ "$actual" != "$expected" ]]; then
        printf 'Expected %s to equal %s in %s\n' "$key" "$expected" "$plist" >&2
        exit 1
    fi
}
require_value CFBundleIdentifier string "$bundle_id"
require_value CFBundleExecutable string DabaiPet
require_value CFBundleName string DabaiPet
require_value CFBundleDisplayName string DabaiPet
require_value CFBundlePackageType string APPL
require_value CFBundleShortVersionString string 0.1.0
require_value CFBundleVersion string 1
require_value LSMinimumSystemVersion string 26.0
require_value LSUIElement bool true
require_value NSPrincipalClass string NSApplication
require_value NSAppTransportSecurity.NSAllowsLocalNetworking bool true
for key in NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription \
           NSCameraUsageDescription NSLocalNetworkUsageDescription; do
    description="$(plutil -extract "$key" raw -expect string "$plist")"
    if [[ ! "$description" =~ [^[:space:]] ]]; then
        printf 'Missing usage description for %s in %s\n' "$key" "$plist" >&2
        exit 1
    fi
done

identities="$(security find-identity -v -p codesigning)"
identity_line='^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"(.*)"[[:space:]]*$'
requested_hash="$(printf '%s' "$identity" | tr '[:lower:]' '[:upper:]')"
signer_hash=''
while IFS= read -r line; do
    [[ "$line" =~ $identity_line ]] || continue
    candidate_hash="${BASH_REMATCH[1]}"
    candidate_name="${BASH_REMATCH[2]}"
    candidate_hash="$(printf '%s' "$candidate_hash" | tr '[:lower:]' '[:upper:]')"
    [[ "$candidate_name" == "$identity" || "$candidate_hash" == "$requested_hash" ]] || continue
    if [[ -n "$signer_hash" && "$signer_hash" != "$candidate_hash" ]]; then
        printf 'Ambiguous signing identity %s. Specify its certificate SHA-1 hash.\n' "$identity" >&2
        exit 1
    fi
    signer_hash="$candidate_hash"
done <<< "$identities"
if [[ -z "$signer_hash" ]]; then
    printf 'No valid code signing identity matches %s exactly.\n' "$identity" >&2
    exit 1
fi

swift build --configuration release --product DabaiPet
bin_dir="$(swift build --configuration release --show-bin-path)"

mkdir -p -- "$dist_dir"
staging_dir="$(mktemp -d "$dist_dir/.DabaiPet.XXXXXX")"
staged_app="$staging_dir/DabaiPet.app"
previous_app="$staging_dir/previous.app"
publish_locked=false

cleanup() {
    if [[ "$publish_locked" == true ]]; then
        if [[ -e "$previous_app" || -L "$previous_app" ]] &&
            [[ ! -e "$output_app" && ! -L "$output_app" ]]; then
            if ! mv -h -- "$previous_app" "$output_app"; then
                printf 'Previous bundle preserved at %s\n' "$previous_app" >&2
                rmdir -- "$publish_lock"
                return
            fi
        fi
        rmdir -- "$publish_lock"
    fi
    rm -rf -- "$staging_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p -- "$staged_app/Contents/MacOS"
install -m 0755 "$bin_dir/DabaiPet" "$staged_app/Contents/MacOS/DabaiPet"
install -m 0644 "$plist" "$staged_app/Contents/Info.plist"

# Bind the identifier to the same leaf certificate used to sign this bundle.
requirement="designated => identifier \"$bundle_id\" and certificate leaf = H\"$signer_hash\""
codesign --force --sign "$signer_hash" --timestamp=none --identifier "$bundle_id" \
    --requirements "=$requirement" "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

# Serialize publication and keep the previous verified bundle until replacement.
if ! mkdir -- "$publish_lock"; then
    printf 'Could not acquire the publish lock at %s\n' "$publish_lock" >&2
    exit 1
fi
publish_locked=true
if [[ -e "$output_app" || -L "$output_app" ]]; then
    mv -h -- "$output_app" "$previous_app"
fi
mv -h -- "$staged_app" "$output_app"
printf 'Built %s\n' "$output_app"
