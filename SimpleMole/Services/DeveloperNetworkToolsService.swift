import Foundation

/// Tool-specific, read-only configuration inspection. Values remain private to
/// this inventory; only redacted projections enter view state or command logs.
enum DeveloperNetworkToolsService {
    enum ProxyLayer: String, CaseIterable, Identifiable {
        case terminal, git, npm, pip, docker
        var id: String { rawValue }
        var title: String { rawValue == "terminal" ? "Shell" : rawValue }
        var writable: Bool { self != .docker }
    }
    struct ProxyRow: Identifiable, Equatable {
        let layer: ProxyLayer
        let values: [String: String]
        let available: Bool
        var id: String { layer.id }
        var display: String {
            values.keys.sorted().map { $0 + " = " + DeveloperNetworkService.redactedEndpoint(values[$0] ?? "") }.joined(separator: "\n")
        }
        var hasExplicitProxy: Bool { values.contains { $0.key.lowercased() != "no_proxy" && !$0.value.isEmpty } }
    }
    enum MirrorTool: String, CaseIterable, Identifiable {
        case npm, pnpm, yarn, pip, uv, brewAPI, brewBottles, go, cargo
        var id: String { rawValue }
        var title: String {
            switch self {
            case .brewAPI: return "Homebrew API"
            case .brewBottles: return "Homebrew bottles"
            case .go: return "Go"
            default: return rawValue
            }
        }
        var executable: String {
            switch self { case .brewAPI, .brewBottles: return "brew"; default: return rawValue }
        }
        var official: String {
            switch self {
            case .npm, .pnpm, .yarn: return "https://registry.npmjs.org"
            case .pip, .uv: return "https://pypi.org/simple"
            case .brewAPI: return "https://formulae.brew.sh/api"
            case .brewBottles: return "https://ghcr.io/v2/homebrew/core"
            case .go: return "https://proxy.golang.org,direct"
            case .cargo: return "sparse+https://index.crates.io/"
            }
        }
        var shellKey: String? {
            switch self {
            case .uv: return "UV_DEFAULT_INDEX"
            case .brewAPI: return "HOMEBREW_API_DOMAIN"
            case .brewBottles: return "HOMEBREW_BOTTLE_DOMAIN"
            default: return nil
            }
        }
        var presets: [(name: String, url: String)] {
            var values = [("dev.network.official", official)]
            switch self {
            case .npm, .pnpm, .yarn:
                values.append(("dev.network.mirror.alibaba", "https://registry.npmmirror.com"))
            case .pip, .uv:
                values += [("dev.network.mirror.tsinghua", "https://pypi.tuna.tsinghua.edu.cn/simple"),
                           ("dev.network.mirror.alibaba", "https://mirrors.aliyun.com/pypi/simple"),
                           ("dev.network.mirror.ustc", "https://pypi.mirrors.ustc.edu.cn/simple"),
                           ("dev.network.mirror.tencent", "https://mirrors.cloud.tencent.com/pypi/simple")]
            case .go:
                values += [("dev.network.mirror.alibaba", "https://mirrors.aliyun.com/goproxy/,direct"),
                           ("dev.network.mirror.tencent", "https://mirrors.cloud.tencent.com/go/,direct")]
            case .brewAPI:
                values.append(("dev.network.mirror.tsinghua", "https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"))
            case .brewBottles:
                values += [("dev.network.mirror.tsinghua", "https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"),
                           ("dev.network.mirror.ustc", "https://mirrors.ustc.edu.cn/homebrew-bottles")]
            case .cargo:
                values += [("dev.network.mirror.tsinghua", "sparse+https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/"),
                           ("dev.network.mirror.ustc", "sparse+https://mirrors.ustc.edu.cn/crates.io-index/")]
            }
            return values
        }
    }
    struct MirrorRow: Identifiable, Equatable {
        let tool: MirrorTool
        let current: String
        let available: Bool
        var yarnModern = false
        var overridingEnvironmentKey: String? = nil
        var id: String { tool.id }
        var display: String {
            current.components(separatedBy: "|").map { segment in
                segment.components(separatedBy: ",").map { part in
                    if part == "direct" || part == "off" { return part }
                    return part.hasPrefix("sparse+") ? "sparse+" + DeveloperNetworkService.redactedEndpoint(String(part.dropFirst(7)))
                        : DeveloperNetworkService.redactedEndpoint(part)
                }.joined(separator: ",")
            }.joined(separator: "|")
        }
    }
    struct Snapshot {
        let proxies: [ProxyRow]
        let mirrors: [MirrorRow]
        let terminal: DeveloperTerminalSnapshot
    }
    enum Failure: Error { case invalidValue, unavailable, unsupportedShell, unsupportedProxy, changed, unsafeConfig }
    struct Command {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        var display: String {
            ([executable.path] + arguments).map { "'" + DeveloperSecretRedactor.redact($0).replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        }
    }

