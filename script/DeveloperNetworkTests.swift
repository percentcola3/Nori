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

    static func structureTests() throws {
        typealias Network = DeveloperNetworkService
        let text = """
        ##
        # Host Database
        #
        # localhost is used to configure the loopback interface
        # when the system is booting.  Do not change this entry.
        ##
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost
        ::1             localhost
        127.0.0.1 loose.test

        # --- 本地开发 ---
        127.0.0.1 api.local dashboard.test # keep me
        #127.0.0.1 off.local
        # just a note

        # Staging
        10.0.0.5 staging.test

        """
        let groups = Network.hostsGroups(text)
        expect(groups.map(\.kind) == [.system, .ungrouped, .named("本地开发"), .named("Staging")], "hosts grouping")
        expect(groups[0].entries.count == 3, "system defaults grouped")
        let dev = groups[2]
        expect(dev.entries.map(\.enabled) == [true, false] && dev.entries[0].comment == "keep me", "entries, comments and disabled lines")
        let disabled = Network.settingHostsEntries(text, entries: dev.entries, enabled: false)
        expect(disabled.contains("\n# 127.0.0.1 api.local dashboard.test # keep me\n#127.0.0.1 off.local\n"), "disabling comments only enabled lines")
        let enabled = Network.settingHostsEntries(text, entries: dev.entries, enabled: true)
        expect(enabled.contains("\n127.0.0.1 off.local\n"), "enabling strips the comment marker")
        expect(Network.settingHostsEntries(text, entries: groups[0].entries, enabled: false) == text, "system entries never toggle")
        try Network.validateHosts(disabled)
        try Network.validateHosts(enabled)
        let edited = try Network.settingHostsEntry(text, entry: dev.entries[0], address: "127.0.0.2",
                                                   hostnames: ["api.local"], comment: "moved")
        expect(edited.contains("\n127.0.0.2\tapi.local\t# moved\n#127.0.0.1 off.local\n"), "editing replaces one line")
        let removed = Network.removingHostsEntry(text, entry: dev.entries[1])
        expect(!removed.contains("off.local") && removed.contains("# just a note"), "removing keeps neighbors")
        let toGroup = try Network.addingHostsEntry(text, address: "127.0.0.1", hostnames: ["new.local"], comment: "", to: dev)
        expect(Network.hostsGroups(toGroup)[2].entries.map(\.hostnames) == [["api.local", "dashboard.test"], ["off.local"], ["new.local"]],
               "new entry joins its group")
        let ungrouped = try Network.addingHostsEntry(text, address: "::1", hostnames: ["six.test"], comment: "",
                                                     to: Network.HostsGroup(kind: .ungrouped, headerLineIndex: nil, entries: []))
        expect(Network.hostsGroups(ungrouped)[1].entries.count == 2, "ungrouped entry stays outside named groups")
        let newGroup = try Network.addingHostsEntry(text, address: "192.168.1.2", hostnames: ["nas.home"], comment: "",
                                                    to: nil, newGroupTitle: "Home")
        expect(newGroup.hasSuffix("10.0.0.5 staging.test\n\n# Home\n192.168.1.2\tnas.home\n"), "new group appended")
        expect(Network.hostsGroups(newGroup).last?.kind == .named("Home"), "new group parses back")
        try Network.validateHosts(newGroup)
        do {
            _ = try Network.addingHostsEntry(text, address: "127.0.0.1", hostnames: ["localhost"], comment: "", to: dev)
            expect(false, "protected hostname accepted")
        } catch { expect(error as? Network.HostsEntryProblem == .protectedHostname, "protected hostname error") }
        do {
            _ = try Network.addingHostsEntry(text, address: "1.2.3", hostnames: ["a.test"], comment: "", to: dev)
            expect(false, "invalid address accepted")
        } catch { expect(error as? Network.HostsEntryProblem == .invalidAddress, "invalid address error") }
        expect(Network.hostnameList("a.test, b.test  c.test") == ["a.test", "b.test", "c.test"], "hostname list parsing")
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
        let effective = DeveloperNetworkService.parseEffectiveProxies("<dictionary> {\n HTTPEnable : 1\n HTTPProxy : 127.0.0.1\n HTTPPort : 7897\n HTTPSEnable : 0\n ProxyAutoConfigEnable : 1\n ProxyAutoConfigURLString : https://example.test/proxy.pac?token=secret\n}")
        expect(effective.map(\.kind) == ["HTTP", "PAC"], "effective proxy distinguishes enabled schemes")
        expect(DeveloperNetworkService.redactedEndpoint("https://user:secret@proxy.test:7890/path?token=secret#private") == "https://proxy.test:7890/path", "proxy display leaked credentials or query")
        expect(DeveloperNetworkService.redactedEndpoint("user:secret@proxy.test:7890") == "proxy.test:7890", "schemeless proxy display leaked credentials")
        try structureTests()
        print("Developer network: hosts structure, validation, preservation, fingerprints, services, DNS and proxies passed")
    }
}
