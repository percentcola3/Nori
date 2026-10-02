import Foundation
import CryptoKit

/// 按用户勾选把 MCP 服务器条目从配置文件中移除。
/// 修改前把原文件备份为 `<path>.nori-backup`；JSON 重写为规格化输出，
/// TOML 只整段删除命中的 `[<table>.<name>]`，其余行保持原样。
enum AgentMCPConfigEditor {
    struct Request: Equatable, Sendable {
        let configPath: String
        let format: AgentMCPFormat
        let serverName: String
        let scope: String?
        var expectedIdentity: String? = nil
        var expectedFingerprint: String? = nil
    }

    struct Outcome: Sendable {
        var removed = 0
        /// 复核时条目已不存在（配置被外部改动）。
        var missing = 0
        var failed = 0
        var messages: [String] = []
        var editedPaths = Set<String>()
    }

    static func apply(_ requests: [Request]) -> Outcome {
        var outcome = Outcome()
        let unique = requests.reduce(into: [Request]()) { result, request in
            if !result.contains(request) { result.append(request) }
        }
        let byFile = Dictionary(grouping: unique, by: \.configPath)
        for (path, fileRequests) in byFile.sorted(by: { $0.key < $1.key }) {
            guard isPhysicalConfig(path), let identity = DeletionPlan.identity(at: path),
                  let fingerprint = fingerprint(at: path),
                  fileRequests.allSatisfy({ request in
                      (request.expectedIdentity == nil || request.expectedIdentity == identity)
                        && (request.expectedFingerprint == nil || request.expectedFingerprint == fingerprint)
                  }) else {
                outcome.failed += fileRequests.count
                outcome.messages.append("Configuration changed or is a symbolic link: " + path)
                continue
            }
            guard let format = fileRequests.first?.format else { continue }
            switch format {
            case .json(let keyPath):
                if !editJSON(at: path, keyPath: keyPath, requests: fileRequests, outcome: &outcome) {
                    outcome.failed += fileRequests.count
                    outcome.messages.append(path)
                }
            case .toml(let table):
                if !editTOML(at: path, table: table, requests: fileRequests, outcome: &outcome) {
                    outcome.failed += fileRequests.count
                    outcome.messages.append(path)
                }
            }
        }
        return outcome
    }

    // MARK: - JSON

