# MetalShade

MetalShade is a prospective, open-source macOS post-processing tool for native
Metal games. The first intended test target is Cyberpunk 2077's native Mac
build.

This repository currently contains **Phase 0 only**: a signing and runtime
diagnostic. Phase 1 is deliberately not scaffolded until the diagnostic has
been run on the target installation.

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
- Once effects exist, the README will include a before/after screenshot for
  every effect.

## Phase 0

Run the diagnostic against the actual game `.app` bundle, not a launcher
shortcut:

```bash
./scripts/check-target.sh "/path/to/Game.app"
```

See [DIAGNOSTIC.md](DIAGNOSTIC.md) for interpretation and the recorded
Cyberpunk 2077 Steam result.

## License

MIT. See [LICENSE](LICENSE).
