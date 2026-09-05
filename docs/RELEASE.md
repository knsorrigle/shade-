# Release checklist

MetalShade is distributed as a notarized `.zip` containing `MetalShade.app`.
Work through this list in order; the gates near the top are the ones that make
a build shareable rather than merely built.

## 1. Prerequisites (one time)

A **Developer ID Application** certificate is required. Without one, macOS
Gatekeeper blocks the app on every Mac except the one that built it, and the
Apple notary service will not accept the submission.

```bash
security find-identity -v -p codesigning
```

If that prints `0 valid identities found`, there is nothing to sign with. A
Developer ID certificate comes from a paid Apple Developer Program membership;
it cannot be substituted with an ad-hoc or self-signed certificate.

Store notary credentials once:

```bash
xcrun notarytool store-credentials metalshade \
    --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

Then, per shell:

```bash
export METALSHADE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
export METALSHADE_NOTARY_PROFILE="metalshade"
```

## 2. Validate against the real game

A release must not be cut from an unvalidated overlay.

Two checks are automated and need no Screen Recording grant, because they use
`CGWindowList` rather than capture. Run them first — they isolate overlay
geometry from whether capture works, which previously failed together and made
the cause hard to see:

```bash
open -n ./dist/MetalShade.app --args --bundle <bundle-id> --self-test
./scripts/validate-overlay.sh <bundle-id>
```

Self-test draws a green calibration border where the overlay would be. The
validator reports the delta between overlay and target, and whether the overlay
is in front. Move and resize the target window, then run the validator again.

- [ ] `validate-overlay.sh` reports PASS with zero delta.
- [ ] It still reports PASS after moving and resizing the target window.

Then, against the running game, confirm that:

- [ ] MetalShade's menu reports `Capturing <bundle-id>` rather than an error.
- [ ] `validate-overlay.sh` still passes with capture running, not only in
      self-test mode.
- [ ] The overlay stays aligned when the window moves across displays.
- [ ] The overlay is click-through: input reaches the game, not the overlay.
- [ ] Sharpening and LUT grading both visibly change the image.
- [ ] Command-Option-O bypasses effects without producing a black screen.
- [ ] Frame pacing is acceptable — the overlay does not add visible latency.
- [ ] Quitting MetalShade leaves the game rendering normally.

Record anything that fails in `CHANGELOG.md` under known limitations rather
than leaving it undocumented.

## 3. Capture the before/after screenshots

The README publishes one before/after pair per effect. These have to be real
captures of the same scene from the running game — never a mock-up, a stock
image, or a filter applied in an image editor. A fabricated comparison would
misrepresent what the software does.

```bash
./scripts/capture-screenshots.sh cas
./scripts/capture-screenshots.sh lut
```

The helper handles timing and naming; you press the toggle. Note that
`screencapture` needs its own Screen Recording grant for the terminal.

- [ ] `docs/images/cas-off.png` and `docs/images/cas-on.png`
- [ ] `docs/images/lut-off.png` and `docs/images/lut-on.png`
- [ ] Each pair shows the same scene, differing only by the effect.
- [ ] README references them and the placeholder note is removed.

## 4. Version and changelog

- [ ] Bump `VERSION`.
- [ ] Move the `Unreleased` section of `CHANGELOG.md` under the new version
      with today's date.
- [ ] Commit. `package-release.sh` refuses to run on a dirty tree, so the
      shipped `Info.plist` records a clean revision.

## 5. Package

```bash
./scripts/package-release.sh
```

This signs with the hardened runtime, verifies, archives with `ditto`,
notarizes, staples the ticket, re-archives, runs a Gatekeeper assessment, and
writes a SHA-256 checksum next to the `.zip`.

- [ ] `spctl --assess` reports `accepted`.
- [ ] `dist/MetalShade-<version>.zip` and its `.sha256` exist.

## 6. Verify on a clean machine

Notarization is not the same as working. On a Mac that has never built this
project:

- [ ] Unzip and launch; the app opens without a Gatekeeper warning.
- [ ] Granting Screen Recording once is enough — it survives a relaunch.

## 7. Publish

- [ ] Tag: `git tag -a v<version> -m "MetalShade v<version>" && git push --tags`
- [ ] Create the GitHub release, attach the `.zip` and `.sha256`, and paste the
      changelog section as the release notes.
- [ ] State plainly in the release notes which games the build was validated
      against, and that overlay-mode effects cannot use depth.

## Signing and the Screen Recording grant

macOS keys the Screen Recording (TCC) grant to the bundle identifier *and* the
code signature. An ad-hoc signature changes on every rebuild, so a locally
built MetalShade must be re-approved in System Settings each time. A stable
Developer ID signature keeps the grant across updates — which is the main
practical reason releases are signed rather than merely zipped.