    private static func editJSON(at path: String, keyPath: String,
                                 requests: [Request], outcome: inout Outcome) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(
                with: data, options: [.json5Allowed, .mutableContainers])) as? NSMutableDictionary
        else { return false }
        var removals = 0
        for request in requests {
            var removed = false
            if request.scope == nil {
                removed = removeServer(request.serverName, keyPath: keyPath, object: root)
            }
            if let scope = request.scope,
               let projects = root["projects"] as? NSMutableDictionary,
               let project = projects[scope] as? NSMutableDictionary {
                if removeServer(request.serverName, keyPath: keyPath, object: project) {
                    removed = true
                }
            }
            if removed { removals += 1 } else { outcome.missing += 1 }
        }
        guard removals > 0 else { return true }
        guard FileManager.default.contents(atPath: path) == data,
              isPhysicalConfig(path), backup(path),
              let output = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        guard FileManager.default.contents(atPath: path) == data, isPhysicalConfig(path) else { return false }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions])
        do {
            try output.write(to: URL(fileURLWithPath: path), options: .atomic)
            if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path) }
        }
        catch { return false }
        outcome.removed += removals
        outcome.editedPaths.insert(path)
        return true
    }

    /// 按 keyPath 定位 name → server 表并删除条目；兼容「整个 key 写成带点名字」的工具。
    @discardableResult
    private static func removeServer(_ name: String, keyPath: String,
                                     object: NSMutableDictionary) -> Bool {
        var container: NSDictionary = object
        for component in keyPath.split(separator: ".") {
            guard let next = container[String(component)] as? NSDictionary else {
                container = [:]
                break
            }
            container = next
        }
        if let table = container as? NSMutableDictionary, table[name] != nil {
            table.removeObject(forKey: name)
            return true
        }
        if let flat = object[keyPath] as? NSMutableDictionary, flat[name] != nil {
            flat.removeObject(forKey: name)
            return true
        }
        return false
    }

    // MARK: - TOML

    private static func editTOML(at path: String, table: String,
                                 requests: [Request], outcome: inout Outcome) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let statements = AgentTOMLStatements.read(text) else { return false }
        let targets = Set(requests.map(\.serverName))
        let lines = text.components(separatedBy: "\n")
        let headers = statements.compactMap { statement -> (Int, AgentTOMLStatements.Header)? in
            AgentTOMLStatements.header(statement.text).map { (statement.line, $0) }
        }
        var removedLines = Set<Int>()
        var removedNames = Set<String>()
        var currentTable: [String] = []
        for statement in statements {
            if let header = AgentTOMLStatements.header(statement.text) { currentTable = header.path }
            else if let item = AgentTOMLStatements.assignment(statement.text),
                    item.path.first == table || currentTable == [table] { return false }
        }
        for (index, entry) in headers.enumerated() {
            let (line, header) = entry
            guard header.path.first == table else { continue }
            guard !header.array else { return false }
            guard header.path.count >= 2, targets.contains(header.path[1]) else { continue }
            let end = index + 1 < headers.count ? headers[index + 1].0 : lines.count
            removedLines.formUnion(line..<end)
            removedNames.insert(header.path[1])
        }
        for name in targets where !removedNames.contains(name) {
            outcome.missing += 1
        }
        guard !removedNames.isEmpty else { return true }
        guard (try? String(contentsOfFile: path, encoding: .utf8)) == text,
              isPhysicalConfig(path), backup(path) else { return false }
        guard (try? String(contentsOfFile: path, encoding: .utf8)) == text, isPhysicalConfig(path) else { return false }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions])
        do {
            try lines.enumerated().filter { !removedLines.contains($0.offset) }.map(\.element)
                .joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path) }
        }
        catch { return false }
        outcome.removed += removedNames.count
        outcome.editedPaths.insert(path)
        return true
    }

    // MARK: - 备份

    static func fingerprint(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isPhysicalConfig(_ path: String) -> Bool {
        guard DeletionPlan.isLexicallySafePath(path), AgentCatalog.exists(path) else { return false }
        var probe = path
        while probe != "/" {
            if AgentCatalog.isSymlink(probe) { return false }
            probe = (probe as NSString).deletingLastPathComponent
        }
        return true
    }

    /// 备份不可解析的配置后，调用方可经统一删除漏斗重置整份配置。
    static func backupConfiguration(_ path: String, identity: String, fingerprint expected: String) -> Bool {
        guard isPhysicalConfig(path), !identity.isEmpty, !expected.isEmpty,
              DeletionPlan.identity(at: path) == identity, fingerprint(at: path) == expected else { return false }
        return backup(path)
    }

    /// 固定备份保留最新原貌，时间戳副本保留首次及后续原貌；权限沿用配置文件。
    private static func backup(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        do {
            let archive = path + ".nori-backup-" + UUID().uuidString
            try data.write(to: URL(fileURLWithPath: archive), options: .withoutOverwriting)
            try data.write(to: URL(fileURLWithPath: path + ".nori-backup"), options: .atomic)
            let permissions = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) ?? 0o600
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: archive)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path + ".nori-backup")
            return true
        } catch {
            return false
        }
    }
}

/// Codex 的显式 Skill 挂靠（[[skills.config]]）也随已删除的本体解除。
/// 仅改写命中 path 的完整数组元素，模型/provider/MCP 等其它配置逐行保留。
enum AgentSkillConfigEditor {
    struct ScanResult {
        let registrations: [Registration]
        /// Configuration exists but cannot be safely interpreted. Body deletion
        /// must retain it until the caller can rule out unknown registrations.
        let unresolvedConfigPaths: Set<String>
    }

    struct Registration: Equatable, Sendable {
        let configPath: String
        let skillPath: String
        let resolvedPath: String
        let configIdentity: String
        let configFingerprint: String

        func references(_ body: String) -> Bool {
            resolvedPath == body || (resolvedPath.hasPrefix(body + "/") && resolvedPath.hasSuffix("/SKILL.md"))
        }

        /// A declaration through a Skill link belongs to that link, even though
        /// its resolved body may be shared by other declarations and links.
        func declares(_ path: String, home: String) -> Bool {
            let absolute = skillPath.hasPrefix("~/") ? home + skillPath.dropFirst() : skillPath
            guard DeletionPlan.isLexicallySafePath(absolute) else { return false }
            let declared = URL(fileURLWithPath: absolute).standardizedFileURL.path
            return declared == path || declared.hasPrefix(path + "/")
        }
    }

    static func scan(home: String) -> [Registration] {
        scanResult(home: home).registrations
    }

