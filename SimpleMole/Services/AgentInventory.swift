import Foundation

struct AgentSkill: Identifiable, Equatable, Sendable {
    let path: String
    var id: String { path }
    let name: String
    let summary: String
    let directory: String
    var usedBy: [String]
    /// 挂靠的 Agent 分组 id；共享目录落到 "shared"。
    var agentID: String
    let bytes: UInt64
    let identity: String
    /// 链接清理仅解除关联；identity 绑定链接自身，绝不删除 linkTarget。
    let linked: Bool
    let linkTarget: String?
    var measurementComplete = true
}

struct AgentMCPServer: Identifiable, Equatable, Sendable {
    enum Issue: Hashable, Sendable {
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
    var installationID: String? = nil
    var configIdentity: String = ""
    var configFingerprint: String = ""
}

/// MCP 安装本体与各 Agent 的注册分开管理。远程服务、临时 npx/uvx 下载和
/// node/python 等共享运行时不会被误认成可卸载的 MCP 本体。
struct AgentMCPInstallation: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    let bytes: UInt64
    let identity: String
    let serverIDs: [String]
    var measurementComplete = true
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
    var installations: [AgentMCPInstallation] = []
    var complete = true
}

/// Agent 专清的扫描：目录计量、Skills 清点与 MCP 配置体检。
/// MCP 配置在扫描阶段只读取；清理阶段的改写见 AgentMCPConfigEditor。
enum AgentInventory {
    static func scan(home: String = NSHomeDirectory(),
                     control: CleanupScanControl = CleanupScanControl(
                        mode: .deep, totalBudget: 180, directoryBudget: 30),
                     localize: (String) -> String = { $0 },
                     presence context: AgentPresenceContext? = nil,
                     includingAgentIDs: Set<String> = []) -> AgentScanReport {
        var report = AgentScanReport()
        let whitelist = NativeCore.shared.loadWhitelist(homeDirectory: home)
        let installed = AgentCatalog.definitions.filter {
            AgentCatalog.hasData($0, home: home) || AgentCatalog.isInstalled($0, home: home, presence: context)
        }
        let orphanedIDs = Set(installed.filter { AgentCatalog.isOrphaned($0, home: home, presence: context) }
            .map(\.id))
        // Removed tools remain available only through an explicitly resumed
        // Agent cleanup; their history is never ordinary junk.
        let active = installed.filter { !orphanedIDs.contains($0.id) || includingAgentIDs.contains($0.id) }
        let discoveredResolved = active.map { agent in
            (agent, AgentCatalog.resolve(agent, home: home, presence: context).compactMap { target -> AgentCatalog.ResolvedTarget? in
                let paths = target.paths.filter { !NativeCore.shared.matchesWhitelist($0, entries: whitelist) }
                guard !paths.isEmpty else { return nil }
                return AgentCatalog.ResolvedTarget(agentID: target.agentID, tier: target.tier,
                    labelKey: target.labelKey, owners: target.owners, paths: paths)
            })
        }
        let allRegistrations = scanMCP(agents: AgentCatalog.definitions, home: home, presence: context)
        let skillDeclarations = NativeCore.shared.matchesWhitelist(home + "/.codex/config.toml", entries: whitelist)
            ? [] : AgentSkillConfigEditor.scan(home: home)
        let registeredBodies = Set(allRegistrations.compactMap(\.installationID) + skillDeclarations.map {
            $0.resolvedPath.hasSuffix("/SKILL.md")
                ? ($0.resolvedPath as NSString).deletingLastPathComponent : $0.resolvedPath
        })
        var cacheInputs: [CleanupCategory] = []
        var cacheInputIDs: [String: UUID] = [:]
        for (agentIndex, entry) in discoveredResolved.enumerated() {
            for (targetIndex, target) in entry.1.enumerated() where target.tier == .safe {
                let input = CleanupCategory(name: target.labelKey, paths: target.paths, bytes: 0,
                    selected: true, source: .aiCache, risk: .safe, disposal: .permanentDelete,
                    applyRoute: .aiTrash, activityGuard: .aiAgent, reasonKey: "agents.reason.rebuildable")
                cacheInputs.append(input)
                cacheInputIDs["\(agentIndex):\(targetIndex)"] = input.id
            }
        }
        let cacheScan = cacheInputs.isEmpty ? nil : NativeCore.shared.preflightCleanupCategories(cacheInputs,
            homeDirectory: home, control: control,
            verifiedRebuildableRoots: Set(cacheInputs.flatMap(\.paths)), excludingPaths: registeredBodies)
        if let cacheScan, !cacheScan.succeeded || !cacheScan.deferredPaths.isEmpty { report.complete = false }
        let cacheCategories = Dictionary((cacheScan?.categories ?? []).map { ($0.id, $0) },
                                         uniquingKeysWith: { first, _ in first })
        let cacheSizes = (cacheScan?.categories ?? []).reduce(into: [String: UInt64]()) {
            $0.merge($1.pathBytes, uniquingKeysWith: { first, _ in first })
        }
        let rawResolved = discoveredResolved.enumerated().map { agentIndex, entry in
            (entry.0, entry.1.enumerated().compactMap { targetIndex, target -> AgentCatalog.ResolvedTarget? in
                guard target.tier == .safe else { return target }
                guard let id = cacheInputIDs["\(agentIndex):\(targetIndex)"],
                      let category = cacheCategories[id], !category.paths.isEmpty else { return nil }
                return AgentCatalog.ResolvedTarget(agentID: target.agentID, tier: target.tier,
                    labelKey: target.labelKey, owners: target.owners, paths: category.paths)
            })
        }
        // 同一实体只在一个组产生操作项，但守卫保留所有消费者。
        var pathOwners: [String: Set<String>] = [:]
        var pathTiers: [String: AgentTier] = [:]
        func severity(_ tier: AgentTier) -> Int { tier == .showOnly ? 2 : tier == .review ? 1 : 0 }
        for (_, targets) in rawResolved {
            for target in targets {
                for path in target.paths {
                    pathOwners[path, default: []].formUnion(target.owners)
                    if severity(target.tier) > severity(pathTiers[path] ?? .safe) { pathTiers[path] = target.tier }
                }
            }
        }
        var claimed = Set<String>()
        let resolved = rawResolved.map { agent, targets in
            (agent, targets.compactMap { target -> AgentCatalog.ResolvedTarget? in
                let paths = target.paths.filter { claimed.insert($0).inserted }
                guard !paths.isEmpty else { return nil }
                let tier = paths.compactMap { pathTiers[$0] }.max { severity($0) < severity($1) } ?? target.tier
                let owners = Set(paths.flatMap { Array(pathOwners[$0] ?? []) }).sorted()
                return AgentCatalog.ResolvedTarget(agentID: target.agentID, tier: tier,
                    labelKey: target.labelKey, owners: owners, paths: paths)
            })
        }
        let allPaths = Array(Set(resolved.flatMap { $0.1.flatMap(\.paths) }).subtracting(cacheSizes.keys)).sorted()
        let measurements = CleanupScanWorker.measure(allPaths, control: control) { _, _ in }
        var sizes = cacheSizes
        for (path, measurement) in zip(allPaths, measurements) {
            sizes[path] = measurement.bytes
            if !measurement.complete { report.complete = false }
        }

        report.skills = scanSkills(home: home, control: control, agents: active,
                                   orphanedAgentIDs: orphanedIDs.subtracting(includingAgentIDs))
        let activeIDs = Set(active.map(\.id))
        report.servers = allRegistrations.filter { activeIDs.contains($0.agentID) }
        report.installations = mcpInstallations(servers: allRegistrations, home: home, control: control)
        report.complete = report.complete && report.skills.allSatisfy(\.measurementComplete)
            && report.installations.allSatisfy(\.measurementComplete)

        for (agent, targets) in resolved {
            var merged: [String: CleanupCategory] = [:]
            var order: [String] = []
            for target in targets {
                let paths = target.paths.filter { (sizes[$0] ?? 0) > 0 }
                guard !paths.isEmpty else { continue }
                let key = target.labelKey + "|" + target.tier.rawValue
                if var existing = merged[key] {
                    for path in paths {
                        existing.appendPath(path, bytes: sizes[path] ?? 0)
                        if isDefaultCleanupSelection(target, documented: agent.documented) {
                            existing.setPathSelected(path, selected: true)
                        }
                    }
                    merged[key] = existing
                    continue
                }
                order.append(key)
                var category = CleanupCategory(
                    name: localize(target.labelKey),
                    paths: paths,
                    bytes: paths.reduce(0) { $0 &+ (sizes[$1] ?? 0) },
                    pathBytes: Dictionary(uniqueKeysWithValues: paths.map { ($0, sizes[$0] ?? 0) }),
                    selected: isDefaultCleanupSelection(target, documented: agent.documented),
                    source: target.tier == .safe ? .aiCache : .aiSession,
                    risk: risk(for: target.tier),
                    disposal: .permanentDelete,
                    applyRoute: .aiTrash,
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
        let sharedSkills = report.skills.filter { $0.agentID == "shared" }
        if !sharedSkills.isEmpty, !report.groups.contains(where: { $0.id == "shared" }) {
            report.groups.append(AgentGroupSummary(
                id: "shared", name: localize("agents.sharedSkills"), documented: true,
                orphaned: false, categoryIDs: [], skillIDs: sharedSkills.map(\.id), serverIDs: [],
                bytes: sharedSkills.reduce(0) { $0 &+ $1.bytes }))
        }
        if !report.installations.isEmpty {
            report.groups.append(AgentGroupSummary(
                id: "shared-mcp", name: localize("agents.sharedMCP"), documented: true,
                orphaned: false, categoryIDs: [], skillIDs: [], serverIDs: [],
                bytes: report.installations.reduce(0) { $0 &+ $1.bytes }))
        }
        report.groups.sort { $0.bytes > $1.bytes }
        return report
    }

    private static func risk(for tier: AgentTier) -> CleanupRisk {
        switch tier {
        case .safe: return .safe
        case .review: return .warning
        case .showOnly: return .warning
        }
    }

    /// Default selection is a cleanup recommendation, not a lower risk tier.
    /// Checkpoints and reviewed logs/cache still retain their owner and identity
    /// guards. Live conversations, state, credentials and installations are
    /// left for an explicit selection.
    private static func isDefaultCleanupSelection(_ target: AgentCatalog.ResolvedTarget,
                                                   documented: Bool) -> Bool {
        if target.tier == .safe { return true }
        guard documented, target.tier == .review else { return false }
        return ["agents.label.cache", "agents.label.logs", "agents.label.logDatabase",
                "agents.label.tempFiles", "agents.label.checkpoints"].contains(target.labelKey)
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
        let codexInstalled = agents.contains { $0.id == "codex" }
        let codexName = AgentCatalog.definitions.first { $0.id == "codex" }?.name ?? "Codex CLI"
        let whitelist = NativeCore.shared.loadWhitelist(homeDirectory: home)
        let declarations = NativeCore.shared.matchesWhitelist(home + "/.codex/config.toml", entries: whitelist)
            ? [] : AgentSkillConfigEditor.scan(home: home)
        let allLinkUsers = AgentCatalog.skillDirectories(home: home).flatMap { directory in
            AgentCatalog.childNames(of: directory.path).compactMap { name -> (String, [String])? in
                let path = directory.path + "/" + name
                guard !NativeCore.shared.matchesWhitelist(path, entries: whitelist) else { return nil }
                guard AgentCatalog.isSymlink(path) else { return nil }
                return (URL(fileURLWithPath: path).resolvingSymlinksInPath().path, directory.agentNames)
            }
        }
        var skills: [AgentSkill] = []
        for directory in AgentCatalog.skillDirectories(home: home) {
            let liveUsers = directory.agentNames.filter { idsByAgentName[$0] != nil }
            let orphanedDirectory = !directory.globallyManaged && !directory.ownerNames.isEmpty
                && directory.ownerNames.allSatisfy({ orphanedNames.contains($0) }) && liveUsers.isEmpty
            let ownerID = directory.globallyManaged ? "shared"
                : directory.ownerNames.first.flatMap { idsByAgentName[$0] } ?? "shared"
            for name in AgentCatalog.childNames(of: directory.path) {
                let path = directory.path + "/" + name
                guard !NativeCore.shared.matchesWhitelist(path, entries: whitelist) else { continue }
                let linked = AgentCatalog.isSymlink(path)
                let resolved = linked
                    ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : path
                let hasLiveLink = allLinkUsers.contains {
                    $0.0 == path && $0.1.contains { idsByAgentName[$0] != nil }
                }
                let hasLiveDeclaration = codexInstalled
                    && declarations.contains { $0.references(path) }
                if orphanedDirectory && (linked || (!hasLiveLink && !hasLiveDeclaration)) { continue }
                // 悬空链接也要可解除；扫描不跟着链接递归计量。
                guard linked || AgentCatalog.isDirectory(resolved) else { continue }
                let manifest = readManifest(resolved + "/SKILL.md")
                let measurement = linked ? nil : CleanupScanWorker.measure(path, control: control)
                var skill = AgentSkill(
                    path: path, name: manifest.name ?? name, summary: manifest.summary ?? "",
                    directory: directory.path, usedBy: liveUsers,
                    agentID: orphanedDirectory ? "shared" : ownerID,
                    bytes: measurement?.bytes ?? 0,
                    identity: DeletionPlan.identity(at: path) ?? "",
                    linked: linked, linkTarget: linked ? resolved : nil)
                skill.measurementComplete = measurement?.complete ?? true
                skills.append(skill)
            }
        }
        // 共享本体展示实际使用者；不因某个 Agent 已卸载而漏掉其尚存的挂靠。
        for index in skills.indices where !skills[index].linked {
            let users = allLinkUsers.filter { $0.0 == skills[index].path }.flatMap { $0.1 }
            let explicitUsers = declarations.contains { $0.references(skills[index].path) } ? [codexName] : []
            skills[index].usedBy = Array(Set(skills[index].usedBy + users + explicitUsers)).sorted()
            if skills[index].usedBy.count > 1 { skills[index].agentID = "shared" }
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

    static func scanMCP(agents: [AgentDefinition], home: String,
                        presence context: AgentPresenceContext? = nil,
                        excludingWhitelist: Bool = true) -> [AgentMCPServer] {
        var servers: [AgentMCPServer] = []
        let whitelist = excludingWhitelist ? NativeCore.shared.loadWhitelist(homeDirectory: home) : []
        let searchPath = context?.searchPath ?? executableSearchPath(home: home)
        for agent in agents {
            for source in agent.mcpSources {
                let path = AgentCatalog.absolute(source.path, home: home)
                guard !NativeCore.shared.matchesWhitelist(path, entries: whitelist) else { continue }
                guard AgentCatalog.exists(path) else { continue }
                let entries: [(scope: String?, name: String, config: [String: Any])]?
                switch source.format {
                case .json(let keyPath): entries = jsonServers(at: path, keyPath: keyPath)
                case .toml(let table): entries = tomlServers(at: path, table: table)
                }
                guard let entries else {
                    var unreadable = AgentMCPServer(
                        id: agent.id + "|" + path, agentName: agent.name, agentID: agent.id,
                        configPath: path, format: source.format,
                        scope: nil, name: (path as NSString).lastPathComponent, remote: false,
                        endpoint: "", disabled: false, issues: [.unreadableConfig])
                    unreadable.configIdentity = DeletionPlan.identity(at: path) ?? ""
                    unreadable.configFingerprint = AgentMCPConfigEditor.fingerprint(at: path) ?? ""
                    servers.append(unreadable)
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
        var result = AgentMCPServer(
            id: agent.id + "|" + path + "|" + (entry.scope ?? "") + "|" + entry.name,
            agentName: agent.name, agentID: agent.id, configPath: path, format: format,
            scope: entry.scope, name: entry.name,
            remote: url != nil, endpoint: String(endpoint.prefix(180)), disabled: disabled,
            issues: issues)
        result.configIdentity = DeletionPlan.identity(at: path) ?? ""
        result.configFingerprint = AgentMCPConfigEditor.fingerprint(at: path) ?? ""
        if url == nil, let command {
            result.installationID = mcpInstallationPath(command: command, arguments: arguments,
                                                        searchPath: searchPath, home: home)
        }
        return result
    }

    static func mcpInstallations(servers: [AgentMCPServer], home: String,
                                control: CleanupScanControl = CleanupScanControl(mode: .deep))
        -> [AgentMCPInstallation] {
        let grouped = Dictionary(grouping: servers.filter { $0.installationID != nil },
                                 by: { $0.installationID! })
        let whitelist = NativeCore.shared.loadWhitelist(homeDirectory: home)
        return grouped.sorted(by: { $0.key < $1.key }).compactMap { path, registrations in
            guard !NativeCore.shared.matchesWhitelist(path, entries: whitelist),
                  let identity = DeletionPlan.identity(at: path),
                  isPhysicalInstallation(path, home: home) else { return nil }
            let measurement = CleanupScanWorker.measure(path, control: control)
            var installation = AgentMCPInstallation(
                id: path, name: registrations.first?.name ?? (path as NSString).lastPathComponent,
                path: path, bytes: measurement.bytes,
                identity: identity, serverIDs: registrations.map(\.id))
            installation.measurementComplete = measurement.complete
            return installation
        }
    }

    /// npm 的包目录必须由 package.json 的 name 和 bin 共同证明；不删除 npm/npx/node。
    static func mcpInstallationPath(command: String, arguments: [String],
                                    searchPath: [String], home: String) -> String? {
        let executableName = (command as NSString).lastPathComponent
        let hostCommands = Set(AgentCatalog.definitions.flatMap {
            AgentCatalog.installationPresence(for: $0)?.commands ?? []
        } + ["agent"])
        if hostCommands.contains(executableName) { return nil }
        if executableName == "npx" || executableName == "bunx" {
            var package: String?
            if let option = arguments.firstIndex(where: { $0 == "-p" || $0 == "--package" }),
               arguments.indices.contains(option + 1) {
                package = arguments[option + 1]
            } else {
                package = arguments.first { !$0.hasPrefix("-") }
            }
            guard var name = package, !name.contains(":"), !name.hasPrefix("/"),
                  !name.contains("..") else { return nil }
            if let version = name.dropFirst().lastIndex(of: "@") { name = String(name[..<version]) }
            guard name.split(separator: "/").count <= 2,
                  name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn:
                    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@/_.-").contains($0) })
            else { return nil }
            let roots = globalNodeModuleRoots(searchPath: searchPath, home: home)
            return roots.map { $0 + "/" + name }.first {
                validNodePackage($0, expectedName: name, home: home)
            }
        }
        let runtimes = ["node", "nodejs", "python", "python3", "python2", "uv", "uvx", "pip", "pipx",
                        "ruby", "java", "deno", "bun", "npm", "pnpm", "yarn", "sh", "bash", "zsh",
                        "env", "docker", "podman", "ssh", "git", "curl", "osascript", "open"]
        if runtimes.contains(executableName) {
            guard ["node", "nodejs", "bun"].contains(executableName),
                  let script = arguments.first(where: { $0.hasPrefix("/") }),
                  let root = nodePackageRoot(containing: script),
                  validNodePackage(root, expectedName: nil, home: home) else { return nil }
            return root
        }
        guard let resolved = resolveExecutable(command, searchPath: searchPath, home: home),
              resolved.hasPrefix("/") else { return nil }
        let physical = URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
        if let root = nodePackageRoot(containing: physical),
           validNodePackage(root, expectedName: nil, home: home) { return root }
        // 只认 home 中命名明确的 MCP 独立可执行文件；系统工具和宿主 Agent 不做本体卸载。
        guard (physical as NSString).lastPathComponent.lowercased().contains("mcp"),
              !AgentCatalog.isDirectory(physical), isPhysicalInstallation(physical, home: home),
              physical.hasPrefix(home + "/") else { return nil }
        return physical
    }

    private static func globalNodeModuleRoots(searchPath: [String], home: String) -> [String] {
        let prefixes = searchPath.filter { $0.hasSuffix("/bin") }
            .map { String($0.dropLast(4)) + "/lib/node_modules" }
        return Array(Set(prefixes + [home + "/.npm-global/lib/node_modules",
                                      home + "/.local/lib/node_modules",
                                      home + "/.bun/install/global/node_modules",
                                      "/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules"]))
    }

    private static func nodePackageRoot(containing path: String) -> String? {
        guard let range = path.range(of: "/node_modules/", options: .backwards) else { return nil }
        let base = String(path[..<range.upperBound])
        let parts = path[range.upperBound...].split(separator: "/")
        guard let first = parts.first else { return nil }
        let count = first.hasPrefix("@") ? 2 : 1
        guard parts.count >= count else { return nil }
        return base + parts.prefix(count).joined(separator: "/")
    }

    private static func validNodePackage(_ path: String, expectedName: String?, home: String) -> Bool {
        guard !NativeCore.shared.matchesWhitelist(path,
                    entries: NativeCore.shared.loadWhitelist(homeDirectory: home)),
              isPhysicalInstallation(path, home: home), AgentCatalog.isDirectory(path),
              let data = FileManager.default.contents(atPath: path + "/package.json"),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = manifest["name"] as? String,
              expectedName == nil || expectedName == name else { return false }
        let executables: [String]
        if ["npm", "npx", "node", "pnpm", "yarn", "bun", "typescript"].contains(name)
            || AgentCLIService.ownsNPMPackage(name) { return false }
        if let bin = manifest["bin"] as? String { executables = [bin] }
        else if let bins = manifest["bin"] as? [String: String] {
            let hostCommands = Set(AgentCatalog.definitions.flatMap {
                AgentCatalog.installationPresence(for: $0)?.commands ?? []
            } + ["agent"])
            guard bins.keys.allSatisfy({ !hostCommands.contains($0) }) else { return false }
            executables = Array(bins.values)
        }
        else { return false }
        return executables.contains { bin in
            let executable = URL(fileURLWithPath: path).appendingPathComponent(bin).standardizedFileURL.path
            return executable.hasPrefix(path + "/") && AgentCatalog.exists(executable)
                && !AgentCatalog.isSymlink(executable)
        }
    }

    static func isPhysicalInstallation(_ path: String, home: String) -> Bool {
        guard DeletionPlan.isLexicallySafePath(path), AgentCatalog.exists(path),
              path.hasPrefix(home + "/") || path.hasPrefix("/opt/homebrew/lib/node_modules/")
                || path.hasPrefix("/usr/local/lib/node_modules/") else { return false }
        var probe = path
        while probe != "/" {
            if AgentCatalog.isSymlink(probe) { return false }
            probe = (probe as NSString).deletingLastPathComponent
        }
        return true
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

    /// 只解析 MCP 段需要的 TOML 子集，跨行字符串和数组不会产生伪段头。
    static func tomlServers(at path: String, table: String)
        -> [(scope: String?, name: String, config: [String: Any])]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let statements = AgentTOMLStatements.read(text) else { return nil }
        var order: [String] = []
        var configs: [String: [String: Any]] = [:]
        var currentName: String?
        var currentSub: String?
        var currentTable: [String] = []
        for statement in statements {
            if let header = AgentTOMLStatements.header(statement.text) {
                currentTable = header.path
                currentName = nil
                currentSub = nil
                guard header.path.first == table else { continue }
                guard !header.array, header.path.count <= 3 else { return nil }
                guard header.path.count >= 2 else { continue }
                let name = header.path[1]
                currentName = name
                currentSub = header.path.count == 3 ? header.path[2] : nil
                if configs[name] == nil { order.append(name); configs[name] = [:] }
                continue
            }
            guard let name = currentName else {
                if let item = AgentTOMLStatements.assignment(statement.text),
                   item.path.first == table || currentTable == [table] { return nil }
                continue
            }
            guard let item = AgentTOMLStatements.assignment(statement.text),
                  item.path.count <= (currentSub == nil ? 2 : 1),
                  let value = AgentTOMLStatements.value(item.value) else { return nil }
            let key = item.path.last!
            let sub = currentSub ?? (item.path.count == 2 ? item.path[0] : nil)
            if let sub {
                var nested = configs[name]?[sub] as? [String: Any] ?? [:]
                guard nested[key] == nil else { return nil }
                nested[key] = value
                configs[name]?[sub] = nested
            } else {
                guard configs[name]?[key] == nil else { return nil }
                configs[name]?[key] = value
            }
        }
        return order.map { (nil, $0, configs[$0] ?? [:]) }
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