    static func scan(terminal: DeveloperTerminalSnapshot) async -> Snapshot {
        let environment = terminal.environment
        let terminalValues = environment.filter { ["http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"].contains($0.key) }
        var proxies = [ProxyRow(layer: .terminal, values: terminalValues, available: true)]
        for layer in [ProxyLayer.git, .npm, .pip] {
            let name = layer.rawValue
            let binary = executable(name, environment: environment)
            var values: [String: String] = [:]
            if binary != nil {
                switch layer {
                case .git: if let value = await value(name, ["config", "--global", "--get", "http.proxy"], environment) { values["http.proxy"] = value }
                case .npm:
                    for key in ["proxy", "https-proxy"] {
                        if let value = await value(name, ["config", "get", key, "--location=user"], environment), !["null", "undefined"].contains(value) { values[key] = value }
                    }
                case .pip: if let value = await value(name, ["config", "--user", "get", "global.proxy"], environment) { values["global.proxy"] = value }
                default: break
                }
            }
            proxies.append(ProxyRow(layer: layer, values: values, available: binary != nil))
        }
        let dockerPath = (environment["DOCKER_CONFIG"] ?? NSHomeDirectory() + "/.docker") + "/config.json"
        var docker: [String: String] = [:]
        if let data = limitedData(dockerPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let configured = json["proxies"] as? [String: [String: String]] {
            docker = configured["default"] ?? [:]
        }
        proxies.append(ProxyRow(layer: .docker, values: docker, available: executable("docker", environment: environment) != nil))
        var mirrors: [MirrorRow] = []
        for tool in MirrorTool.allCases {
            let installed = executable(tool.executable, environment: environment) != nil
            guard installed else { continue }
            let current: String?
            var yarnModern = false
            switch tool {
            case .npm, .pnpm: current = await value(tool.rawValue, ["config", "get", "registry"], environment)
            case .yarn:
                let modern = await value("yarn", ["config", "get", "npmRegistryServer", "--home"], environment)
                yarnModern = modern.map(validHTTPS) ?? false
                current = yarnModern ? modern : await value("yarn", ["config", "get", "registry"], environment)
            case .pip:
                let configured = await value("pip", ["config", "--user", "get", "global.index-url"], environment)
                current = environment["PIP_INDEX_URL"] ?? configured
            case .go: current = await value("go", ["env", "GOPROXY"], environment)
            case .cargo: current = cargoRegistry(environment: environment)
            default: current = tool.shellKey.flatMap { environment[$0] }
            }
            let overrideKeys: [MirrorTool: String] = [.npm: "npm_config_registry", .pnpm: "npm_config_registry",
                                                       .yarn: "YARN_NPM_REGISTRY_SERVER", .pip: "PIP_INDEX_URL", .go: "GOPROXY"]
            let overriding = overrideKeys[tool].flatMap { key in environment[key].map { _ in key } }
            mirrors.append(MirrorRow(tool: tool, current: current.flatMap { ["null", "undefined", ""].contains($0) ? nil : $0 } ?? tool.official, available: true, yarnModern: yarnModern, overridingEnvironmentKey: overriding))
        }
        return Snapshot(proxies: proxies, mirrors: mirrors, terminal: terminal)
    }

    static func executable(_ name: String, environment: [String: String]) -> URL? {
        for component in (environment["PATH"] ?? "").split(separator: ":") where component.hasPrefix("/") {
            let path = URL(fileURLWithPath: String(component)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path.path) { return path }
        }
        return name == "pip" ? executable("pip3", environment: environment) : nil
    }
    private static func value(_ tool: String, _ arguments: [String], _ environment: [String: String]) async -> String? {
        guard let path = executable(tool, environment: environment) else { return nil }
        var env = MoleEngine.shared.standardEnvironment(environment)
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"; env["GOTOOLCHAIN"] = "local"
        env["COREPACK_ENABLE_NETWORK"] = "0"; env["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        let result = await MoleEngine.shared.run(executable: path, arguments: arguments,
                                                environment: env, currentDirectory: URL(fileURLWithPath: NSHomeDirectory()), timeout: 8)
        guard result.succeeded, result.output.utf8.count < 16_384 else { return nil }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    static func proxyCommand(layer: ProxyLayer, target: String?, environment: [String: String]) throws -> [Command] {
        if let target {
            guard validProxyURL(target) else { throw Failure.invalidValue }
            if [.npm, .pip].contains(layer), target.hasPrefix("socks") { throw Failure.unsupportedProxy }
        }
        guard [.git, .npm, .pip].contains(layer), let path = executable(layer.rawValue, environment: environment) else { throw Failure.unavailable }
        let arguments: [[String]]
        switch layer {
        case .git: arguments = [["config", "--global"] + (target.map { ["http.proxy", $0] } ?? ["--unset-all", "http.proxy"])]
        case .npm: arguments = ["proxy", "https-proxy"].map { ["config", target == nil ? "delete" : "set", $0] + (target.map { [$0] } ?? []) + ["--location=user"] }
        case .pip: arguments = [["config", "--user", target == nil ? "unset" : "set", "global.proxy"] + (target.map { [$0] } ?? [])]
        default: throw Failure.unavailable
        }
        return arguments.map { Command(executable: path, arguments: $0, environment: MoleEngine.shared.standardEnvironment(environment)) }
    }
    static func mirrorCommand(tool: MirrorTool, target: String, environment: [String: String], yarnModern: Bool = false) throws -> Command {
        guard validMirror(target, tool: tool), let path = executable(tool.executable, environment: environment) else { throw Failure.invalidValue }
        let arguments: [String]
        switch tool {
        case .npm: arguments = ["config", "set", "registry", target, "--location=user"]
        case .pnpm: arguments = ["config", "set", "registry", target, "--global"]
        case .yarn: arguments = ["config", "set", yarnModern ? "npmRegistryServer" : "registry", target] + (yarnModern ? ["--home"] : [])
        case .pip: arguments = ["config", "--user", "set", "global.index-url", target]
        case .go: arguments = ["env", "-w", "GOPROXY=" + target]
        default: throw Failure.unavailable
        }
        return Command(executable: path, arguments: arguments, environment: MoleEngine.shared.standardEnvironment(environment))
    }
    static func validProxyURL(_ raw: String) -> Bool {
        guard let value = URLComponents(string: raw), ["http", "https", "socks5", "socks5h"].contains(value.scheme ?? ""),
              let host = value.host, !host.isEmpty, value.user == nil, value.password == nil,
              value.query == nil, value.fragment == nil, value.path.isEmpty || value.path == "/",
              value.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        return !raw.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    static func validMirror(_ raw: String, tool: MirrorTool) -> Bool {
        if tool == .go {
            let parts = raw.split(whereSeparator: { $0 == "," || $0 == "|" })
            return !parts.isEmpty && parts.allSatisfy { $0 == "direct" || $0 == "off" || validHTTPS(String($0)) }
        }
        let normalized = tool == .cargo && raw.hasPrefix("sparse+") ? String(raw.dropFirst(7)) : raw
        return validHTTPS(normalized)
    }
    static func validHTTPS(_ raw: String) -> Bool {
        guard !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), let url = URLComponents(string: raw),
              url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil, url.query == nil else { return false }
        return true
    }
    private static func limitedData(_ path: String) -> Data? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 1_048_576 else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
    static func cargoRegistry(environment: [String: String]) -> String? {
        let home = environment["CARGO_HOME"] ?? NSHomeDirectory() + "/.cargo"
        guard let data = limitedData(home + "/config.toml"), let text = String(data: data, encoding: .utf8) else { return nil }
        var section = "", replacement: String?, sources: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if section == "source.crates-io", pair[0] == "replace-with" { replacement = value }
            if section.hasPrefix("source."), pair[0] == "registry" { sources[String(section.dropFirst(7))] = value }
        }
        return replacement.flatMap { sources[$0] }
    }
}
