import Foundation

/// Only the runner's frozen compiler copies call these instrumentation hooks.
final class AgentScanPerformanceProbe: @unchecked Sendable {
    static let shared = AgentScanPerformanceProbe()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var skillEnumerations: [String: Int] = [:]
    private var sizingPaths: [String: Int] = [:]
    private var activeArtifacts = 0
    private var peakArtifacts = 0
    private var artifactVisits = 0
    func fingerprint() { lock.lock(); counts["fingerprints", default: 0] += 1; lock.unlock() }
    func manifest() { lock.lock(); counts["manifests", default: 0] += 1; lock.unlock() }
    func enumerate(_ path: String) {
        guard path.contains("/skills") else { return }
        lock.lock(); skillEnumerations[path, default: 0] += 1; lock.unlock()
    }
    func measure(_ path: String) {
        lock.lock(); sizingPaths[path, default: 0] += 1
        let artifact = path.contains("/review-worker-fixture/") && path.hasSuffix("/node_modules")
        if artifact { activeArtifacts += 1; artifactVisits += 1; peakArtifacts = max(peakArtifacts, activeArtifacts) }
        lock.unlock()
        if artifact { Thread.sleep(forTimeInterval: 0.005) }
    }
    func finishMeasure(_ path: String) {
        guard path.contains("/review-worker-fixture/"), path.hasSuffix("/node_modules") else { return }
        lock.lock(); activeArtifacts -= 1; lock.unlock()
    }
    func artifactSnapshot() -> (peak: Int, visits: Int) {
        lock.lock(); defer { lock.unlock() }
        return (peakArtifacts, artifactVisits)
    }
    func snapshot() -> (fingerprints: Int, manifests: Int, enumerations: Int, roots: Int) {
        lock.lock(); defer { lock.unlock() }
        return (counts["fingerprints", default: 0], counts["manifests", default: 0], skillEnumerations.values.reduce(0, +), sizingPaths.values.reduce(0, +))
    }
}

