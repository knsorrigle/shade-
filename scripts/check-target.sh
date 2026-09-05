#!/usr/bin/env bash
# MetalShade Phase 0 signing diagnostic.
#
# Usage: ./scripts/check-target.sh /path/to/Game.app
#
# This script only reads signing metadata and bundle layout. It does not launch,
# modify, inject into, or otherwise alter the target application.

set -u

usage() {
  echo "Usage: $(basename "$0") /path/to/Game.app" >&2
  exit 64
}

[ "$#" -eq 1 ] || usage

input_path="$1"
[ -d "$input_path" ] || {
  echo "ERROR: app bundle not found: $input_path" >&2
  exit 66
}

app_path="$(cd "$input_path" && pwd -P)"
info_plist="$app_path/Contents/Info.plist"
[ -f "$info_plist" ] || {
  echo "ERROR: not a macOS app bundle (missing Contents/Info.plist): $app_path" >&2
  exit 65
}

executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null || true)"
[ -n "$executable_name" ] || {
  echo "ERROR: CFBundleExecutable is missing from $info_plist" >&2
  exit 65
}

binary_path="$app_path/Contents/MacOS/$executable_name"
[ -f "$binary_path" ] || {
  echo "ERROR: main executable not found: $binary_path" >&2
  exit 65
}

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/metalshade-signing.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT
detail_file="$scratch_dir/codesign-detail.txt"
entitlements_file="$scratch_dir/entitlements.txt"

codesign -d -vvv "$binary_path" >"$detail_file" 2>&1 || true
codesign -d --entitlements :- "$binary_path" >"$entitlements_file" 2>&1 || true

detail_text="$(<"$detail_file")"
entitlements_text="$(<"$entitlements_file")"

if printf '%s\n' "$detail_text" | grep -q 'flags=.*runtime'; then
  hardened_runtime="enabled"
elif printf '%s\n' "$detail_text" | grep -q 'code object is not signed'; then
  hardened_runtime="unknown (main executable is unsigned)"
else
  hardened_runtime="not detected"
fi

if printf '%s\n' "$entitlements_text" | grep -q 'invalid entitlements blob'; then
  entitlements_status="invalid (macOS will ignore them)"
elif printf '%s\n' "$entitlements_text" | grep -q 'code object is not signed'; then
  entitlements_status="unavailable (main executable is unsigned)"
else
  entitlements_status="readable or empty"
fi

if [ "$entitlements_status" = "readable or empty" ] && printf '%s\n' "$entitlements_text" | grep -A 1 -F 'com.apple.security.cs.disable-library-validation' | grep -q '<true/>'; then
  library_validation="DISABLED by entitlement"
  library_validation_disabled=true
else
  library_validation="not disabled"
  library_validation_disabled=false
fi

if [ "$entitlements_status" = "readable or empty" ] && printf '%s\n' "$entitlements_text" | grep -A 1 -F 'com.apple.security.app-sandbox' | grep -q '<true/>'; then
  sandbox="yes"
else
  sandbox="no or not declared"
fi

team_id="$(sed -n 's/^TeamIdentifier=//p' "$detail_file" | head -n 1)"
[ -n "$team_id" ] || team_id="unavailable"

if [ -e "$app_path/Contents/_MASReceipt/receipt" ]; then
  distribution="Mac App Store (receipt present)"
elif printf '%s\n' "$app_path" | grep -qi '/steamapps/'; then
  distribution="Steam/direct distribution layout (Steam library path; no MAS receipt)"
elif find "$(dirname "$app_path")" -maxdepth 2 -name 'goggame-*.info' -print -quit 2>/dev/null | grep -q .; then
  distribution="GOG/direct distribution layout (GOG metadata; no MAS receipt)"
else
  distribution="Direct distribution / unknown store (Contents/MacOS present; no MAS receipt)"
fi

if [ "$hardened_runtime" = "enabled" ] && [ "$library_validation_disabled" = false ]; then
  verdict="INJECTION BLOCKED — use overlay"
  reason="Hardened Runtime is enabled and no effective disable-library-validation entitlement was found."
elif [ "$hardened_runtime" = "enabled" ] && [ "$library_validation_disabled" = true ]; then
  verdict="INJECTION VIABLE"
  reason="The target opts out of Library Validation. Other protections and game updates can still prevent a hook from working."
else
  verdict="PARTIAL — differs by distribution channel or requires manual verification"
  reason="The main executable is unsigned or its signing state could not be established from this bundle."
fi

printf '%s\n' 'MetalShade target diagnostic'
printf '%s\n' "App bundle: $app_path"
printf '%s\n' "Main executable: $binary_path"
printf '%s\n' "Hardened Runtime: $hardened_runtime"
printf '%s\n' "Entitlements: $entitlements_status"
printf '%s\n' "Library Validation: $library_validation"
printf '%s\n' "Team ID: $team_id"
printf '%s\n' "App Sandbox: $sandbox"
printf '%s\n' "Distribution: $distribution"
printf '\nVERDICT: %s\n%s\n' "$verdict" "$reason"

printf '\n-- codesign -d -vvv (raw) --\n%s\n' "$detail_text"
printf '\n-- codesign -d --entitlements :- (raw) --\n%s\n' "$entitlements_text"
