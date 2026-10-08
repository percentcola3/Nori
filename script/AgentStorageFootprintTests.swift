import Foundation

@main
struct AgentStorageFootprintTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: message, code: 1) }
    }

    static func main() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        func directory(_ relative: String) throws -> String {
            let url = root.appendingPathComponent(relative)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
        func category(_ name: String, _ path: String, _ bytes: UInt64,
                      safe: Bool = false, selected: Bool = false, review: Bool = false) -> CleanupCategory {
            .init(name: name, paths: [path], bytes: bytes, selected: selected,
                source: safe ? .aiCache : .aiSession, risk: safe ? .safe : .warning,
                disposal: .permanentDelete, applyRoute: .aiTrash, activityGuard: .aiAgent,
                reasonKey: safe ? "agents.reason.rebuildable" : review ? "agents.reason.review" : "agents.reason.showOnly")
        }
        func group(_ id: String, _ categories: [CleanupCategory], skills: [AgentSkill] = [], documented: Bool = true) -> AgentGroupSummary {
            .init(id: id, name: id, documented: documented, orphaned: false,
                categoryIDs: categories.map(\.id), skillIDs: skills.map(\.id), serverIDs: [], bytes: 0)
        }
        func skill(_ path: String, bytes: UInt64, owner: String, users: [String] = [], linked: Bool = false,
                   target: String? = nil) -> AgentSkill {
            .init(path: path, name: "Skill", summary: "", directory: (path as NSString).deletingLastPathComponent,
                  usedBy: users, agentID: owner, bytes: bytes, identity: DeletionPlan.identity(at: path) ?? "",
                  linked: linked, linkTarget: target)
        }
        func installation(_ id: String, _ path: String) -> AgentCLIInstallation {
            .init(id: id, agentID: "codex", name: "Codex CLI", executablePaths: [], managedPaths: [path], manager: .native,
                  managerExecutable: nil, packageName: nil,
                  identities: [path: DeletionPlan.identity(at: path) ?? ""], detail: "fixture")
        }

        let cache = category("缓存", try directory(".codex/cache"), 20, safe: true)
        let logs = category("任意本地化的日志名称", try directory(".codex/log-db"), 40, review: true)
        let sessions = category("用户已勾选的会话", try directory(".codex/sessions"), 300, selected: true)
        let state = category("state", try directory(".codex/state"), 50, selected: true)
        let credentials = category("credentials", try directory(".codex/credentials"), 5, selected: true)
        let ownedSkill = skill(try directory(".codex/skills/own"), bytes: 12, owner: "codex", users: ["Codex CLI"])
        let sharedSkill = skill(try directory(".agents/skills/shared"), bytes: 2_000, owner: "shared", users: ["Codex CLI", "Other Agent"])
        let mcpPath = try directory("mcp/body")
        let mcp = AgentMCPInstallation(id: mcpPath, name: "MCP", path: mcpPath, bytes: 5_000,
                                       identity: DeletionPlan.identity(at: mcpPath)!, serverIDs: [])
        let programPath = try directory("npm/global/@openai/codex")
        let program = installation("program", programPath)
        let bodyAsData = category("installation body", programPath, 1_000, safe: true)
        let sharedAsData = category("shared Skill", sharedSkill.path, 2_000, safe: true)
        let mcpAsData = category("shared MCP", mcpPath, 5_000, safe: true)
        let ownCategories = [cache, logs, sessions, state, credentials, bodyAsData]
        var report = AgentScanReport()
        report.categories = ownCategories + [sharedAsData, mcpAsData]
        report.skills = [ownedSkill, sharedSkill]
        report.installations = [mcp]
        report.groups = [group("codex", ownCategories, skills: [ownedSkill, sharedSkill]),
                         group("factory", [sharedAsData, mcpAsData]), group("shared", [], skills: [sharedSkill]),
                         group("shared-mcp", [])]
        report.recommendedCleanupCategoryIDs = [logs.id]
        let snapshot = AgentStorageFootprint.build(report: report, cli: [program])
        let agentPage = snapshot["codex"]!
        let softwarePage = snapshot[program.agentID]!
        try expect(agentPage == softwarePage && agentPage.identifiedDataBytes == 427
                   && agentPage.reclaimableBytes == 60 && agentPage.preservedBytes == 367
                   && agentPage.measurementComplete,
                   "Agent and software pages did not share identified/preserved/reclaimable values")
        try expect(snapshot["factory"]?.identifiedDataBytes == 0 && snapshot["shared"] == nil
                   && snapshot["shared-mcp"] == nil && !agentPage.entries.contains { $0.path == programPath },
                   "A program, shared Skill or shared MCP body was charged again as Agent data")
        try expect(agentPage.entries.filter { [sessions.paths[0], state.paths[0], credentials.paths[0]].contains($0.path) }
            .allSatisfy { $0.role == .preserved }, "Session/state/credentials were offered as garbage")
        let overview = AgentStorageFootprint.totals(Array(snapshot.values))
        try expect(overview.identifiedDataBytes == 427 && overview.reclaimableBytes == 60
                   && overview.preservedBytes == 367 && overview.measurementComplete,
                   "The overview merged installation bodies or preserved data into its garbage total")
        try expect(AgentStorageFootprint.totals([agentPage, softwarePage]) == overview,
                   "Multiple pages charged their same cached resource snapshot twice")
        try expect(!AgentStorageFootprint.totals([]).measurementComplete,
                   "An absent footprint snapshot was reported as a complete measurement")

        // User checkboxes and translated text never become static policy.
        report.categories = report.categories.map { item in
            var result = item
            result.selected.toggle()
            result.name = "translated presentation text"
            return result
        }
        try expect(AgentStorageFootprint.build(report: report, cli: [program]) == snapshot,
                   "Current selection or localization changed the storage policy")
        report.recommendedCleanupCategoryIDs.insert(sessions.id)
        try expect(AgentStorageFootprint.build(report: report, cli: [program])["codex"]?.reclaimableBytes == 60,
                   "A show-only category accepted an unrelated recommendation marker")
        report.recommendedCleanupCategoryIDs = []
        try expect(AgentStorageFootprint.build(report: report, cli: [program])["codex"]?.reclaimableBytes == 20,
                   "Missing static recommendation evidence did not fall back to safe caches")

        let parent = try directory("physical/cache")
        let child = try directory("physical/cache/nested")
        let alias = root.appendingPathComponent("alias-parent")
        try manager.createSymbolicLink(atPath: alias.path, withDestinationPath: root.appendingPathComponent("physical").path)
        let parentCategory = category("parent", parent, 100, safe: true)
        let childCategory = category("child", child, 40, safe: true)
        let aliasCategory = category("alias", alias.appendingPathComponent("cache").path, 100, safe: true)
        var nested = AgentScanReport()
        nested.categories = [childCategory, aliasCategory, parentCategory]
        nested.groups = [group("codex", nested.categories)]
        let union = AgentStorageFootprint.build(report: nested, cli: [])["codex"]!
        try expect(union.identifiedDataBytes == 100 && union.reclaimableBytes == 100 && union.entries.count == 1,
                   "Nested measurements or a physical directory alias were counted twice")
        nested.categories[0].risk = .warning
        nested.categories[0].source = .aiSession
        nested.categories[0].reasonKey = "agents.reason.showOnly"
        let mixed = AgentStorageFootprint.build(report: nested, cli: [])["codex"]!
        try expect(mixed.identifiedDataBytes == 100 && mixed.reclaimableBytes == 0 && mixed.preservedBytes == 100,
                   "A safe ancestor swallowed preserved nested data into its garbage total")

        let link = root.appendingPathComponent("direct-data-link")
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: sessions.paths[0])
        let linkCategory = category("direct link", link.path, 9_999, safe: true)
        var links = AgentScanReport()
        links.categories = [linkCategory]
        links.groups = [group("codex", links.categories)]
        let skippedLink = AgentStorageFootprint.build(report: links, cli: [])["codex"]!
        try expect(skippedLink.identifiedDataBytes == 0 && !skippedLink.measurementComplete,
                   "A symlink caused the builder to recount its target directory")
        let linkedSkill = skill(link.path, bytes: 0, owner: "codex", users: ["Codex CLI"], linked: true, target: sessions.paths[0])
        links.categories = []
        links.skills = [linkedSkill]
        links.groups = [group("codex", [], skills: [linkedSkill])]
        try expect(AgentStorageFootprint.build(report: links, cli: [])["codex"]?.identifiedDataBytes == 0,
                   "A linked Skill's target was treated as this Agent's owned data")

        let first = root.appendingPathComponent("first.cache")
        let second = root.appendingPathComponent("second.cache")
        try Data([0x61]).write(to: first)
        try manager.linkItem(at: first, to: second)
        let firstCategory = category("first", first.path, 25, safe: true)
        let secondCategory = category("second", second.path, 25, safe: true)
        var hardLinks = AgentScanReport()
        hardLinks.categories = [firstCategory, secondCategory]
        hardLinks.groups = [group("codex", hardLinks.categories)]
        try expect(AgentStorageFootprint.build(report: hardLinks, cli: [])["codex"]?.identifiedDataBytes == 25,
                   "The same measured file object was charged twice through hard links")
        hardLinks.groups = [group("codex", [firstCategory]), group("factory", [secondCategory])]
        let crossAgent = AgentStorageFootprint.build(report: hardLinks, cli: [])
        try expect(crossAgent["codex"]?.identifiedDataBytes == 25 && crossAgent["factory"]?.identifiedDataBytes == 25
                   && crossAgent.values.allSatisfy(\.measurementComplete)
                   && crossAgent.values.allSatisfy { $0.reclaimableBytes == 0 }
                   && crossAgent["codex"]?.entries.first?.resourceID == crossAgent["factory"]?.entries.first?.resourceID
                   && crossAgent["factory"]?.entries.first?.consumerAgentIDs == ["codex", "factory"],
                   "A shared consumer lost its associated capacity or physical resource identity")
        let sharedOverview = AgentStorageFootprint.totals(Array(crossAgent.values))
        try expect(sharedOverview.identifiedDataBytes == 25 && sharedOverview.reclaimableBytes == 0
                   && sharedOverview.preservedBytes == 25 && sharedOverview.measurementComplete,
                   "The overall capacity duplicated a shared resource or offered it as garbage")
        hardLinks.categories[1].source = .aiSession
        hardLinks.categories[1].risk = .warning
        hardLinks.categories[1].reasonKey = "agents.reason.showOnly"
        let sharedHistory = AgentStorageFootprint.build(report: hardLinks, cli: [])
        try expect(sharedHistory.values.allSatisfy { $0.identifiedDataBytes == 25 && $0.reclaimableBytes == 0 },
                   "A consumer offered another consumer's preserved shared history as garbage")

        var crossNested = AgentScanReport()
        crossNested.categories = [parentCategory, childCategory, aliasCategory]
        crossNested.groups = [group("codex", [parentCategory, aliasCategory]), group("factory", [childCategory])]
        let nestedConsumers = AgentStorageFootprint.build(report: crossNested, cli: [])
        let nestedOverview = AgentStorageFootprint.totals(Array(nestedConsumers.values))
        try expect(nestedConsumers["codex"]?.identifiedDataBytes == 100 && nestedConsumers["factory"]?.identifiedDataBytes == 40
                   && nestedOverview.identifiedDataBytes == 100 && nestedOverview.reclaimableBytes == 0
                   && nestedOverview.preservedBytes == 100 && nestedOverview.measurementComplete,
                   "An overview counted a physical alias/containing tree twice or offered shared nested data as garbage")

        // Totals read the cached physical path, including synthetic absent paths;
        // they never remeasure a directory or resolve its current aliases.
        let cached = AgentStorageFootprint(agentID: "fixture", identifiedDataBytes: 123, reclaimableBytes: 123,
            preservedBytes: 0, measurementComplete: true,
            entries: [.init(path: "/absent-fixture/data", bytes: 123, role: .reclaimable,
                            resourceID: "fixture-resource", consumerAgentIDs: ["fixture"], physicalPath: "/cached-snapshot/data")])
        try expect(AgentStorageFootprint.totals([cached]).reclaimableBytes == 123,
                   "The overview changed cached measurements using new filesystem IO")

        var aggregate = AgentScanReport()
        let aggregateRoot = try directory("aggregate")
        let bodyBelow = try directory("aggregate/program")
        aggregate.categories = [category("aggregate", aggregateRoot, 100, safe: true)]
        aggregate.groups = [group("codex", aggregate.categories)]
        let overlap = AgentStorageFootprint.build(report: aggregate, cli: [installation("nested-program", bodyBelow)])["codex"]!
        try expect(overlap.identifiedDataBytes == 0 && !overlap.measurementComplete,
                   "A coarse aggregate invented a data subtotal around an installation body")

        var partial = nested
        partial.complete = false
        let partialFootprints = AgentStorageFootprint.build(report: partial, cli: [])
        try expect(partialFootprints["codex"]?.measurementComplete == false
                   && !AgentStorageFootprint.totals(Array(partialFootprints.values)).measurementComplete,
                   "A partial report appeared fully measured")
        partial = report
        partial.complete = true
        partial.skills[0].measurementComplete = false
        try expect(AgentStorageFootprint.build(report: partial, cli: [])["codex"]?.measurementComplete == false,
                   "Incomplete resource measurement appeared fully measured")
        partial = nested
        partial.categories[0].pathBytes = [:]
        let missingBytes = AgentStorageFootprint.build(report: partial, cli: [])["codex"]!
        try expect(!missingBytes.measurementComplete && missingBytes.reclaimableBytes == 0,
                   "An absent preserved-path measurement was invented or swallowed by a safe ancestor")
        print("Agent storage footprints: shared snapshot policy, preserved history, body exclusion, aliases, nested unions and incomplete measurements passed")
    }
}
