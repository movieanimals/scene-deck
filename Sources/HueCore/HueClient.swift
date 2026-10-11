import Foundation
import Security

public enum HueError: Error, Equatable, LocalizedError {
    case approvalRequired, invalidHost, invalidResource, invalidBrightness, invalidCredential, http(Int), api(String), malformedResponse
    public var requiresAccessRecovery: Bool {
        switch self {
        case .http(401), .http(403), .invalidCredential, .api: return true
        default: return false
        }
    }
    public var errorDescription: String? {
        switch self {
        case .approvalRequired: return "Bridge access requires explicit approval. Demo mode remains available."
        case .invalidHost: return "Enter only a Bridge IP address or hostname, without a scheme, port, or path."
        case .invalidResource: return "That scene or group is no longer available. Refresh the library."
        case .invalidBrightness: return "Brightness must be between 0 and 100."
        case .invalidCredential: return "A valid application key is required."
        case .http(let code): return "Bridge request failed (HTTP \(code))."
        case .api: return "The Bridge rejected the request. Refresh and try again."
        case .malformedResponse: return "The Bridge returned an unexpected response."
        }
    }
}
public struct BridgeConfiguration {
    public let host: String
    public let applicationKey: String
    public init(host: String, applicationKey: String) { self.host = host; self.applicationKey = applicationKey }
}
public enum BridgeAccess { case blocked, readOnly, control }
public struct HueRequestFactory {
    public let configuration: BridgeConfiguration
    public init(configuration: BridgeConfiguration) { self.configuration = configuration }
    private func request(path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        let host = configuration.host
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."), host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw HueError.invalidHost }
        guard !configuration.applicationKey.isEmpty, !configuration.applicationKey.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw HueError.invalidCredential }
        var components = URLComponents(); components.scheme = "https"; components.host = host; components.path = path
        guard let url = components.url else { throw HueError.invalidHost }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 15
        request.setValue(configuration.applicationKey, forHTTPHeaderField: "hue-application-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    private func validID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { throw HueError.invalidResource }
    }
    public func resources() throws -> URLRequest { try request(path: "/clip/v2/resource") }
    public func recall(id: String) throws -> URLRequest { try validID(id); return try request(path: "/clip/v2/resource/scene/\(id)", method: "PUT", body: ["recall": ["action": "active"]]) }
    public func brightness(id: String, value: Double) throws -> URLRequest {
        try validID(id); guard value.isFinite, (0...100).contains(value) else { throw HueError.invalidBrightness }
        return try request(path: "/clip/v2/resource/grouped_light/\(id)", method: "PUT", body: ["dimming": ["brightness": value]])
    }
    public func power(id: String, on: Bool) throws -> URLRequest {
        try validID(id)
        return try request(path: "/clip/v2/resource/grouped_light/\(id)", method: "PUT", body: ["on": ["on": on]])
    }
    public func sceneWrite(_ plan: SceneWritePlan) throws -> URLRequest {
        if let id = plan.sceneID { try validID(id); return try request(path: "/clip/v2/resource/scene/\(id)", method: "PUT", body: plan.body) }
        return try request(path: "/clip/v2/resource/scene", method: "POST", body: plan.body)
    }
    public func events() throws -> URLRequest {
        var result = try request(path: "/eventstream/clip/v2"); result.setValue("text/event-stream", forHTTPHeaderField: "Accept"); result.timeoutInterval = 90; return result
    }
}

