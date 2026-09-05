# Changelog

All notable changes to MetalShade are recorded here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); until 1.0.0 the
minor version may carry breaking changes.

## [Unreleased]

### Added

- Control panel window (**Control Panel…** in the menu-bar menu): effect
  selection, intensity, and the brightness/contrast/saturation/temperature
  sliders, which previously had no interface and could only be set by importing
  a preset.
- Drag-and-drop import for ReShade `.ini` presets and `.cube` LUTs, backed by a
  watched library at `~/Library/Application Support/MetalShade/{Presets,LUTs}`.
  Dropping files into those folders in Finder works identically, and removing
  one there removes it from the app. `open -a MetalShade preset.ini` imports as
  well.
- Preset import warnings are shown in the window. They previously went only to
  `NSLog`, so a preset whose settings were nearly all unsupported appeared to
  apply cleanly.

### Changed

- `AppModel` is now the single source of truth for render state. The window,
  the menu, and the global shortcuts all mutate it and it pushes to
  `MetalRenderer`, so they cannot disagree about what is on screen.

### Fixed

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
