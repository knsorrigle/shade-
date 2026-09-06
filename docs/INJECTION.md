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

## Running it from MetalShade

Injection is a MetalShade feature, not a separate tool. The payload ships inside
`MetalShade.app`, and any detected game whose signature permits injection shows
a **Launch injected** button in the control panel. MetalShade starts the game
with the payload loaded, and intensity and tint then apply **live** — the
launch environment cannot change while a game runs, so the app writes
`~/Library/Application Support/MetalShade/inject-settings.json` and the payload
polls it.

Injection and the overlay are alternative routes to the same picture. Starting
an injected session stops any capture first; running both would process the
frame twice.

## Running it from the command line

```bash
./scripts/inject.sh "/path/to/Game.app"
```

The script refuses to launch when the target's signature would ignore the
payload, rather than starting a silent no-op. Output goes to
`~/Library/Application Support/MetalShade/inject.log`.

For a Steam game, Steam's own launch options keep Steam starting the game the way
it expects (overlay, cloud saves, playtime).

**macOS Steam does not run launch options through a shell.** The
`VAR=value %command%` form that works on Linux fails here: Steam tries to
execute `VAR=value` as the program and reports *Failed to start process for this
game : OS Error 260*. Put `/usr/bin/env` first, so the program Steam launches is
a real executable:

```text
/usr/bin/env DYLD_INSERT_LIBRARIES=/absolute/path/to/libMetalShadeInject.dylib %command%
```

With an effect enabled:

```text
/usr/bin/env METALSHADE_TINT=1 DYLD_INSERT_LIBRARIES=/absolute/path/to/libMetalShadeInject.dylib %command%
```

Right-click the game in Steam → Properties → Launch Options. Use an absolute
path; `~` is not expanded, because no shell is involved.

If that still fails, launch the game directly instead — this works with the
Steam client running, which is enough for Steam's own checks:

```bash
./scripts/inject.sh "$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app"
```

The trade is that Steam does not see the session: no in-game overlay, no
playtime, no automatic cloud-save sync.

## Which games this works for

The hooks are generic rather than per-game:

- `-[CAMetalLayer nextDrawable]` is how every Metal application on macOS obtains
  a frame to draw into, including games built on MoltenVK, which translates
  Vulkan to Metal and still presents through this layer.
- `presentDrawable:` is declared by the `MTLCommandBuffer` protocol; the
  concrete class is private and varies by GPU driver, so it is discovered at
  runtime from a command buffer created on the same device rather than
  hardcoded. On this machine it resolves to `AGXG16GFamilyCommandBuffer`.

Two things do vary per game:

| Requirement | Consequence if unmet |
|---|---|
| The signature permits injection | Fall back to the overlay; `scripts/check-target.sh` reports which |
| Architecture matches the payload | The library cannot load at all |

The second is easy to miss. Many Mac ports are x86_64 running under Rosetta, and
an arm64-only library cannot load into an x86_64 process. `build-payload.sh`
produces a universal binary covering both, and `inject.sh` compares the target's
architecture against the payload's and refuses rather than failing silently.

## Settings

Configured by environment variable, so a Steam launch option can set them
without a rebuild and a bad setting can be removed without touching the game:

| Variable | Effect |
|---|---|
| `METALSHADE_INTENSITY` | Sharpening strength, `0`–`1`. Default `0`. |
| `METALSHADE_TINT` | `1` paints frames green, to confirm processing is live. |

**Both default to off, so injecting alone changes nothing.** The hooks install
and observe; processing happens only when asked for. A fault while processing
disables it and lets the unmodified frame through rather than taking the game
down.

```text
METALSHADE_TINT=1 DYLD_INSERT_LIBRARIES=/path/to/libMetalShadeInject.dylib %command%
```

## Current state

The payload loads, hooks both entry points, and encodes a post-process pass into
the game's own command buffer before presentation: the frame is copied to a
scratch texture (a texture cannot be read and written in one pass) and rendered
back through a sharpening shader that mirrors the overlay's.

Verified in Cyberpunk 2077, by reading a pixel back from the presented drawable
rather than inferring from the fact that the code ran:

```text
hooked -[CAMetalLayer nextDrawable]
hooked -[AGXG16GFamilyCommandBuffer presentDrawable:]
first frame processed in the game's command buffer
centre pixel after processing: B=0 G=191 R=0 A=255
```

Not yet measured: frame rate and pacing across a real play session, which is the
question injection exists to answer — the overlay collapsed to single-digit fps
on this game.

Depth-based effects remain out of reach. The depth texture is available inside
the process, but identifying which texture it is means reading a specific game's
render graph, and that is per-game work that breaks with patches.

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
