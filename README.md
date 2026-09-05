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

The default global shortcuts, supplied by the MIT-licensed
`KeyboardShortcuts` Swift package, do not require Accessibility permission:

- Command-Option-O — toggle effects (the capture overlay remains as a neutral
  pass-through when off, which avoids black output from some full-screen games)
- Command-Option-Right — switch between sharpening and LUT grading
- Command-Option-Up / Down — adjust effect intensity

### Effects and assets

Exactly two effect shaders are included:

1. CAS-style adaptive sharpening.
2. Standard 3D `.cube` LUT colour grading.

Choose **Load .cube LUT…** from the status menu to load a LUT; an
[identity example](Examples/Identity.cube) is included. Shader source is
created on first run at:

```text
~/Library/Application Support/MetalShade/Shaders/MetalShadeEffects.metal
```

Save edits to this file to hot-reload both Metal pipelines. Compilation errors
leave the last valid pipeline active and are written to Console.

**Import ReShade preset…** accepts `.ini` files, applies only sharpening plus
brightness, contrast, saturation, and temperature, and logs every unsupported
setting. It specifically warns when skipping depth-dependent effects such as
AO, DOF, or depth fog.

## Screenshots

**None yet.** MetalShade has not been validated against a running game, so
there is nothing honest to show. Before/after images will be added once real
captures exist; they will be two frames of the same scene from the actual game,
one with effects bypassed and one processed — not mock-ups and not an image
editor imitating the shader.

`./scripts/capture-screenshots.sh <cas|lut>` handles the timing and file naming
when that capture happens.

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
