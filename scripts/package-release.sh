#!/usr/bin/env bash
# Package a distributable MetalShade release: signed, notarized, stapled, zipped.
#
#   export METALSHADE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#   export METALSHADE_NOTARY_PROFILE="metalshade"   # xcrun notarytool keychain profile
#   ./scripts/package-release.sh
#
# Create the notary profile once with:
#   xcrun notarytool store-credentials metalshade \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Without METALSHADE_SIGN_IDENTITY this script refuses to run: an ad-hoc bundle
# cannot be notarized, and Gatekeeper will refuse to open it on another Mac.
# Use scripts/build-app.sh for unsigned local builds instead.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$project_dir"

sign_identity="${METALSHADE_SIGN_IDENTITY:-}"
notary_profile="${METALSHADE_NOTARY_PROFILE:-}"
skip_notarize=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize) skip_notarize=1; shift ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

if [[ -z "$sign_identity" ]]; then
    cat >&2 <<'MSG'
error: METALSHADE_SIGN_IDENTITY is not set.

A release build needs a Developer ID Application certificate. List the ones
installed on this machine with:

    security find-identity -v -p codesigning

For a local, unsigned build use ./scripts/build-app.sh instead.
MSG
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty; commit or stash before packaging a release" >&2
    exit 1
fi

version="$(tr -d '[:space:]' < VERSION)"
app="$project_dir/dist/MetalShade.app"
archive="$project_dir/dist/MetalShade-$version.zip"

./scripts/build-app.sh --sign "$sign_identity"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$app"

rm -f "$archive"
echo "==> Creating $archive"
# ditto preserves the bundle's symlinks, extended attributes, and signature.
/usr/bin/ditto -c -k --keepParent "$app" "$archive"

if [[ "$skip_notarize" -eq 1 ]]; then
    echo "==> Skipping notarization (--skip-notarize)"
else
    if [[ -z "$notary_profile" ]]; then
        echo "error: METALSHADE_NOTARY_PROFILE is not set; pass --skip-notarize to bypass" >&2
        exit 1
    fi
    echo "==> Submitting to Apple notary service (this can take several minutes)"
    xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait

    echo "==> Stapling the notarization ticket"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"

    # Re-zip so the archive carries the stapled ticket.
    rm -f "$archive"
    /usr/bin/ditto -c -k --keepParent "$app" "$archive"

    echo "==> Gatekeeper assessment"
    spctl --assess --type execute --verbose=2 "$app"
fi

shasum -a 256 "$archive" | tee "$archive.sha256"

echo
echo "Release artifact: $archive"
echo "Next: docs/RELEASE.md — tag, capture screenshots, publish."
