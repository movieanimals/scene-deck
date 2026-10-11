# Silent wake recovery checkpoint

Prepared 2026-10-11. **0.4.2 build 7; local, not installed or published.** Includes the singular scene-count fix from `666b9a1`. Installed 0.4.1 (`dd4be2d`) and the public 0.4.0 beta remain unchanged.

## Corrected intent

The user confirmed that Scene Deck should reconnect silently after wake, without requiring a button press. The previous manual gate originated in `9ec10e7` and was retained by a later handoff; this checkpoint replaces that behavior based on the clarified instruction.

## Behavior

- Sleep cancels reads, event streams, and pending lighting work. Commands are never replayed on wake.
- Wake starts one recovery task using the selected Bridge's existing saved access. Repeated wake/foreground events do not create additional loops. A legacy persisted sleep pause also recovers on launch.
- Transient connection failures retry after 1, 2, 4, 8, 16, 32, then at most every 60 seconds, measured after each failed attempt. Recovery refreshes inventory before enabling previously approved controls; enabling controls sends no lighting command.
- Keychain access during automatic recovery forbids authentication UI. Temporary unavailability retries silently, including wake before unlock. Missing keys, rejected credentials, and secure-connection failures stop automatic retries and show manual recovery guidance. No automatic pairing, credential creation, or credential replacement occurs.
- Explicit Disconnect cancels recovery, retains saved access/preferences, and remains disconnected across wake and relaunch. Selecting another saved Bridge still requires explicit Reconnect. Revoked-access blocks also persist across relaunch until an explicit successful recovery.
- Offline wake retains the last library, disables lighting controls, and reports the outage honestly. Retry now/Reconnect remains available as a manual fallback. Recovery failure does not open a setup sheet automatically.
- Session identity checks discard late responses after sleep, disconnect, or superseding recovery. Optional Hue discovery failures preserve the original retryable LAN error, and discovery remains throttled across restore attempts.

The native implementation uses `NSWorkspace.didWakeNotification` and a single cancellable task. Silent Keychain reads use `LAContext.interactionNotAllowed` with `kSecUseAuthenticationContext`, following the installed Apple SDK guidance. Existing app-scoped TLS validation remains intact.

## Verification

- **208 synthetic functional checks passed:** 47 core, 42 store, 20 client, 15 pairing, 26 scene-file, 9 read recovery, 14 switching, 16 refresh, and 19 wake lifecycle checks.
- **16 offline TLS checks passed**, without installing roots or making network requests.
- Wake tests use in-memory responses and a manually advanced retry clock: sleep/wake, delayed network, repeated notifications, bounded backoff, explicit disconnect, missing/revoked/temporarily locked credentials, and late in-flight responses. They also cover manual retry racing with Disconnect and wake arriving during manual teardown.
- All recovery requests in these tests are GETs. No real network, Keychain, or light operations occur.
- Targeted review found and closed three lifecycle/recovery issues; final review found no remaining material issue.
- Native app build and strict deep signature verification of a fresh ZIP extraction succeeded using existing Command Line Tools.
- Installed 0.4.1 executable SHA-256 remains `4039508e9893643628790d003dd36b979c6c91245e6c8a8fd36214529500835b`.

Real Mac sleep/wake, current Bridge recovery, and the new noninteractive Keychain path have not been exercised against the installed app. That acceptance pass follows approval to replace the installed app. The existing 0.4.0 backup and private local settings remain untouched. No public push, tag, or release was made.

## Artifact

Local ZIP: `local/Scene-Deck-0.4.2-wake-checkpoint.zip` (Git-ignored).

SHA-256: `4cfe5bf3b0245c6cfed75356f67d49f73daf1615fa066bf24ddaf6237a4263f7`

Build/test commands: `./scripts/test.sh`, `./scripts/test-trust.sh`, `./scripts/build.sh`. For an explicitly offline launch: `open "dist/Scene Deck.app" --args --demo`.

The package remains ad-hoc signed, not Developer ID signed or notarized. This checkpoint does not change Gatekeeper behavior.
