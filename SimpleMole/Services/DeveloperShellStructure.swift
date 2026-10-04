import Foundation

/// Structured editing on top of the text inventory: values are literal text plus plain
/// `$NAME` references, PATH is a list of directories, and every write regenerates exactly one line.
extension DeveloperShellService {
    enum PathItem: Equatable, Hashable {
        /// The `$PATH` placeholder: everything set before this line.
        case inherited
        case directory([ValuePart])
    }

    struct PathDeclaration: Identifiable, Equatable {
        enum Style: Equatable { case scalar, array, arrayAppend }
        let variable: Variable
        let items: [PathItem]
        var style: Style = .scalar
        var id: String { variable.id }
        var replacesInherited: Bool { !items.contains(.inherited) }
    }

    struct OtherLine: Identifiable, Equatable {
        let lineNumber: Int
        let text: String
        var id: Int { lineNumber }
    }

    // MARK: Lexing

    /// Accepts quoted and unquoted literals, `$NAME`, `${NAME}` and a leading or post-colon `~`.
    /// Anything that needs evaluation (command substitution, modifiers, globs of `=`) returns nil.
    static func structuredValue(_ expression: String) -> (parts: [ValuePart], suffix: String)? {
        let characters = Array(expression)
        var parts: [ValuePart] = []
        var literal = ""
        var quote: Character?
        var segmentStart = true
        var index = 0
        func flush() {
            if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
        }
        while index < characters.count {
            let character = characters[index]
            if quote == "'" {
                if character == "'" { quote = nil } else { literal.append(character) }
                index += 1
                segmentStart = false
                continue
            }
            if character == "\\" {
                guard index + 1 < characters.count else { return nil }
                let next = characters[index + 1]
                if quote == "\"", !["$", "`", "\"", "\\"].contains(next) { literal.append("\\") }
                literal.append(next)
                index += 2
                segmentStart = false
                continue
            }
            if character == "$" {
                guard let reference = referenceName(characters, from: index + 1) else { return nil }
                flush()
                parts.append(.reference(reference.name))
                index = reference.end
                segmentStart = false
                continue
            }
            if character == "`" { return nil }
            if quote == "\"" {
                if character == "\"" { quote = nil } else { literal.append(character) }
                index += 1
                segmentStart = false
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                segmentStart = false
            case " ", "\t", "\r":
                let suffix = String(characters[index...])
                let remainder = suffix.trimmingCharacters(in: .whitespaces)
                guard remainder.isEmpty || remainder.hasPrefix("#") else { return nil }
                flush()
                return (parts, suffix)
            case "~":
                let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
                guard segmentStart, next == nil || next == "/" || next == ":" || next == " " || next == "\t" else {
                    return nil
                }
                flush()
                parts.append(.reference("HOME"))
                segmentStart = false
            case "=":
                guard !segmentStart else { return nil }
                literal.append(character)
            case ";", "|", "&", "(", ")", "<", ">", "{", "}":
                return nil
            case ":":
                literal.append(character)
                segmentStart = true
                index += 1
                continue
            default:
                literal.append(character)
                segmentStart = false
            }
            index += 1
        }
        guard quote == nil else { return nil }
        flush()
        return (parts, "")
    }

    private static func referenceName(_ characters: [Character], from start: Int) -> (name: String, end: Int)? {
        guard start < characters.count else { return nil }
        func isNameCharacter(_ character: Character) -> Bool {
            character == "_" || (character.isASCII && (character.isLetter || character.isNumber))
        }
        if characters[start] == "{" {
            var index = start + 1
            var name = ""
            while index < characters.count, characters[index] != "}" {
                guard isNameCharacter(characters[index]) else { return nil }
                name.append(characters[index])
                index += 1
            }
            guard index < characters.count, isValidReference(name) else { return nil }
            return (name, index + 1)
        }
        var index = start
        var name = ""
        while index < characters.count, isNameCharacter(characters[index]) {
            name.append(characters[index])
            index += 1
        }
        guard isValidReference(name) else { return nil }
        return (name, index)
    }

