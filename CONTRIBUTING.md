# Contributing to MetalShade

Thanks for looking. MetalShade is MIT-licensed; contributions are welcome under
the same terms.

## Before anything else: what this project will not claim

MetalShade makes statements about what it can and cannot do to a game's image.
Those statements have to be true, because a user cannot easily check them.

- **Never fabricate a before/after screenshot.** A published comparison must be
  two real captures of the same scene, one bypassed and one processed. See
  `scripts/capture-screenshots.sh`.
- **Never silently drop a setting.** If an imported preset asks for something
  that cannot be reproduced, say so, grouped and with the reason. An overlay
  has no depth buffer; a preset built around ambient occlusion will mostly not
  work, and the UI must not imply otherwise.
- **Never record a diagnostic verdict you cannot reproduce.** The Cyberpunk
  2077 entry in `DIAGNOSTIC.md` was a false negative taken from a bundle that
  was still downloading, and it redirected the whole project for a while.

## Getting set up

Requirements: macOS 14+, Apple Silicon, Xcode command-line tools.

```bash
./scripts/build-app.sh
open -n ./dist/MetalShade.app --args --bundle com.apple.TextEdit --self-test
```

`--self-test` draws a calibration overlay and runs no shader, so it needs no
Screen Recording grant. It is the fastest way to check overlay geometry.

## Verifying a change

There is no test target yet; verification is through the scripts:

| Script | Checks |
|---|---|
| `scripts/validate-overlay.sh <bundle-id>` | overlay alignment and stacking against the target window |
| `scripts/check-preset.sh <preset.ini>` | what the importer takes from a preset, and what it skips |
| `scripts/check-target.sh <Game.app>` | whether a game's signature permits injection |

Run `validate-overlay.sh` after touching anything in `OverlayWindow`,
`CaptureController`, or `ScreenGeometry`. Overlay geometry has broken silently
before: `SCWindow.frame` is CoreGraphics space (origin top-left, y downward)
and `NSWindow` is AppKit space (origin bottom-left, y upward), and mixing them
puts the overlay on the menu bar where it covers everything and cannot be
dismissed. `⌘⌥Q` quits from anywhere if that happens.

A test target would be a genuinely useful contribution. It needs the sources
split into a library target with a thin executable on top, because SwiftPM
cannot `@testable import` an executable target cleanly on macOS.

## Scope

Single-player games only. Do not add support that targets multiplayer titles or
that works around anti-cheat; the cost of that lands on users' accounts.

Effects that need a depth buffer cannot work in overlay mode. Proposals for
them belong with the injection or estimated-depth methods described in the
README, not as overlay shaders.

## Commit messages

Say what changed and why it was wrong before. If a change fixes a bug, describe
the failure it produced, not just the mechanism — the history is the only
record of what this project has already got wrong.
