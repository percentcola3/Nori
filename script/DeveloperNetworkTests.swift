import CryptoKit
import Foundation

// Pure parser and validation tests. The executable never runs system commands.
struct RunResult {
    let output: String
    let exitCode: Int32
    let timedOut: Bool
    var succeeded: Bool { exitCode == 0 && !timedOut }
}
final class MoleEngine {
    static let shared = MoleEngine()
    func standardEnvironment(_ extra: [String: String] = [:], includeHomebrew: Bool) -> [String: String] { extra }
    func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async -> RunResult {
        fatalError("Network tests must not execute system commands")
    }
    func runPrivilegedBridge(_ path: String, arguments: [String], timeout: TimeInterval) async -> RunResult {
        fatalError("Network tests must not request administrator access")
    }
}

@main struct DeveloperNetworkTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func rejected(_ text: String, as expected: DeveloperNetworkService.HostsError) {
        do { try DeveloperNetworkService.validateHosts(text); expect(false, "accepted invalid hosts") }
        catch { expect(error as? DeveloperNetworkService.HostsError == expected, "unexpected validation failure: \(error)") }
    }

    static func main() throws {
        let base = "# System entries\n127.0.0.1 localhost\n255.255.255.255 broadcasthost\n::1 localhost\n"
        let valid = base + "\n# 本地开发\n127.0.0.1 api.local dashboard.test # preserved comment\n2001:db8::1 ipv6.test\n"
        try DeveloperNetworkService.validateHosts(valid)
        expect(DeveloperNetworkService.document(text: valid).text == valid, "draft comments changed")
        expect(DeveloperNetworkService.document(text: valid).customEntryCount == 2, "custom mapping count wrong")
        expect(DeveloperNetworkService.document(text: valid).fingerprint != DeveloperNetworkService.document(text: base).fingerprint, "fingerprint misses changes")
        rejected(base + "999.1.2.3 api.local\n", as: .invalidLine(5))
        rejected(base + "127.0.0.1 -bad.test\n", as: .invalidLine(5))
        rejected(base + "127.0.0.1 bad..test\n", as: .invalidLine(5))
        rejected(base + "127.0.0.1 $(touch /tmp/test)\n", as: .invalidLine(5))
        rejected("127.0.0.1 localhost\n", as: .protectedMapping)
        rejected(base + "1.2.3.4 localhost\n", as: .protectedMapping)
        rejected(base + "1.2.3.4 localhost.\n", as: .protectedMapping)
        rejected(base + "# comment\u{0000}\n", as: .invalidLine(5))
        rejected(base + "fe80::1%en0 api.local\n", as: .invalidLine(5))
        rejected(base + "127.0.0.1%en0 api.local\n", as: .invalidLine(5))
        try DeveloperNetworkService.validateHosts(base.replacingOccurrences(of: "\n", with: "\r\n"))
        rejected(base + String(repeating: "#", count: 65_536), as: .tooLarge)
        let services = DeveloperNetworkService.parseServiceNames("An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Thunderbolt Bridge\nUSB 10/100 LAN\n")
        expect(services.count == 3 && services[1].name == "Thunderbolt Bridge" && !services[1].enabled, "disabled network service parsing failed")
        let resolvers = DeveloperNetworkService.parseResolverServers(" nameserver[0] : 8.8.8.8\n nameserver[1] : 2001:4860:4860::8888\n nameserver[0] : 8.8.8.8\n")
        expect(resolvers == ["8.8.8.8", "2001:4860:4860::8888"], "IPv6 DNS parsing failed")
        let scopedResolvers = DeveloperNetworkService.parseResolverServers(" nameserver[0] : fe80::1%en0\n nameserver[1] : fe80::2%utun3\n nameserver[2] : fe80::1%en0\n nameserver[3] : 127.0.0.1%en0\n nameserver[4] : fe80::1%\n nameserver[5] : fe80::1%en0%bad\n")
        expect(scopedResolvers == ["fe80::1%en0", "fe80::2%utun3"], "scoped IPv6 DNS must retain valid interface scopes")
        let serviceDNS = DeveloperNetworkService.parseDNSServiceServers("  fe80::1%en0  \n2001:4860:4860::8888\n8.8.8.8\nfe80::2%4\n127.0.0.1%en0\nfe80::1%bad scope\nfe80::1%en0%bad\n")
        expect(serviceDNS == ["fe80::1%en0", "2001:4860:4860::8888", "8.8.8.8", "fe80::2%4"], "networksetup DNS parser must retain scoped IPv6 and reject invalid scopes")
        expect(DeveloperNetworkService.parseProxy("Enabled: No\nServer: localhost\nPort: 7890", kind: "HTTP") == nil, "disabled proxy shown as enabled")
        expect(DeveloperNetworkService.parseProxy("Enabled: Yes\nServer: 127.0.0.1\nPort: 7890", kind: "SOCKS")?.endpoint == "127.0.0.1:7890", "SOCKS proxy parsing failed")
        expect(DeveloperNetworkService.parseProxy("URL: https://example.test/proxy.pac\nEnabled: Yes", kind: "PAC")?.endpoint == "https://example.test/proxy.pac", "PAC parsing failed")
        print("Developer network: hosts validation, preservation, fingerprints, services, DNS and proxies passed")
    }
}
