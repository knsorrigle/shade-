# MetalShade

MetalShade is an open-source macOS post-processing tool for native Metal games.
It detects installed games, works out which techniques each one actually
permits, and applies effects by whichever route that game allows.

It is a menu-bar-only app. It finds installed games, reports which route each
one permits, and applies effects by that route.

## Methods

Different games permit different things, and MetalShade reports which, per
game, rather than assuming.

| Method | How it works | Depth-based effects | Status |
|---|---|---|---|
| **Injection** | `DYLD_INSERT_LIBRARIES` loads a payload that hooks the game's Metal presentation and encodes effects into the game's own command buffer | Not yet — see below | **Works**; preferred where the signature permits it |
| **Overlay** | ScreenCaptureKit captures the window; Metal processes it; a click-through window draws the result | No — the depth buffer is gone before capture | **Works**; the fallback for games that cannot load a library |
| **Estimated depth** | A monocular depth model over the frame synthesises an approximate depth buffer | Approximate; soft and temporally unstable | Not implemented |

Both routes have been confirmed on Cyberpunk 2077 by reading pixels back from
the presented frame rather than by eye.

**Prefer injection where it is available.** An overlay above a full-screen game
forces it out of direct-to-display scanout, and on Cyberpunk 2077 that collapsed
the game to single-digit frame rates. Injection adds one pass inside a pipeline
that was already running: no capture, no second copy of the frame, no extra
compositing.

### Depth

Neither working route can reach a depth buffer, so ambient occlusion, depth of
field, and depth fog are out of scope — not omitted, but unavailable.

Both hook at presentation, and by then the game has discarded its depth buffer:
it exists only as an intermediate during the render pass, used for the game's own
lighting and effects, and is gone by the time a finished colour image reaches the
screen. Reaching it would mean hooking inside the render pass and identifying
which of the many textures a frame binds is depth — per-game reverse engineering
that a patch can invalidate.

Whether injection is possible is a property of the game's code signature, and
it varies. On one machine's Steam library:

```text
Cyberpunk 2077            arm64             injection possible — library validation disabled
Rise of the Tomb Raider   x86_64 (Rosetta)  injection possible — executable is unsigned
```

Run the diagnostic yourself with [`scripts/check-target.sh`](scripts/check-target.sh);
see [DIAGNOSTIC.md](DIAGNOSTIC.md) for how to read it. **Re-run it after any
game update, and never trust a verdict taken from a bundle that may still be
downloading** — that produces a false negative, as recorded in that file.

## Scope: single-player only

Do not point MetalShade at a multiplayer game. Injecting code into a process,
and in some cases overlaying it, is what anti-cheat systems exist to detect,
and the consequence falls on the player's account rather than on this project.
The intended targets are single-player titles.

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
open -n ./dist/MetalShade.app
```

No launch flags are needed. The control panel lists the games it finds and takes
a bundle identifier for anything else; pick a target there and capture starts.

Use `open -n`, not plain `open`. When an instance is already running, `open`
activates that one instead of starting a new process, which is why passing a
target on the command line was unreliable.

`build-app.sh` produces an **ad-hoc signed** bundle. macOS keys the Screen
Recording grant to the code signature as well as the bundle identifier, and an
ad-hoc signature changes on every rebuild, so a locally built MetalShade has to
be re-approved in System Settings after each build. Pass
`--sign "Developer ID Application: …"` to sign with a stable identity instead.

On first run, grant **Screen Recording** permission to MetalShade, then quit
and relaunch it. The app captures the first visible window owned by the bundle
identifier. Its menu-bar icon is `MS`; it never appears in the Dock.

## Running a game with injection

Open MetalShade and press **Launch injected** next to a detected game whose
signature permits it. MetalShade starts the game with its payload loaded, and
every effect then applies **live** — the launch environment is fixed once a game
starts, so the app writes a settings file the payload polls.

Adjust with the global shortcuts while playing. Clicking the control panel takes
focus from the game, and most games pause when that happens:

```text
⌘⌥↑ / ⌘⌥↓   intensity      ⌘⌥→   effect
⌘⌥O          bypass         ⌘⌥Q   quit
```

Injection and the overlay are alternatives, not layers. Starting an injected
session stops any capture first; running both would process every frame twice.

[docs/INJECTION.md](docs/INJECTION.md) covers the entitlements a game needs, the
Steam launch-options form, running from the command line, and the cautions —
single-player only, back up saves, re-check after a game update.

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

### Effects

All of these are colour operations on a finished frame, which is what makes them
reproducible without depth. **Both routes compile the same file**,
[`Sources/MetalShade/Resources/EffectChain.metal`](Sources/MetalShade/Resources/EffectChain.metal),
so an edit reaches whichever route a game happens to use.

| Stage | |
|---|---|
| Sharpen | contrast-adaptive, so edges do not ring |
| Clarity | wide-radius unsharp on luminance — lifts midtone structure rather than edges |
| Bloom | bright pass plus separable Gaussian at quarter resolution |
| Filmic tone | Uncharted 2 curve, normalised so white stays white |
| Exposure, gamma, vibrance | |
| Brightness, contrast, saturation, temperature | |
| 3D `.cube` LUT | |

Nothing is encoded at all when every stage is neutral, so an idle session costs
the game nothing.


Drop a LUT on the control panel to load it; an
[identity example](Examples/Identity.cube) is included. Shader source is
created on first run at:

```text
~/Library/Application Support/MetalShade/Shaders/EffectChain.metal
```

Save edits to this file to hot-reload both Metal pipelines. Compilation errors
leave the last valid pipeline active and are written to Console.


## Screenshots

**None yet.** Both routes have been confirmed working on Cyberpunk 2077 by
reading pixels back from the presented frame, but no before/after pair has been
captured. Before/after images will be added once real
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
- Neither working route can access a game's depth buffer, so ambient occlusion,
  depth of field, and depth fog are unavailable. Both hook at presentation,
  after the game has discarded depth.
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
