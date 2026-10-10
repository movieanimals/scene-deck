import Foundation
@testable import HueCore

@main struct PairingChecks {
    static var count = 0
    static func check(_ value: Bool, _ name: String) {
        guard value else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1; print("PASS: \(name)")
    }
    static func main() throws {
        let request = try HuePairingService.request(host: "192.0.2.1")
        check(request.url?.absoluteString == "https://192.0.2.1/api", "Pairing is HTTPS on intended endpoint")
        check(request.httpMethod == "POST", "Pairing registers with POST")
        check(request.value(forHTTPHeaderField: "hue-application-key") == nil, "Pairing sends no credential")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        check(body == ["devicetype": "scene_deck#mac"], "Pairing requests app access only; no entertainment key")
        do { _ = try HuePairingService.request(host: "host/path"); check(false, "invalid host") } catch { check(true, "Invalid host fails before registration") }
        let synthetic = #"[{"success":{"username":"synthetic-test-only"}}]"#
        check(try HuePairingService.decode(Data(synthetic.utf8), status: 200) == "synthetic-test-only", "Decode synthetic registration result")
        do { _ = try HuePairingService.decode(Data(#"[{"error":{"type":101,"description":"untrusted response"}}]"#.utf8), status: 200); check(false, "button missing") }
        catch PairingError.buttonRequired { check(true, "Physical button error is explicit") }
        for value in [#"[{"success":{"username":""}}]"#, #"[{"success":{"username":"bad key"}}]"#, "[]", "{}", #"[{"success":{"username":"synthetic"},"error":{"type":1}}]"#] {
            do { _ = try HuePairingService.decode(Data(value.utf8), status: 200); check(false, "invalid result") } catch { check(true, "Malformed or error pairing result fails closed") }
        }
        do { _ = try HuePairingService.decode(Data(synthetic.utf8), status: 401); check(false, "HTTP error") } catch { check(true, "HTTP failure cannot return access key") }
        check(HueTrustConfiguration(host: "192.0.2.1", bridgeID: "AABBCCDDEEFF7788").bridgeID == "aabbccddeeff7788", "Normalize configured Bridge identity")
        check(HuePinnedRoots.certificates.count == 2, "Only the two approved pinned roots are compiled")
        print("\(count) pairing checks passed. Synthetic responses only; no network or Keychain access.")
    }
}
