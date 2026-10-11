import Foundation
@testable import HueCore

@main struct ReadConnectionChecks {
    static var count = 0
    static func check(_ value: Bool, _ name: String) { guard value else { fputs("FAIL: \(name)\n", stderr); exit(1) }; count += 1; print("PASS: \(name)") }
    static func client(_ failure: Error? = nil) -> HueClient {
        HueClient(configuration: .init(host: "unit-test.invalid", applicationKey: "synthetic"), access: .readOnly, transport: { request in
            if let failure { throw failure }
            return (Data(#"{"errors":[],"data":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }
    static func main() async throws {
        let entries = try JSONDecoder().decode([HueReadConnection.Entry].self, from: Data(#"[{"id":"other-household","internalipaddress":"192.0.2.2"},{"id":"expected-household","internalipaddress":"192.0.2.3"}]"#.utf8))
        var chosen = "", discoveries = 0, address = ""
        let recovered = HueReadConnection(client: client(URLError(.cannotConnectToHost)), bridgeID: "expected-household", host: "192.0.2.1", discover: { discoveries += 1; return entries }, relocate: { _, host, identity in chosen = host + "|" + identity; return client() }, addressChanged: { address = $0 })
        _ = try await recovered.resources()
        check(chosen == "192.0.2.3|expected-household" && address == "192.0.2.3", "Address recovery selects exact household identity before validating candidate")
        _ = try await recovered.resources()
        check(discoveries == 1, "Successful relocation reuses verified read connection")
        var deniedDiscovery = 0
        let denied = HueReadConnection(client: client(HueError.http(403)), bridgeID: "expected-household", host: "192.0.2.1", discover: { deniedDiscovery += 1; return entries }, relocate: { _, _, _ in client() })
        do { _ = try await denied.resources(); check(false, "denied") } catch { check(deniedDiscovery == 0, "Authorization failure never triggers address discovery") }
        var throttledDiscoveries = 0
        let throttled = HueReadConnection(client: client(URLError(.timedOut)), bridgeID: "missing-household", host: "192.0.2.1", discover: { throttledDiscoveries += 1; return entries }, relocate: { _, _, _ in client() })
        for _ in 0..<3 { _ = try? await throttled.resources() }
        check(throttledDiscoveries == 1, "Failed discovery is throttled for thirty seconds")
        let discoveryOutage = HueReadConnection(client: client(URLError(.notConnectedToInternet)), bridgeID: "expected-household", host: "192.0.2.1", discover: { throw HueError.http(503) }, relocate: { _, _, _ in client() })
        do { _ = try await discoveryOutage.resources(); check(false, "discovery outage") }
        catch { check((error as? URLError)?.code == .notConnectedToInternet, "Optional discovery outage preserves retryable LAN failure") }
        var unsafeAddress = false
        let badTrust = HueReadConnection(client: client(URLError(.cannotConnectToHost)), bridgeID: "expected-household", host: "192.0.2.1", discover: { entries }, relocate: { _, _, _ in client(URLError(.serverCertificateUntrusted)) }, addressChanged: { _ in unsafeAddress = true })
        do { _ = try await badTrust.resources(); check(false, "trust") } catch { check(!unsafeAddress, "Failed candidate TLS cannot replace saved address") }
        await recovered.close()
        do { _ = try await recovered.resources(); check(false, "closed") } catch { check(discoveries == 1, "Closed connection cannot restart or discover after sleep") }
        let pairing = HuePairingService(trust: .init(host: "unit-test.invalid", bridgeID: "synthetic"))
        await pairing.close()
        do { try await pairing.verifyBridge(); check(false, "closed verify") } catch is CancellationError { check(true, "Closed setup service blocks verification before network") }
        do { _ = try await pairing.pair(); check(false, "closed pair") } catch is CancellationError { check(true, "Closed setup service blocks registration before network") }
        print("\(count) read recovery checks passed. Synthetic endpoints; no network or credentials.")
    }
}
