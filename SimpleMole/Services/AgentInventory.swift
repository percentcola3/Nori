import Foundation

struct AgentSkill: Identifiable, Equatable, Sendable {
    let path: String
    var id: String { path }
    let name: String
    let summary: String
    let directory: String
    let usedBy: [String]
    /// 挂靠的 Agent 分组 id；共享目录落到 "shared"。
    let agentID: String
    let bytes: UInt64
    let identity: String
    /// 指向别处的链接只展示来源，不作为删除对象。
    let linked: Bool
    let linkTarget: String?
}

struct AgentMCPServer: Identifiable, Equatable, Sendable {
    enum Issue: Equatable, Sendable {
        case commandMissing(String)
        case plaintextSecret(key: String, masked: String)
        case unreadableConfig
    }

    let id: String
    let agentName: String
    /// 挂靠的 Agent 分组 id（即所属 AgentDefinition.id）。
    let agentID: String
    let configPath: String
    let format: AgentMCPFormat
    let scope: String?
    let name: String
    let remote: Bool
    let endpoint: String
    let disabled: Bool
    let issues: [Issue]
}

struct AgentGroupSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let documented: Bool
    /// undocumented 工具且应用本体已找不到：数据为卸载残留。
    let orphaned: Bool
    let categoryIDs: [UUID]
    let skillIDs: [String]
    let serverIDs: [String]
    let bytes: UInt64
}

struct AgentScanReport: Sendable {
    var groups: [AgentGroupSummary] = []
    var categories: [CleanupCategory] = []
    var skills: [AgentSkill] = []
    var servers: [AgentMCPServer] = []
    var complete = true
}

/// Agent 专清的扫描：目录计量、Skills 清点与 MCP 配置体检。
/// MCP 配置在扫描阶段只读取；清理阶段的改写见 AgentMCPConfigEditor。
enum AgentInventory {
    static func scan(home: String = NSHomeDirectory(),
                     control: CleanupScanControl = CleanupScanControl(
                        mode: .deep, totalBudget: 180, directoryBudget: 30),
                     localize: (String) -> String = { $0 },
                     presence context: AgentPresenceContext? = nil) -> AgentScanReport {
        var report = AgentScanReport()
        let installed = AgentCatalog.definitions.filter { AgentCatalog.isInstalled($0, home: home) }
        let orphanedIDs = Set(installed.filter { AgentCatalog.isOrphaned($0, home: home, presence: context) }
            .map(\.id))
        // 已卸载工具不再是“Agent”：数据属于磁盘垃圾，由清理扫描按应用残留收录。
        let active = installed.filter { !orphanedIDs.contains($0.id) }
        let resolved = active.map { ($0, AgentCatalog.resolve($0, home: home, presence: context)) }
        let allPaths = Array(Set(resolved.flatMap { $0.1.flatMap(\.paths) })).sorted()
        let measurements = CleanupScanWorker.measure(allPaths, control: control) { _, _ in }
        var sizes: [String: UInt64] = [:]
        for (path, measurement) in zip(allPaths, measurements) {
            sizes[path] = measurement.bytes
            if !measurement.complete { report.complete = false }
        }

        report.skills = scanSkills(home: home, control: control, agents: active,
                                   orphanedAgentIDs: orphanedIDs)
        report.servers = scanMCP(agents: active, home: home)

        for (agent, targets) in resolved {
            var merged: [String: CleanupCategory] = [:]
            var order: [String] = []
            for target in targets {
                let paths = target.paths.filter { (sizes[$0] ?? 0) > 0 }
                guard !paths.isEmpty else { continue }
                let key = target.labelKey + "|" + target.tier.rawValue
                if var existing = merged[key] {
                    for path in paths { existing.appendPath(path, bytes: sizes[path] ?? 0) }
                    merged[key] = existing
                    continue
                }
                order.append(key)
                var category = CleanupCategory(
                    name: localize(target.labelKey),
                    paths: paths,
                    bytes: paths.reduce(0) { $0 &+ (sizes[$1] ?? 0) },
                    pathBytes: Dictionary(uniqueKeysWithValues: paths.map { ($0, sizes[$0] ?? 0) }),
                    source: target.tier == .safe ? .aiCache : .aiSession,
                    risk: risk(for: target.tier),
                    disposal: target.tier == .showOnly ? .none : .permanentDelete,
                    applyRoute: target.tier == .showOnly ? .none : .aiTrash,
                    activityGuard: .aiAgent,
                    reasonKey: reasonKey(for: target, documented: agent.documented))
                category.activityOwners = target.owners
                merged[key] = category
            }
            let categories = order.compactMap { merged[$0] }.sorted(by: CleanupCategory.sizeDescending)
            let skillIDs = report.skills.filter { $0.agentID == agent.id }.map(\.path)
            let serverIDs = report.servers.filter { $0.agentID == agent.id }.map(\.id)
            guard !categories.isEmpty || !skillIDs.isEmpty || !serverIDs.isEmpty else { continue }
            report.categories.append(contentsOf: categories)
            report.groups.append(AgentGroupSummary(
                id: agent.id, name: agent.name, documented: agent.documented,
                orphaned: orphanedIDs.contains(agent.id),
                categoryIDs: categories.map(\.id),
                skillIDs: skillIDs, serverIDs: serverIDs,
                bytes: categories.reduce(0) { $0 &+ $1.bytes }))
        }
        report.groups.sort { $0.bytes > $1.bytes }
        return report
    }

