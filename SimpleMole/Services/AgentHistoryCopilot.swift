import Foundation

final class AgentHistoryCopilot: AgentHistoryBackend, @unchecked Sendable {
    private let context: AgentHistoryContext
    private let rpc: AgentHistoryRPC
    private(set) var version = ""
    var ownedProcessIDs: Set<Int32> { rpc.ownedProcessIDs }

    init(context: AgentHistoryContext) throws {
        self.context = context
        rpc = try AgentHistoryRPC(context: context)
    }

    func list() async throws -> [AgentHistorySession] {
        if version.isEmpty {
            let connected: [String: Any]
            do {
                connected = try await call("connect", ["clientInfo": ["name": "Nori", "version": "1"],
                    "supportedTaskKinds": ["agent", "client", "shell"]])
            } catch let failure as AgentHistoryFailure where failure.key == "agents.history.error.unsupported" {
                connected = try await call("ping", ["message": "Nori history"])
            }
            // The researched SDK's minimum and maximum are both protocol 3.
            guard let protocolVersion = connected["protocolVersion"] as? Int,
                  protocolVersion == 3 else { throw AgentHistoryFailure("agents.history.error.unsupported") }
            let status = try await call("status.get")
            guard let nativeVersion = status["version"] as? String, !nativeVersion.isEmpty, nativeVersion.count <= 80 else {
                throw AgentHistoryFailure("agents.history.error.unsupported")
            }
            version = nativeVersion + " / RPC \(protocolVersion)"
        }
        let result = try await call("session.list", ["filter": ["cwd": context.project]])
        guard let items = result["sessions"] as? [[String: Any]], items.count <= 2000 else {
            throw AgentHistoryFailure("agents.history.error.protocol")
        }
        var sessions: [AgentHistorySession] = []
        for item in items {
            guard let id = item["sessionId"] as? String, AgentHistorySession.validID(id),
                  let remote = item["isRemote"] as? Bool else {
                throw AgentHistoryFailure("agents.history.error.protocol")
            }
            let scope = item["context"] as? [String: Any]
            let cwd = scope?["cwd"] as? String
            if let cwd, URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path != context.project { continue }
            let data = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
            let root = AgentCatalog.absolute(".copilot/session-state", home: context.home) + "/" + id
            var protection = remote ? "agents.history.protected.remote"
                : AgentHistorySession.protection(in: item, project: context.project)
            if !remote && cwd == nil { protection = "agents.history.protected.unknown" }
            if !remote && !AgentCatalog.isRegularFile(root + "/events.jsonl") { protection = "agents.history.protected.backup" }
            sessions.append(.init(provider: .copilot, sessionID: id,
                title: item["summary"] as? String ?? id, project: context.project,
                updatedAt: (item["modifiedTime"] as? String).flatMap(Self.date),
                fingerprint: AgentHistorySession.digest(data), metadata: data, protection: protection,
                transcript: nil, artifactRoot: remote ? nil : root))
        }
        guard Set(sessions.map(\.id)).count == sessions.count else { throw AgentHistoryFailure("agents.history.error.protocol") }
        return sessions.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    func prepareBackup(_ session: AgentHistorySession, to directory: URL) async throws {
        guard let root = session.artifactRoot else { throw AgentHistoryFailure("agents.history.error.backup") }
        try AgentHistoryBackup.copy(root, to: directory.appendingPathComponent("session-state"), home: context.home)
        let index = AgentCatalog.absolute(".copilot/session-store.db", home: context.home)
        if AgentCatalog.exists(index) {
            // sqlite3_backup includes committed WAL data; never copy an online main file alone.
            try AgentHistoryBackup.snapshotSQLite(index, to: directory.appendingPathComponent("session-store.sqlite"))
        }
    }

    func delete(_ session: AgentHistorySession) async throws {
        guard AgentHistorySession.validID(session.sessionID) else { throw AgentHistoryFailure("agents.history.error.protocol") }
        let result = try await call("session.delete", ["sessionId": session.sessionID])
        guard result["success"] as? Bool == true else { throw AgentHistoryFailure("agents.history.error.api") }
    }

    func close() { rpc.close() }

    private func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let data = try await rpc.call(method, params)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentHistoryFailure("agents.history.error.protocol")
        }
        return result
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
