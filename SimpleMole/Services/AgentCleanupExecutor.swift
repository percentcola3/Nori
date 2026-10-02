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
        var messages: [String]
        var liveTargets: Set<String>
    }

    struct BlockingResources {
        var paths = Set<String>()
        var skillPaths = Set<String>()
        var installationIDs = Set<String>()
        var serverIDs = Set<String>()
        var owners: [String] = []
    }

    /// Read-only preflight for the UI's close-and-recheck prompt. The execution
    /// path repeats these owner checks using a fresh snapshot at mutation time.
    static func blockingOwners(_ requested: [CleanupCategory],
                               skills: [AgentSkill] = [],
                               installations: [AgentMCPInstallation] = [],
                               servers: [AgentMCPServer] = [],
                               running snapshot: RunningApplicationSnapshot,
                               home: String,
                               presence context: AgentPresenceContext? = nil,
                               removingAgentID: String? = nil,
                               removingAgentIDs: Set<String> = []) -> [String] {
        blockingResources(requested, skills: skills, installations: installations, servers: servers,
            running: snapshot, home: home, presence: context, removingAgentID: removingAgentID,
            removingAgentIDs: removingAgentIDs).owners
    }

    static func blockingResources(_ requested: [CleanupCategory],
                                  skills: [AgentSkill] = [],
                                  installations: [AgentMCPInstallation] = [],
                                  servers: [AgentMCPServer] = [],
                                  running snapshot: RunningApplicationSnapshot,
                                  home: String,
                                  presence context: AgentPresenceContext? = nil,
                                  removingAgentID: String? = nil,
                                  removingAgentIDs: Set<String> = []) -> BlockingResources {
        let removalIDs = removingAgentIDs.union(removingAgentID.map { [$0] } ?? [])
        let allServers = AgentInventory.scanMCP(agents: AgentCatalog.definitions, home: home,
            presence: context, excludingWhitelist: false)
        let links = skillLinks(home: home)
        let declarations = AgentSkillConfigEditor.scan(home: home)
        let catalogPaths = cleanupCatalogPaths(home: home, presence: context, removingAgentIDs: removalIDs)
        let leftoverPaths = agentLeftoverPaths(for: requested, home: home, presence: context)
        let freshTargets = currentTargets(home: home, presence: context, removingAgentIDs: removalIDs)
        let rebuildablePaths = rebuildablePaths(in: freshTargets)
        var result = BlockingResources()
        var owners = Set<String>()
        func isBlocked(_ resourceOwners: [String]) -> Bool {
            let matching = resourceOwners.filter {
                snapshot.contains(bundleIdentifier: $0) || snapshot.contains(processName: $0)
            }
            owners.formUnion(matching)
            return !snapshot.isComplete || !matching.isEmpty
        }
        for category in requested {
            let paths = knownSelectedPaths(category, catalogPaths: catalogPaths,
                leftoverPaths: leftoverPaths, rebuildablePaths: rebuildablePaths, home: home)
            guard !paths.isEmpty else { continue }
            for path in paths {
                let freshOwners = freshTargets.filter { $0.paths.contains(path) }.flatMap(\.owners)
                let dependencies = categoryDependencies(paths: [path],
                    owners: category.activityOwners + freshOwners, links: links,
                    declarations: declarations, servers: allServers, home: home, presence: context)
                if isRebuildable(category, paths: [path], verifiedPaths: rebuildablePaths, home: home),
                   !dependencies.hasProtectedResources { continue }
                if isBlocked(dependencies.owners) { result.paths.insert(path) }
            }
        }
        for skill in skills {
            let registrations = skillDeclarations(skill, declarations: declarations, home: home)
            if isBlocked(skillOwners(skill, links: links, home: home, presence: context)
                + declarationOwners(registrations, home: home, presence: context)) {
                result.skillPaths.insert(skill.path)
            }
        }
        for installation in installations {
            if isBlocked(allServers.filter { $0.installationID == installation.id }
                .flatMap { serverOwners($0, home: home, presence: context) }) {
                result.installationIDs.insert(installation.id)
            }
        }
        for server in servers where isBlocked(serverOwners(server, home: home, presence: context)) {
            result.serverIDs.insert(server.id)
        }
        result.owners = snapshot.isComplete ? owners.sorted() : []
        return result
    }

    static func plan(_ requested: [CleanupCategory],
                     running snapshot: RunningApplicationSnapshot,
                     home: String,
                     presence context: AgentPresenceContext? = nil,
                     removingAgentID: String? = nil,
                     removingAgentIDs: Set<String> = []) -> Plan {
        let removalIDs = removingAgentIDs.union(removingAgentID.map { [$0] } ?? [])
        let catalogPaths = cleanupCatalogPaths(home: home, presence: context, removingAgentIDs: removalIDs)
        let leftoverPaths = agentLeftoverPaths(for: requested, home: home, presence: context)
        let skillScan = AgentSkillConfigEditor.scanResult(home: home)
        let unknownSkillConfigs = skillScan.unresolvedConfigPaths
        let freshTargets = currentTargets(home: home, presence: context, removingAgentIDs: removalIDs)
        let rebuildablePaths = rebuildablePaths(in: freshTargets)
        let links = skillLinks(home: home)
        let servers = AgentInventory.scanMCP(agents: AgentCatalog.definitions, home: home,
            presence: context, excludingWhitelist: false)
        var items: [DeletionPlan.Item] = []
        var verified = Set<String>()
        var refused = 0
        var messages: [String] = []
        var liveTargets = Set<String>()
        for requestedCategory in requested {
            let category = requestedCategory
            let candidates = category.paths.filter(category.isPathSelected)
            for path in candidates {
                if resourceIsWhitelisted(path, home: home) {
                    refused += 1
                    messages.append("Kept Agent resource protected by whitelist: " + path)
                    continue
                }
                if mayContainSkillBody(path, home: home), unknownSkillConfigs.contains(where: { config in
                    !candidates.contains { config == $0 || config.hasPrefix($0 + "/") }
                }) {
                    refused += 1
                    messages.append("Kept Agent resource because Skill registrations could not be verified: " + path)
                    continue
                }
                let owners = category.activityOwners + freshTargets.filter { $0.paths.contains(path) }.flatMap(\.owners)
                let dependencies = categoryDependencies(paths: [path], owners: owners,
                    links: links, declarations: skillScan.registrations, servers: servers,
                    home: home, presence: context)
                let live = isRebuildable(category, paths: [path], verifiedPaths: rebuildablePaths, home: home)
                    && !dependencies.hasProtectedResources
                if !live {
                    var guarded = category.selectingPaths([path])
                    guarded.activityOwners = dependencies.owners
                    guard resourceEligible(path: path, owners: dependencies.owners, running: snapshot, home: home),
                          let subset = CleanupRiskPolicy.runtimeEligibleSubset(guarded, running: snapshot, homeDirectory: home),
                          CleanupRiskPolicy.isEligible(subset, mode: .manual, running: snapshot, homeDirectory: home),
                          subset.isPathSelected(path) else {
                        refused += 1
                        messages.append(resourceRefusalReason(path: path, owners: dependencies.owners,
                            running: snapshot, home: home))
                        continue
                    }
                }
                let known: Bool
                if isAgentLeftover(category) { known = leftoverPaths.contains(path) }
                else if category.reasonKey == "agents.reason.skill" {
                    known = AgentCatalog.isDeletableSkill(path, home: home)
                } else { known = catalogPaths.contains(path) || live }
                guard known,
                      let identity = category.pathIdentities[path], !identity.isEmpty else {
                    refused += 1
                    messages.append(known
                        ? "Kept Agent resource because its selection or scanned identity is unavailable: " + path
                        : "Kept Agent resource because it is no longer recognized by the catalog: " + path)
                    continue
                }
                items.append(DeletionPlan.Item(record: path, identity: identity))
                verified.insert(path)
                if live { liveTargets.insert(path) }
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
        return Plan(items: items, verified: verified, families: families, refused: refused,
            messages: messages, liveTargets: liveTargets)
    }

    static func execute(_ requested: [CleanupCategory],
                        running snapshot: RunningApplicationSnapshot,
                        home: String,
                        permanent: Bool = false,
                        presence context: AgentPresenceContext? = nil,
                        skills: [AgentSkill] = [],
                        installations: [AgentMCPInstallation] = [],
                        servers: [AgentMCPServer] = [],
                        removingAgentID: String? = nil,
                        removingAgentIDs: Set<String> = [],
                        onProgress: ((Int, Int, String) -> Void)? = nil) -> Outcome {
        let removalIDs = removingAgentIDs.union(removingAgentID.map { [$0] } ?? [])
        let requestedPaths = requested.flatMap { category in category.paths.filter(category.isPathSelected) }
            + skills.map(\.path) + installations.map(\.path)
        let progress = ExecutionProgress(paths: requestedPaths, servers: servers, callback: onProgress)
        // 删除共享本体会波及所有挂靠，所以包含已卸载 Agent 中仍残留的注册。
        let allServers = AgentInventory.scanMCP(agents: AgentCatalog.definitions, home: home,
            presence: context, excludingWhitelist: false)
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
        let catalogPaths = cleanupCatalogPaths(home: home, presence: context, removingAgentIDs: removalIDs)
        let leftoverPaths = agentLeftoverPaths(for: requested, home: home, presence: context)
        let freshTargets = currentTargets(home: home, presence: context, removingAgentIDs: removalIDs)
        let rebuildablePaths = rebuildablePaths(in: freshTargets)
        // 整个 Agent 根目录里也可能放着被其它 Agent 挂靠的 Skill 本体。
        // 根目录清理同样要计入这些使用者，不能绕过共享 Skill 的运行态复核。
        for index in categories.indices {
            let selectedPaths = knownSelectedPaths(categories[index], catalogPaths: catalogPaths,
                leftoverPaths: leftoverPaths, rebuildablePaths: rebuildablePaths, home: home)
            guard !selectedPaths.isEmpty else { continue }
            var readyPaths: [String] = []
            for path in selectedPaths {
                let owners = categories[index].activityOwners
                    + freshTargets.filter { $0.paths.contains(path) }.flatMap(\.owners)
                let dependencies = categoryDependencies(paths: [path], owners: owners, links: relatedLinks,
                    declarations: skillRegistrations, servers: allServers, home: home, presence: context)
                let live = isRebuildable(categories[index], paths: [path], verifiedPaths: rebuildablePaths, home: home)
                    && !dependencies.hasProtectedResources
                // A live cache is cleaned by file occupancy. Persistent data or
                // registered resources still require their actual consumers to
                // be stopped before changing any body or external declaration.
                if !live, !resourceEligible(path: path, owners: dependencies.owners, running: snapshot, home: home) {
                    refused += 1
                    preflightMessages.append(resourceRefusalReason(path: path, owners: dependencies.owners,
                        running: snapshot, home: home))
                    continue
                }
                let externalDeclarations = dependencies.declarations.filter { declaration in
                    !selectedPaths.contains { declaration.configPath == $0 || declaration.configPath.hasPrefix($0 + "/") }
                }
                let externalServers = dependencies.servers.filter { server in
                    !selectedPaths.contains { server.configPath == $0 || server.configPath.hasPrefix($0 + "/") }
                }
                guard externalDeclarations.allSatisfy({ declaration in
                    !resourceIsWhitelisted(declaration.configPath, home: home)
                        && AgentMCPConfigEditor.backupConfiguration(declaration.configPath,
                        identity: declaration.configIdentity, fingerprint: declaration.configFingerprint)
                }), externalServers.allSatisfy({ server in
                    !resourceIsWhitelisted(server.configPath, home: home)
                        && AgentMCPConfigEditor.backupConfiguration(server.configPath,
                        identity: server.configIdentity, fingerprint: server.configFingerprint)
                }) else {
                    refused += 1
                    preflightMessages.append("Kept Agent resource because its registration configuration changed or could not be backed up: " + path)
                    continue
                }
                readyPaths.append(path)
            }
            categories[index] = categories[index].selectingPaths(readyPaths)
        }
        var explicitLinks: [DeletionPlan.Item] = []
        for skill in skills {
            if !skill.linked && !skillScan.unresolvedConfigPaths.isEmpty {
                refused += 1
                preflightMessages.append("Kept Skill body because its registrations could not be verified: " + skill.path)
                continue
            }
            let declarations = skillDeclarations(skill, declarations: skillRegistrations, home: home)
            let owners = skillOwners(skill, links: relatedLinks, home: home, presence: context)
                + declarationOwners(declarations, home: home, presence: context)
            guard !skill.identity.isEmpty else {
                refused += 1
                preflightMessages.append("Kept Skill because its scanned identity is unavailable: " + skill.path)
                continue
            }
            guard resourceEligible(path: skill.path, owners: owners, running: snapshot, home: home) else {
                refused += 1
                preflightMessages.append(resourceRefusalReason(path: skill.path, owners: owners,
                    running: snapshot, home: home))
                continue
            }
            guard declarations.allSatisfy({ declaration in
                      !resourceIsWhitelisted(declaration.configPath, home: home)
                        && AgentMCPConfigEditor.backupConfiguration(declaration.configPath,
                        identity: declaration.configIdentity, fingerprint: declaration.configFingerprint)
                  }) else {
                refused += 1
                preflightMessages.append("Kept Skill because its registration configuration changed or could not be backed up: "
                    + skill.path)
                continue
            }
            if skill.linked {
                guard isKnownSkillLink(skill.path, home: home) else {
                    refused += 1
                    preflightMessages.append("Kept Skill link because it changed or is no longer recognized: " + skill.path)
                    continue
                }
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
        let plan = plan(categories, running: snapshot, home: home, presence: context, removingAgentIDs: removalIDs)
        let executablePaths = plan.items.map(\.record) + explicitLinks.map(\.record) + installations.map(\.path)
        for path in progress.paths where !executablePaths.contains(where: {
            path == $0 || path.hasPrefix($0 + "/")
        }) {
            progress.complete(path: path)
        }
        var summaries: [NativeCore.ApplySummary] = []
        if !plan.items.isEmpty {
            summaries.append(NativeCore.shared.applyCleanup(
                items: plan.items, permanent: permanent, homeDirectory: home,
                verifiedTargets: plan.verified, atomicFamilies: plan.families,
                liveCleanupTargets: plan.liveTargets, onProgress: { completed, _, path in
                    if completed > 0 { progress.complete(path: path) }
                }, onCurrentFile: { progress.current(path: $0) }))
        }
        var removedPaths = summaries.reduce(into: Set<String>()) { $0.formUnion($1.removedPaths) }
        var removedInstallationIDs = Set(knownInstallations.filter { body in
            removedPaths.contains { body == $0 || body.hasPrefix($0 + "/") }
        })
        var launcherLinks = removedInstallationIDs.flatMap { launchersByInstallation[$0] ?? [] }
        var launcherParents = Set(launcherLinks.map { ($0.record as NSString).deletingLastPathComponent })
        for installation in installations {
            defer { progress.complete(path: installation.path) }
            if removedPaths.contains(where: { installation.path == $0 || installation.path.hasPrefix($0 + "/") }) {
                continue
            }
            let registrations = allServers.filter { $0.installationID == installation.id }
            let owners = registrations.flatMap { serverOwners($0, home: home, presence: context) }
            guard installation.id == installation.path, knownInstallations.contains(installation.path),
                  AgentInventory.isPhysicalInstallation(installation.path, home: home),
                  !installation.identity.isEmpty else {
                refused += 1
                preflightMessages.append("Kept MCP installation because its path or scanned identity is no longer recognized: "
                    + installation.path)
                continue
            }
            guard resourceEligible(path: installation.path, owners: owners, running: snapshot, home: home) else {
                refused += 1
                preflightMessages.append(resourceRefusalReason(path: installation.path, owners: owners,
                    running: snapshot, home: home))
                continue
            }
            guard registrations.allSatisfy({ registration in
                      !resourceIsWhitelisted(registration.configPath, home: home)
                        && AgentMCPConfigEditor.backupConfiguration(registration.configPath,
                        identity: registration.configIdentity, fingerprint: registration.configFingerprint)
                  }) else {
                refused += 1
                preflightMessages.append("Kept MCP installation because a registration configuration changed or could not be backed up: "
                    + installation.path)
                continue
            }
            let launchers = launchersByInstallation[installation.path] ?? []
            let summary = NativeCore.shared.applyCleanup(
                items: [.init(record: installation.path, identity: installation.identity)],
                permanent: permanent, homeDirectory: home, allowedRoots: [installation.path],
                verifiedTargets: [installation.path], onCurrentFile: { progress.current(path: $0) })
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
            let links = NativeCore.shared.applyAgentSkillLinks(
                items: linkItems, homeDirectory: home, allowedDirectories: Array(launcherParents),
                onProgress: { completed, _, path in
                    if completed > 0 { progress.complete(path: path) }
                })
            summaries.append(links)
            removedPaths.formUnion(links.removedPaths)
        }
        let declarations = skillRegistrations.filter { declaration in
            !removedPaths.contains { declaration.configPath == $0 || declaration.configPath.hasPrefix($0 + "/") }
                && removedPaths.contains {
                    declaration.resolvedPath == $0 || declaration.resolvedPath.hasPrefix($0 + "/")
                        || declaration.declares($0, home: home)
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
            progress.current(path: server.configPath, force: true)
            guard knownConfigs.contains(server.configPath) else {
                refused += 1
                preflightMessages.append("Kept MCP registration because its configuration path is no longer recognized: " + server.configPath)
                continue
            }
            let owners = serverOwners(server, home: home, presence: context)
            guard resourceEligible(path: server.configPath, owners: owners, running: snapshot, home: home) else {
                refused += 1
                preflightMessages.append(resourceRefusalReason(path: server.configPath, owners: owners,
                    running: snapshot, home: home))
                continue
            }
            guard AgentMCPConfigEditor.backupConfiguration(server.configPath,
                    identity: server.configIdentity, fingerprint: server.configFingerprint) else {
                refused += 1
                preflightMessages.append("Kept MCP configuration because it changed or could not be backed up: " + server.configPath)
                continue
            }
            summaries.append(NativeCore.shared.applyCleanup(
                items: [.init(record: server.configPath, identity: server.configIdentity)],
                permanent: permanent, homeDirectory: home, verifiedTargets: [server.configPath],
                finalValidation: { AgentMCPConfigEditor.fingerprint(at: $0) == server.configFingerprint }))
        }
        let editable = registrations.filter { !resetConfigs.contains($0.configPath) }
        let requests = editable.compactMap { server -> AgentMCPConfigEditor.Request? in
            guard knownConfigs.contains(server.configPath), !server.issues.contains(.unreadableConfig) else {
                refused += 1
                preflightMessages.append("Kept MCP registration because its configuration path is no longer recognized: " + server.configPath)
                return nil
            }
            let owners = serverOwners(server, home: home, presence: context)
            guard resourceEligible(path: server.configPath, owners: owners, running: snapshot, home: home) else {
                refused += 1
                preflightMessages.append(resourceRefusalReason(path: server.configPath, owners: owners,
                    running: snapshot, home: home))
                return nil
            }
            return .init(configPath: server.configPath, format: server.format,
                         serverName: server.name, scope: server.scope,
                         expectedIdentity: server.configIdentity,
                         expectedFingerprint: server.configFingerprint)
        }
        if let first = requests.first { progress.current(path: first.configPath, force: true) }
        let mcp = AgentMCPConfigEditor.apply(requests)
        // A body or link is not fully handled until its dependent declarations
        // are updated. Only now may aggregate progress reach the final unit.
        progress.finish()
        return Outcome(summary: NativeCore.ApplySummary(
            removed: summaries.reduce(mcp.removed + skillConfig.removed) { $0 + $1.removed },
            skipped: summaries.reduce(mcp.missing + skillConfig.missing) { $0 + $1.skipped },
            failed: summaries.reduce(mcp.failed + skillConfig.failed) { $0 + $1.failed },
            messages: preflightMessages + plan.messages + summaries.flatMap(\.messages) + mcp.messages + skillConfig.messages,
            removedPaths: summaries.reduce(into: Set<String>()) { $0.formUnion($1.removedPaths) },
            reclaimedBytes: summaries.reduce(0) { $0 &+ $1.reclaimedBytes }),
            refused: plan.refused + refused)
    }

    /// Logical selections share one stable denominator even when their bodies,
    /// links and registration edits run in separate services. Filesystem work
    /// advances per submitted root; the last unit includes dependent edits.
    private final class ExecutionProgress {
        let paths: [String]
        private let servers: [AgentMCPServer]
        private let callback: ((Int, Int, String) -> Void)?
        private var completedPaths = Set<String>()
        private var lastPath: String
        private var lastSentAt = Date.distantPast
        private var total: Int { paths.count + Set(servers.map(\.id)).count }

        init(paths: [String], servers: [AgentMCPServer], callback: ((Int, Int, String) -> Void)?) {
            self.paths = DeletionPlan.nonOverlappingPaths(paths)
            self.servers = servers
            self.callback = callback
            self.lastPath = self.paths.first ?? servers.first?.configPath ?? ""
            callback?(0, total, lastPath)
        }

        func complete(path: String) {
            let covered = paths.filter { $0 == path || $0.hasPrefix(path + "/") }
            let previousCount = completedPaths.count
            completedPaths.formUnion(covered)
            guard completedPaths.count > previousCount else { return }
            lastPath = path
            callback?(min(completedPaths.count, max(0, total - 1)), total, path)
        }

        /// Leaf traversal updates the current file without pretending another
        /// logical selection completed. Keep UI delivery to at most 10 Hz.
        func current(path: String, force: Bool = false) {
            guard force || path != lastPath else { return }
            let now = Date()
            guard force || now.timeIntervalSince(lastSentAt) >= 0.1 else { return }
            lastSentAt = now
            lastPath = path
            callback?(min(completedPaths.count, max(0, total - 1)), total, path)
        }

        func finish() {
            callback?(total, total, servers.last?.configPath ?? lastPath)
        }
    }

    private struct SkillLink {
        let path: String
        let target: String
        let identity: String
        let agentNames: [String]
    }

    private struct CategoryDependencies {
        let owners: [String]
        let declarations: [AgentSkillConfigEditor.Registration]
        let servers: [AgentMCPServer]
        let hasProtectedResources: Bool
    }

    private static func currentTargets(home: String, presence context: AgentPresenceContext?,
                                       removingAgentIDs: Set<String>) -> [AgentCatalog.ResolvedTarget] {
        AgentCatalog.definitions.filter {
            removingAgentIDs.contains($0.id) || !AgentCatalog.isOrphaned($0, home: home, presence: context)
        }.flatMap { AgentCatalog.resolve($0, home: home, presence: context) }
    }

    private static func rebuildablePaths(in targets: [AgentCatalog.ResolvedTarget]) -> Set<String> {
        let safe = Set(targets.filter { $0.tier == .safe }.flatMap(\.paths))
        let persistent = Set(targets.filter { $0.tier != .safe }.flatMap(\.paths))
        return safe.subtracting(persistent)
    }

    private static func isRebuildable(_ category: CleanupCategory, paths: [String],
                                      verifiedPaths: Set<String>, home: String) -> Bool {
        guard category.risk == .safe && category.disposal == .permanentDelete && category.applyRoute == .aiTrash,
              !paths.isEmpty, category.reasonKey != "agents.reason.skill", !isAgentLeftover(category) else { return false }
        return paths.allSatisfy { path in
            let root = verifiedPaths.filter { path == $0 || path.hasPrefix($0 + "/") }
                .max { $0.count < $1.count }
            guard let root else { return false }
            // A descendant inherits only cache authorization, never durable
            // registrations, databases, model data or lock-file permission.
            return !NativeCore.shared.isProtectedLiveCacheItem(path, cacheRoot: root,
                homeDirectory: home, rootIsVerifiedRebuildable: true)
        }
    }

    private static func knownSelectedPaths(_ category: CleanupCategory,
                                          catalogPaths: Set<String>, leftoverPaths: Set<String>,
                                          rebuildablePaths: Set<String>,
                                          home: String) -> [String] {
        category.paths.filter(category.isPathSelected).filter {
            if isAgentLeftover(category) { return leftoverPaths.contains($0) }
            return catalogPaths.contains($0) || isRebuildable(category, paths: [$0], verifiedPaths: rebuildablePaths, home: home)
                || (category.reasonKey == "agents.reason.skill"
                && AgentCatalog.isDeletableSkill($0, home: home))
        }
    }

    private static func categoryDependencies(paths: [String], owners: [String], links: [SkillLink],
                                             declarations: [AgentSkillConfigEditor.Registration],
                                             servers: [AgentMCPServer], home: String,
                                             presence context: AgentPresenceContext?) -> CategoryDependencies {
        func contains(_ resource: String) -> Bool {
            paths.contains { resource == $0 || resource.hasPrefix($0 + "/") }
        }
        let linkedNames = Set(links.filter { link in
            contains(link.target) || contains(link.path)
        }.flatMap(\.agentNames))
        // A known configuration or implicit Skills directory remains persistent
        // even when it currently has no registrations to enumerate.
        let skillDirectories = AgentCatalog.skillDirectories(home: home).filter { contains($0.path) }
        let skillNames = Set(skillDirectories.flatMap(\.agentNames))
        let configurationAgents = AgentCatalog.definitions.filter { agent in
            agent.mcpSources.contains { source in
                let configPath = AgentCatalog.absolute(source.path, home: home)
                return contains(configPath) && AgentCatalog.exists(configPath)
            }
        }
        let configurationIDs = Set(configurationAgents.map(\.id))
        let resourceOwners = AgentCatalog.definitions.filter {
            linkedNames.contains($0.name) || skillNames.contains($0.name) || configurationIDs.contains($0.id)
        }.flatMap {
            AgentCatalog.runtimeOwners(for: $0, home: home, presence: context)
        }
        let affectedDeclarations = declarations.filter { registration in
            paths.contains {
                registration.resolvedPath == $0 || registration.resolvedPath.hasPrefix($0 + "/")
                    || registration.declares($0, home: home)
                    || registration.configPath == $0 || registration.configPath.hasPrefix($0 + "/")
            }
        }
        let affectedServers = servers.filter { server in
            paths.contains { path in
                server.configPath == path || server.configPath.hasPrefix(path + "/")
                    || server.installationID.map { $0 == path || $0.hasPrefix(path + "/") } == true
            }
        }
        let allOwners = owners + resourceOwners
            + declarationOwners(affectedDeclarations, home: home, presence: context)
            + affectedServers.flatMap { serverOwners($0, home: home, presence: context) }
        return CategoryDependencies(owners: Array(Set(allOwners)),
            declarations: affectedDeclarations, servers: affectedServers,
            hasProtectedResources: !linkedNames.isEmpty || !skillDirectories.isEmpty || !configurationAgents.isEmpty
                || !affectedDeclarations.isEmpty || !affectedServers.isEmpty)
    }

    private static func skillDeclarations(_ skill: AgentSkill,
                                          declarations: [AgentSkillConfigEditor.Registration],
                                          home: String) -> [AgentSkillConfigEditor.Registration] {
        declarations.filter {
            skill.linked ? $0.declares(skill.path, home: home) : $0.references(skill.path)
        }
    }

    private static func declarationOwners(_ declarations: [AgentSkillConfigEditor.Registration],
                                          home: String, presence context: AgentPresenceContext?) -> [String] {
        guard !declarations.isEmpty,
              let codex = AgentCatalog.definitions.first(where: { $0.id == "codex" }) else { return [] }
        return AgentCatalog.runtimeOwners(for: codex, home: home, presence: context)
    }

    /// 已成功卸载的 CLI 不再满足 installed；只复核该 Agent 的目录规则，
    /// 不扩大到数据根或扫描后新出现的路径。身份、进程和依赖复核仍由原执行器完成。
    private static func cleanupCatalogPaths(home: String, presence: AgentPresenceContext?,
                                            removingAgentIDs: Set<String>) -> Set<String> {
        var paths = AgentCatalog.deletablePaths(home: home, presence: presence)
        for agent in AgentCatalog.definitions where removingAgentIDs.contains(agent.id) {
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
        !resourceIsWhitelisted(path, home: home)
            && CleanupRiskPolicy.isEligible(resourceCategory(path: path, owners: owners), mode: .manual,
            running: snapshot, homeDirectory: home)
    }

    private static func resourceIsWhitelisted(_ path: String, home: String) -> Bool {
        NativeCore.shared.matchesWhitelist(path, entries: NativeCore.shared.loadWhitelist(homeDirectory: home))
    }

    private static func resourceCategory(path: String, owners: [String]) -> CleanupCategory {
        var category = CleanupCategory(name: "Agent resources", paths: [path], bytes: 0, selected: true,
            source: .aiSession, risk: .warning, disposal: .permanentDelete, applyRoute: .aiTrash,
            activityGuard: .aiAgent, reasonKey: "agents.reason.review")
        category.activityOwners = owners
        return category
    }

    private static func resourceRefusalReason(path: String, owners: [String],
                                              running snapshot: RunningApplicationSnapshot, home: String) -> String {
        if resourceIsWhitelisted(path, home: home) { return "Kept Agent resource protected by whitelist: " + path }
        return refusalReason(for: resourceCategory(path: path, owners: owners), running: snapshot, home: home) + ": " + path
    }

    private static func refusalReason(for category: CleanupCategory,
                                       running snapshot: RunningApplicationSnapshot, home: String) -> String {
        let assessment = CleanupRiskPolicy.reassess(category, running: snapshot, homeDirectory: home)
        if assessment.reasonKey == "cleanup.risk.runtimeUnknown" {
            return "Kept Agent resource because running applications could not be verified"
        }
        if assessment.reasonKey == "cleanup.risk.runningApplication" {
            let runningOwners = Set(category.activityOwners.filter {
                snapshot.contains(bundleIdentifier: $0) || snapshot.contains(processName: $0)
            }).sorted()
            return "Kept Agent resource while its owner is running (" + runningOwners.joined(separator: ", ") + ")"
        }
        return "Kept Agent resource because its cleanup policy does not allow the operation"
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
