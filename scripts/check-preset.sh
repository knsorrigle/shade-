#!/usr/bin/env bash
# Report what MetalShade would take from a ReShade preset, without launching it.
#
#   ./scripts/check-preset.sh "~/Downloads/Some Preset.ini"
#
# Useful before importing: it shows which settings map onto the overlay's
# sharpening and colour uniforms, and groups everything it has to skip by the
# effect it came from.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"

if [[ $# -lt 1 ]]; then
    echo "usage: $(basename "$0") <preset.ini>" >&2
    exit 2
fi

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

swiftc -O \
    "$project_dir/Sources/MetalShade/ReShadePreset.swift" \
    "$project_dir/scripts/preset-report/main.swift" \
    -o "$build_dir/preset-report"

"$build_dir/preset-report" "$@"
