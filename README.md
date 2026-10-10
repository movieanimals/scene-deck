# Scene Deck

A native macOS Philips Hue controller built around your existing scenes: a full scene library, rooms and zones, favorites, quick brightness, and a menu bar companion.

![Offline demo with sample scenes](docs/demo-library.png)

## Run

Requires Apple silicon and macOS 13 or later. Extract the ZIP, move **Scene Deck.app** into Applications, and open it. The app is locally ad-hoc signed, **not Developer ID signed or notarized**. A downloaded copy may be blocked by macOS. No security-warning bypass is recommended; use the source build below if needed. A notarized public download is not available.

1. Choose **Connect a Bridge**, then **Find my Bridge** (or enter its address and ID).
2. Choose **Verify secure connection**. Allow the app’s expected Local Network request if prompted.
3. Press the physical Bridge button, then choose **I pressed the Bridge button — Pair**.
4. Review your loaded scenes, then choose **Finish setup & enable controls**. This enables your own scene clicks and brightness adjustments; completing setup itself changes no lights.

Each Mac pairs separately and stores its own Bridge access key in device-only macOS Keychain. The app package contains no credentials, private Bridge configuration, or scene inventory. A MacBook must pair for itself. Saved connections reconnect on that Mac after setup is complete. A rebuilt ad-hoc-signed app may require renewed Keychain access.

Demo mode is available before connection. Favorites are local. Search with **⌘F**, star scenes for the menu bar, click a scene to recall it, and release a brightness slider to commit its room/zone level. Real group power controls are not included in this release.

## Build and test

With Apple Command Line Tools installed:

```sh
./scripts/test.sh
./scripts/test-trust.sh
./scripts/build.sh
open "dist/Scene Deck.app"
```

No downloaded dependencies, developer account, package installation, or Xcode project generation is needed. Build scripts keep caches under `.build/local`. The trust tests use native macOS Security with network certificate fetching disabled and install no roots. Restricted automation sandboxes may need access to the native trust service.

The supplied Swift package also includes XCTest tests for a full Xcode installation. The direct compiler harness is the verified path on a Command-Line-Tools-only machine; `swift test` may fail there because XCTest/PlatformPath is absent.

## Security and current scope

- HTTPS only; redirects refused. App-scoped, pinned OpenHue-published CA roots validate server chain, validity, exact endpoint and Bridge identity. No system roots installed. The legacy CN policy is explicit; see [trust provenance](docs/TRUST-PROVENANCE.md).
- Pairing is one attempt per explicit user action. No key is printed, exported, or included in screenshots. Registration and saved-connection failures fail closed.
- Setup loads resources read-only. Control is enabled by explicit setup completion. Live updates invalidate/refetch authoritative Bridge state; command receipts never invent active scenes.
- Existing scenes are primary. Scene editing, scene-gallery assets, dynamic playback controls, and iPhone feature parity are not promised.
- Real read-only pairing and inventory were verified. Scene/brightness writes were tested using mocks; no physical light changes were made during development verification.

## Homepage handoff

[assets/homepage-handoff.json](assets/homepage-handoff.json) and [assets/scene-deck.png](assets/scene-deck.png) are ready for a separate homepage editor. They describe a downloadable native Mac app, not an embedded web app. No homepage files are changed by this project.
