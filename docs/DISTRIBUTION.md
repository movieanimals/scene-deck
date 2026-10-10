# Distribution readiness — Scene Deck 0.3

The current Apple-silicon/macOS 13+ ZIP is a locally built, ad-hoc-signed preview. It is not a notarized public download. Source remains in the private repository; no public publishing, Apple enrollment, certificate creation, or notarization submission has occurred.

## Prepared

- Native app bundle, original icon, versioned ZIP, separate homepage metadata, offline demo.
- Independent Bridge pairing on each Mac; device-only Keychain access; no credentials or household configuration in the app package.
- Scene file format/schema/example and strict local importer with explicit target mapping.
- One primary window plus a menu-bar companion; existing app activation for a duplicate launch.
- Persistent sleep pause. Wake never reconnects automatically. The user chooses Reconnect. Awake transient read failures use bounded backoff; exact-identity discovery can repair a changed address. Revoked access stops retries. No failed lighting/scene write is replayed.

## Needed before a normal public download

1. An authorized Apple Developer team and its **Developer ID Application** signing identity/private key. Account enrollment/payment and creation or installation of signing credentials require the owner's separate approval. We have not inspected the user's signing credentials. Apple documents the certificate role and type in [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).
2. Sign every nested executable/library and then the app with that identity, Hardened Runtime, and a secure timestamp. Do not add `get-task-allow`, disable library validation, or blanket entitlements. These are [Apple's notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
3. An owner-approved notarization authentication profile, then submit the ZIP with `notarytool`, inspect the result/log, staple the accepted ticket to the app, validate it, and re-create the ZIP. Follow [Apple's command-line workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). Both `notarytool` and `stapler` are present in this machine's Command Line Tools; no tool installation is required for those commands.
4. Test the downloaded, quarantined artifact on a clean destination Mac: Gatekeeper acceptance, Local Network prompt, fresh physical-button pairing, Keychain persistence, sleep/wake pause, menu/window behavior, disconnect/revocation recovery, and deliberate real scene/brightness writes in a test room. No physical light changes were performed during this development session. Full accessibility/keyboard verification also remains outstanding because native UI automation timed out.
5. Choose the public hosting/release URL and source-license/public-repository scope. Publish only the sanitized release artifact after those approvals. Keep private history, logs, Library identities, connected screenshots, and household data private. The homepage handoff intentionally leaves `downloadURL` null.

## Signing recipe for the release owner (not executed)

Use a separate copy of the verified bundle. `SCENE_DECK_SIGNING_IDENTITY` must name the approved Developer ID Application identity; `SCENE_DECK_NOTARY_PROFILE` must name the owner's approved stored authentication profile. Never put passwords, application keys, or private keys in a command or repository.

```sh
codesign --force --options runtime --timestamp --sign "$SCENE_DECK_SIGNING_IDENTITY" "Scene Deck.app/Contents/Frameworks/libHueCore.dylib"
codesign --force --options runtime --timestamp --sign "$SCENE_DECK_SIGNING_IDENTITY" "Scene Deck.app"
codesign --verify --deep --strict "Scene Deck.app"
ditto -c -k --keepParent "Scene Deck.app" "Scene-Deck-submit.zip"
xcrun notarytool submit "Scene-Deck-submit.zip" --keychain-profile "$SCENE_DECK_NOTARY_PROFILE" --wait
# Continue only after an Accepted result; inspect errors instead of proceeding on failure.
xcrun stapler staple "Scene Deck.app"
xcrun stapler validate "Scene Deck.app"
spctl --assess --type execute --verbose=2 "Scene Deck.app"
ditto -c -k --keepParent "Scene Deck.app" "Scene-Deck-macOS-arm64.zip"
```

Changing from ad-hoc to Developer ID signing may require the owner to approve the app's existing Keychain item again. It must not silently create a replacement key or weaken access controls. Do not copy one household's credentials into the distributed app or another Mac.
