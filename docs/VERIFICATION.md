# Verification

macOS 15.7.7, Apple Swift 5.8.1, Command Line Tools SDK, arm64.

- Native SwiftUI app and menu-bar companion compile and locally sign without dependencies.
- Core/store/client/pairing harnesses cover request authorization, malformed responses, scene and group ID targeting, input validation, favorites, event coalescing, lifecycle, read-only setup, explicit command dispatch, no commands on setup completion, error recovery, and reversed refresh completion.
- Synthetic TLS checks cover scoped roots, identity, SAN/CN policy, server usage, validity, signature tampering, host and port mismatches. Native trust evaluation requires trust-service access, never a root installation.
- Real pairing, Keychain storage, and read-only scene inventory succeeded. No physical scene/brightness changes were performed. Write behavior is mock-verified.
- App-owned screenshots require no system screen-capture permission. Native CUA inspection timed out; full keyboard/accessibility testing remains unverified.
- Local ad-hoc signing is not Developer ID signing or notarization. Each destination Mac needs its own pairing/key.

Private diagnostic evidence and delivery identities stay under ignored local files, not in GitHub.
