# Injection

Injection loads MetalShade's code into the game's own process and works on the
frame the game is about to present. Nothing is captured, nothing is composited
on top, and the game keeps its direct-to-display path — which is why it does not
carry the cost that makes the overlay expensive on a full-screen game.

It is also the only route that could ever reach a depth buffer, since the depth
texture never leaves the process.

## What has to be true

`DYLD_INSERT_LIBRARIES` is honoured only when the target permits it:

| Target | Loads? | Why |
|---|---|---|
| Unsigned executable | yes | nothing enforces library validation |
| Signed, no hardened runtime | yes | same |
| Hardened runtime | **only** with both entitlements below | |

```text
com.apple.security.cs.disable-library-validation
com.apple.security.cs.allow-dyld-environment-variables
```

Both are required. A hardened process ignores `DYLD_*` without the second one,
which is the easier of the two to overlook.

`./scripts/check-target.sh "/path/to/Game.app"` reports which case applies, and
the control panel shows the same verdict for every game it finds.

Verified on this machine:

| Game | Verdict |
|---|---|
| Cyberpunk 2077 (Steam) | hardened, declares both entitlements — injection permitted |
| Rise of the Tomb Raider (Steam) | unsigned x86_64 under Rosetta — nothing to enforce |

## Running it

```bash
./scripts/inject.sh "/path/to/Game.app"
```

The script refuses to launch when the target's signature would ignore the
payload, rather than starting a silent no-op. Output goes to
`~/Library/Application Support/MetalShade/inject.log`.

For a Steam game, prefer Steam's own launch options so Steam starts the game the
way it expects (overlay, cloud saves, playtime):

```text
DYLD_INSERT_LIBRARIES=/absolute/path/to/libMetalShadeInject.dylib %command%
```

Right-click the game in Steam → Properties → Launch Options.

## Current state

The payload loads, reports the Metal device, and intercepts
`-[CAMetalLayer nextDrawable]` so the drawable the game is about to render into
can be identified. **It does not yet modify anything.**

That boundary is deliberate. Hooking a shipping renderer can crash the game or
corrupt a frame, and the next step — inserting a post-process pass before
presentation — needs the drawable's texture copied to scratch and rendered back
through MetalShade's shaders. Doing that blind, inside a game holding a save
file, is not worth the risk of skipping a stage.

## Cautions

- **Single-player only.** Injecting into a multiplayer game is what anti-cheat
  exists to detect, and the consequence lands on the player's account.
- **Back up saves** before running an injected session.
- A game update can change everything here: re-run `check-target.sh` afterwards,
  since entitlements are a property of each build.
- Launching the executable directly bypasses Steam. Some titles expect to be
  started by their launcher; use the launch-options route if the game misbehaves.
- Nothing here modifies the game on disk. The payload lives in this project and
  is loaded at launch, so removing it is a matter of not passing the variable.
