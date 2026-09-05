# Changelog

All notable changes to MetalShade are recorded here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); until 1.0.0 the
minor version may carry breaking changes.

## [Unreleased]

### Added

- The capture target is chosen in the window. The panel lists games found in the
  Steam library with their architecture and injection verdict, and accepts a
  bundle identifier for anything else. Capture can be started, switched, and
  stopped without relaunching.
- Control panel window (**Control Panel…** in the menu-bar menu): effect
  selection, intensity, and the brightness/contrast/saturation/temperature
  sliders, which previously had no interface and could only be set by importing
  a preset.
- Drag-and-drop import for ReShade `.ini` presets and `.cube` LUTs, backed by a
  watched library at `~/Library/Application Support/MetalShade/{Presets,LUTs}`.
  Dropping files into those folders in Finder works identically, and removing
  one there removes it from the app. `open -a MetalShade preset.ini` imports as
  well.
- `--self-test` positions the overlay over a target window and draws a
  calibration border instead of captured frames, using `CGWindowList` only. It
  needs no Screen Recording grant, so overlay geometry can be verified
  separately from capture — the two previously failed together.
- `scripts/validate-overlay.sh` measures the overlay against its target window
  and reports the delta and stacking order, turning alignment into a
  measurement rather than an impression.
- `scripts/check-preset.sh` reports what MetalShade would take from a preset
  without launching the app, compiled against the app's own parser.
- Preset import results are grouped by effect. A real preset carries a few
  hundred keys, and one warning per key buried the handful that took effect.
- Preset import warnings are shown in the window. They previously went only to
  `NSLog`, so a preset whose settings were nearly all unsupported appeared to
  apply cleanly.
- Command-Option-Q quits MetalShade from anywhere. The overlay sits above the
  menu bar, so a misplaced one can leave nothing clickable.

### Changed

- `AppModel` is now the single source of truth for render state. The window,
  the menu, and the global shortcuts all mutate it and it pushes to
  `MetalRenderer`, so they cannot disagree about what is on screen.

### Fixed

- ReShade preset import read keys without regard to the effect they belong to.
  ReShade key names are scoped to their effect and mean different things in
  each, so `Saturation=-0.15` inside `FilmicPass.fx` — an offset within a
  filmic tone curve — was read as a global saturation multiplier, clamped to 0,
  and turned the whole image greyscale. `Contrast=0.0` inside `CAS.fx` (its
  contrast-adaptation term) was one section-ordering away from doing the same.
  The parser is now section-aware and reads keys only from effects it knows.
- The overlay was placed in the wrong coordinate space. `SCWindow.frame` is
  CoreGraphics display space (origin top-left, y downward) and was passed
  straight to `NSWindow`, which uses AppKit screen space (origin bottom-left, y
  upward). The overlay therefore appeared mirrored about the screen's centre
  line; for a window low on screen it landed on the menu bar, and because the
  overlay sits at `.screenSaver` level it covered the menu bar and left nothing
  clickable. Present since the overlay MVP.
- An `MTKView` that has not drawn yet is opaque black, so a capture that
  produced no frames — the symptom of a missing Screen Recording grant —
  covered the target window in solid black. The layer is now non-opaque and the
  overlay is not shown until a frame has actually rendered.
- `startCapture()` reports success even when no frames follow. A check now
  reports the likely cause after three seconds of silence.
- The overlay could take key focus; it is now a `.nonactivatingPanel`.
- `scripts/build-app.sh` never copied the `KeyboardShortcuts` resource bundle
  into the app. `.build/release` is a symlink and `find` does not descend
  through it, so the `-exec cp` never matched. Every bundle built before this
  change shipped with an empty `Contents/Resources` directory.

### Added

- `scripts/package-release.sh`: Developer ID signing, notarization, stapling,
  and a `ditto` archive with a SHA-256 checksum.
- `scripts/build-app.sh` now signs the app bundle (ad-hoc by default,
  `--sign <identity>` for Developer ID) with the hardened runtime enabled, and
  stamps the version from `VERSION` plus the git revision into `Info.plist`.
- `scripts/capture-screenshots.sh`: timing helper for the README's before/after
  pairs.
- `docs/RELEASE.md`: release checklist.

## [0.1.0] — unreleased

First overlay build. Not yet validated against a running game; see
`docs/RELEASE.md` for what must be confirmed before this version is tagged.

### Added

- Phase 0 diagnostic (`scripts/check-target.sh`) reporting whether a game's
  main executable can accept `DYLD_INSERT_LIBRARIES`. Recorded result for
  Cyberpunk 2077 (Steam): injection blocked, overlay path selected.
- Menu-bar-only app (`LSUIElement`) that captures one visible window by bundle
  identifier with ScreenCaptureKit and draws a click-through overlay above it.
- Two effects: CAS-style adaptive sharpening and 3D `.cube` LUT grading.
- Shader hot-reload from
  `~/Library/Application Support/MetalShade/Shaders/MetalShadeEffects.metal`,
  keeping the last valid pipeline when compilation fails.
- ReShade `.ini` preset import covering sharpening, brightness, contrast,
  saturation, and temperature, logging every unsupported setting and warning
  explicitly about depth-dependent effects.
- Global shortcuts via `KeyboardShortcuts` (Carbon hotkeys, no Accessibility
  permission): toggle effects, cycle effect, adjust intensity.
- Bypassing effects keeps the capture and overlay path live with a neutral
  shader, because some full-screen Metal games present a black surface when the
  overlay is removed.

### Known limitations

- No depth buffer is available to an overlay, so ambient occlusion, depth of
  field, and depth fog cannot be supported.
- Apple Silicon and macOS 14+ only.
- Protected content, HDR tone mapping, and moving the game window between
  displays are unvalidated.
- No telemetry and no network calls.
