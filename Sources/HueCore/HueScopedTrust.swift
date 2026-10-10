import Foundation
import Security

/// App-scoped trust with explicitly approved pinned roots. Never installs system roots.
internal struct HueScopedTrust {
    let expectedBridgeID: String
    let expectedHost: String
    let rootDER: [Data]
    var allowLegacyCommonName = false

    func evaluate(chainDER: [Data], host: String, port: Int, date: Date? = nil) -> Bool {
        let identity = expectedBridgeID.lowercased()
        guard identity.utf8.count == 16,
              identity.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !expectedHost.isEmpty, host == expectedHost, port == 443,
              !chainDER.isEmpty, !rootDER.isEmpty else { return false }
        let chain = chainDER.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        let anchors = rootDER.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard chain.count == chainDER.count, anchors.count == rootDER.count,
              let leaf = chain.first else { return false }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess,
              (commonName as String?)?.lowercased() == identity,
              let serial = SecCertificateCopySerialNumberData(leaf, nil) as Data? else { return false }
        // Conservative Bridge binding: serial and CN must both equal the selected 64-bit ID.
        let serialHex = serial.map { String(format: "%02x", $0) }.joined()
        guard serialHex.drop(while: { $0 == "0" }) == identity.drop(while: { $0 == "0" }) else { return false }
        var valueError: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(leaf, [kSecOIDSubjectAltName] as CFArray, &valueError) as? [String: Any], valueError == nil else { return false }
        let hasSAN = values[kSecOIDSubjectAltName as String] != nil
        guard hasSAN || allowLegacyCommonName else { return false }
        // A present SAN must match; never fall back to CN after hostname validation fails.
        // Legacy CN mode still requires the full trusted server chain and exact CN+serial above.
        let policy = SecPolicyCreateSSL(true, hasSAN ? identity as CFString : nil)
        var optionalTrust: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, policy, &optionalTrust) == errSecSuccess,
              let trust = optionalTrust,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        if let date, SecTrustSetVerifyDate(trust, date as CFDate) != errSecSuccess { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
