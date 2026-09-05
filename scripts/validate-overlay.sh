#!/usr/bin/env bash
# Measure MetalShade's overlay against the window it is meant to cover.
#
#   ./scripts/validate-overlay.sh com.apple.TextEdit
#
# Run it while MetalShade is overlaying that target. Works in --self-test mode
# too, so alignment can be checked without the Screen Recording grant.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"

if [[ $# -lt 1 ]]; then
    echo "usage: $(basename "$0") <target-bundle-id>" >&2
    exit 2
fi

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

swiftc -O "$project_dir/scripts/overlay-check/main.swift" -o "$build_dir/overlay-check"
"$build_dir/overlay-check" "$@"
