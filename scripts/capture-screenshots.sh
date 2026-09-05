#!/usr/bin/env bash
# Capture the before/after pair the README publishes for an effect.
#
#   ./scripts/capture-screenshots.sh cas
#   ./scripts/capture-screenshots.sh lut --delay 8
#
# The screenshots must come from the real game with MetalShade running over it.
# This script only handles the timing and file naming; you press the toggle.
# It never synthesises or edits an image — a published before/after has to be
# two captures of the same scene, one bypassed and one processed.
#
# `screencapture` needs Screen Recording permission for the terminal running it,
# granted separately from MetalShade's own grant.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
output_dir="$project_dir/docs/images"
delay=5

effect="${1:-}"
shift || true
case "$effect" in
    cas|lut) ;;
    *) echo "usage: $(basename "$0") <cas|lut> [--delay SECONDS]" >&2; exit 2 ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --delay)
            [[ $# -ge 2 ]] || { echo "error: --delay requires a value" >&2; exit 2; }
            delay="$2"; shift 2 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

mkdir -p "$output_dir"

capture() {
    local label="$1" path="$output_dir/$effect-$label.png"
    echo "  capturing in ${delay}s…"
    # -x suppresses the shutter sound; -C excludes the cursor; -t png is explicit.
    /usr/sbin/screencapture -x -C -t png -T "$delay" "$path"
    echo "  wrote $path"
}

cat <<EOF
Capturing the '$effect' before/after pair.

Set the scene first:
  1. The game is running and MetalShade reports "Capturing …" in its menu.
  2. The camera is stationary — both frames must show the same scene.
  3. The effect is set to $effect (Command-Option-Right cycles) at the
     intensity you want to publish.

EOF

read -r -p "Press Return, then bypass effects with Command-Option-O (menu shows 'effects bypassed')… "
capture off

echo
read -r -p "Press Return, then enable effects with Command-Option-O… "
capture on

cat <<EOF

Done. Check both files: the scene must be identical apart from the effect.
Recapture if the camera drifted, an HUD element changed, or a cutscene advanced.

Reference them from README.md as:
  ![$effect off](docs/images/$effect-off.png)
  ![$effect on](docs/images/$effect-on.png)
EOF
