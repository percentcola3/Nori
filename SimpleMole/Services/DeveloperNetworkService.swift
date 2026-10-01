import CryptoKit
import Darwin
import Foundation

/// Read-only network inspection and the narrowly scoped hosts editor. No scan
/// runs a shell startup file, changes proxy settings, or repairs the network.
enum DeveloperNetworkService {
    struct Proxy: Identifiable, Equatable {
        let kind: String
        let endpoint: String
        var id: String { kind }
    }

    struct NetworkService: Identifiable, Equatable {
        let name: String
        let enabled: Bool
        let address: String?
        let dnsServers: [String]
        let proxies: [Proxy]
        let dnsReadable: Bool
        let proxiesReadable: Bool
        let readable: Bool
        var id: String { name }
    }

    struct HostsDocument: Equatable {
        let text: String
        let fingerprint: String
        let customEntryCount: Int
    }

    struct Snapshot: Equatable {
        let services: [NetworkService]
        let resolverServers: [String]
        let hosts: HostsDocument?
        let warnings: [String]
    }

    enum HostsError: LocalizedError, Equatable {
        case unavailable
        case tooLarge
        case invalidLine(Int)
        case protectedMapping
        case changedExternally
        case saveFailed
        case skippedInTestMode

        var errorDescription: String? {
            switch self {
            case .unavailable: return "The hosts file is unavailable or is not a regular system file."
            case .tooLarge: return "The hosts file exceeds the 64 KB editor limit."
            case .invalidLine(let line): return "Invalid IP address or hostname on line \(line)."
            case .protectedMapping: return "Keep 127.0.0.1 localhost, ::1 localhost and 255.255.255.255 broadcasthost."
            case .changedExternally: return "The hosts file changed outside Nori. Reload it before saving."
            case .saveFailed: return "Could not confirm the hosts save. Your draft is kept."
            case .skippedInTestMode: return "System changes are disabled in test mode."
            }
        }
    }

    struct HostsSave: Equatable {
        let backupPath: String
    }

    static let hostsPath = "/private/etc/hosts"
    static let maxHostsBytes = 65_536
    private static let protectedMappings: Set<String> = [
        "127.0.0.1\tlocalhost", "::1\tlocalhost", "255.255.255.255\tbroadcasthost"
    ]

    static func scan() async -> Snapshot {
        async let listed = command("/usr/sbin/networksetup", ["-listallnetworkservices"])
        async let resolver = command("/usr/sbin/scutil", ["--dns"])
        let hosts = try? readHosts()
        let namesResult = await listed
        let resolverResult = await resolver
        let names = parseServiceNames(namesResult.output)
        let services = await withTaskGroup(of: (Int, NetworkService).self) { group in
            var entries = Array(names.prefix(32).enumerated()).makeIterator()
            for _ in 0..<4 {
                guard let (index, entry) = entries.next() else { break }
                group.addTask { (index, await inspect(entry.name, enabled: entry.enabled)) }
            }
            var collected: [(Int, NetworkService)] = []
            for await completed in group {
                collected.append(completed)
                if let (index, entry) = entries.next() {
                    group.addTask { (index, await inspect(entry.name, enabled: entry.enabled)) }
                }
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var warnings: [String] = []
        if !namesResult.succeeded { warnings.append("services") }
        if !resolverResult.succeeded { warnings.append("resolver") }
        if hosts == nil { warnings.append("hosts") }
        if names.count > 32 { warnings.append("serviceLimit") }
        return Snapshot(services: services, resolverServers: parseResolverServers(resolverResult.output),
                        hosts: hosts, warnings: warnings)
    }

    static func readHosts() throws -> HostsDocument {
        let url = URL(fileURLWithPath: hostsPath)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { throw HostsError.unavailable }
        guard (values.fileSize ?? 0) <= maxHostsBytes else { throw HostsError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maxHostsBytes else { throw HostsError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw HostsError.unavailable }
        return document(text: text, data: data)
    }

    static func document(text: String, data: Data? = nil) -> HostsDocument {
        let bytes = data ?? Data(text.utf8)
        let count = text.components(separatedBy: .newlines).filter { line in
            let fields = hostFields(line)
            return fields.count > 1 && fields.dropFirst().contains { !["localhost", "broadcasthost"].contains($0.lowercased()) }
        }.count
        return HostsDocument(text: text, fingerprint: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                             customEntryCount: count)
    }

    /// Keep the draft verbatim, including comments. Validation never rewrites it.
    static func validateHosts(_ text: String) throws {
        guard text.utf8.count <= maxHostsBytes else { throw HostsError.tooLarge }
        var found: Set<String> = []
        for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard !line.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\t") || $0.value == 127 }) else {
                throw HostsError.invalidLine(offset + 1)
            }
            let fields = hostFields(line)
            if fields.isEmpty { continue }
            guard fields.count >= 2, validAddress(fields[0]), fields.dropFirst().allSatisfy(validHostname) else {
                throw HostsError.invalidLine(offset + 1)
            }
            for name in fields.dropFirst() {
                let mapping = fields[0] + "\t" + name.lowercased()
                let normalized = (name.hasSuffix(".") ? String(name.dropLast()) : name).lowercased()
                if ["localhost", "broadcasthost"].contains(normalized) {
                    guard protectedMappings.contains(mapping) else { throw HostsError.protectedMapping }
                    found.insert(mapping)
                }
            }
        }
        guard protectedMappings.isSubset(of: found) else { throw HostsError.protectedMapping }
    }

    static func saveHosts(_ text: String, original: HostsDocument) async throws -> HostsSave {
        try validateHosts(text)
        let environment = ProcessInfo.processInfo.environment
        guard environment["MOLE_TEST_MODE"] != "1", environment["MOLE_TEST_NO_AUTH"] != "1" else {
            throw HostsError.skippedInTestMode
        }
        guard try readHosts().fingerprint == original.fingerprint else { throw HostsError.changedExternally }
        let result = await MoleEngine.shared.runPrivilegedBridge(
            "bin/app_dev_hosts.sh",
            arguments: [String(getuid()), "apply", original.fingerprint, Data(text.utf8).base64EncodedString()], timeout: 90)
        let lines = result.output.components(separatedBy: .newlines)
        if lines.contains("hosts\tconflict") { throw HostsError.changedExternally }
        guard result.succeeded,
              let line = lines.last(where: { $0.hasPrefix("hosts\tapplied\t/private/etc/hosts.nori-backup.") }) else {
            throw HostsError.saveFailed
        }
        return HostsSave(backupPath: String(line.dropFirst("hosts\tapplied\t".count)))
    }

    static func parseServiceNames(_ output: String) -> [(name: String, enabled: Bool)] {
        output.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("An asterisk"), !line.hasPrefix("**"),
                  !line.contains("Error:") else { return nil }
            let enabled = !line.hasPrefix("*")
            let name = enabled ? line : String(line.dropFirst())
            return name.isEmpty ? nil : (name, enabled)
        }
    }

