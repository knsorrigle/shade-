#!/usr/bin/env bash
# Build MetalShade.app.
#
# By default this produces a locally signed (ad-hoc) development bundle. Pass a
# Developer ID identity to produce a bundle that can be notarized and shared;
# scripts/package-release.sh wraps this for full releases.
#
#   ./scripts/build-app.sh
#   ./scripts/build-app.sh --sign "Developer ID Application: Name (TEAMID)"
#
# Signing matters even for local use: macOS keys the Screen Recording grant to
# the bundle identifier *and* the code signature. An ad-hoc signature changes
# every rebuild, so each new build must be re-approved in System Settings. A
# stable Developer ID signature keeps the grant across updates.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
output_dir="$project_dir/dist/MetalShade.app"
sign_identity="${METALSHADE_SIGN_IDENTITY:--}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign)
            [[ $# -ge 2 ]] || { echo "error: --sign requires an identity" >&2; exit 2; }
            sign_identity="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

cd "$project_dir"

short_version="$(tr -d '[:space:]' < VERSION)"
if git rev-parse --git-dir >/dev/null 2>&1; then
    build_version="$(git rev-list --count HEAD)"
    revision="$(git rev-parse --short HEAD)"
    [[ -z "$(git status --porcelain)" ]] || revision="$revision-dirty"
else
    build_version="1"
    revision="unknown"
fi

swift build -c release

rm -rf "$output_dir"
mkdir -p "$output_dir/Contents/MacOS" "$output_dir/Contents/Resources"
cp Resources/Info.plist "$output_dir/Contents/Info.plist"
cp .build/release/MetalShade "$output_dir/Contents/MacOS/MetalShade"
printf 'APPL????' > "$output_dir/Contents/PkgInfo"

# KeyboardShortcuts ships localization resources in a SwiftPM bundle. `.build/release`
# is a symlink, so resolve it first: `find` does not descend through it.
build_products="$(cd .build/release && pwd -P)"
shopt -s nullglob
resource_bundles=("$build_products"/*.bundle)
shopt -u nullglob
if [[ ${#resource_bundles[@]} -eq 0 ]]; then
    echo "error: no SwiftPM resource bundles found in $build_products" >&2
    exit 1
fi
cp -R "${resource_bundles[@]}" "$output_dir/Contents/Resources/"

# The injection payload ships inside the app, so launching a game with it does
# not depend on a build directory being present.
"$project_dir/scripts/build-payload.sh" >/dev/null
cp "$project_dir/dist/libMetalShadeInject.dylib" "$output_dir/Contents/Resources/"
# The effect chain both routes compile.
cp "$project_dir/Resources/EffectChain.metal" "$output_dir/Contents/Resources/"

plist_buddy=/usr/libexec/PlistBuddy
"$plist_buddy" -c "Set :CFBundleShortVersionString $short_version" "$output_dir/Contents/Info.plist"
"$plist_buddy" -c "Set :CFBundleVersion $build_version" "$output_dir/Contents/Info.plist"
"$plist_buddy" -c "Add :MetalShadeSourceRevision string $revision" "$output_dir/Contents/Info.plist"

# Fail before signing rather than after: a codesign failure part-way leaves a
# bundle that looks built but carries only the linker's signature, which is
# indistinguishable from a signed one at a glance and silently loses any TCC
# grant tied to the real identity.
if [[ "$sign_identity" != "-" ]]; then
    if ! security find-identity -v -p codesigning | grep -qF "$sign_identity"; then
        rm -rf "$output_dir"
        echo "error: no valid code-signing identity named '$sign_identity'." >&2
        echo "       Create one with ./scripts/create-dev-cert.sh, or list what you have:" >&2
        echo "         security find-identity -v -p codesigning" >&2
        exit 1
    fi
fi

# Sign nested bundles before the outer bundle, innermost first.
timestamp_flag=(--timestamp)
if [[ "$sign_identity" == "-" ]]; then
    # A secure timestamp requires a real identity; ad-hoc signatures cannot use one.
    timestamp_flag=(--timestamp=none)
fi

for nested in "$output_dir/Contents/Resources"/*.bundle; do
    codesign --force --options runtime "${timestamp_flag[@]}" \
        --sign "$sign_identity" "$nested"
done

codesign --force --options runtime "${timestamp_flag[@]}" \
    --sign "$sign_identity" "$output_dir"
codesign --verify --strict --verbose=2 "$output_dir"

echo "Built $output_dir"
echo "  version   $short_version ($build_version), source $revision"
if [[ "$sign_identity" == "-" ]]; then
    echo "  signature ad-hoc — Screen Recording must be re-approved after every rebuild"
else
    echo "  signature $sign_identity"
fi
