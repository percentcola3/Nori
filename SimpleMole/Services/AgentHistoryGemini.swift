import Foundation

final class AgentHistoryGemini: AgentHistoryBackend, @unchecked Sendable {
    private let context: AgentHistoryContext
    private(set) var version = ""
    var ownedProcessIDs: Set<Int32> { [] }

    init(context: AgentHistoryContext) { self.context = context }

    func list() async throws -> [AgentHistorySession] {
        if version.isEmpty {
            let result = try await AgentHistoryProcess.run(context: context, arguments: ["--version"], timeout: 10)
            guard result.status == 0, !result.timedOut, !result.overflowed,
                  let text = String(data: result.data, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: {
                      $0.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil
                  }) else { throw AgentHistoryFailure("agents.history.error.unsupported") }
            version = String(line)
        }
        let result = try await runHistoryCommand(["--list-sessions"])
        guard result.status == 0, !result.timedOut, !result.overflowed,
              let text = String(data: result.data, encoding: .utf8) else {
            throw AgentHistoryFailure("agents.history.error.protocol")
        }
        if text.contains("No previous sessions found for this project.") { return [] }
        let header = try NSRegularExpression(pattern: #"Available sessions for this project \((\d+)\):"#)
        let fullRange = NSRange(text.startIndex..., in: text)
        guard let match = header.firstMatch(in: text, range: fullRange),
              let countRange = Range(match.range(at: 1), in: text),
              let expected = Int(text[countRange]), expected <= 2000 else {
            throw AgentHistoryFailure("agents.history.error.unsupported")
        }
        let row = try NSRegularExpression(pattern: #"^\s*\d+\. (.+) \(([^\n]*)\) \[([0-9a-fA-F-]{36})\]$"#)
        let root = try projectStorage()
        var sessions: [AgentHistorySession] = []
        for line in text.components(separatedBy: .newlines) {
            guard let item = row.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let idRange = Range(item.range(at: 3), in: line), let titleRange = Range(item.range(at: 1), in: line),
                  let stateRange = Range(item.range(at: 2), in: line) else { continue }
            let id = String(line[idRange])
            guard UUID(uuidString: id) != nil else { throw AgentHistoryFailure("agents.history.error.protocol") }
            let file = try transcript(id: id, root: root)
            let metadata = try transcriptMetadata(file)
            guard metadata["sessionId"] as? String == id else { throw AgentHistoryFailure("agents.history.error.changed") }
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            var protection = AgentHistorySession.protection(in: metadata, project: context.project)
            if line[stateRange].contains("current") { protection = "agents.history.protected.active" }
            let modified = try URL(fileURLWithPath: file)
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            sessions.append(.init(provider: .gemini, sessionID: id, title: String(line[titleRange]),
                project: context.project,
                updatedAt: (metadata["lastUpdated"] as? String).flatMap(Self.date)
                    ?? modified,
                fingerprint: try AgentHistoryBackup.hashFile(URL(fileURLWithPath: file)),
                metadata: data, protection: protection, transcript: file, artifactRoot: root))
        }
        guard sessions.count == expected, Set(sessions.map(\.id)).count == expected else {
            throw AgentHistoryFailure("agents.history.error.protocol")
        }
        return sessions
    }

    func prepareBackup(_ session: AgentHistorySession, to directory: URL) async throws {
        guard let file = session.transcript, let root = session.artifactRoot else {
            throw AgentHistoryFailure("agents.history.error.backup")
        }
        try AgentHistoryBackup.copy(file, to: directory.appendingPathComponent("transcript"), home: context.home)
        let fm = FileManager.default
        let short = String(session.sessionID.prefix(8))
        let scoped = root + "/" + session.sessionID
        if AgentCatalog.exists(scoped) { try AgentHistoryBackup.copy(scoped, to: directory.appendingPathComponent("artifacts"), home: context.home) }
        // Old layouts have shared artifact directories. Save their related state
        // without ever copying credentials, settings, memory or skills.
        for leaf in ["plans", "tracker", "tasks", "tool-outputs", "logs", "subagents"] {
            let parent = root + "/" + leaf
            guard AgentCatalog.isDirectory(parent) else { continue }
            for name in try fm.contentsOfDirectory(atPath: parent) where name.contains(session.sessionID) || name.contains(short) {
                try AgentHistoryBackup.copy(parent + "/" + name,
                    to: directory.appendingPathComponent(leaf + "-" + name), home: context.home)
            }
        }
        let registry = URL(fileURLWithPath: root).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("projects.json").path
        if AgentCatalog.isRegularFile(registry) {
            try AgentHistoryBackup.copy(registry, to: directory.appendingPathComponent("project-registry.json"), home: context.home)
        }
    }

    func delete(_ session: AgentHistorySession) async throws {
        guard UUID(uuidString: session.sessionID) != nil else { throw AgentHistoryFailure("agents.history.error.protocol") }
        let result = try await runHistoryCommand(["--delete-session", session.sessionID])
        // Gemini can report failures to stderr and still exit zero. The coordinator
        // always lists again and checks the exact UUID, regardless of this status.
        guard result.status == 0, !result.timedOut, !result.overflowed,
              let output = String(data: result.data, encoding: .utf8), output.contains("Deleted session ") else {
            throw AgentHistoryFailure("agents.history.error.api")
        }
    }

    func close() {}

    private func runHistoryCommand(_ arguments: [String]) async throws -> AgentHistoryProcess.Output {
        // The official CLI starts expiry cleanup even for --list-sessions.
        // Override that setting for this invocation, preserving other system
        // settings and the original system-defaults path. Never edit user settings.
        let environment = AgentCatalog.storageEnvironment(home: context.home)
        let original = environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"]
            ?? "/Library/Application Support/GeminiCli/settings.json"
        guard (original as NSString).isAbsolutePath else { throw AgentHistoryFailure("agents.history.error.unsupported") }
        var settings: [String: Any] = [:]
        if AgentCatalog.exists(original) {
            guard AgentCatalog.isRegularFile(original), !AgentCatalog.isSymlink(original) else {
                throw AgentHistoryFailure("agents.history.error.unsupported")
            }
            // A JSONC or unreadable managed file is retained, not silently replaced.
            settings = try AgentHistoryBackup.smallJSON(URL(fileURLWithPath: original))
        }
        guard settings["general"] == nil || settings["general"] is [String: Any] else {
            throw AgentHistoryFailure("agents.history.error.unsupported")
        }
        var general = settings["general"] as? [String: Any] ?? [:]
        guard general["sessionRetention"] == nil || general["sessionRetention"] is [String: Any] else {
            throw AgentHistoryFailure("agents.history.error.unsupported")
        }
        var retention = general["sessionRetention"] as? [String: Any] ?? [:]
        retention["enabled"] = false
        general["sessionRetention"] = retention
        settings["general"] = general
        let root = URL(fileURLWithPath: context.home)
            .appendingPathComponent("Library/Application Support/Nori/agent-history-invocations")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard root.resolvingSymlinksInPath().path == root.path else { throw AgentHistoryFailure("agents.history.error.backup") }
        let invocation = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: invocation, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        // This directory is created exclusively by this invocation, not obtained
        // from Agent metadata. Removing it cannot remove a history file.
        defer { try? FileManager.default.removeItem(at: invocation) }
        let file = invocation.appendingPathComponent("settings.json")
        try AgentHistoryBackup.writeJSON(settings, to: file)
        let defaults = environment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"]
            ?? URL(fileURLWithPath: original).deletingLastPathComponent().appendingPathComponent("system-defaults.json").path
        return try await AgentHistoryProcess.run(context: context, arguments: arguments,
            environment: ["GEMINI_CLI_SYSTEM_SETTINGS_PATH": file.path, "GEMINI_CLI_SYSTEM_DEFAULTS_PATH": defaults])
    }

    private func projectStorage() throws -> String {
        let environment = AgentCatalog.storageEnvironment(home: context.home)
        let base = AgentCatalog.absolute(environment["SANDBOX"] == "sandbox-exec" ? ".cache/.gemini" : ".gemini", home: context.home)
        let registry = try AgentHistoryBackup.smallJSON(URL(fileURLWithPath: base + "/projects.json"))
        guard let projects = registry["projects"] as? [String: String],
              let slug = projects[context.project],
              slug.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else {
            throw AgentHistoryFailure("agents.history.error.backup")
        }
        let root = base + "/tmp/" + slug
        guard AgentCatalog.isPhysical(root, home: context.home), AgentCatalog.isDirectory(root) else {
            throw AgentHistoryFailure("agents.history.error.backup")
        }
        let marker = root + "/.project_root"
        guard AgentCatalog.isRegularFile(marker), !AgentCatalog.isSymlink(marker),
              try String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == context.project else {
            throw AgentHistoryFailure("agents.history.error.changed")
        }
        return root
    }

    private func transcript(id: String, root: String) throws -> String {
        let chats = root + "/chats"
        let names = try FileManager.default.contentsOfDirectory(atPath: chats)
        guard names.count < 10_000 else { throw AgentHistoryFailure("agents.history.error.tooLarge") }
        let candidates = names.filter {
            $0.hasPrefix("session-") && ($0.hasSuffix(".json") || $0.hasSuffix(".jsonl"))
                && $0.contains(String(id.prefix(8)))
        }.map { chats + "/" + $0 }.filter {
            AgentCatalog.isRegularFile($0) && !AgentCatalog.isSymlink($0)
        }
        let matches = try candidates.filter { try transcriptMetadata($0)["sessionId"] as? String == id }
        guard matches.count == 1 else { throw AgentHistoryFailure("agents.history.error.backup") }
        return matches[0]
    }

    private func transcriptMetadata(_ path: String) throws -> [String: Any] {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 64 * 1024) ?? Data()
        if let newline = header.firstIndex(of: 10),
           let object = (try? JSONSerialization.jsonObject(with: header[..<newline])) as? [String: Any],
           object["sessionId"] as? String != nil { return object }
        let object = try AgentHistoryBackup.smallJSON(URL(fileURLWithPath: path))
        return object.filter { ["sessionId", "projectHash", "startTime", "lastUpdated", "type", "parentSessionId"].contains($0.key) }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