    private static func risk(for tier: AgentTier) -> CleanupRisk {
        switch tier {
        case .safe: return .safe
        case .review: return .warning
        case .showOnly: return .protected
        }
    }

    private static func reasonKey(for target: AgentCatalog.ResolvedTarget,
                                  documented: Bool) -> String {
        guard documented else { return "agents.reason.undocumented" }
        switch target.tier {
        case .safe:
            return target.labelKey == "agents.label.oldVersions"
                || target.labelKey == "agents.label.embeddedAgentVersions"
                ? "agents.reason.oldVersion" : "agents.reason.rebuildable"
        case .review: return "agents.reason.review"
        case .showOnly: return "agents.reason.showOnly"
        }
    }

    // MARK: - Skills

    /// Skill 挂靠规则：目录被多个 Agent 声明时归属第一个声明者，无人声明落到 "shared"。
    /// 只属于已卸载工具的 skills 目录随残留一起走清理漏斗，不出现在 Agent 页。
    static func scanSkills(home: String, control: CleanupScanControl,
                           agents: [AgentDefinition] = [],
                           orphanedAgentIDs: Set<String> = []) -> [AgentSkill] {
        let idsByAgentName = Dictionary(agents.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let orphanedNames = Set(AgentCatalog.definitions
            .filter { orphanedAgentIDs.contains($0.id) }.map(\.name))
        var skills: [AgentSkill] = []
        for directory in AgentCatalog.skillDirectories(home: home) {
            if !directory.agentNames.isEmpty,
               directory.agentNames.allSatisfy({ orphanedNames.contains($0) }) {
                continue
            }
            let ownerID = directory.agentNames.first.flatMap { idsByAgentName[$0] } ?? "shared"
            for name in AgentCatalog.childNames(of: directory.path) {
                let path = directory.path + "/" + name
                let linked = AgentCatalog.isSymlink(path)
                let resolved = linked
                    ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : path
                guard AgentCatalog.isDirectory(resolved) else { continue }
                let manifest = readManifest(resolved + "/SKILL.md")
                let bytes = linked ? 0 : CleanupScanWorker.measure(path, control: control).bytes
                skills.append(AgentSkill(
                    path: path, name: manifest.name ?? name, summary: manifest.summary ?? "",
                    directory: directory.path, usedBy: directory.agentNames, agentID: ownerID,
                    bytes: bytes,
                    identity: linked ? "" : (DeletionPlan.identity(at: path) ?? ""),
                    linked: linked, linkTarget: linked ? resolved : nil))
            }
        }
        return skills
    }

    /// 读取 SKILL.md 的 YAML front matter 中的 name / description。
    static func readManifest(_ path: String) -> (name: String?, summary: String?) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 16_384)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        var name: String?
        var summary: String?
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let value = frontMatterValue(line, key: "name") { name = value }
            if let value = frontMatterValue(line, key: "description") {
                summary = String(value.prefix(160))
            }
        }
        return (name, summary)
    }

    private static func frontMatterValue(_ line: String, key: String) -> String? {
        guard line.hasPrefix(key + ":") else { return nil }
        var value = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'",
           value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty || value == "|" || value == ">" ? nil : value
    }

    // MARK: - MCP（只读）

    static func scanMCP(agents: [AgentDefinition], home: String) -> [AgentMCPServer] {
        var servers: [AgentMCPServer] = []
        let searchPath = executableSearchPath(home: home)
        for agent in agents {
            for source in agent.mcpSources {
                let path = AgentCatalog.absolute(source.path, home: home)
                guard AgentCatalog.exists(path) else { continue }
                let entries: [(scope: String?, name: String, config: [String: Any])]?
                switch source.format {
                case .json(let keyPath): entries = jsonServers(at: path, keyPath: keyPath)
                case .toml(let table): entries = tomlServers(at: path, table: table)
                }
                guard let entries else {
                    servers.append(AgentMCPServer(
                        id: agent.id + "|" + path, agentName: agent.name, agentID: agent.id,
                        configPath: path, format: source.format,
                        scope: nil, name: (path as NSString).lastPathComponent, remote: false,
                        endpoint: "", disabled: false, issues: [.unreadableConfig]))
                    continue
                }
                for entry in entries {
                    servers.append(server(agent: agent, path: path, entry: entry,
                                          format: source.format,
                                          searchPath: searchPath, home: home))
                }
            }
        }
        return servers
    }

    private static func server(agent: AgentDefinition, path: String,
                               entry: (scope: String?, name: String, config: [String: Any]),
                               format: AgentMCPFormat,
                               searchPath: [String], home: String) -> AgentMCPServer {
        let config = entry.config
        var command: String?
        var arguments: [String] = []
        switch config["command"] {
        case let value as String:
            command = value
        case let values as [String]:
            command = values.first
            arguments = Array(values.dropFirst())
        case let nested as [String: Any]:
            command = nested["path"] as? String
            arguments = nested["args"] as? [String] ?? []
        default:
            break
        }
        if let args = config["args"] as? [String] { arguments += args }
        let url = ["url", "serverUrl", "httpUrl", "endpoint"].lazy
            .compactMap { config[$0] as? String }.first
        let disabled = (config["disabled"] as? Bool) == true || (config["enabled"] as? Bool) == false
        var issues: [AgentMCPServer.Issue] = []
        if let command, url == nil,
           resolveExecutable(command, searchPath: searchPath, home: home) == nil {
            issues.append(.commandMissing(command))
        }
        for key in ["env", "environment", "headers", "http_headers"] {
            guard let table = config[key] as? [String: Any] else { continue }
            for (name, value) in table.sorted(by: { $0.key < $1.key }) {
                guard let text = value as? String, isPlaintextSecret(name: name, value: text) else { continue }
                issues.append(.plaintextSecret(key: name, masked: mask(text)))
            }
        }
        if let url, let components = URLComponents(string: url) {
            for item in components.queryItems ?? [] {
                guard let value = item.value, isPlaintextSecret(name: item.name, value: value) else { continue }
                issues.append(.plaintextSecret(key: item.name, masked: mask(value)))
            }
        }
        let endpoint: String
        if let url {
            endpoint = maskURL(url)
        } else {
            endpoint = ([command ?? ""] + arguments).map(maskToken).joined(separator: " ")
        }
        return AgentMCPServer(
            id: agent.id + "|" + path + "|" + (entry.scope ?? "") + "|" + entry.name,
            agentName: agent.name, agentID: agent.id, configPath: path, format: format,
            scope: entry.scope, name: entry.name,
            remote: url != nil, endpoint: String(endpoint.prefix(180)), disabled: disabled,
            issues: issues)
    }

    static func jsonServers(at path: String, keyPath: String)
        -> [(scope: String?, name: String, config: [String: Any])]? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]))
                as? [String: Any] else { return nil }
        var result: [(scope: String?, name: String, config: [String: Any])] = []
        func collect(_ object: [String: Any], scope: String?) {
            var current: Any? = object
            for component in keyPath.split(separator: ".") {
                current = (current as? [String: Any])?[String(component)]
            }
            // 有的工具把整个 key 直接写成带点的名字（如 "amp.mcpServers"）。
            if current == nil { current = object[keyPath] }
            guard let table = current as? [String: Any] else { return }
            for (name, value) in table.sorted(by: { $0.key < $1.key }) {
                if let config = value as? [String: Any] { result.append((scope, name, config)) }
            }
        }
        collect(root, scope: nil)
        // Claude Code 在 ~/.claude.json 的 projects.<路径>.mcpServers 里保存项目级服务器。
        if let projects = root["projects"] as? [String: Any] {
            for (project, value) in projects.sorted(by: { $0.key < $1.key }) {
                if let object = value as? [String: Any] { collect(object, scope: project) }
            }
        }
        return result
    }

    /// 只解析 MCP 段需要的最小 TOML 子集：段头与 `key = "string" | [..] | bool`。
    static func tomlServers(at path: String, table: String)
        -> [(scope: String?, name: String, config: [String: Any])]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var order: [String] = []
        var configs: [String: [String: Any]] = [:]
        var currentName: String?
        var currentSub: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("[") {
                currentName = nil
                currentSub = nil
                guard line.hasPrefix("[" + table + "."), line.hasSuffix("]"),
                      !line.hasPrefix("[[") else { continue }
                let body = String(line.dropFirst(table.count + 2).dropLast())
                let parts = splitTomlKey(body)
                guard let name = parts.first, !name.isEmpty else { continue }
                currentName = name
                currentSub = parts.count > 1 ? parts[1] : nil
                if configs[name] == nil { order.append(name); configs[name] = [:] }
                continue
            }
            guard let name = currentName, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parseTomlValue(line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces))
            if let sub = currentSub {
                var nested = configs[name]?[sub] as? [String: Any] ?? [:]
                nested[key] = value
                configs[name]?[sub] = nested
            } else {
                configs[name]?[key] = value
            }
        }
        return order.map { (nil, $0, configs[$0] ?? [:]) }
    }

    private static func splitTomlKey(_ body: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in body {
            if character == "\"" { quoted.toggle(); continue }
            if character == "." && !quoted { parts.append(current); current = ""; continue }
            current.append(character)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTomlValue(_ raw: String) -> Any {
        if raw == "true" { return true }
        if raw == "false" { return false }
        if raw.hasPrefix("\"") || raw.hasPrefix("'") {
            let quote = raw.first!
            let body = raw.dropFirst()
            if let end = body.firstIndex(of: quote) { return String(body[..<end]) }
            return String(body)
        }
        if raw.hasPrefix("["), let end = raw.lastIndex(of: "]") {
            let inner = raw[raw.index(after: raw.startIndex)..<end]
            return inner.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }.filter { !$0.isEmpty }
        }
        return raw
    }

    // MARK: - 检查规则

    static func executableSearchPath(home: String) -> [String] {
        AgentCatalog.executableSearchPath(home: home)
    }

    static func resolveExecutable(_ command: String, searchPath: [String], home: String) -> String? {
        AgentCatalog.resolveExecutable(command, searchPath: searchPath, home: home)
    }

    static func isPlaintextSecret(name: String, value: String) -> Bool {
        let lowered = name.lowercased()
        let sensitive = ["token", "secret", "password", "passwd", "apikey", "api_key", "api-key",
                         "authorization", "auth", "credential", "private_key", "access_key", "key"]
        guard sensitive.contains(where: { lowered.contains($0) }) else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // 环境变量引用（$VAR、${VAR}、{env:VAR}）不是明文。
        if trimmed.hasPrefix("$") || trimmed.hasPrefix("{env:") || trimmed.hasPrefix("env:") {
            return false
        }
        let secretPart = trimmed.lowercased().hasPrefix("bearer ")
            ? String(trimmed.dropFirst(7)) : trimmed
        if secretPart.hasPrefix("$") || secretPart.hasPrefix("{env:") { return false }
        return secretPart.count >= 8
    }

    static func mask(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let prefix = trimmed.lowercased().hasPrefix("bearer ") ? "Bearer " : ""
        let secret = prefix.isEmpty ? trimmed : String(trimmed.dropFirst(7))
        return prefix + String(secret.prefix(4)) + "…(\(secret.count))"
    }

    /// 命令行里常见的密钥形态（sk-、ghp_、xoxb- 等）一律打码后再展示。
    static func maskToken(_ token: String) -> String {
        let prefixes = ["sk-", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "xoxa-", "AIza", "eyJ"]
        if let prefix = prefixes.first(where: { token.hasPrefix($0) }), token.count >= prefix.count + 8 {
            return prefix + "…"
        }
        if let equals = token.firstIndex(of: "=") {
            let key = String(token[..<equals])
            let value = String(token[token.index(after: equals)...])
            if isPlaintextSecret(name: key, value: value) { return key + "=" + mask(value) }
        }
        return token
    }

    private static func maskURL(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.queryItems = components.queryItems?.map { item in
            guard let value = item.value, isPlaintextSecret(name: item.name, value: value) else { return item }
            return URLQueryItem(name: item.name, value: String(value.prefix(4)) + "…")
        }
        components.password = components.password == nil ? nil : "…"
        return components.string ?? url
    }
}