    static func isValidReference(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    // MARK: Serialization

    /// Literal-only values keep the single-quoted form; references need double quotes.
    static func shellWord(_ parts: [ValuePart]) -> String {
        let merged = mergeLiterals(parts)
        if merged.allSatisfy({ if case .literal = $0 { return true } else { return false } }) {
            let text = merged.map { if case .literal(let value) = $0 { return value } else { return "" } }.joined()
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var word = "\""
        for (offset, part) in merged.enumerated() {
            switch part {
            case .literal(let value):
                for character in value {
                    if ["\\", "\"", "$", "`"].contains(character) { word.append("\\") }
                    word.append(character)
                }
            case .reference(let name):
                let nextStartsName: Bool = {
                    guard offset + 1 < merged.count, case .literal(let next) = merged[offset + 1],
                          let first = next.first else { return false }
                    return first == "_" || (first.isASCII && (first.isLetter || first.isNumber))
                }()
                word += nextStartsName ? "${\(name)}" : "$\(name)"
            }
        }
        return word + "\""
    }

    static func mergeLiterals(_ parts: [ValuePart]) -> [ValuePart] {
        var merged: [ValuePart] = []
        for part in parts {
            if case .literal(let value) = part {
                if value.isEmpty { continue }
                if case .literal(let previous) = merged.last {
                    merged[merged.count - 1] = .literal(previous + value)
                    continue
                }
            }
            merged.append(part)
        }
        return merged
    }

    /// Editable form shown to people: `~` for a leading HOME, `$NAME` for references,
    /// and `\$` / `\\` when the literal itself contains those characters.
    static func editableText(_ parts: [ValuePart]) -> String {
        let merged = mergeLiterals(parts)
        var text = ""
        for (offset, part) in merged.enumerated() {
            switch part {
            case .literal(let value):
                for character in value {
                    if character == "$" || character == "\\" { text.append("\\") }
                    text.append(character)
                }
            case .reference(let name):
                if offset == 0, name == "HOME" {
                    text += "~"
                    continue
                }
                let nextStartsName: Bool = {
                    guard offset + 1 < merged.count, case .literal(let next) = merged[offset + 1],
                          let first = next.first else { return false }
                    return first == "_" || (first.isASCII && (first.isLetter || first.isNumber))
                }()
                text += nextStartsName ? "${\(name)}" : "$\(name)"
            }
        }
        return text
    }

    /// Inverse of `editableText`. nil when a `$` does not start a plain reference.
    static func parseEditableText(_ text: String) -> [ValuePart]? {
        let characters = Array(text)
        var parts: [ValuePart] = []
        var literal = ""
        var index = 0
        if characters.first == "~", characters.count == 1 || characters[1] == "/" {
            parts.append(.reference("HOME"))
            index = 1
        }
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                literal.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "$" {
                guard let reference = referenceName(characters, from: index + 1) else { return nil }
                if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
                parts.append(.reference(reference.name))
                index = reference.end
                continue
            }
            literal.append(character)
            index += 1
        }
        if !literal.isEmpty { parts.append(.literal(literal)) }
        return parts
    }

    /// Expands references from the known environment; nil when any reference is unknown.
    static func expand(_ parts: [ValuePart], environment: [String: String]) -> String? {
        var result = ""
        for part in parts {
            switch part {
            case .literal(let value): result += value
            case .reference(let name):
                guard let value = environment[name] else { return nil }
                result += value
            }
        }
        return result
    }

    /// Literal declarations in zsh startup order, so `$JAVA_HOME/bin` can be previewed.
    static func knownEnvironment(_ profiles: [Profile], home: String = NSHomeDirectory()) -> [String: String] {
        var environment = ["HOME": home]
        for name in startupNames(in: profiles) {
            guard let profile = profiles.first(where: { $0.name == name }) else { continue }
            for variable in profile.variables {
                guard let parts = variable.structuredParts, variable.name != "PATH",
                      let value = expand(parts, environment: environment) else { continue }
                environment[variable.name] = value
            }
        }
        return environment
    }

    /// A PATH declaration captures references when its own line is evaluated. Later
    /// assignments must not change the directory whose commands are shown for that line.
    static func knownEnvironment(before variable: Variable, in profiles: [Profile],
                                 home: String = NSHomeDirectory()) -> [String: String] {
        var environment = ["HOME": home]
        for name in startupNames(in: profiles) {
            guard let profile = profiles.first(where: { $0.name == name }) else { continue }
            for preceding in profile.variables.sorted(by: { $0.lineNumber < $1.lineNumber }) {
                if profile.name == variable.fileName, preceding.lineNumber >= variable.lineNumber { return environment }
                if preceding.id == variable.id { return environment }
                guard preceding.name != "PATH" else { continue }
                if let parts = preceding.structuredParts,
                   let value = expand(parts, environment: environment) {
                    environment[preceding.name] = value
                } else {
                    // A value requiring shell evaluation invalidates any earlier literal.
                    environment.removeValue(forKey: preceding.name)
                }
            }
        }
        return environment
    }

    // MARK: PATH

    static func pathDeclaration(_ variable: Variable) -> PathDeclaration? {
        guard variable.name == "PATH", let parts = variable.structuredParts else { return nil }
        var items: [PathItem] = []
        var segment: [ValuePart] = []
        func closeSegment() -> Bool {
            let merged = mergeLiterals(segment)
            segment = []
            if merged.isEmpty { return false }
            items.append(merged == [.reference("PATH")] ? .inherited : .directory(merged))
            return true
        }
        for part in parts {
            guard case .literal(let value) = part else {
                segment.append(part)
                continue
            }
            let pieces = value.components(separatedBy: ":")
            for (offset, piece) in pieces.enumerated() {
                if offset > 0 { guard closeSegment() else { return nil } }
                if !piece.isEmpty { segment.append(.literal(piece)) }
            }
        }
        // An empty segment means the current directory; leave such lines to a text editor.
        guard closeSegment() else { return nil }
        return PathDeclaration(variable: variable, items: items)
    }

    static func pathDeclarations(in profile: Profile) -> [PathDeclaration] {
        var declarations = profile.variables.compactMap(pathDeclaration)
        guard profile.shellKind == .zsh else { return declarations }
        let regex = try! NSRegularExpression(pattern: #"^(\s*)path(\+?)=\((.*)\)(\s*(?:#.*)?)$"#)
        var context = DeclarationContext()
        for (offset, line) in profile.text.components(separatedBy: "\n").enumerated() {
            if context.consumeHeredoc(line) { continue }
            let accepts = context.acceptsDeclaration
            context.consumeShellLine(line)
            guard accepts, let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let prefix = Range(match.range(at: 1), in: line), let operation = Range(match.range(at: 2), in: line),
                  let body = Range(match.range(at: 3), in: line), let suffix = Range(match.range(at: 4), in: line),
                  let words = pathArrayWords(String(line[body])) else { continue }
            var items: [PathItem] = line[operation].isEmpty ? [] : [.inherited]
            var valid = true
            for word in words {
                if word == "$path" || word == "${path}" { items.append(.inherited); continue }
                guard let parsed = structuredValue(word), !parsed.parts.isEmpty,
                      !parsed.parts.contains(.reference("path")),
                      !word.contains("*"), !word.contains("?"), !word.contains("["),
                      (try? validate(parsed.parts)) != nil else { valid = false; break }
                items.append(.directory(parsed.parts))
            }
            guard valid, !items.isEmpty else { continue }
            let variable = Variable(fileName: profile.name, lineNumber: offset + 1, name: "PATH", literalValue: nil,
                                    parts: nil, originalLine: line, assignmentPrefix: String(line[prefix]),
                                    commentSuffix: String(line[suffix]))
            declarations.append(.init(variable: variable, items: items, style: line[operation].isEmpty ? .array : .arrayAppend))
        }
        return declarations.sorted { $0.variable.lineNumber < $1.variable.lineNumber }
    }

    private static func pathArrayWords(_ expression: String) -> [String]? {
        var words: [String] = [], word = "", quote: Character?, escaped = false
        for character in expression {
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\" { word.append(character); escaped = true; continue }
            if let active = quote {
                word.append(character)
                if character == active { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character; word.append(character)
            } else if character.isWhitespace {
                if !word.isEmpty { words.append(word); word = "" }
            } else { word.append(character) }
        }
        guard quote == nil, !escaped else { return nil }
        if !word.isEmpty { words.append(word) }
        return words
    }

    /// Hidden inherited references stay fixed. Only directories inside one segment may move or be removed.
    static func preservesPathAnchors(_ edited: [PathItem], original: [PathItem]) -> Bool {
        func segments(_ items: [PathItem]) -> [[PathItem]] {
            var result: [[PathItem]] = [[]]
            for item in items {
                if item == .inherited { result.append([]) } else { result[result.count - 1].append(item) }
            }
            return result
        }
        let before = segments(original), after = segments(edited)
        guard before.count == after.count else { return false }
        return zip(before, after).allSatisfy { original, edited in
            var remaining = original
            for item in edited {
                guard let index = remaining.firstIndex(of: item) else { return false }
                remaining.remove(at: index)
            }
            return true
        }
    }

    static func settingPath(in profile: Profile, declaration: PathDeclaration, items: [PathItem]) throws -> String {
        let variable = declaration.variable
        guard profile.canEdit, variable.fileName == profile.name else { throw Failure.dynamicVariable }
        guard preservesPathAnchors(items, original: declaration.items) else { throw Failure.invalidVariable }
        var lines = profile.text.components(separatedBy: "\n")
        let index = variable.lineNumber - 1
        guard lines.indices.contains(index), lines[index] == variable.originalLine else {
            throw Failure.changedOnDisk
        }
        let hasDirectory = items.contains { if case .directory = $0 { return true } else { return false } }
        if !hasDirectory, items.filter({ $0 == .inherited }).count <= 1 {
            lines.remove(at: index)
            return lines.joined(separator: "\n")
        }
        try validate(items)
        switch declaration.style {
        case .scalar:
            lines[index] = variable.assignmentPrefix + "PATH=" + shellWord(pathParts(items)) + variable.commentSuffix
        case .array, .arrayAppend:
            let operands = declaration.style == .arrayAppend ? Array(items.dropFirst()) : items
            let body = operands.map { item in
                if case .directory(let parts) = item { return shellWord(parts) }
                return "$path"
            }.joined(separator: " ")
            lines[index] = variable.assignmentPrefix + (declaration.style == .arrayAppend ? "path+=(" : "path=(") + body + ")" + variable.commentSuffix
        }
        return lines.joined(separator: "\n")
    }

    /// New directories go first: `export PATH="dir:$PATH"` on a new last line.
    static func addingPathDirectory(in profile: Profile, directory: [ValuePart]) throws -> String {
        guard profile.canEdit else { throw Failure.unsafeFile }
        let items: [PathItem] = [.directory(directory), .inherited]
        try validate(items)
        let separator = profile.text.isEmpty || profile.text.hasSuffix("\n") ? "" : "\n"
        return profile.text + separator + "export PATH=" + shellWord(pathParts(items)) + "\n"
    }

    private static func pathParts(_ items: [PathItem]) -> [ValuePart] {
        var parts: [ValuePart] = []
        for (offset, item) in items.enumerated() {
            if offset > 0 { parts.append(.literal(":")) }
            switch item {
            case .inherited: parts.append(.reference("PATH"))
            case .directory(let directory): parts.append(contentsOf: directory)
            }
        }
        return parts
    }

    private static func validate(_ items: [PathItem]) throws {
        for case .directory(let parts) in items {
            try validate(parts)
            for case .literal(let value) in parts where value.contains(":") { throw Failure.invalidVariable }
        }
    }

    private static func validate(_ parts: [ValuePart]) throws {
        for part in parts {
            switch part {
            case .literal(let value):
                guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
                    throw Failure.invalidVariable
                }
            case .reference(let name):
                guard isValidReference(name) else { throw Failure.invalidVariable }
            }
        }
    }

    // MARK: Variables

    /// Rewrites one declaration (or appends a new `export`) from structured parts.
    static func settingVariable(in profile: Profile, variable: Variable?, name: String,
                                parts: [ValuePart]) throws -> String {
        guard profile.canEdit, isValidReference(name), name != "PATH" else { throw Failure.invalidVariable }
        try validate(parts)
        let word = shellWord(parts)
        if let variable {
            guard variable.fileName == profile.name, variable.isStructured else { throw Failure.dynamicVariable }
            var lines = profile.text.components(separatedBy: "\n")
            let index = variable.lineNumber - 1
            guard lines.indices.contains(index), lines[index] == variable.originalLine else {
                throw Failure.changedOnDisk
            }
            lines[index] = variable.assignmentPrefix + name + "=" + word + variable.commentSuffix
            return lines.joined(separator: "\n")
        }
        let separator = profile.text.isEmpty || profile.text.hasSuffix("\n") ? "" : "\n"
        return profile.text + separator + "export \(name)=\(word)\n"
    }

    /// Lines that are neither blank, comments, nor recognized declarations.
    static func otherLines(in profile: Profile) -> [OtherLine] {
        let declared = Set(profile.variables.map(\.lineNumber))
        return profile.text.components(separatedBy: "\n").enumerated().compactMap { offset, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !declared.contains(offset + 1) else { return nil }
            return OtherLine(lineNumber: offset + 1, text: line)
        }
    }
}
