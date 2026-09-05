# Phase 0 diagnostic

`scripts/check-target.sh` determines whether a game's **main executable** can
plausibly accept a library injected via `DYLD_INSERT_LIBRARIES`. It is a
diagnostic, not an injection tool: it reads bundle metadata and `codesign`
output only.

## Run it

```bash
chmod +x scripts/check-target.sh
./scripts/check-target.sh "/path/to/Game.app"
```

Always supply the actual game bundle. Launchers can masquerade as an `.app`
but contain only an unsigned shell script that opens the game through Steam.

The script resolves `CFBundleExecutable` from `Contents/Info.plist` and
inspects `Contents/MacOS/<CFBundleExecutable>` using these commands:

```bash
codesign -d -vvv "/path/to/Game.app/Contents/MacOS/<CFBundleExecutable>"
codesign -d --entitlements :- "/path/to/Game.app/Contents/MacOS/<CFBundleExecutable>"
```

It reports:

- Hardened Runtime from the CodeDirectory `runtime` flag.
- The `com.apple.security.cs.disable-library-validation` entitlement.
- Signing team identifier and App Sandbox entitlement.
- Distribution clues: a Mac App Store receipt, Steam library location, GOG
  metadata, or a generic direct-distribution layout.

## Verdicts

- **INJECTION VIABLE**: Hardened Runtime is on and the target has an effective
  `disable-library-validation` entitlement. This is only a necessary
  condition—game architecture and updates can still break interposing.
- **INJECTION BLOCKED — use overlay**: Hardened Runtime is on and the target
  does not opt out of Library Validation. `DYLD_INSERT_LIBRARIES` will not be
  a supported route for injecting a third-party dylib.
- **PARTIAL — differs by distribution channel or requires manual
  verification**: the script could not establish the main executable's
  signing state (for example, it was unsigned). Test the actual signed game
  executable for each distribution channel.

## Cyberpunk 2077 (Steam, this machine)

The visible application shortcut at
`/Users/rohitha/Applications/Cyberpunk 2077.app` was not the game: its
`CFBundleExecutable` is the unsigned `run.sh`, which contains `open
steam://run/1091500`.

The actual installed game bundle was:

```text
/Users/rohitha/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app
```

Command run:

```bash
./scripts/check-target.sh "/Users/rohitha/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app"
```

Observed signing output (2026-09-05):

```text
Executable=/Users/rohitha/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077
Identifier=com.cdprojektred.cyberpunk.steam
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=1174892 flags=0x10000(runtime) hashes=36704+7 location=embedded
Hash type=sha256 size=32
CandidateCDHash sha256=d4c2a8386653e6ff7346f57a846e2f8a12e5b280
CandidateCDHashFull sha256=d4c2a8386653e6ff7346f57a846e2f8a12e5b280445d6459504d4b413a6605cf
Hash choices=sha256
CMSDigest=d4c2a8386653e6ff7346f57a846e2f8a12e5b280445d6459504d4b413a6605cf
CMSDigestType=2
CDHash=d4c2a8386653e6ff7346f57a846e2f8a12e5b280
Signature size=9049
Authority=(unavailable)
Notarization Ticket=stapled
Info.plist=not bound
TeamIdentifier=PL47UP47QQ
Runtime Version=15.2.0
Sealed Resources version=2 rules=13 files=7
Internal requirements count=1 size=224

warning: Specifying ':' in the path is deprecated and will not work in a future release
warning: binary contains an invalid entitlements blob. The OS will ignore these entitlements.
```

The bundle has no `Contents/_MASReceipt/receipt`, and it resides in a Steam
library. The entitlements blob is invalid, so macOS ignores it; in particular,
there is no effective `com.apple.security.cs.disable-library-validation`
entitlement.

**Verdict as recorded on 2026-09-05: INJECTION BLOCKED — use overlay.**

## Correction (re-tested 2026-09-06): INJECTION VIABLE

The result above does not reproduce. Re-running the same command against the
same file now reports the opposite verdict, and the file has not changed —
`CDHash` is identical (`d4c2a8386653e6ff7346f57a846e2f8a12e5b280`).

What differs is the rest of the signing report:

| | 2026-09-05 | 2026-09-06 |
|---|---|---|
| `Authority` | `(unavailable)` | `Developer ID Application: CD PROJEKT S.A. (PL47UP47QQ)` |
| `Info.plist` | `not bound` | `entries=23` |
| entitlements blob | `warning: ... invalid ... The OS will ignore these entitlements` | parses cleanly |

An unreadable authority chain, an unbound `Info.plist`, and a malformed
entitlements blob together indicate the bundle was read while incomplete — a
Steam download or verification still in progress. The recorded run was a false
negative caused by inspecting the bundle mid-install.

The executable declares both entitlements that `DYLD_INSERT_LIBRARIES` requires
on a hardened process:

```text
com.apple.security.cs.disable-library-validation
com.apple.security.cs.allow-dyld-environment-variables
```

Disabling library validation alone is not sufficient; a hardened process
ignores `DYLD_*` variables without the second entitlement. Both are present,
and `codesign --verify` reports the signature valid and satisfying its
designated requirement.

**This means loading a third-party dylib into Cyberpunk 2077 is permitted by
the signature.** It does not mean a hook is easy: reaching the depth buffer
still requires identifying textures in the game's Metal render graph, which is
game-specific and can break with any patch. But the door the overlay decision
was built around is not locked.

Re-run this diagnostic after any game update, and never record a verdict from a
bundle that may still be downloading.
