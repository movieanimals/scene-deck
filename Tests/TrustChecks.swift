import Foundation
import Security
@testable import HueCore

@main struct TrustChecks {
    static var count = 0
    static func check(_ condition: Bool, _ name: String) {
        guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1; print("PASS: \(name)")
    }
    static func pem(_ path: String) throws -> [Data] {
        let text = try String(contentsOfFile: path)
        let regex = try NSRegularExpression(pattern: "-----BEGIN CERTIFICATE-----([\\s\\S]*?)-----END CERTIFICATE-----")
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in Data(base64Encoded: ns.substring(with: match.range(at: 1)), options: .ignoreUnknownCharacters) }
    }
    static func main() throws {
        let base = CommandLine.arguments[1]
        let root = try pem(base + "/root.pem")[0]
        let wrongRoot = try pem(base + "/wrong-root.pem")[0]
        let leaf = try pem(base + "/leaf.pem")[0]
        let matchingSAN = try pem(base + "/matching-san.pem")[0]
        let clientOnly = try pem(base + "/client-only.pem")[0]
        let wrongSAN = try pem(base + "/wrong-san.pem")[0]
        let wrongSerial = try pem(base + "/wrong-serial.pem")[0]
        let policy = HueScopedTrust(expectedBridgeID: "aabbccddeeff7788", expectedHost: "192.0.2.1", rootDER: [root], allowLegacyCommonName: true)
        check(policy.evaluate(chainDER: [leaf], host: "192.0.2.1", port: 443), "Valid private CA chain plus exact legacy Bridge ID")
        check(HueScopedTrust(expectedBridgeID: "aabbccddeeff7788", expectedHost: "192.0.2.1", rootDER: [root]).evaluate(chainDER: [matchingSAN], host: "192.0.2.1", port: 443), "Matching SAN succeeds without legacy opt-in")
        check(!policy.evaluate(chainDER: [leaf], host: "192.0.2.2", port: 443), "Reject unexpected endpoint host")
        check(!policy.evaluate(chainDER: [leaf], host: "192.0.2.1", port: 80), "Reject unexpected endpoint port")
        check(!policy.evaluate(chainDER: [clientOnly], host: "192.0.2.1", port: 443), "Reject client-auth-only certificate")
        check(!policy.evaluate(chainDER: [wrongSAN], host: "192.0.2.1", port: 443), "Reject wrong SAN without falling back to matching CN")
        check(!policy.evaluate(chainDER: [wrongSerial], host: "192.0.2.1", port: 443), "Reject matching CN with wrong Bridge serial")
        check(!policy.evaluate(chainDER: [leaf], host: "192.0.2.1", port: 443, date: Date(timeIntervalSinceNow: 86400 * 10)), "Reject expired leaf")
        check(!policy.evaluate(chainDER: [leaf], host: "192.0.2.1", port: 443, date: Date(timeIntervalSinceNow: -86400 * 10)), "Reject not-yet-valid leaf")
        var damaged = leaf; damaged[damaged.count - 1] ^= 1
        check(!policy.evaluate(chainDER: [damaged], host: "192.0.2.1", port: 443), "Reject tampered signature")
        check(!policy.evaluate(chainDER: [], host: "192.0.2.1", port: 443), "Reject missing leaf")
        check(!HueScopedTrust(expectedBridgeID: "8877665544332211", expectedHost: "192.0.2.1", rootDER: [root], allowLegacyCommonName: true).evaluate(chainDER: [leaf], host: "192.0.2.1", port: 443), "Reject another Bridge ID under trusted CA")
        check(!HueScopedTrust(expectedBridgeID: "aabbccddeeff7788", expectedHost: "192.0.2.1", rootDER: [wrongRoot], allowLegacyCommonName: true).evaluate(chainDER: [leaf], host: "192.0.2.1", port: 443), "Reject matching identity under wrong root")
        check(!HueScopedTrust(expectedBridgeID: "aabbccddeeff7788", expectedHost: "192.0.2.1", rootDER: [], allowLegacyCommonName: true).evaluate(chainDER: [leaf], host: "192.0.2.1", port: 443), "Reject empty trust anchor configuration")
        check(!HueScopedTrust(expectedBridgeID: "aabbccddeeff7788", expectedHost: "192.0.2.1", rootDER: [root], allowLegacyCommonName: false).evaluate(chainDER: [leaf], host: "192.0.2.1", port: 443), "CN-only policy requires explicit opt-in")
        check(!HueScopedTrust(expectedBridgeID: "not-a-bridge", expectedHost: "192.0.2.1", rootDER: [root], allowLegacyCommonName: true).evaluate(chainDER: [leaf], host: "192.0.2.1", port: 443), "Reject malformed expected identity")
        if CommandLine.arguments.count == 6 {
            let observed = try pem(CommandLine.arguments[2])[0]
            let candidateRoots = try pem(CommandLine.arguments[3])
            let observedPolicy = HueScopedTrust(expectedBridgeID: CommandLine.arguments[4], expectedHost: CommandLine.arguments[5], rootDER: candidateRoots, allowLegacyCommonName: true)
            check(observedPolicy.evaluate(chainDER: [observed], host: CommandLine.arguments[5], port: 443), "Captured Bridge leaf cryptographically chains to OpenHue-published candidate root (offline only)")
        }
        print("\(count) offline trust checks passed; no roots installed and no network requests.")
    }
}
