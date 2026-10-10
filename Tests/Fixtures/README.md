# Offline CA provenance candidates

Downloaded 2026-10-10 from OpenHue's public implementation:
https://raw.githubusercontent.com/openhue/openhue-go/main/certs.go
Repository: https://github.com/openhue/openhue-go (Apache-2.0)

`openhue-certs-source.go` is the unchanged source used to extract the two PEMs in `openhue-roots.pem`. Its comment attributes these roots to the official Hue HTTPS guide. That attribution has NOT been independently verified from the login-gated guide. These files are offline analysis fixtures; the accepted certificate bytes are separately compiled into HuePinnedRoots.swift. Their third-party provenance and user acceptance are documented in docs/TRUST-PROVENANCE.md. Never treat a chain-validation pass as proof of official provenance.

SHA-256 file digests at retrieval:
- source: `340fe0a13754b69e033b3357444eccd75ba62c909e5a69ba6bc3da87f2ba628a`
- extracted roots: `2ff54626fc51de587cce0f3f0339552f89da781b5d5949fa0c90ec30ddf8acfa`

Synthetic TLS fixture keys/certificates are generated separately beneath ignored `.build/local/trust-fixtures`. Their private keys are deleted when the test runner exits. They are not Bridge application credentials.
