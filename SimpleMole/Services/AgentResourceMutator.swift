import Foundation

enum AgentResourceMutator {
    static func execute(_ changes: AgentResourceChanges, running: RunningApplicationSnapshot,
                        home: String, presence: AgentPresenceContext? = nil) -> AgentCleanupExecutor.Outcome {
        var accepted: [AgentSkillConfigEditor.Registration] = []
        var messages: [String] = []
        var refused = 0
        let fresh = AgentSkillConfigEditor.scan(home: home)
        let whitelist = NativeCore.shared.loadWhitelist(homeDirectory: home)
        let owners = AgentCatalog.definitions.first { $0.id == "codex" }.map {
            AgentCatalog.runtimeOwners(for: $0, home: home, presence: presence)
        } ?? []
        for registration in changes.registrations {
            guard running.isComplete, !owners.contains(where: {
                running.contains(processName: $0) || running.contains(bundleIdentifier: $0)
            }), fresh.contains(registration),
                !NativeCore.shared.matchesWhitelist(registration.configPath, entries: whitelist),
                !NativeCore.shared.matchesWhitelist(registration.resolvedPath, entries: whitelist) else {
                refused += 1
                messages.append("Kept Skill registration because it is running, protected or changed: " + registration.configPath)
                continue
            }
            if !accepted.contains(registration) { accepted.append(registration) }
        }
        let config = AgentSkillConfigEditor.apply(accepted)
        var servers = changes.servers
        // Only this operation's verified edit may refresh another accepted
        // registration in the same file. Unrelated file changes stay rejected.
        for index in servers.indices where config.editedPaths.contains(servers[index].configPath) {
            guard accepted.contains(where: { $0.configPath == servers[index].configPath
                && $0.configIdentity == servers[index].configIdentity
                && $0.configFingerprint == servers[index].configFingerprint }),
                let written = config.writtenFingerprints[servers[index].configPath],
                AgentMCPConfigEditor.fingerprint(at: servers[index].configPath) == written else { continue }
            servers[index].configIdentity = DeletionPlan.identity(at: servers[index].configPath) ?? ""
            servers[index].configFingerprint = written
        }
        var result = AgentCleanupExecutor.execute([], running: running, home: home, permanent: true,
            presence: presence, skills: changes.skills, installations: changes.installations, servers: servers)
        let original = result.summary
        result.summary = .init(removed: original.removed + config.removed,
            skipped: original.skipped + config.missing, failed: original.failed + config.failed,
            messages: original.messages + config.messages + messages, removedPaths: original.removedPaths,
            remainingPaths: original.remainingPaths, retainedPaths: original.retainedPaths,
            reclaimedBytes: original.reclaimedBytes)
        result.refused += refused
        return result
    }
}
