import Foundation

/// Read-only address recovery. Identity is matched before a candidate's scoped TLS check.
public actor HueReadConnection {
    public struct Entry: Decodable { public let id: String; public let internalipaddress: String }
    private var client: HueClient
    private var candidate: HueClient?
    private let bridgeID: String
    private var host: String
    private var closed = false
    private var lastDiscovery = Date.distantPast
    private let addressChanged: (String) -> Void
    private let discover: () async throws -> [Entry]
    private let relocate: (HueClient, String, String) -> HueClient
    private let now: () -> Date
    public init(client: HueClient, bridgeID: String, host: String, addressChanged: @escaping (String) -> Void) {
        self.client = client; self.bridgeID = bridgeID.lowercased(); self.host = host; self.addressChanged = addressChanged
        discover = Self.discoverBridges; relocate = { $0.readOnlyCopy(host: $1, bridgeID: $2) }; now = Date.init
    }
    internal init(client: HueClient, bridgeID: String, host: String, discover: @escaping () async throws -> [Entry], relocate: @escaping (HueClient, String, String) -> HueClient, now: @escaping () -> Date = Date.init, addressChanged: @escaping (String) -> Void = { _ in }) {
        self.client = client; self.bridgeID = bridgeID.lowercased(); self.host = host; self.discover = discover; self.relocate = relocate; self.now = now; self.addressChanged = addressChanged
    }
    private static func discoverBridges() async throws -> [Entry] {
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://discovery.meethue.com/")!); request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HueError.malformedResponse }
        return try JSONDecoder().decode([Entry].self, from: data)
    }
    private func checkOpen() throws { try Task.checkCancellation(); if closed { throw CancellationError() } }
    public func resources() async throws -> [HueResource] {
        try checkOpen()
        do { let result = try await client.resources(); try checkOpen(); return result }
        catch {
            try checkOpen()
            let network = error as? URLError
            let retryable: Set<URLError.Code> = [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet]
            guard let network, retryable.contains(network.code), now().timeIntervalSince(lastDiscovery) >= 30 else { throw error }
            lastDiscovery = now()
            let entries = try await discover()
            try checkOpen()
            guard let match = entries.first(where: { $0.id.lowercased() == bridgeID }), match.internalipaddress != host else { throw error }
            let proposed = relocate(client, match.internalipaddress, bridgeID)
            candidate = proposed
            do {
                let result = try await proposed.resources()
                try checkOpen()
                client.close(); client = proposed; candidate = nil; host = match.internalipaddress
                addressChanged(host)
                return result
            } catch { proposed.close(); candidate = nil; throw error }
        }
    }
    public func currentEndpoint() -> (client: HueClient, host: String) { (client, host) }
    public func listen(onChange: @escaping () async -> Void) async throws { try checkOpen(); try await client.listen(onChange: onChange) }
    public func close() { closed = true; client.close(); candidate?.close(); candidate = nil }
}