internal final class SecureSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let trust: HueTrustConfiguration?
    init(trust: HueTrustConfiguration? = nil) { self.trust = trust }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else { completionHandler(.performDefaultHandling, nil); return }
        guard let trust else { completionHandler(.performDefaultHandling, nil); return }
        guard challenge.previousFailureCount == 0, let presented = challenge.protectionSpace.serverTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        guard let certificates = SecTrustCopyCertificateChain(presented) as? [SecCertificate] else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let chain = certificates.map { SecCertificateCopyData($0) as Data }
        guard trust.policy.evaluate(chainDER: chain, host: challenge.protectionSpace.host, port: challenge.protectionSpace.port) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: presented))
    }
    // Never forward the application key to a redirect target. TLS uses scoped approved validation, or default system evaluation when unconfigured.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class HueClient {
    private let factory: HueRequestFactory
    private let access: BridgeAccess
    private let delegate: SecureSessionDelegate
    // Internal-only seam for deterministic in-memory tests. Production uses the owned HTTPS session.
    private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    private let eventTransport: ((@escaping () async -> Void) async throws -> Void)?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    public convenience init(configuration: BridgeConfiguration, access: BridgeAccess = .blocked, trust: HueTrustConfiguration? = nil) {
        self.init(configuration: configuration, access: access, transport: nil, trust: trust)
    }
    internal init(configuration: BridgeConfiguration, access: BridgeAccess, transport: ((URLRequest) async throws -> (Data, URLResponse))?, trust: HueTrustConfiguration? = nil, eventTransport: ((@escaping () async -> Void) async throws -> Void)? = nil) {
        factory = HueRequestFactory(configuration: configuration); self.access = access; self.transport = transport
        self.eventTransport = eventTransport
        delegate = SecureSessionDelegate(trust: trust)
    }
    deinit { /* No session is created merely to tear it down. Owner calls close after use. */ }
    public func relocatedCopy(host: String, bridgeID: String) -> HueClient {
        HueClient(configuration: .init(host: host, applicationKey: factory.configuration.applicationKey), access: access, trust: .init(host: host, bridgeID: bridgeID))
    }
    public func readOnlyCopy(host: String, bridgeID: String) -> HueClient {
        HueClient(configuration: .init(host: host, applicationKey: factory.configuration.applicationKey), access: .readOnly, trust: .init(host: host, bridgeID: bridgeID))
    }
    public func close() { if access != .blocked && transport == nil { session.invalidateAndCancel() } }
    private func authorize(write: Bool = false) throws {
        guard access != .blocked, !write || access == .control else { throw HueError.approvalRequired }
    }
    public static func decode(_ data: Data, status: Int) throws -> HueEnvelope {
        guard (200...299).contains(status) else { throw HueError.http(status) }
        let envelope = try JSONDecoder().decode(HueEnvelope.self, from: data)
        guard envelope.errors.isEmpty else { throw HueError.api(envelope.errors.map(\.description).joined(separator: "; ")) }
        return envelope
    }
    private func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let transport { return try await transport(request) }
        return try await session.data(for: request)
    }
    private func send(_ request: URLRequest) async throws -> HueEnvelope {
        let (data, response) = try await exchange(request)
        guard let http = response as? HTTPURLResponse else { throw HueError.malformedResponse }
        return try Self.decode(data, status: http.statusCode)
    }
    private struct WriteStatus: Decodable { let errors: [HueAPIError] }
    private struct WriteAcknowledgment: Decodable { let data: [HueResource.Reference] }
    private func sendWrite(_ request: URLRequest, expectedID: String?, expectedType: String) async throws -> String {
        let (data, response) = try await exchange(request)
        guard let http = response as? HTTPURLResponse else { throw HueError.malformedResponse }
        guard (200...299).contains(http.statusCode) else { throw HueError.http(http.statusCode) }
        let status = try JSONDecoder().decode(WriteStatus.self, from: data)
        guard status.errors.isEmpty else { throw HueError.api(status.errors.map(\.description).joined(separator: "; ")) }
        // A write acknowledges resources; it does not return an authoritative resource snapshot.
        // Do not require resource id/type/metadata fields, or optimistically project this into home state.
        let acknowledgment = try JSONDecoder().decode(WriteAcknowledgment.self, from: data)
        guard let receipt = acknowledgment.data.first(where: { (expectedID == nil || $0.rid == expectedID) && $0.rtype == expectedType }), !receipt.rid.isEmpty else { throw HueError.malformedResponse }
        return receipt.rid
    }
    public func resources() async throws -> [HueResource] { try authorize(); return try await send(factory.resources()).data }
    public func recall(_ id: String) async throws { try authorize(write: true); _ = try await sendWrite(factory.recall(id: id), expectedID: id, expectedType: "scene") }
    public func brightness(_ id: String, value: Double) async throws { try authorize(write: true); _ = try await sendWrite(factory.brightness(id: id, value: value), expectedID: id, expectedType: "grouped_light") }
    public func power(_ id: String, on: Bool) async throws { try authorize(write: true); _ = try await sendWrite(factory.power(id: id, on: on), expectedID: id, expectedType: "grouped_light") }
    public func saveScene(_ plan: SceneWritePlan) async throws -> String {
        try authorize(write: true)
        return try await sendWrite(factory.sceneWrite(plan), expectedID: plan.sceneID, expectedType: "scene")
    }
    /// Invalidates a snapshot for each complete event frame. Caller owns coalescing, refetch, backoff and cancellation.
    public func listen(onChange: @escaping () async -> Void) async throws {
        try authorize()
        if let eventTransport { try await eventTransport(onChange); return }
        let (bytes, response) = try await session.bytes(for: factory.events())
        guard let http = response as? HTTPURLResponse else { throw HueError.malformedResponse }
        guard http.statusCode == 200 else { throw HueError.http(http.statusCode) }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else { throw HueError.malformedResponse }
        var parser = SSEParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let frame = parser.feed(line), let data = frame.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [Any] { await onChange() }
        }
    }
}
public struct SSEParser {
    private var lines: [String] = []
    private var size = 0
    public init() {}
    public mutating func feed(_ line: String) -> String? {
        if line.isEmpty {
            defer { lines.removeAll(keepingCapacity: true); size = 0 }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5)); if value.first == " " { value.removeFirst() }
            size += value.utf8.count
            if size < 1_048_576 { lines.append(value) } else { lines.removeAll() }
        }
        return nil
    }
}
