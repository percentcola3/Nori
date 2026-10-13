import Foundation

/// One reviewed, ID-bound operation. Files are read only for backup; the owning
/// Agent exclusively performs deletion and maintains its indexes.
enum AgentHistoryService {
    // Code-only delivery. Enable after the deferred protocol and backup checks.
    static let interfacesEnabled = false

    static func list(context: AgentHistoryContext) async throws -> AgentHistoryInventory {
        guard interfacesEnabled else { throw AgentHistoryFailure("agents.history.pendingValidation") }
        try context.checkExecutable()
        try await AgentHistoryProcessGuard.requireIdle(context)
        let backend = try makeBackend(context)
        defer { backend.close() }
        let sessions = try await backend.list()
        try await AgentHistoryProcessGuard.requireIdle(context, excluding: backend.ownedProcessIDs)
        return .init(context: context, sessions: sessions, version: backend.version)
    }

    static func delete(inventory: AgentHistoryInventory, selected: [AgentHistorySession],
                       progress: @escaping @Sendable (Int, Int) -> Void) async -> AgentHistoryDeleteResult {
        var result = AgentHistoryDeleteResult()
        let context = inventory.context
        let selectedIDs = Set(selected.map(\.id))
        guard interfacesEnabled else {
            for row in selected { result.failed[row.id] = "agents.history.pendingValidation" }
            return result
        }
        guard !selected.isEmpty, selected.count <= 100, selectedIDs.count == selected.count,
              selected.allSatisfy({ $0.provider == context.provider && $0.project == context.project
                  && $0.canSelect && inventory.sessions.contains($0) }) else {
            for row in selected { result.failed[row.id] = "agents.history.error.selection" }
            return result
        }
        progress(0, selected.count)
        do {
            try context.checkExecutable()
            try await AgentHistoryProcessGuard.requireIdle(context)
            let backend = try makeBackend(context)
            defer { backend.close() }
            var current = try await backend.list()
            guard backend.version == inventory.version else { throw AgentHistoryFailure("agents.history.error.changed") }
            for (index, accepted) in selected.enumerated() {
                var backup: URL?
                var mutationStarted = false
                do {
                    try Task.checkCancellation()
                    try context.checkExecutable()
                    try await AgentHistoryProcessGuard.requireIdle(context, excluding: backend.ownedProcessIDs)
                    guard let fresh = current.first(where: { $0.id == accepted.id }), fresh.canSelect,
                          fresh.fingerprint == accepted.fingerprint else {
                        throw AgentHistoryFailure("agents.history.error.changed")
                    }
                    let directory = try AgentHistoryBackup.create(for: accepted, context: context, version: backend.version)
                    backup = directory
                    result.backups.append(directory.path)
                    try await backend.prepareBackup(fresh, to: directory)
                    try AgentHistoryBackup.validate(directory, session: accepted)
                    try AgentHistoryBackup.finish(directory, state: "backed-up")
                    // Repeat all checks after copying; backups never grant deletion authority.
                    current = try await backend.list()
                    guard let reviewed = current.first(where: { $0.id == accepted.id }), reviewed.canSelect,
                          reviewed.fingerprint == accepted.fingerprint else {
                        throw AgentHistoryFailure("agents.history.error.changed")
                    }
                    try context.checkExecutable()
                    try AgentHistoryBackup.recheckSources(directory)
                    try await AgentHistoryProcessGuard.requireIdle(context, excluding: backend.ownedProcessIDs)
                    mutationStarted = true
                    try await backend.delete(reviewed)
                    current = try await backend.list()
                    guard !current.contains(where: { $0.id == accepted.id }) else {
                        throw AgentHistoryFailure("agents.history.error.verification")
                    }
                    result.deleted.insert(accepted.id)
                    try? AgentHistoryBackup.finish(directory, state: "deleted-and-verified")
                    progress(index + 1, selected.count)
                } catch {
                    let reason = mutationStarted ? "agents.history.error.uncertain"
                        : (error as? AgentHistoryFailure)?.key ?? "agents.history.error.backup"
                    result.failed[accepted.id] = reason
                    if let backup { try? AgentHistoryBackup.finish(backup, state: mutationStarted ? "needs-review" : "retained") }
                    // Stop this batch. Do not retry a possibly completed mutation,
                    // and never replace an interface failure with file deletion.
                    for pending in selected.dropFirst(index + 1) {
                        result.failed[pending.id] = "agents.history.error.notProcessed"
                    }
                    if let refreshed = try? await backend.list() { current = refreshed }
                    break
                }
            }
            // An uncertain response stays visible even if a later list omitted it.
            // Preserve the receipt and disable repeat deletion until a new scan.
            result.remaining = (current + selected.filter { accepted in
                result.failed[accepted.id] != nil && !current.contains { $0.id == accepted.id }
            }).map { row in
                guard result.failed[row.id] == "agents.history.error.uncertain" else { return row }
                return AgentHistorySession(provider: row.provider, sessionID: row.sessionID, title: row.title,
                    project: row.project, updatedAt: row.updatedAt, fingerprint: row.fingerprint,
                    metadata: row.metadata, protection: "agents.history.error.uncertain",
                    transcript: row.transcript, artifactRoot: row.artifactRoot)
            }
        } catch {
            let key = (error as? AgentHistoryFailure)?.key ?? "agents.history.error.api"
            for row in selected where !result.deleted.contains(row.id) { result.failed[row.id] = key }
        }
        return result
    }

    private static func makeBackend(_ context: AgentHistoryContext) throws -> AgentHistoryBackend {
        switch context.provider {
        case .opencode: return try AgentHistoryOpenCode(context: context)
        case .copilot: return try AgentHistoryCopilot(context: context)
        case .gemini: return AgentHistoryGemini(context: context)
        }
    }
}
