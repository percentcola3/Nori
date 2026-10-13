import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Private, disk-backed snapshots. Nothing here writes to an Agent's data root.
enum AgentHistoryBackup {
    private static let maximumBytes: Int64 = 512 * 1024 * 1024

    static func create(for session: AgentHistorySession, context: AgentHistoryContext, version: String) throws -> URL {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: context.home)
            .appendingPathComponent("Library/Application Support/Nori/agent-history-backups")
        try fm.createDirectory(at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard base.resolvingSymlinksInPath().standardizedFileURL.path == base.standardizedFileURL.path else {
            throw AgentHistoryFailure("agents.history.error.backup")
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        let directory = base.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let manifest: [String: Any] = ["schemaVersion": 1, "provider": session.provider.rawValue,
            "sessionID": session.sessionID, "project": session.project, "title": session.title,
            "createdAt": ISO8601DateFormatter().string(from: Date()), "nativeVersion": version,
            "fingerprint": session.fingerprint, "state": "preparing",
            "restore": "Manual recovery only. Do not overwrite live Agent databases."]
        try writeJSON(manifest, to: directory.appendingPathComponent("manifest.json"))
        try write(session.metadata, to: directory.appendingPathComponent("session-metadata.json"))
        return directory
    }

    static func writeJSON(_ object: Any, to url: URL) throws {
        try write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]), to: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        guard data.count <= Int(maximumBytes) else { throw AgentHistoryFailure("agents.history.error.tooLarge") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func copy(_ source: String, to destination: URL, home: String = NSHomeDirectory()) throws {
        guard AgentCatalog.isPhysical(source, home: home),
              !AgentCatalog.isSymlink(source) else { throw AgentHistoryFailure("agents.history.error.backup") }
        let fm = FileManager.default
        var paths = [URL(fileURLWithPath: source)]
        if AgentCatalog.isDirectory(source) {
            var enumerationFailed = false
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: source),
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                options: [], errorHandler: { _, _ in enumerationFailed = true; return false }) else {
                throw AgentHistoryFailure("agents.history.error.backup")
            }
            // Bound the manifest as well as payload bytes; an incomplete walk refuses deletion.
            for case let url as URL in enumerator {
                guard paths.count < 20_000 else { throw AgentHistoryFailure("agents.history.error.tooLarge") }
                paths.append(url)
            }
            guard !enumerationFailed else { throw AgentHistoryFailure("agents.history.error.backup") }
        }
        var bytes = try directoryBytes(destination.deletingLastPathComponent())
        var proofs: [[String: String]] = []
        for url in paths {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw AgentHistoryFailure("agents.history.error.backup") }
            let relative = String(url.path.dropFirst(source.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = relative.isEmpty ? destination : destination.appendingPathComponent(relative)
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } else {
                guard values.isRegularFile == true, let size = values.fileSize else {
                    throw AgentHistoryFailure("agents.history.error.backup")
                }
                guard Int64(size) <= maximumBytes - bytes, let identity = DeletionPlan.identity(at: url.path) else {
                    throw AgentHistoryFailure("agents.history.error.tooLarge")
                }
                bytes += Int64(size)
                let before = try hashFile(url)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try fm.copyItem(at: url, to: target)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                guard DeletionPlan.identity(at: url.path) == identity,
                      try hashFile(url) == before, try hashFile(target) == before else {
                    throw AgentHistoryFailure("agents.history.error.changed")
                }
                proofs.append(["source": url.path, "identity": identity, "sha256": before])
            }
        }
        try writeJSON(proofs, to: destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + "-proof.json"))
    }

    static func snapshotSQLite(_ source: String, to destination: URL) throws {
        guard AgentCatalog.isRegularFile(source), !AgentCatalog.isSymlink(source) else {
            throw AgentHistoryFailure("agents.history.error.backup")
        }
        let sourceBytes = try URL(fileURLWithPath: source).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        let wal = source + "-wal"
        let walBytes = AgentCatalog.exists(wal)
            ? (try URL(fileURLWithPath: wal).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) : 0
        guard Int64(sourceBytes) <= maximumBytes,
              Int64(walBytes) <= maximumBytes - Int64(sourceBytes),
              try directoryBytes(destination.deletingLastPathComponent()) <= maximumBytes - Int64(sourceBytes) - Int64(walBytes) else {
            throw AgentHistoryFailure("agents.history.error.tooLarge")
        }
        var input: OpaquePointer?
        var output: OpaquePointer?
        defer { if let input { sqlite3_close(input) }; if let output { sqlite3_close(output) } }
        guard sqlite3_open_v2(source, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw AgentHistoryFailure("agents.history.error.backup")
        }
        var result: Int32 = SQLITE_OK
        let deadline = Date().addingTimeInterval(5)
        repeat {
            result = sqlite3_backup_step(backup, 256)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.05) }
        } while [SQLITE_OK, SQLITE_BUSY, SQLITE_LOCKED].contains(result) && Date() < deadline
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else {
            throw AgentHistoryFailure("agents.history.error.backup")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func finish(_ directory: URL, state: String) throws {
        let url = directory.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw AgentHistoryFailure("agents.history.error.backup")
        }
        manifest["state"] = state
        try writeJSON(manifest, to: url)
    }

    static func validate(_ directory: URL, session: AgentHistorySession) throws {
        let manifest = try smallJSON(directory.appendingPathComponent("manifest.json"))
        guard manifest["sessionID"] as? String == session.sessionID,
              manifest["fingerprint"] as? String == session.fingerprint,
              try Data(contentsOf: directory.appendingPathComponent("session-metadata.json")) == session.metadata,
              try directoryBytes(directory) <= maximumBytes,
              let enumerator = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw AgentHistoryFailure("agents.history.error.backup")
        }
        var files: [[String: Any]] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw AgentHistoryFailure("agents.history.error.backup") }
            guard values.isRegularFile == true else { continue }
            guard files.count < 20_000 else { throw AgentHistoryFailure("agents.history.error.tooLarge") }
            files.append(["path": String(file.path.dropFirst(directory.path.count + 1)),
                          "sha256": try hashFile(file)])
        }
        guard files.contains(where: { item in
            guard let path = item["path"] as? String else { return false }
            return path != "manifest.json" && path != "session-metadata.json" && !path.hasSuffix("-proof.json")
        }) else { throw AgentHistoryFailure("agents.history.error.backup") }
        try writeJSON(files, to: directory.appendingPathComponent("backup-files.json"))
    }

    static func recheckSources(_ directory: URL) throws {
        for file in try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil) where file.lastPathComponent.hasSuffix("-proof.json") {
            guard let proofs = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: String]] else {
                throw AgentHistoryFailure("agents.history.error.backup")
            }
            for proof in proofs {
                guard let source = proof["source"], let identity = proof["identity"], let digest = proof["sha256"],
                      DeletionPlan.identity(at: source) == identity,
                      try hashFile(URL(fileURLWithPath: source)) == digest else {
                    throw AgentHistoryFailure("agents.history.error.changed")
                }
            }
        }
    }

    private static func directoryBytes(_ directory: URL) throws -> Int64 {
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [], errorHandler: { _, _ in failed = true; return false }) else {
            throw AgentHistoryFailure("agents.history.error.backup")
        }
        var total: Int64 = 0
        var count = 0
        for case let file as URL in enumerator {
            count += 1
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard count <= 20_000, values.isSymbolicLink != true else {
                throw AgentHistoryFailure("agents.history.error.backup")
            }
            if values.isRegularFile == true {
                let bytes = Int64(values.fileSize ?? 0)
                guard bytes <= maximumBytes - total else { throw AgentHistoryFailure("agents.history.error.tooLarge") }
                total += bytes
            }
        }
        guard !failed else { throw AgentHistoryFailure("agents.history.error.backup") }
        return total
    }

    static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func smallJSON(_ url: URL) throws -> [String: Any] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 8 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw AgentHistoryFailure("agents.history.error.protocol")
        }
        return object
    }
}
