import Foundation

/// 与 UI 无关的执行计划，便于在测试中直接驱动。
enum AgentCleanupExecutor {
    struct Outcome {
        var summary: NativeCore.ApplySummary
        /// 复核阶段被拒绝（归属者在运行、目录不再认领、身份缺失）的条目数。
        var refused: Int
    }

    struct Plan {
        var items: [DeletionPlan.Item]
        var verified: Set<String>
        var families: [[String]]
        var refused: Int
    }

    static func plan(_ requested: [CleanupCategory],
                     running snapshot: RunningApplicationSnapshot,
                     home: String,
                     presence context: AgentPresenceContext? = nil,
                     removingAgentID: String? = nil) -> Plan {
        let catalogPaths = cleanupCatalogPaths(home: home, presence: context, removingAgentID: removingAgentID)
        let leftoverPaths = agentLeftoverPaths(for: requested, home: home, presence: context)
        let unknownSkillConfigs = AgentSkillConfigEditor.scanResult(home: home).unresolvedConfigPaths
        let freshTargets = AgentCatalog.definitions.filter {
            !AgentCatalog.isOrphaned($0, home: home, presence: context)
        }.flatMap { AgentCatalog.resolve($0, home: home, presence: context) }
        var items: [DeletionPlan.Item] = []
        var verified = Set<String>()
        var refused = 0
        for requestedCategory in requested {
            var category = requestedCategory
            let candidates = category.paths.filter(category.isPathSelected)
            if candidates.contains(where: { mayContainSkillBody($0, home: home) }),
               unknownSkillConfigs.contains(where: { config in
                   !candidates.contains { config == $0 || config.hasPrefix($0 + "/") }
               }) {
                refused += candidates.count
                continue
            }
            category.activityOwners = Array(Set(category.activityOwners + freshTargets.filter {
                !$0.paths.filter { candidates.contains($0) }.isEmpty
            }.flatMap(\.owners)))
            guard let subset = CleanupRiskPolicy.runtimeEligibleSubset(category, running: snapshot, homeDirectory: home),
                  CleanupRiskPolicy.isEligible(subset, mode: .manual, running: snapshot, homeDirectory: home) else {
                refused += candidates.count
                continue
            }
            for path in candidates {
                let known: Bool
                if isAgentLeftover(category) { known = leftoverPaths.contains(path) }
                else if category.reasonKey == "agents.reason.skill" {
                    known = AgentCatalog.isDeletableSkill(path, home: home)
                } else { known = catalogPaths.contains(path) }
                guard known, subset.isPathSelected(path),
                      let identity = category.pathIdentities[path], !identity.isEmpty else {
                    refused += 1
                    continue
                }
                items.append(DeletionPlan.Item(record: path, identity: identity))
                verified.insert(path)
            }
        }
        // 族成员以磁盘现状为准：未进入计划的成员（扫描后新出现的 -wal、
        // 用户只勾了伴随文件）没有身份，漏斗会因此保留整族。
        let planned = Set(items.map(\.record))
        var mains = Set<String>()
        for path in planned {
            let main = AgentCatalog.sqliteCompanionSuffixes.reduce(path) { current, suffix in
                current.hasSuffix(suffix) ? String(current.dropLast(suffix.count)) : current
            }
            let lowered = main.lowercased()
            if lowered.hasSuffix(".sqlite") || lowered.hasSuffix(".db") || lowered.hasSuffix(".vscdb") {
                mains.insert(main)
            }
        }
        let families: [[String]] = mains.sorted().compactMap { main in
            let members = ([main] + AgentCatalog.sqliteCompanionSuffixes.map { main + $0 })
                .filter { planned.contains($0) || AgentCatalog.exists($0) }
            return members.count > 1 ? members : nil
        }
        return Plan(items: items, verified: verified, families: families, refused: refused)
    }

