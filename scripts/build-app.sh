#!/usr/bin/env bash
# Build a local, unsigned development app bundle. Distribution signing and
# notarization belong in a later release pipeline.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
output_dir="$project_dir/dist/MetalShade.app"

cd "$project_dir"
swift build -c release

rm -rf "$output_dir"
mkdir -p "$output_dir/Contents/MacOS" "$output_dir/Contents/Resources"
cp Resources/Info.plist "$output_dir/Contents/Info.plist"
cp .build/release/MetalShade "$output_dir/Contents/MacOS/MetalShade"

# KeyboardShortcuts ships localization resources in a SwiftPM bundle.
find .build/release -maxdepth 1 -name 'KeyboardShortcuts_KeyboardShortcuts.bundle' -exec cp -R {} "$output_dir/Contents/Resources/" \;

echo "Built $output_dir"
