# Scene Deck 0.4.0 beta 1

Scenes first, with more everyday controls:

- Room and zone power in the library; room power in the menu bar.
- Recently played scenes, remembered separately for each Bridge.
- Favorite shortcuts in the Scenes menu (⌘1–⌘9 while the app is active).
- Right-click edit/export and duplicate actions on scene cards.
- Native color picker and Kelvin warmth display in the static scene editor.
- Existing favorites, room brightness, menu bar, portable scene files, multiple saved Bridges, and explicit reconnect after sleep.

## Install

Download **Scene-Deck-macOS-arm64.zip** under Assets, unzip, quit any older Scene Deck, and move the app into Applications. Requires Apple silicon and macOS 13+. Keep only one launch copy. Each Mac pairs separately with its own Hue Bridge using the physical button; keys stay in that Mac’s Keychain. Existing local pairing and preferences are retained when updating, though a rebuilt ad-hoc app may prompt for renewed Keychain access.

**This is an ad-hoc-signed technical beta, not a Developer ID signed/notarized release. macOS may block a downloaded copy because Apple cannot verify it. Do not disable Gatekeeper or remove quarantine. Source-build instructions are in the README.** No Intel download or automatic updater is included.

## Testing and limits

Synthetic tests cover requests, capability checks, confirmed recent recalls, failed commands, stale targets, sleep/reconnect, Bridge switching, scene-file validation, and TLS identity. A real Bridge was tested for pairing and read-only inventory; real lighting and scene-definition writes need further beta testing by the owner. Screen colors are approximate, with no per-bulb gamut calibration. Dynamic scene editing, Hue-owned gallery artwork, and iPhone parity are not included.

Report problems in GitHub Issues with macOS version, app version, Bridge model, and reproduction steps. Do not post application keys, Bridge IDs, private network addresses, or household scene exports.