    static func execute(_ requested: [CleanupCategory],
                        running snapshot: RunningApplicationSnapshot,
                        home: String,
                        permanent: Bool = false,
                        presence context: AgentPresenceContext? = nil,
                        skills: [AgentSkill] = [],
                        installations: [AgentMCPInstallation] = [],
                        servers: [AgentMCPServer] = [],
                        removingAgentID: String? = nil) -> Outcome {
        // 删除共享本体会波及所有挂靠，所以包含已卸载 Agent 中仍残留的注册。
        let allServers = AgentInventory.scanMCP(agents: AgentCatalog.definitions, home: home, presence: context)
        let knownInstallations = Set(allServers.compactMap(\.installationID))
        let launchersByInstallation = Dictionary(uniqueKeysWithValues: knownInstallations.map {
            ($0, mcpLauncherLinks($0, home: home))
        })
        let relatedLinks = skillLinks(home: home)
        let skillScan = AgentSkillConfigEditor.scanResult(home: home)
        let skillRegistrations = skillScan.registrations
        var categories = requested
        var refused = 0
        var preflightMessages: [String] = []
        let catalogPaths = cleanupCatalogPaths(home: home, presence: context, removingAgentID: removingAgentID)
        let leftoverPaths = agentLeftoverPaths(for: requested, home: home, presence: context)
        // 整个 Agent 根目录里也可能放着被其它 Agent 挂靠的 Skill 本体。
        // 根目录清理同样要计入这些使用者，不能绕过共享 Skill 的运行态复核。
        for index in categories.indices {
            let selectedPaths = categories[index].paths.filter(categories[index].isPathSelected)
                .filter {
                    if isAgentLeftover(categories[index]) { return leftoverPaths.contains($0) }
                    return catalogPaths.contains($0) || (categories[index].reasonKey == "agents.reason.skill"
                        && AgentCatalog.isDeletableSkill($0, home: home))
                }
            guard !selectedPaths.isEmpty else { continue }
            let linkedNames = relatedLinks.filter { link in
                selectedPaths.contains { link.target == $0 || link.target.hasPrefix($0 + "/") }
            }.flatMap(\.agentNames)
            let owners = AgentCatalog.definitions.filter { linkedNames.contains($0.name) }.flatMap {
                AgentCatalog.runtimeOwners(for: $0, home: home, presence: context)
            }
            let affectedDeclarations = skillRegistrations.filter { registration in
                selectedPaths.contains {
                    registration.resolvedPath == $0 || registration.resolvedPath.hasPrefix($0 + "/")
                }
            }
            let affectedServers = allServers.filter { server in
                guard let body = server.installationID else { return false }
                return selectedPaths.contains { body == $0 || body.hasPrefix($0 + "/") }
            }
            let codexOwners = !affectedDeclarations.isEmpty
                ? AgentCatalog.definitions.first(where: { $0.id == "codex" }).map {
                    AgentCatalog.runtimeOwners(for: $0, home: home, presence: context)
                } ?? [] : []
            let allOwners = categories[index].activityOwners + owners + codexOwners
                + affectedServers.flatMap { serverOwners($0, home: home, presence: context) }
            categories[index].activityOwners = Array(Set(allOwners))
            // 父目录的选择隐式授权移除内部本体，也必须先保证外部挂靠配置可备份。
            // 同时删掉的内部配置无需另改；外部配置任何一次失败都保留整分类。
            let externalDeclarations = affectedDeclarations.filter { declaration in
                !selectedPaths.contains { declaration.configPath == $0 || declaration.configPath.hasPrefix($0 + "/") }
            }
            let externalServers = affectedServers.filter { server in
                !selectedPaths.contains { server.configPath == $0 || server.configPath.hasPrefix($0 + "/") }
            }
            guard selectedPaths.allSatisfy({ resourceEligible(path: $0, owners: allOwners,
                running: snapshot, home: home) }),
                  externalDeclarations.allSatisfy({ declaration in
                      AgentMCPConfigEditor.backupConfiguration(declaration.configPath,
                        identity: declaration.configIdentity, fingerprint: declaration.configFingerprint)
                  }),
                  externalServers.allSatisfy({ server in
                      AgentMCPConfigEditor.backupConfiguration(server.configPath,
                        identity: server.configIdentity, fingerprint: server.configFingerprint)
                  }) else {
                refused += selectedPaths.count
                preflightMessages.append("Skipped Agent category with active dependencies or unavailable registration backups: "
                    + selectedPaths.joined(separator: ", "))
                categories[index] = categories[index].clearingSelection()
                continue
            }
        }
        var explicitLinks: [DeletionPlan.Item] = []
        for skill in skills {
            if !skill.linked && !skillScan.unresolvedConfigPaths.isEmpty {
                refused += 1
                preflightMessages.append("Kept Skill body because its registrations could not be verified: " + skill.path)
                continue
            }
            let declarations = skillRegistrations.filter { $0.references(skill.path) }
            let owners = skillOwners(skill, links: relatedLinks, home: home, presence: context)
                + (declarations.isEmpty ? [] : AgentCatalog.definitions.first(where: { $0.id == "codex" }).map {
                    AgentCatalog.runtimeOwners(for: $0, home: home, presence: context)
                } ?? [])
            guard !skill.identity.isEmpty,
                  resourceEligible(path: skill.path, owners: owners, running: snapshot, home: home),
                  declarations.allSatisfy({ declaration in
                      AgentMCPConfigEditor.backupConfiguration(declaration.configPath,
                        identity: declaration.configIdentity, fingerprint: declaration.configFingerprint)
                  }) else { refused += 1; continue }
            if skill.linked {
                guard isKnownSkillLink(skill.path, home: home) else { refused += 1; continue }
                explicitLinks.append(.init(record: skill.path, identity: skill.identity))
            } else {
                var category = CleanupCategory(
                    name: "Skills", paths: [skill.path], bytes: skill.bytes,
                    pathBytes: [skill.path: skill.bytes], pathIdentities: [skill.path: skill.identity],
                    selected: true, source: .aiSession, risk: .warning, disposal: .permanentDelete,
                    applyRoute: .aiTrash, activityGuard: .aiAgent, reasonKey: "agents.reason.skill")
                category.activityOwners = owners
                categories.append(category)
            }
        }
        let plan = plan(categories, running: snapshot, home: home, presence: context, removingAgentID: removingAgentID)
        var summaries: [NativeCore.ApplySummary] = []
        if !plan.items.isEmpty {
            summaries.append(NativeCore.shared.applyCleanup(
                items: plan.items, permanent: permanent, homeDirectory: home,
                verifiedTargets: plan.verified, atomicFamilies: plan.families))
        }
        var removedPaths = summaries.reduce(into: Set<String>()) { $0.formUnion($1.removedPaths) }
        var removedInstallationIDs = Set(knownInstallations.filter { body in
            removedPaths.contains { body == $0 || body.hasPrefix($0 + "/") }
        })
        var launcherLinks = removedInstallationIDs.flatMap { launchersByInstallation[$0] ?? [] }
        var launcherParents = Set(launcherLinks.map { ($0.record as NSString).deletingLastPathComponent })
        for installation in installations {
            if removedPaths.contains(where: { installation.path == $0 || installation.path.hasPrefix($0 + "/") }) {
                continue
            }
            let registrations = allServers.filter { $0.installationID == installation.id }
            let owners = registrations.flatMap { serverOwners($0, home: home, presence: context) }
            guard installation.id == installation.path, knownInstallations.contains(installation.path),
                  AgentInventory.isPhysicalInstallation(installation.path, home: home),
                  !installation.identity.isEmpty,
                  resourceEligible(path: installation.path, owners: owners, running: snapshot, home: home),
                  registrations.allSatisfy({ registration in
                      AgentMCPConfigEditor.backupConfiguration(registration.configPath,
                        identity: registration.configIdentity, fingerprint: registration.configFingerprint)
                  })
            else { refused += 1; continue }
            let launchers = launchersByInstallation[installation.path] ?? []
            let summary = NativeCore.shared.applyCleanup(
                items: [.init(record: installation.path, identity: installation.identity)],
                permanent: permanent, homeDirectory: home, allowedRoots: [installation.path],
                verifiedTargets: [installation.path])
            summaries.append(summary)
            if summary.removedPaths.contains(installation.path) {
                removedPaths.insert(installation.path)
                removedInstallationIDs.insert(installation.id)
                launcherLinks += launchers
                launcherParents.formUnion(launchers.map { ($0.record as NSString).deletingLastPathComponent })
            }
        }
        // 本体只有实际删除成功，才解除其它 Agent 的链接。链接身份来自删除前快照。
        let automaticLinks = relatedLinks.filter { link in
            removedPaths.contains { body in link.target == body || link.target.hasPrefix(body + "/") }
        }.map { DeletionPlan.Item(record: $0.path, identity: $0.identity) }
        let linkItems = (explicitLinks + automaticLinks + launcherLinks).filter { item in
            !removedPaths.contains { item.record == $0 || item.record.hasPrefix($0 + "/") }
        }.reduce(into: [DeletionPlan.Item]()) { result, item in
            if !result.contains(where: { $0.record == item.record }) { result.append(item) }
        }
        if !linkItems.isEmpty {
            summaries.append(NativeCore.shared.applyAgentSkillLinks(
                items: linkItems, homeDirectory: home, allowedDirectories: Array(launcherParents)))
        }
        let declarations = skillRegistrations.filter { declaration in
            !removedPaths.contains { declaration.configPath == $0 || declaration.configPath.hasPrefix($0 + "/") }
                && removedPaths.contains {
                    declaration.resolvedPath == $0 || declaration.resolvedPath.hasPrefix($0 + "/")
                }
        }
        let skillConfig = AgentSkillConfigEditor.apply(declarations)
        var registrations = servers
        registrations += allServers.filter { $0.installationID.map(removedInstallationIDs.contains) == true }
        registrations = registrations.filter { server in
            !removedPaths.contains { server.configPath == $0 || server.configPath.hasPrefix($0 + "/") }
        }
        registrations = registrations.reduce(into: []) { result, server in
            if !result.contains(where: { $0.configPath == server.configPath && $0.scope == server.scope
                && $0.name == server.name && $0.format == server.format }) { result.append(server) }
        }
        for index in registrations.indices where skillConfig.editedPaths.contains(registrations[index].configPath) {
            guard let declaration = skillRegistrations.first(where: { $0.configPath == registrations[index].configPath }),
                  registrations[index].configIdentity == declaration.configIdentity,
                  registrations[index].configFingerprint == declaration.configFingerprint else { continue }
            registrations[index].configIdentity = DeletionPlan.identity(at: registrations[index].configPath) ?? ""
            registrations[index].configFingerprint = AgentMCPConfigEditor.fingerprint(at: registrations[index].configPath) ?? ""
        }
        let rawConfigs = registrations.filter { $0.issues.contains(.unreadableConfig) }
        let knownConfigs = Set(AgentCatalog.definitions.flatMap { $0.mcpSources }
            .map { AgentCatalog.absolute($0.path, home: home) })
        var resetConfigs = Set<String>()
        for server in rawConfigs where resetConfigs.insert(server.configPath).inserted {
            guard knownConfigs.contains(server.configPath),
                  resourceEligible(path: server.configPath, owners: serverOwners(server, home: home, presence: context), running: snapshot, home: home),
                  AgentMCPConfigEditor.backupConfiguration(server.configPath,
                    identity: server.configIdentity, fingerprint: server.configFingerprint) else {
                refused += 1; continue
            }
            summaries.append(NativeCore.shared.applyCleanup(
                items: [.init(record: server.configPath, identity: server.configIdentity)],
                permanent: permanent, homeDirectory: home, verifiedTargets: [server.configPath],
                finalValidation: { AgentMCPConfigEditor.fingerprint(at: $0) == server.configFingerprint }))
        }
        let editable = registrations.filter { !resetConfigs.contains($0.configPath) }
        let requests = editable.compactMap { server -> AgentMCPConfigEditor.Request? in
            guard knownConfigs.contains(server.configPath), !server.issues.contains(.unreadableConfig),
                  resourceEligible(path: server.configPath, owners: serverOwners(server, home: home, presence: context), running: snapshot, home: home)
            else { refused += 1; return nil }
            return .init(configPath: server.configPath, format: server.format,
                         serverName: server.name, scope: server.scope,
                         expectedIdentity: server.configIdentity,
                         expectedFingerprint: server.configFingerprint)
        }
        let mcp = AgentMCPConfigEditor.apply(requests)
        return Outcome(summary: NativeCore.ApplySummary(
            removed: summaries.reduce(mcp.removed + skillConfig.removed) { $0 + $1.removed },
            skipped: summaries.reduce(mcp.missing + skillConfig.missing) { $0 + $1.skipped },
            failed: summaries.reduce(mcp.failed + skillConfig.failed) { $0 + $1.failed },
            messages: preflightMessages + summaries.flatMap(\.messages) + mcp.messages + skillConfig.messages,
            removedPaths: summaries.reduce(into: Set<String>()) { $0.formUnion($1.removedPaths) }),
            refused: plan.refused + refused)
    }

