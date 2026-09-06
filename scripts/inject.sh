#!/usr/bin/env bash
# Launch a target with the MetalShade payload loaded.
#
#   ./scripts/inject.sh "/path/to/Game.app"
#   ./scripts/inject.sh /path/to/executable
#
# Checks first whether the target's signature permits DYLD_INSERT_LIBRARIES, and
# refuses rather than launching into a silent no-op when it does not.
#
# For a Steam game, prefer Steam's own launch options so Steam starts the game
# normally — see docs/INJECTION.md.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
payload="$project_dir/.build/release/libMetalShadeInject.dylib"

if [[ $# -lt 1 ]]; then
    echo "usage: $(basename "$0") <Game.app | executable> [args...]" >&2
    exit 2
fi

target="$1"; shift

if [[ ! -f "$payload" ]]; then
    echo "==> Building the payload"
    (cd "$project_dir" && swift build -c release --product MetalShadeInject)
fi

# Resolve an .app bundle to its main executable.
if [[ -d "$target" && "$target" == *.app ]]; then
    name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$target/Contents/Info.plist")"
    executable="$target/Contents/MacOS/$name"
else
    executable="$target"
fi

if [[ ! -x "$executable" ]]; then
    echo "error: $executable is not executable" >&2
    exit 1
fi

signing="$(codesign -d -vvv "$executable" 2>&1 || true)"
entitlements="$(codesign -d --entitlements :- "$executable" 2>&1 || true)"

if grep -q "not signed at all" <<<"$signing"; then
    echo "==> Target is unsigned; nothing enforces library validation."
elif ! grep -q "runtime" <<<"$signing"; then
    echo "==> Target has no hardened runtime; nothing enforces library validation."
else
    missing=()
    grep -q "disable-library-validation" <<<"$entitlements" || missing+=("disable-library-validation")
    grep -q "allow-dyld-environment-variables" <<<"$entitlements" || missing+=("allow-dyld-environment-variables")
    if [[ ${#missing[@]} -gt 0 ]]; then
        cat >&2 <<MSG
error: this target will not load an injected library.

It uses the hardened runtime and lacks: ${missing[*]}

A hardened process ignores DYLD_* variables without
allow-dyld-environment-variables, and refuses third-party libraries without
disable-library-validation. Both are required. Use the overlay for this game.
MSG
        exit 1
    fi
    echo "==> Target is hardened but permits injection."
fi

echo "==> Payload: $payload"
echo "==> Launching: $executable"
echo "    Log: ~/Library/Application Support/MetalShade/inject.log"
exec env DYLD_INSERT_LIBRARIES="$payload" "$executable" "$@"
