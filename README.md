# MetalShade

MetalShade is a prospective, open-source macOS post-processing tool for native
Metal games. The first intended test target is Cyberpunk 2077's native Mac
build.

The Cyberpunk 2077 Steam diagnostic selected the overlay path. MetalShade is
now a menu-bar-only macOS app that captures one visible game window using
ScreenCaptureKit, processes the captured texture with Metal, and places a
click-through overlay above that window.

## Install

Requirements: macOS 14+ and Apple Silicon.

No release has been published yet. Until one is, build from source — see
[Build and run](#build-and-run). Released builds will be notarized `.zip`
archives with a published SHA-256 checksum; verify one before opening it:

```bash
shasum -a 256 -c MetalShade-<version>.zip.sha256
```

## Build and run

Additional requirement: Xcode command-line tools, plus a running target game.

```bash
./scripts/build-app.sh
open ./dist/MetalShade.app --args --bundle com.cdprojektred.cyberpunk.steam
```

`build-app.sh` produces an **ad-hoc signed** bundle. macOS keys the Screen
Recording grant to the code signature as well as the bundle identifier, and an
ad-hoc signature changes on every rebuild, so a locally built MetalShade has to
be re-approved in System Settings after each build. Pass
`--sign "Developer ID Application: …"` to sign with a stable identity instead.

On first run, grant **Screen Recording** permission to MetalShade, then quit
and relaunch it. The app captures the first visible window owned by the bundle
identifier. Its menu-bar icon is `MS`; it never appears in the Dock.

## Control panel

Choose **Control Panel…** from the menu-bar icon (or launch MetalShade without
`--bundle`) to open the window. It holds everything the shortcuts do, plus the
parts that previously had no interface at all:

- Enable or bypass effects, pick sharpening or LUT grading, set intensity.
- Brightness, contrast, saturation, and temperature sliders. These uniforms
  existed before but could only be set by importing a preset.
- A **Last import** panel listing every ReShade setting that could not be
  honoured — including a specific note for depth-based effects. Those warnings
  used to go only to the Console, so a preset could silently do almost nothing.

The window and the global shortcuts share one state object, so they cannot
drift apart.

## Adding ReShade presets and LUTs

Drag `.ini` presets and `.cube` LUTs onto the control panel's drop zone. Files
are copied into a library folder, so a preset outlives the volume it came from:

```text
~/Library/Application Support/MetalShade/Presets/   # ReShade .ini
~/Library/Application Support/MetalShade/LUTs/      # .cube
```

Both folders are watched. Dropping files into them in Finder is equivalent to
dropping them on the window — the lists update either way, and deleting a file
in Finder removes it from the app. **Presets Folder…** and **LUTs Folder…** in
the menu open them. `open -a MetalShade preset.ini` imports too.

A dropped preset applies immediately, and duplicate names are kept rather than
overwritten (`Preset 2.ini`).

What carries over from a ReShade preset is narrow. The importer reads keys only
from effects it recognises — `CAS`, `LumaSharpen`, `AdaptiveSharpen`,
`qUINT_lightroom`, `Vibrance`, `Colourfulness`, `Tonemap` — and maps them onto
sharpening, brightness, contrast, saturation, and temperature.

It refuses to guess at the rest, because ReShade key names are scoped to their
effect: `Saturation` inside `FilmicPass.fx` is an offset within a tone curve,
not a global saturation multiplier. Everything else is reported, grouped by the
effect it came from, with the reason. Depth-based effects — AO, DOF, GI, depth
fog — can never work here, whatever the preset asks for.

To see what a preset would do before importing it:

```bash
./scripts/check-preset.sh "~/Downloads/Some Preset.ini"
```

The default global shortcuts, supplied by the MIT-licensed
`KeyboardShortcuts` Swift package, do not require Accessibility permission:

- Command-Option-O — toggle effects (the capture overlay remains as a neutral
  pass-through when off, which avoids black output from some full-screen games)
- Command-Option-Right — switch between sharpening and LUT grading
- Command-Option-Up / Down — adjust effect intensity
- Command-Option-Q — quit MetalShade from anywhere. The overlay draws above the
  menu bar, so this is the reliable way out if it is ever mispositioned.

### Effects and assets

Exactly two effect shaders are included:

1. CAS-style adaptive sharpening.
2. Standard 3D `.cube` LUT colour grading.

Drop a LUT on the control panel to load it; an
[identity example](Examples/Identity.cube) is included. Shader source is
created on first run at:

```text
~/Library/Application Support/MetalShade/Shaders/MetalShadeEffects.metal
```

Save edits to this file to hot-reload both Metal pipelines. Compilation errors
leave the last valid pipeline active and are written to Console.


## Screenshots

**None yet.** MetalShade has not been validated against a running game, so
there is nothing honest to show. Before/after images will be added once real
captures exist; they will be two frames of the same scene from the actual game,
one with effects bypassed and one processed — not mock-ups and not an image
editor imitating the shader.

`./scripts/capture-screenshots.sh <cas|lut>` handles the timing and file naming
when that capture happens.

## Verifying the overlay

Overlay geometry can be checked without granting Screen Recording, which keeps
alignment problems separate from capture problems:

```bash
open -n ./dist/MetalShade.app --args --bundle com.apple.TextEdit --self-test
./scripts/validate-overlay.sh com.apple.TextEdit
```

Self-test positions the overlay over the target and draws a green border and
crosshair instead of captured frames. The validator compares the two windows
through `CGWindowList` and reports the delta:

```text
target   com.apple.TextEdit
         182,88 656x422
overlay  182,88 656x422
delta    x +0  y +0  w +0  h +0
order    overlay is in front of the target  PASS
```

Move and resize the target window and run the validator again; the delta should
stay at zero.

## Current scope and limitations

- v1 will target macOS 14+ and Apple Silicon only. This keeps the capture and
  Metal implementation focused on the ScreenCaptureKit and Metal feature set
  available on current Apple Silicon Macs.
- Whether in-process injection is possible is determined per game, per
  distribution channel, and potentially per game update. A result is not a
  permanent compatibility promise.
- An overlay implementation cannot access a game's depth buffer. Depth-based
  effects such as ambient occlusion, depth of field, and depth fog will not be
  supported in that mode.
- MetalShade will contain no telemetry and no network calls, aside from an
  optional future GitHub Releases update check.
- ScreenCaptureKit requires Screen Recording permission. Protected content,
  unusual full-screen window behaviour, HDR tone mapping, and window movement
  across displays still require per-game validation.

## Phase 0

Run the diagnostic against the actual game `.app` bundle, not a launcher
shortcut:

```bash
./scripts/check-target.sh "/path/to/Game.app"
```

See [DIAGNOSTIC.md](DIAGNOSTIC.md) for interpretation and the recorded
Cyberpunk 2077 Steam result.

## Releasing

[docs/RELEASE.md](docs/RELEASE.md) is the checklist: validation against the
real game, screenshot capture, signing, notarization, and publication.
`./scripts/package-release.sh` performs the packaging steps. Changes are
recorded in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
