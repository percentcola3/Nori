import Foundation

extension DeveloperShellService {
    struct AliasDeclaration: Identifiable, Equatable {
        let fileName: String
        let lineNumber: Int
        let name: String
        let command: String
        let originalLine: String
        let prefix: String
        let suffix: String
        var id: String { "\(fileName):\(lineNumber):alias:\(name)" }
    }

    static func aliasDeclarations(in profile: Profile) -> [AliasDeclaration] {
        let regex = try! NSRegularExpression(pattern: #"^(\s*alias\s+)([A-Za-z0-9_][A-Za-z0-9_.+\-]*)=(.*)$"#)
        var context = DeclarationContext()
        return profile.text.components(separatedBy: "\n").enumerated().compactMap { offset, line in
            if context.consumeHeredoc(line) { return nil }
            let accepts = context.acceptsDeclaration
            context.consumeShellLine(line)
            guard accepts, let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let prefixRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line),
                  let valueRange = Range(match.range(at: 3), in: line),
                  let value = structuredValue(String(line[valueRange])),
                  value.parts.allSatisfy({ if case .literal = $0 { return true }; return false }) else { return nil }
            let command = value.parts.map { if case .literal(let text) = $0 { return text }; return "" }.joined()
            return .init(fileName: profile.name, lineNumber: offset + 1, name: String(line[nameRange]), command: command,
                         originalLine: line, prefix: String(line[prefixRange]), suffix: value.suffix)
        }
    }

