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
payload="$project_dir/dist/libMetalShadeInject.dylib"

tint=0
intensity=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tint) tint=1; shift ;;
        --intensity)
            [[ $# -ge 2 ]] || { echo "error: --intensity needs a value 0-1" >&2; exit 2; }
            intensity="$2"; shift 2 ;;
        --) shift; break ;;
        -*) echo "error: unknown option '$1'" >&2; exit 2 ;;
        *) break ;;
    esac
done

if [[ $# -lt 1 ]]; then
    cat >&2 <<'USAGE'
usage: inject.sh [--tint] [--intensity 0-1] <Game.app | executable> [args...]

  --tint            paint frames green, to confirm processing is live
  --intensity N     sharpening strength, 0 to 1

Effects are off unless asked for, so injecting alone changes nothing.
USAGE
    exit 2
fi

target="$1"; shift

if [[ ! -f "$payload" ]]; then
    echo "==> Building the payload"
    "$project_dir/scripts/build-payload.sh"
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

# An arm64-only payload cannot load into an x86_64 process, and many Mac ports
# are x86_64 under Rosetta.
target_arch="$(file "$executable" 2>/dev/null | grep -o 'x86_64\|arm64' | head -1 || true)"
payload_archs="$(lipo -archs "$payload" 2>/dev/null || echo unknown)"
if [[ -n "$target_arch" ]] && ! grep -q -- "$target_arch" <<<"$payload_archs"; then
    echo "error: the target is $target_arch but the payload provides: $payload_archs" >&2
    echo "       Rebuild both architectures with ./scripts/build-payload.sh" >&2
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

settings=()
[[ "$tint" == "1" ]] && settings+=("METALSHADE_TINT=1")
[[ -n "$intensity" ]] && settings+=("METALSHADE_INTENSITY=$intensity")

echo "==> Payload: $payload"
if [[ ${#settings[@]} -eq 0 ]]; then
    echo "==> Effects: none — the payload will load and hook but change nothing."
    echo "    Add --tint or --intensity N to see an effect."
else
    echo "==> Effects: ${settings[*]}"
fi
echo "==> Launching: $executable"
echo "    Log: ~/Library/Application Support/MetalShade/inject.log"
exec env "${settings[@]}" DYLD_INSERT_LIBRARIES="$payload" "$executable" "$@"