    private struct SkillLink {
        let path: String
        let target: String
        let identity: String
        let agentNames: [String]
    }

    /// 已成功卸载的 CLI 不再满足 installed；只复核该 Agent 的目录规则，
    /// 不扩大到数据根或扫描后新出现的路径。身份、进程和依赖复核仍由原执行器完成。
    private static func cleanupCatalogPaths(home: String, presence: AgentPresenceContext?,
                                            removingAgentID: String?) -> Set<String> {
        var paths = AgentCatalog.deletablePaths(home: home, presence: presence)
        if let removingAgentID,
           let agent = AgentCatalog.definitions.first(where: { $0.id == removingAgentID }) {
            paths.formUnion(AgentCatalog.resolve(agent, home: home, presence: presence).flatMap(\.paths))
        }
        return paths
    }

    private static func isAgentLeftover(_ category: CleanupCategory) -> Bool {
        category.source == .appLeftover && category.reasonKey == "cleanup.risk.agentLeftover"
    }

    private static func agentLeftoverPaths(for requested: [CleanupCategory], home: String,
                                            presence context: AgentPresenceContext?) -> Set<String> {
        guard requested.contains(where: isAgentLeftover) else { return [] }
        return Set(AgentCatalog.definitions.flatMap {
            AgentCatalog.orphanedDataRoots($0, home: home, presence: context)
        })
    }

