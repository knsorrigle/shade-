#!/usr/bin/env bash
# Build the injection payload as a universal binary.
#
#   ./scripts/build-payload.sh
#
# Both architectures are required for broad game support: an arm64-only library
# cannot load into an x86_64 process, and many Mac ports are x86_64 running
# under Rosetta. Rise of the Tomb Raider is one.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$project_dir"

output="$project_dir/dist/libMetalShadeInject.dylib"
mkdir -p "$(dirname "$output")"

swift build -c release --arch arm64 --arch x86_64 --product MetalShadeInject

built="$project_dir/.build/apple/Products/Release/libMetalShadeInject.dylib"
[[ -f "$built" ]] || { echo "error: expected $built" >&2; exit 1; }
cp "$built" "$output"

# Library validation is disabled in the targets that accept this, so an ad-hoc
# signature is sufficient. Signing at all matters: arm64 code must be signed to
# execute.
codesign --force --sign - "$output"

echo "Built $output"
lipo -archs "$output" | sed 's/^/  architectures: /'
