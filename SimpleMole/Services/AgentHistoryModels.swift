import CryptoKit
import Foundation

/// History has its own identity and consent. It never becomes a CleanupCategory.
enum AgentHistoryProvider: String, CaseIterable, Codable, Hashable, Sendable {
    case opencode, copilot, gemini

    var command: String { rawValue }
    var name: String {
        switch self {
        case .opencode: return "OpenCode"
        case .copilot: return "Copilot CLI"
        case .gemini: return "Gemini CLI"
        }
    }
}

struct AgentHistoryContext: Equatable, Sendable {
    let provider: AgentHistoryProvider
    let project: String
    let home: String
    let executable: String
    let executableIdentity: String
    let searchPath: [String]

    static func make(provider: AgentHistoryProvider, project: String, home: String) throws -> Self {
        let directory = URL(fileURLWithPath: project).resolvingSymlinksInPath().standardizedFileURL.path
        let search = AgentCatalog.executableSearchPath(home: home)
        guard DeletionPlan.isLexicallySafePath(directory), AgentCatalog.isDirectory(directory),
              directory != "/",
              let executable = AgentCatalog.resolveExecutable(provider.command, searchPath: search, home: home),
              let identity = DeletionPlan.identity(at: executable) else {
            throw AgentHistoryFailure("agents.history.error.context")
        }
        return .init(provider: provider, project: directory, home: home, executable: executable,
                     executableIdentity: identity, searchPath: search)
    }

    func checkExecutable() throws {
        guard DeletionPlan.identity(at: executable) == executableIdentity else {
            throw AgentHistoryFailure("agents.history.error.changed")
        }
    }
}

struct AgentHistorySession: Identifiable, Equatable, Sendable {
    let provider: AgentHistoryProvider
    let sessionID: String
    let title: String
    let project: String
    let updatedAt: Date?
    let fingerprint: String
    let metadata: Data
    let protection: String?
    /// Only the provider's selected-session backup path, never a delete target.
    let transcript: String?
    let artifactRoot: String?

    var id: String { provider.rawValue + "|" + project + "|" + sessionID }
    var canSelect: Bool { protection == nil }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
    }

    static func protection(in object: [String: Any], project: String) -> String? {
        if object["isRemote"] as? Bool == true || object["share"] is [String: Any] {
            return "agents.history.protected.remote"
        }
        if object["pinned"] as? Bool == true || object["isPinned"] as? Bool == true {
            return "agents.history.protected.pinned"
        }
        if object["automationId"] != nil && !(object["automationId"] is NSNull)
            || object["scheduleId"] != nil && !(object["scheduleId"] is NSNull) {
            return "agents.history.protected.automation"
        }
        if let source = object["source"] as? [String: Any],
           let kind = source["kind"] as? String, ["automation", "scheduled", "workflow"].contains(kind) {
            return "agents.history.protected.automation"
        }
        if object["parentID"] as? String != nil || object["parentSessionId"] as? String != nil {
            return "agents.history.protected.related"
        }
        if ["worktreeId", "worktreeID", "worktree", "workspaceID", "workspaceId"].contains(where: {
            object[$0] != nil && !(object[$0] is NSNull)
        })
            || AgentCatalog.isRegularFile(project + "/.git") {
            return "agents.history.protected.worktree"
        }
        if object["active"] as? Bool == true || object["locked"] as? Bool == true {
            return "agents.history.protected.active"
        }
        // Extensions may introduce ownership that this adapter does not understand.
        if let extra = object["extra"], !(extra is NSNull) {
            if let fields = extra as? [String: Any], fields.isEmpty { return nil }
            return "agents.history.protected.unknown"
        }
        return nil
    }
}

struct AgentHistoryInventory: Sendable {
    let context: AgentHistoryContext
    let sessions: [AgentHistorySession]
    let version: String
}

struct AgentHistoryPageState {
    var project = ""
    var inventory: AgentHistoryInventory?
    var selection = Set<String>()
    var statusKey: String?
    var statusArguments: [String] = []
    var failureKeys: [String: String] = [:]
    var backupDirectories: [String] = []
}

struct AgentHistoryDeleteResult: Sendable {
    var deleted = Set<String>()
    var failed: [String: String] = [:]
    var backups: [String] = []
    var remaining: [AgentHistorySession]?
}

struct AgentHistoryFailure: Error, LocalizedError {
    let key: String
    init(_ key: String) { self.key = key }
    var errorDescription: String? { key }
}

protocol AgentHistoryBackend: AnyObject, Sendable {
    var ownedProcessIDs: Set<Int32> { get }
    var version: String { get }
    func list() async throws -> [AgentHistorySession]
    func prepareBackup(_ session: AgentHistorySession, to directory: URL) async throws
    func delete(_ session: AgentHistorySession) async throws
    func close()
}