    static func scanResult(home: String) -> ScanResult {
        let path = AgentCatalog.absolute(".codex/config.toml", home: home)
        guard AgentCatalog.exists(path) else { return ScanResult(registrations: [], unresolvedConfigPaths: []) }
        guard AgentCatalog.isPhysical(path, home: home),
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let identity = DeletionPlan.identity(at: path),
              let fingerprint = AgentMCPConfigEditor.fingerprint(at: path),
              let parsed = sections(text) else {
            return ScanResult(registrations: [], unresolvedConfigPaths: [path])
        }
        let registrations = parsed.compactMap { section -> Registration? in
            guard let value = section.path else { return nil }
            let absolute = value.hasPrefix("~/") ? home + value.dropFirst() : value
            guard DeletionPlan.isLexicallySafePath(absolute) else { return nil }
            return Registration(configPath: path, skillPath: value,
                resolvedPath: URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path,
                configIdentity: identity, configFingerprint: fingerprint)
        }
        return ScanResult(registrations: registrations, unresolvedConfigPaths: [])
    }

    static func apply(_ registrations: [Registration]) -> AgentMCPConfigEditor.Outcome {
        var outcome = AgentMCPConfigEditor.Outcome()
        for (path, requests) in Dictionary(grouping: registrations, by: \.configPath) {
            guard let request = requests.first,
                  requests.allSatisfy({ $0.configIdentity == request.configIdentity
                    && $0.configFingerprint == request.configFingerprint }),
                  AgentMCPConfigEditor.isPhysicalConfig(path),
                  DeletionPlan.identity(at: path) == request.configIdentity,
                  AgentMCPConfigEditor.fingerprint(at: path) == request.configFingerprint,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                outcome.failed += requests.count
                outcome.messages.append("Skill configuration changed or is a symbolic link: " + path)
                continue
            }
            let targets = Set(requests.map(\.skillPath))
            guard let parsed = sections(text) else {
                outcome.failed += requests.count
                outcome.messages.append("Unsupported or malformed Skill TOML configuration: " + path)
                continue
            }
            let matches = parsed.filter { $0.path.map(targets.contains) == true }
            guard !matches.isEmpty else { outcome.missing += requests.count; continue }
            let lines = text.components(separatedBy: "\n")
            let removedLines = Set(matches.flatMap { Array($0.range) })
            let output = lines.enumerated().filter { !removedLines.contains($0.offset) }
                .map(\.element).joined(separator: "\n")
            guard AgentMCPConfigEditor.backupConfiguration(path,
                identity: request.configIdentity, fingerprint: request.configFingerprint),
                  DeletionPlan.identity(at: path) == request.configIdentity,
                  AgentMCPConfigEditor.fingerprint(at: path) == request.configFingerprint,
                  AgentMCPConfigEditor.isPhysicalConfig(path) else {
                outcome.failed += matches.count
                outcome.messages.append("Failed to back up Skill configuration: " + path)
                continue
            }
            do {
                let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
                try output.write(toFile: path, atomically: true, encoding: .utf8)
                if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path) }
                outcome.removed += matches.count
                outcome.editedPaths.insert(path)
            } catch {
                outcome.failed += matches.count
                outcome.messages.append("Failed to unlink Skill configuration: " + path)
            }
        }
        return outcome
    }

    private struct Section {
        let range: Range<Int>
        let path: String?
    }

    private static func sections(_ text: String) -> [Section]? {
        guard let statements = AgentTOMLStatements.read(text) else { return nil }
        var result: [Section] = []
        var start: Int?
        var path: String?
        var tablePath: [String] = []
        var keys = Set<[String]>()
        var tables = Set<[String]>()
        var arrays = Set<[String]>()
        for statement in statements {
            let stripped = statement.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.hasPrefix("[") {
                let array = stripped.hasPrefix("[[")
                let count = array ? 2 : 1
                guard stripped.hasSuffix(array ? "]]" : "]"),
                      let name = AgentTOMLStatements.keyPath(String(stripped.dropFirst(count).dropLast(count))) else { return nil }
                // Nested tables belong to an array element; removing only its header
                // would reattach them to another Skill. Leave this layout untouched.
                if Array(name.prefix(2)) == ["skills", "config"], name.count > 2 || !array { return nil }
                if array {
                    guard !tables.contains(name) else { return nil }
                    arrays.insert(name)
                } else {
                    guard !arrays.contains(name), tables.insert(name).inserted else { return nil }
                }
                if let start { result.append(Section(range: start..<statement.line, path: path)) }
                start = array && name == ["skills", "config"] ? statement.line : nil
                tablePath = name
                path = nil
                keys.removeAll()
            } else {
                guard let equals = stripped.firstIndex(of: "="),
                      let name = AgentTOMLStatements.keyPath(String(stripped[..<equals])),
                      !keys.contains(where: { $0.starts(with: name) || name.starts(with: $0) }),
                      !stripped[stripped.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                keys.insert(name)
                // Inline/dotted Skills arrays need a real value decoder before
                // their elements can safely be removed by a section editor.
                if start == nil, name.first == "skills" || (tablePath == ["skills"] && name.first == "config") {
                    return nil
                }
                guard start != nil, name == ["path"] else { continue }
                let value = stripped[stripped.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                guard let decoded = AgentTOMLStatements.stringValue(value) else { return nil }
                path = decoded
            }
        }
        if let start { result.append(Section(range: start..<text.components(separatedBy: "\n").count, path: path)) }
        return result
    }


}

/// Only exposes complete TOML statements at physical line boundaries. String
/// contents and multiline array values never become table headers. This is a
/// bounded lexer, not a general TOML decoder; ambiguous input fails closed.
enum AgentTOMLStatements {
    struct Header {
        let path: [String]
        let array: Bool
    }

    struct Assignment {
        let path: [String]
        let value: String
    }

    static func header(_ raw: String) -> Header? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("[") else { return nil }
        let array = text.hasPrefix("[[")
        let count = array ? 2 : 1
        guard text.hasSuffix(array ? "]]" : "]"),
              let path = keyPath(String(text.dropFirst(count).dropLast(count))) else { return nil }
        return Header(path: path, array: array)
    }

    static func assignment(_ raw: String) -> Assignment? {
        var quote: Character?
        var escaped = false
        for index in raw.indices {
            let character = raw[index]
            if escaped { escaped = false; continue }
            if quote == "\"", character == "\\" { escaped = true; continue }
            if character == quote { quote = nil }
            else if quote == nil, character == "\"" || character == "'" { quote = character }
            if character == "=", quote == nil {
                guard let path = keyPath(String(raw[..<index])) else { return nil }
                let value = raw[raw.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : Assignment(path: path, value: value)
            }
        }
        return nil
    }

    /// MCP fields use strings, string arrays, booleans and numeric timeouts.
    /// Unsupported compound values are reported as unreadable, never guessed.
    static func value(_ raw: String) -> Any? {
        if raw == "true" { return true }
        if raw == "false" { return false }
        if let string = stringValue(raw) { return string }
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let body = String(raw.dropFirst().dropLast())
            var values: [String] = []
            var part = ""
            var quote: Character?
            var escaped = false
            for character in body {
                if escaped { escaped = false; part.append(character); continue }
                if quote == "\"", character == "\\" { escaped = true; part.append(character); continue }
                if character == quote { quote = nil }
                else if quote == nil, character == "\"" || character == "'" { quote = character }
                if character == ",", quote == nil {
                    guard let string = stringValue(part.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
                    values.append(string); part = ""
                } else { part.append(character) }
            }
            let trailing = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                guard let string = stringValue(trailing) else { return nil }
                values.append(string)
            }
            return values
        }
        if let number = Double(raw.replacingOccurrences(of: "_", with: "")) { return number }
        return nil
    }

    static func stringValue(_ value: String) -> String? {
        guard !value.hasPrefix("\"\"\""), !value.hasPrefix("'''"), !value.contains("\n") else { return nil }
        if value.hasPrefix("\""), let data = ("[" + value + "]").data(using: .utf8),
           let array = (try? JSONSerialization.jsonObject(with: data)) as? [String], array.count == 1 {
            return array[0]
        }
        if value.count >= 2, value.first == "'", value.last == "'" {
            let body = String(value.dropFirst().dropLast())
            return body.contains("'") ? nil : body
        }
        return nil
    }

    static func keyPath(_ value: String) -> [String]? {
        var parts: [String] = []
        var part = ""
        var quote: Character?
        var escaped = false
        func appendPart() -> Bool {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if let decoded = stringValue(trimmed) { parts.append(decoded) }
            else {
                guard !trimmed.isEmpty, trimmed.allSatisfy({
                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
                }) else { return false }
                parts.append(trimmed)
            }
            part = ""
            return true
        }
        for character in value {
            if escaped { part.append(character); escaped = false; continue }
            if quote == "\"", character == "\\" { part.append(character); escaped = true; continue }
            if character == quote { quote = nil }
            else if quote == nil, character == "\"" || character == "'" { quote = character }
            if character == ".", quote == nil {
                guard appendPart() else { return nil }
            } else { part.append(character) }
        }
        guard quote == nil, !escaped, appendPart() else { return nil }
        return parts
    }

    struct Statement {
        let line: Int
        let text: String
    }

    private enum Quote { case basic, literal, multilineBasic, multilineLiteral }

    static func read(_ text: String) -> [Statement]? {
        guard text.utf8.count <= 1_048_576 else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.count <= 50_000 else { return nil }
        var result: [Statement] = []
        var quote: Quote?
        var escaped = false
        var folding = false
        var unicodeDigits = 0
        var brackets: [Character] = []
        var content = ""
        var start = 0
        for (lineIndex, line) in lines.enumerated() {
            let characters = Array(line)
            var index = 0
            if content.isEmpty { start = lineIndex }
            while index < characters.count {
                let character = characters[index]
                guard character.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\t" || $0 == "\r" }) else { return nil }
                if folding {
                    guard character.isWhitespace else { return nil }
                    content.append(character); index += 1; continue
                }
                if unicodeDigits > 0 {
                    guard character.isHexDigit else { return nil }
                    unicodeDigits -= 1
                    content.append(character); index += 1; continue
                }
                if escaped {
                    guard "btnfr\"\\uU".contains(character)
                        || (quote == .multilineBasic && character.isWhitespace) else { return nil }
                    if character == "u" { unicodeDigits = 4 }
                    if character == "U" { unicodeDigits = 8 }
                    if character.isWhitespace { folding = true }
                    escaped = false
                    content.append(character); index += 1; continue
                }
                switch quote {
                case .basic:
                    if character == "\\" { escaped = true }
                    else if character == "\"" { quote = nil }
                case .literal:
                    if character == "'" { quote = nil }
                case .multilineBasic, .multilineLiteral:
                    let delimiter: Character = quote == .multilineBasic ? "\"" : "'"
                    if quote == .multilineBasic, character == "\\" { escaped = true }
                    if character == delimiter {
                        var end = index
                        while end < characters.count, characters[end] == delimiter { end += 1 }
                        let count = end - index
                        if count >= 3 {
                            guard count <= 5 else { return nil }
                            content += String(characters[index..<end]); index = end
                            quote = nil
                            continue
                        }
                    }
                case nil:
                    if character == "#" { index = characters.count; continue }
                    if character == "\"" || character == "'" {
                        if index + 2 < characters.count,
                           characters[index + 1] == character, characters[index + 2] == character {
                            quote = character == "\"" ? .multilineBasic : .multilineLiteral
                            content += String(repeating: String(character), count: 3); index += 3; continue
                        }
                        quote = character == "\"" ? .basic : .literal
                    } else if character == "[" || character == "{" {
                        guard brackets.count < 64 else { return nil }
                        brackets.append(character)
                    } else if character == "]" || character == "}" {
                        guard brackets.popLast() == (character == "]" ? "[" : "{") else { return nil }
                    }
                }
                content.append(character); index += 1
            }
            guard quote != .basic, quote != .literal, unicodeDigits == 0 else { return nil }
            // A basic multiline string may fold an escaped newline. It stays
            // inside the string, so the next line cannot introduce a table.
            if escaped {
                guard quote == .multilineBasic else { return nil }
                escaped = false
            }
            folding = false
            if quote == nil, brackets.isEmpty {
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(Statement(line: start, text: content))
                }
                content = ""
            } else { content.append("\n") }
        }
        guard quote == nil, brackets.isEmpty, content.isEmpty else { return nil }
        var keys = Set<[String]>()
        var tables = Set<[String]>()
        var arrays = Set<[String]>()
        for statement in result {
            if statement.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
                guard let header = header(statement.text) else { return nil }
                if header.array {
                    guard !tables.contains(header.path) else { return nil }
                    arrays.insert(header.path)
                } else {
                    guard !arrays.contains(header.path), tables.insert(header.path).inserted else { return nil }
                }
                keys.removeAll()
            } else {
                guard let item = assignment(statement.text),
                      !keys.contains(where: { $0.starts(with: item.path) || item.path.starts(with: $0) }) else { return nil }
                keys.insert(item.path)
            }
        }
        return result
    }
}
