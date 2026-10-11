import Foundation

enum AgentCodexFeatureEditor {
    static let threadStoreCompressionKey = "local_thread_store_compression"

    enum State: Equatable, Sendable {
        case enabled, disabled, unknown
    }

    enum Failure: LocalizedError {
        case unreadable
        case changed
        case backupFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "config.toml could not be parsed safely"
            case .changed: return "config.toml changed while it was being edited"
            case .backupFailed: return "config.toml could not be backed up"
            case .writeFailed(let message): return message
            }
        }
    }

    static func threadStoreCompression(home: String) -> State {
        let path = AgentCatalog.absolute(".codex/config.toml", home: home)
        guard FileManager.default.fileExists(atPath: path) else { return .disabled }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let parsed = parse(text) else { return .unknown }
        return parsed.value.map { $0 ? .enabled : .disabled } ?? .disabled
    }

    static func setThreadStoreCompression(_ enabled: Bool, home: String) -> Result<Void, Error> {
        let path = AgentCatalog.absolute(".codex/config.toml", home: home)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            do {
                try fileManager.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let text = "[features]\n\(threadStoreCompressionKey) = \(enabled ? "true" : "false")\n"
                try text.write(toFile: path, atomically: true, encoding: .utf8)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                return .success(())
            } catch {
                return .failure(Failure.writeFailed(error.localizedDescription))
            }
        }

        guard AgentMCPConfigEditor.isPhysicalConfig(path),
              let original = try? String(contentsOfFile: path, encoding: .utf8),
              let parsed = parse(original) else { return .failure(Failure.unreadable) }
        let output: String
        if let line = parsed.assignmentLine {
            guard let replaced = replacingBoolean(in: original, line: line, enabled: enabled) else {
                return .failure(Failure.unreadable)
            }
            output = replaced
        } else if let insertionLine = parsed.featuresInsertionLine {
            var lines = original.components(separatedBy: "\n")
            lines.insert("\(threadStoreCompressionKey) = \(enabled ? "true" : "false")", at: insertionLine)
            output = lines.joined(separator: "\n")
        } else {
            var suffix = original
            if !suffix.isEmpty, !suffix.hasSuffix("\n") { suffix += "\n" }
            if !suffix.isEmpty, !suffix.hasSuffix("\n\n") { suffix += "\n" }
            output = suffix + "[features]\n\(threadStoreCompressionKey) = \(enabled ? "true" : "false")\n"
        }
        guard (try? String(contentsOfFile: path, encoding: .utf8)) == original else {
            return .failure(Failure.changed)
        }
        guard let identity = DeletionPlan.identity(at: path),
              let fingerprint = AgentMCPConfigEditor.fingerprint(at: path),
              AgentMCPConfigEditor.backupConfiguration(path, identity: identity, fingerprint: fingerprint) else {
            return .failure(Failure.backupFailed)
        }
        guard (try? String(contentsOfFile: path, encoding: .utf8)) == original,
              AgentMCPConfigEditor.isPhysicalConfig(path) else { return .failure(Failure.changed) }
        let permissions = (try? fileManager.attributesOfItem(atPath: path)[.posixPermissions]) ?? 0o600
        do {
            try output.write(toFile: path, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
            return .success(())
        } catch {
            return .failure(Failure.writeFailed(error.localizedDescription))
        }
    }

    private struct Parsed {
        let value: Bool?
        let assignmentLine: Int?
        let featuresInsertionLine: Int?
    }

    private static func parse(_ text: String) -> Parsed? {
        guard let statements = AgentTOMLStatements.read(text),
              statements.allSatisfy({ !$0.text.contains("\n")
                  && !$0.text.contains("\"\"\"") && !$0.text.contains("'''") }) else { return nil }
        var inFeatures = false
        var featuresFound = false
        var assignmentLine: Int?
        var value: Bool?
        var insertionLine: Int?
        for statement in statements {
            if let header = AgentTOMLStatements.header(statement.text) {
                inFeatures = header.path == ["features"] && !header.array
                if inFeatures {
                    guard !featuresFound else { return nil }
                    featuresFound = true
                    insertionLine = statement.line + 1
                }
                continue
            }
            guard inFeatures else { continue }
            insertionLine = statement.line + 1
            guard let assignment = AgentTOMLStatements.assignment(statement.text),
                  assignment.path == [threadStoreCompressionKey] else { continue }
            guard assignmentLine == nil else { return nil }
            switch assignment.value {
            case "true": value = true
            case "false": value = false
            default: return nil
            }
            assignmentLine = statement.line
        }
        return Parsed(value: value, assignmentLine: assignmentLine,
                      featuresInsertionLine: featuresFound ? insertionLine : nil)
    }

    private static func replacingBoolean(in text: String, line lineIndex: Int,
                                         enabled: Bool) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex), let equals = lines[lineIndex].firstIndex(of: "=") else { return nil }
        let line = lines[lineIndex]
        let valueStart = line.index(after: equals)
        let tail = line[valueStart...]
        let comment = tail.firstIndex(of: "#") ?? line.endIndex
        let valueSlice = line[valueStart..<comment]
        let leading = valueSlice.prefix(while: \Character.isWhitespace)
        let trailing = valueSlice.reversed().prefix(while: \Character.isWhitespace).reversed()
        lines[lineIndex] = String(line[...equals]) + leading
            + (enabled ? "true" : "false") + trailing + line[comment...]
        return lines.joined(separator: "\n")
    }
}