    static func settingAlias(in profile: Profile, alias: AliasDeclaration?, name: String, command: String) throws -> String {
        guard profile.canEdit, name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.+\-]*$"#, options: .regularExpression) != nil,
              !command.isEmpty, !command.contains("\n"), !command.contains("\r"), !command.contains("\0") else { throw Failure.invalidVariable }
        let value = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        if let alias {
            var lines = profile.text.components(separatedBy: "\n")
            let index = alias.lineNumber - 1
            guard alias.fileName == profile.name, lines.indices.contains(index), lines[index] == alias.originalLine else { throw Failure.changedOnDisk }
            lines[index] = alias.prefix + name + "=" + value + alias.suffix
            return lines.joined(separator: "\n")
        }
        let separator = profile.text.isEmpty || profile.text.hasSuffix("\n") ? "" : "\n"
        return profile.text + separator + "alias \(name)=\(value)\n"
    }

    static func removingAlias(in profile: Profile, alias: AliasDeclaration) throws -> String {
        var lines = profile.text.components(separatedBy: "\n")
        let index = alias.lineNumber - 1
        guard profile.canEdit, alias.fileName == profile.name, lines.indices.contains(index), lines[index] == alias.originalLine else { throw Failure.changedOnDisk }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    struct CommandAlias: Equatable, Sendable {
        let name: String
        let targetPath: String
        let targetCommand: String
    }

    /// Recognizes configured aliases to a single absolute executable path. This is a text
    /// inventory, not an evaluation of which aliases a running terminal has activated.
    static func commandAliases(in profiles: [Profile], home: String = NSHomeDirectory()) -> [CommandAlias] {
        let pattern = #"^[ \t]*alias[ \t]+([A-Za-z0-9_][A-Za-z0-9_.+\-]*)=(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var targets: [String: String] = [:]
        for fileName in startupNames(in: profiles) {
            guard let profile = profiles.first(where: { $0.name == fileName }) else { continue }
            var context = DeclarationContext()
            for line in profile.text.components(separatedBy: "\n") {
                if context.consumeHeredoc(line) { continue }
                let acceptsDeclaration = context.acceptsDeclaration
                context.consumeShellLine(line)
                guard acceptsDeclaration else { continue }
                if let operands = commandAliasOperands(in: line, command: "unalias") {
                    if operands == ["-a"] { targets.removeAll() }
                    else if !operands.isEmpty && operands.allSatisfy(isCommandAliasName) {
                        for name in operands { targets.removeValue(forKey: name) }
                    }
                    continue
                }
                guard let operands = commandAliasOperands(in: line, command: "alias") else { continue }
                let assignedNames = operands.compactMap { word -> String? in
                    guard let equals = word.firstIndex(of: "=") else { return nil }
                    let name = String(word[..<equals])
                    return isCommandAliasName(name) ? name : nil
                }
                for name in assignedNames { targets.removeValue(forKey: name) }
                // Multiple assignments and alias options remain unsupported, but every name
                // assigned by that statement still invalidates its previously known mapping.
                guard assignedNames.count == 1,
                      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let nameRange = Range(match.range(at: 1), in: line),
                      let valueRange = Range(match.range(at: 2), in: line) else { continue }
                let name = String(line[nameRange])
                // Assigning nil deliberately removes a previously understood target. A later
                // unsupported body still overrides that alias and must not expose stale data.
                targets[name] = singleAliasCommand(String(line[valueRange]), home: home)
            }
        }

        var resolved: [String: String] = [:]
        var unresolved: Set<String> = []
        for name in targets.keys.sorted() {
            var current = name
            var trail: [String] = []
            var visiting: Set<String> = []
            var finalPath: String?
            // Iterative resolution avoids recursion limits for long alias chains.
            while !unresolved.contains(current), visiting.insert(current).inserted {
                if let known = resolved[current] { finalPath = known; break }
                guard let target = targets[current] else { break }
                trail.append(current)
                if target.hasPrefix("/") {
                    finalPath = URL(fileURLWithPath: target).standardizedFileURL.path
                    break
                }
                current = target
            }
            for alias in trail {
                if let finalPath { resolved[alias] = finalPath }
                else { unresolved.insert(alias) }
            }
        }
        return resolved.keys.sorted().compactMap { name in
            guard let path = resolved[name] else { return nil }
            return CommandAlias(name: name, targetPath: path,
                                targetCommand: URL(fileURLWithPath: path).lastPathComponent)
        }
    }

    private static func singleAliasCommand(_ expression: String, home: String) -> String? {
        let environment = ["HOME": home]
        // First remove the assignment's quotes. A single-quoted alias may retain `$HOME`
        // for expansion when invoked, so then parse the resulting one-word command too.
        guard let assignment = structuredValue(expression),
              let body = expand(assignment.parts, environment: environment),
              !body.isEmpty, !body.contains(where: { $0.isWhitespace }),
              let commandWord = structuredValue(body), commandWord.suffix.isEmpty,
              let command = expand(commandWord.parts, environment: environment),
              !command.isEmpty, !command.contains(where: { $0.isWhitespace || $0.isNewline }),
              !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !command.contains(where: { #";$|&<>()[ ]{}*?!`'"\"#.contains($0) }) else { return nil }
        if command.hasPrefix("/") {
            guard !command.hasSuffix("/"), command != "/" else { return nil }
            return command
        }
        guard isCommandAliasName(command) else { return nil }
        return command
    }

    private static func isCommandAliasName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.+\-]*$"#, options: .regularExpression) != nil
    }

    /// Splits ordinary alias operands without evaluating them. Quotes and substitutions stay
    /// inside a word so assignment-looking text inside a body cannot invalidate another alias.
    private static func commandAliasOperands(in line: String, command: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(command), trimmed.count > command.count,
              trimmed.dropFirst(command.count).first?.isWhitespace == true else { return nil }
        let characters = Array(trimmed.dropFirst(command.count))
        var words: [String] = []
        var word = ""
        var quote: Character?
        var substitutions: [(depth: Int, outerQuote: Character?)] = []
        var index = 0
        func flush() {
            if !word.isEmpty { words.append(word); word = "" }
        }
        while index < characters.count {
            let character = characters[index]
            if character == "\\", quote != "'" {
                word.append(character)
                if index + 1 < characters.count { index += 1; word.append(characters[index]) }
            } else if quote == "'" || quote == "`" {
                word.append(character)
                if character == quote { quote = nil }
            } else if character == "$", index + 1 < characters.count, characters[index + 1] == "(" {
                substitutions.append((depth: 1, outerQuote: quote))
                quote = nil
                word += "$("
                index += 1
            } else if let activeQuote = quote {
                word.append(character)
                if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" || character == "`" {
                quote = character
                word.append(character)
            } else if !substitutions.isEmpty {
                let last = substitutions.count - 1
                if character == "(" { substitutions[last].depth += 1 }
                if character == ")" {
                    substitutions[last].depth -= 1
                    if substitutions[last].depth == 0 { quote = substitutions.removeLast().outerQuote }
                }
                word.append(character)
            } else if character.isWhitespace {
                flush()
            } else if (character == "#" && word.isEmpty) || ";|&<>".contains(character) {
                flush()
                break
            } else {
                word.append(character)
            }
            index += 1
        }
        flush()
        return words
    }
}
