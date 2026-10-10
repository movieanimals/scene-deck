# Portable scene files

Scene Deck 0.3 imports and exports **Scene Deck JSON version 1**. This is a small static-light format, not an importer for arbitrary Hue-app backups or gallery downloads. Files stay on your Mac. Importing a file never calls a Bridge.

Open **Scene files & editor**. Choose a room/zone, then import a file, load an existing static scene, or start from current lights. Demo mode also supports preparation and export. To save on a real Bridge, finish setup, map every source lamp to a different light in the selected room, and review **Preview changes**. The final **Create scene on Bridge** or **Apply changes to scene** button is the only write step. It saves the definition without issuing a recall command.

The app re-reads the selected Bridge before writing, validates room membership and each light's capabilities again, and refuses an edit if the original supported settings changed since loading. Changes made by another controller after that final read remain a possible race; the Hue endpoint does not provide a transaction here. Failed/uncertain writes are never retried automatically. Refresh the library and check for the scene before trying again.

## Version 1 rules

See [warm-evening.scenedeck.json](examples/warm-evening.scenedeck.json) and [scene-file.schema.json](scene-file.schema.json).

- UTF-8 JSON, at most 128 KiB, 1–50 lights; unknown fields rejected.
- `format` is `scene-deck.scene`; `version` is `1`.
- `name` is 1–32 characters; `groupLabel` and lamp `label` are 1–64. Labels cannot be blank or contain control characters.
- Each `slot` is a unique 1–32 character ASCII letter/digit/hyphen identifier. It is a portable label, never a Hue resource ID.
- Each state requires boolean `on`. Optional `brightness` is 0–100, `mirek` is an integer 153–500, and `xy` uses finite coordinates with x ≥ 0, y > 0 and x+y ≤ 1. Color and temperature are mutually exclusive. Actual light capabilities may impose tighter limits.
- Omitted optional values mean unchanged. Export refuses scenes whose actions omit power or use effects, gradients, or other unsupported action fields; it never silently flattens those scenes.
- The JSON schema describes structural bounds. The app additionally enforces unique slots, nonblank labels, xy sums, finite values, room membership, unique mappings, and live capability ranges.

Exports contain scene/room/light labels and static states. Review those human-readable names before sharing. They contain no Bridge address, Bridge ID, resource IDs, application keys, external URLs, executable code, gallery images, or network instructions. Mapping is deliberately performed again on the destination household. Every Mac pairs independently.

## API basis and limits

Scene creation uses POST `/clip/v2/resource/scene`; editing uses PUT for the selected scene, with metadata and static actions only. The implementation follows the public [OpenHue ScenePost](https://github.com/openhue/openhue-api/blob/main/src/scene/schemas/ScenePost.yaml), [ScenePut](https://github.com/openhue/openhue-api/blob/main/src/scene/schemas/ScenePut.yaml), and [ActionPost](https://github.com/openhue/openhue-api/blob/main/src/scene/schemas/ActionPost.yaml) schemas. The detailed official Hue reference remains login-gated. Scene writes are verified with synthetic responses, not with real-light changes. Editing dynamic palettes/effects and importing proprietary scene-gallery assets are outside this version.