    private static func skillLinks(home: String) -> [SkillLink] {
        AgentCatalog.skillDirectories(home: home).flatMap { directory in
            AgentCatalog.childNames(of: directory.path).compactMap { name -> SkillLink? in
                let path = directory.path + "/" + name
                guard AgentCatalog.isSymlink(path), let identity = DeletionPlan.identity(at: path) else { return nil }
                return SkillLink(path: path, target: URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                                 identity: identity, agentNames: directory.agentNames)
            }
        }
    }

    static func isKnownSkillLink(_ path: String, home: String) -> Bool {
        guard DeletionPlan.isLexicallySafePath(path), AgentCatalog.isSymlink(path) else { return false }
        return AgentCatalog.skillDirectories(home: home).contains {
            $0.path == (path as NSString).deletingLastPathComponent
        }
    }

    private static func skillOwners(_ skill: AgentSkill, links: [SkillLink], home: String,
                                    presence context: AgentPresenceContext?) -> [String] {
        let implicitUsers = AgentCatalog.skillDirectories(home: home)
            .filter { $0.path == skill.directory }.flatMap(\.agentNames)
        let names = Set(skill.usedBy + implicitUsers + links.filter { $0.target == skill.path }.flatMap(\.agentNames))
        return AgentCatalog.definitions.filter { names.contains($0.name) }.flatMap {
            AgentCatalog.runtimeOwners(for: $0, home: home, presence: context)
        }
    }

