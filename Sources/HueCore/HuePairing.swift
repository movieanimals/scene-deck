import Foundation
import Security

public struct HueTrustConfiguration {
    public let host: String
    public let bridgeID: String
    public init(host: String, bridgeID: String) { self.host = host; self.bridgeID = bridgeID.lowercased() }
    internal var policy: HueScopedTrust { HueScopedTrust(expectedBridgeID: bridgeID, expectedHost: host, rootDER: HuePinnedRoots.certificates, allowLegacyCommonName: true) }
}

public enum PairingError: Error, LocalizedError {
    case buttonRequired, invalidResponse, rejected, keychain(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .buttonRequired: return "Press the physical Bridge button, then choose Pair again."
        case .invalidResponse: return "The Bridge returned an unexpected pairing response. No response details were logged."
        case .rejected: return "The Bridge rejected pairing. Press its button and try again."
        case .keychain: return "The Bridge paired, but Keychain could not save access. Keep this window open and retry saving."
        }
    }
}
public final class HuePairingService {
    private let trust: HueTrustConfiguration
    public init(trust: HueTrustConfiguration) { self.trust = trust }
    public static func request(host: String) throws -> URLRequest {
        // Reuse strict host construction; this synthetic value is never sent.
        let factory = HueRequestFactory(configuration: .init(host: host, applicationKey: "validation-only"))
        let base = try factory.resources().url!
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path = "/api"
        var request = URLRequest(url: parts.url!); request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["devicetype": "scene_deck#mac"])
        return request
    }
    public static func decode(_ data: Data, status: Int) throws -> String {
        guard (200...299).contains(status) else { throw HueError.http(status) }
        struct Item: Decodable {
            struct Success: Decodable { let username: String }
            struct Failure: Decodable { let type: Int }
            let success: Success?; let error: Failure?
        }
        guard let result = try? JSONDecoder().decode([Item].self, from: data), result.count == 1 else { throw PairingError.invalidResponse }
        if let error = result[0].error { throw error.type == 101 ? PairingError.buttonRequired : PairingError.rejected }
        guard let key = result[0].success?.username, !key.isEmpty, key.count <= 256,
              key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw PairingError.invalidResponse }
        return key
    }
    public func verifyBridge() async throws {
        var request = try Self.request(host: trust.host)
        request.url = request.url!.appendingPathComponent("config")
        request.httpMethod = "GET"; request.httpBody = nil
        let delegate = SecureSessionDelegate(trust: trust)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["bridgeid"] as? String)?.lowercased() == trust.bridgeID else { throw PairingError.invalidResponse }
    }
    /// Exactly one registration attempt per explicit UI action. Never auto-retries POST.
    public func pair() async throws -> String {
        let delegate = SecureSessionDelegate(trust: trust)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: Self.request(host: trust.host))
        guard let response = response as? HTTPURLResponse else { throw PairingError.invalidResponse }
        return try Self.decode(data, status: response.statusCode)
    }
}

public enum BridgeKeychain {
    private static let service = "com.derektoth.scenedeck.bridge"
    private static func query(_ bridgeID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: bridgeID.lowercased(), kSecAttrSynchronizable as String: false]
    }
    public static func load(bridgeID: String) throws -> String? {
        var query = query(bridgeID)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw PairingError.keychain(status) }
        return key
    }
    public static func save(_ key: String, bridgeID: String) throws {
        var item = query(bridgeID)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "Scene Deck Hue Bridge"
        // Never silently replace another saved key; a successful existing key is reused by the app.
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairingError.keychain(status) }
    }
}
