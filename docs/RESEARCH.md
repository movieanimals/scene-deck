# Integration references

Checked 2026-10-10.

- Official new API overview: https://developers.meethue.com/new-hue-api/ — HTTPS v2, dynamics, gradients, events.
- Official getting started: https://developers.meethue.com/develop/get-started-2/ — discovery and physical-button-authorized HTTPS POST `/api` with `devicetype`.
- Official detailed v2 and HTTPS guidance can require developer login; no account was created. Do not claim complete official-schema verification.
- OpenHue CA publication: https://github.com/openhue/openhue-go/blob/main/certs.go — explicitly accepted pinned trust source; see TRUST-PROVENANCE.md.
- OpenHue resource contracts: https://github.com/openhue/openhue-api/tree/main/src/scene — third-party primary implementation references, not a substitute for authenticated current vendor documentation.
- Apple Local Network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy

The resource subset handles rooms, zones, grouped-light capabilities, scenes, errors, and SSE invalidation. Optional fields decode by resource type. Physical Bridge identities, local diagnostics, credentials, and personal inventories are excluded from the repository.