    private static func mayContainSkillBody(_ path: String, home: String) -> Bool {
        AgentCatalog.skillDirectories(home: home).contains { directory in
            directory.path == path || directory.path.hasPrefix(path + "/")
                || (path.hasPrefix(directory.path + "/") && AgentCatalog.isDeletableSkill(path, home: home))
        }
    }

    private static func serverOwners(_ server: AgentMCPServer, home: String,
                                     presence context: AgentPresenceContext?) -> [String] {
        AgentCatalog.definitions.first { $0.id == server.agentID }.map {
            AgentCatalog.runtimeOwners(for: $0, home: home, presence: context)
        } ?? []
    }

    private static func resourceEligible(path: String, owners: [String],
                                          running snapshot: RunningApplicationSnapshot, home: String) -> Bool {
        var category = CleanupCategory(name: "Agent resources", paths: [path], bytes: 0, selected: true,
            source: .aiSession, risk: .warning, disposal: .permanentDelete, applyRoute: .aiTrash,
            activityGuard: .aiAgent, reasonKey: "agents.reason.review")
        category.activityOwners = owners
        return CleanupRiskPolicy.isEligible(category, mode: .manual, running: snapshot, homeDirectory: home)
    }

    private static func mcpLauncherLinks(_ body: String, home: String) -> [DeletionPlan.Item] {
        var parents = AgentCatalog.executableSearchPath(home: home)
        if let range = body.range(of: "/lib/node_modules/") {
            parents.append(String(body[..<range.lowerBound]) + "/bin")
        }
        return Set(parents).flatMap { parent in
            AgentCatalog.childNames(of: parent).compactMap { name -> DeletionPlan.Item? in
                let path = parent + "/" + name
                guard AgentCatalog.isSymlink(path), let identity = DeletionPlan.identity(at: path) else { return nil }
                let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard target == body || target.hasPrefix(body + "/") else { return nil }
                return .init(record: path, identity: identity)
            }
        }
    }
}
