# Verification — 0.3.1

macOS 15.7.7, Apple Swift 5.8.1, Command Line Tools SDK 13.3, arm64.

- Native SwiftUI app and menu-bar companion compile and locally sign without downloaded dependencies.
- **152 core/store/client/pairing/scene/recovery/switching checks passed**: 39 core, 33 store/synchronizer, 17 client, 15 pairing, 26 portable scene, 8 read recovery, 14 Bridge switching. Checks cover read/write authorization, receipts, request targets, event coalescing, stale-response suppression, revoked-access cancellation, sleep pause persistence, household-specific preferences, strict import bounds, capabilities, mapping isolation, scene write bodies, and exact-ID address recovery/throttling. A same-named-light retargeting regression first reproduced the stale-edit failure and now passes. A→B→A switching runs through the production disconnect/selection/restore flow with injected in-memory transports and credential services, verifies stream cancellation, credential/selection isolation, persistent disconnect and sleep pause, and GET-only requests. All are synthetic and make no Bridge requests or Keychain accesses.
- **16 synthetic TLS checks passed** with native macOS Security, network certificate fetching disabled, and no roots installed. They exercise identity, scoped anchors, SAN/CN policy, validity, signature tampering, and endpoint/port mismatch. The earlier 0.2 verification also validated one privately captured Bridge certificate offline.
- Earlier real pairing, Keychain storage, and read-only scene inventory succeeded. No physical scene/brightness changes or real scene-definition writes have been performed. Version 0.3 writes and recovery are mock-verified; real write confirmation remains a deliberate user-selected test.
- The installed 0.3.1 bundle passed strict code-signature verification. The unchanged single-instance flow was verified with 0.3.0: launching a second app copy exited successfully while the installed process remained alive; both test processes then closed. Demo screenshots use the app's own window rendering and need no system screen-capture permission.
- Native CUA access previously timed out and now reports a locked Mac. Complete keyboard/accessibility checks and the requested Dock pin remain pending; no lock bypass or Dock changes were attempted.
- Local ad-hoc signing is not Developer ID signing or notarization. Each destination Mac needs its own pairing/key. No public distribution has occurred.

Private diagnostic evidence, connected screenshots, and delivery identities remain under ignored local files. The ZIP contains only the app binary, core library, original icon, and bundle metadata. The repository contains synthetic example scene files; it contains no household scene exports or credentials.

## Deliberate remaining live validation

Use a selected test room only after its owner is ready: recall one selected scene, make one brightness change, create/edit one named test scene, and confirm resulting state from a fresh Bridge read. Then exercise sleep/wake, a controlled Bridge/IP interruption, and revocation on a disposable test credential. Do not repeatedly register or retry uncertain writes. These tests were not performed while the user was asleep.