    static func parseResolverServers(_ output: String) -> [String] {
        var values: [String] = []
        for line in output.components(separatedBy: .newlines) where line.contains("nameserver[") {
            guard let value = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces),
                  validDNSServerAddress(value), !values.contains(value) else { continue }
            values.append(value)
        }
        return values
    }

    static func parseDNSServiceServers(_ output: String) -> [String] {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(validDNSServerAddress)
    }

    static func parseProxy(_ output: String, kind: String) -> Proxy? {
        let fields = parseFields(output)
        guard fields["Enabled"] == "Yes" else { return nil }
        if kind == "PAC", let url = fields["URL"], !url.isEmpty { return Proxy(kind: kind, endpoint: url) }
        guard let server = fields["Server"], !server.isEmpty, let port = fields["Port"] else { return nil }
        return Proxy(kind: kind, endpoint: "\(server):\(port)")
    }

    private static func inspect(_ name: String, enabled: Bool) async -> NetworkService {
        async let info = command("/usr/sbin/networksetup", ["-getinfo", name])
        async let dns = command("/usr/sbin/networksetup", ["-getdnsservers", name])
        async let http = command("/usr/sbin/networksetup", ["-getwebproxy", name])
        async let https = command("/usr/sbin/networksetup", ["-getsecurewebproxy", name])
        async let socks = command("/usr/sbin/networksetup", ["-getsocksfirewallproxy", name])
        async let pac = command("/usr/sbin/networksetup", ["-getautoproxyurl", name])
        let results = await [info, dns, http, https, socks, pac]
        let fields = parseFields(results[0].output)
        let address = fields["IP address"].flatMap { validAddress($0) ? $0 : nil }
        let servers = parseDNSServiceServers(results[1].output)
        let proxies = zip(results.dropFirst(2), ["HTTP", "HTTPS", "SOCKS", "PAC"])
            .compactMap { parseProxy($0.0.output, kind: $0.1) }
        return NetworkService(name: name, enabled: enabled, address: address, dnsServers: servers,
                              proxies: proxies, dnsReadable: results[1].succeeded,
                              proxiesReadable: results.dropFirst(2).allSatisfy(\.succeeded),
                              readable: results.allSatisfy(\.succeeded))
    }

    private static func command(_ path: String, _ arguments: [String]) async -> RunResult {
        await MoleEngine.shared.run(executable: URL(fileURLWithPath: path), arguments: arguments,
                                    environment: MoleEngine.shared.standardEnvironment(["LC_ALL": "C"], includeHomebrew: false), timeout: 8)
    }

    private static func parseFields(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return result
    }

    private static func hostFields(_ line: String) -> [String] {
        let data = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return data.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
    }

    private static func validAddress(_ text: String) -> Bool {
        guard !text.contains("%"), !text.utf8.contains(0) else { return false }
        var v4 = in_addr()
        var v6 = in6_addr()
        return text.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    /// DNS resolvers may use link-local IPv6 with an interface scope (RFC 4007).
    /// Keep that scope for display; hosts entries continue to require plain IPs.
    private static func validDNSServerAddress(_ text: String) -> Bool {
        guard !text.utf8.contains(0) else { return false }
        let parts = text.split(separator: "%", omittingEmptySubsequences: false)
        if parts.count == 1 { return validAddress(text) }
        guard parts.count == 2, !parts[1].isEmpty, parts[1].utf8.count < Int(IFNAMSIZ),
              parts[1].utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                      || byte == 45 || byte == 46 || byte == 95
              }) else { return false }
        var address = in6_addr()
        return String(parts[0]).withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }

    private static func validHostname(_ text: String) -> Bool {
        let name = text.hasSuffix(".") ? String(text.dropLast()) : text
        guard !name.isEmpty, name.utf8.count <= 253 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
}