@main
struct AgentScanPerformanceTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        func write(_ relative: String, _ data: Data) throws {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try write(".local/bin/claude", Data("#!/bin/sh\nexit 0\n".utf8))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path + "/.local/bin/claude")
        for index in 0..<200 {
            try write(".claude/tasks/\(index)/history.json", Data(repeating: 97, count: 4096))
            for child in 0..<20 {
                try write(".agents/skills/skill-\(index)/\(child).cache", Data(repeating: 97, count: 4096))
            }
            try write(".agents/skills/skill-\(index)/SKILL.md", Data("---\nname: Fixture\n---\n".utf8))
            let link = root.appendingPathComponent(".claude/skills/alias-\(index)")
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent(".agents/skills/skill-\(index)"))
        }
        for index in 0..<4000 {
            try write(".claude/statsig/\(index).cache", Data(repeating: 97, count: 4096))
        }
        let servers = Dictionary(uniqueKeysWithValues: (0..<600).map {
            ("server-\($0)", ["url": "https://fixture.example/endpoint/\($0)?padding=" + String(repeating: "a", count: 80)])
        })
        try write(".claude.json", try JSONSerialization.data(withJSONObject: ["mcpServers": servers]))
        let presence = AgentPresenceContext(applicationDirs: [], searchPath: [root.path + "/.local/bin"])
        let start = ProcessInfo.processInfo.systemUptime
        let report = AgentInventory.scan(home: root.path,
            control: CleanupScanControl(mode: .deep, totalBudget: 180, directoryBudget: 30), presence: presence)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let counters = AgentScanPerformanceProbe.shared.snapshot()
        precondition(report.complete && report.skills.count == 400 && report.servers.count == 600)
        precondition(report.categories.flatMap(\.paths).count == 201)
        precondition(report.skills.filter(\.linked).allSatisfy { $0.bytes == 0 },
                     "Measuring shared bodies must never follow a command/Skill link")
        precondition(report.skills.filter { !$0.linked }.allSatisfy { $0.bytes > 0 })
        precondition(Set(report.servers.map(\.configFingerprint)).count == 1
                     && report.servers.allSatisfy { !$0.configIdentity.isEmpty && !$0.configFingerprint.isEmpty })
        print(String(format: "agent_scan elapsed_ms=%.2f fingerprints=%d manifests=%d skill_directory_enumerations=%d fts_roots=%d files=8400 skills=400 servers=600",
            elapsed * 1000, counters.fingerprints, counters.manifests, counters.enumerations, counters.roots))
        let reviewHome = root.appendingPathComponent("review-worker-fixture")
        for index in 0..<24 {
            try write("review-worker-fixture/Code/project-\(index)/package.json", Data("{}".utf8))
            try write("review-worker-fixture/Code/project-\(index)/node_modules/payload.cache", Data(repeating: 97, count: 4096))
        }
        let reviewCore = NativeCore(cleanupOpenFileProbe: { [] })
        precondition(reviewCore.projectArtifactPaths(home: reviewHome).count == 24)
        _ = reviewCore.appDataReviewCategories(home: reviewHome, offered: [], whitelist: [])
        let workers = AgentScanPerformanceProbe.shared.artifactSnapshot()
        precondition(workers.visits == 24)
        print("review_artifact_workers peak=\(workers.peak) visits=\(workers.visits)")
        #if !AGENT_SCAN_BASELINE
        precondition((1...4).contains(workers.peak), "Review sizing must leave a bounded worker budget")
        let stoppedReview = CleanupScanControl(mode: .deep)
        stoppedReview.cancel()
        precondition(reviewCore.projectArtifactPaths(home: reviewHome, control: stoppedReview).isEmpty)
        precondition(reviewCore.appDataReviewCategories(home: reviewHome, offered: [], whitelist: [],
                                                        scanControl: stoppedReview).isEmpty)
        precondition(counters.fingerprints == 1, "Every MCP config has one scan-local fingerprint")
        precondition(counters.manifests == 200, "Shared Skill bodies have one scan-local manifest read")
        try write(".codex/cache/retained.cache", Data(repeating: 97, count: 4096))
        let orphan = AgentInventory.scan(home: root.path, presence: presence, onlyAgentIDs: ["codex"])
        precondition(orphan.groups.contains { $0.id == "codex" && $0.orphaned })
        precondition(!orphan.categories.isEmpty && orphan.categories.allSatisfy { !$0.selected })
        precondition(!orphan.recommendedCleanupCategoryIDs.isEmpty,
                     "Static recommendations survive the unselected orphan presentation")
        precondition(orphan.skills.isEmpty && orphan.servers.isEmpty && orphan.installations.isEmpty,
                     "A scoped scan must not measure or return unrelated shared resources")
        let resumed = AgentInventory.scan(home: root.path, presence: presence,
            includingAgentIDs: ["codex"], onlyAgentIDs: ["codex"])
        precondition(resumed.categories.contains { $0.selected })
        let partial = AgentInventory.scan(home: root.path,
            control: CleanupScanControl(mode: .deep, totalBudget: 0), presence: presence, onlyAgentIDs: ["codex"])
        precondition(!partial.complete, "Deadline exhaustion must remain visible")
        let cancellation = CleanupScanControl(mode: .deep)
        cancellation.cancel()
        precondition(!AgentInventory.scan(home: root.path, control: cancellation, presence: presence,
                                          onlyAgentIDs: ["codex"]).complete)
        try write(".claude.json", Data(#"{"mcpServers":{"replacement":{"url":"https://fixture.example/changed"}}}"#.utf8))
        let refreshed = AgentInventory.scanMCP(agents: AgentCatalog.definitions, home: root.path, presence: presence)
        precondition(refreshed.count == 1 && refreshed[0].name == "replacement"
                     && refreshed[0].configFingerprint != report.servers[0].configFingerprint,
                     "Config snapshots must be rebuilt on the next scan")
        #endif
        precondition(fm.fileExists(atPath: root.path + "/.claude/statsig/0.cache"))
        print("Agent scan ownership, links, MCP snapshot and completeness fixtures passed")
    }
}
