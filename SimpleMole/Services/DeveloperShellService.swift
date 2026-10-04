import Foundation
import Darwin

/// Reads shell configuration as text. Inventory never sources a profile or executes its values.
enum DeveloperShellService {
    static let fileNames = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]
    static let bashFileNames = [".bash_profile", ".bash_login", ".profile", ".bashrc"]
    static var supportedFileNames: [String] { fileNames + bashFileNames }
    enum Kind: String, Equatable, Sendable { case zsh, bash, unsupported }
    static func kind(for name: String) -> Kind { bashFileNames.contains(name) ? .bash : .zsh }
    private static let maximumBytes = 2 * 1_024 * 1_024

    struct Variable: Identifiable, Equatable {
        let fileName: String
        let lineNumber: Int
        let name: String
        /// nil means shell expansion, command substitution, or unsupported syntax.
        let literalValue: String?
        /// Literal text and plain `$NAME` references; nil when the value needs the shell to evaluate it.
        let parts: [ValuePart]?
        let originalLine: String
        let assignmentPrefix: String
        let commentSuffix: String
        var id: String { "\(fileName):\(lineNumber):\(name)" }
        var isDynamic: Bool { literalValue == nil }
        var structuredParts: [ValuePart]? { parts ?? literalValue.map { [.literal($0)] } }
        var isStructured: Bool { structuredParts != nil }
        var isExported: Bool { assignmentPrefix.contains("export") }
    }

    enum ValuePart: Equatable, Hashable {
        case literal(String)
        case reference(String)
    }

    struct Profile: Identifiable, Equatable {
        let name: String
        let text: String
        let exists: Bool
        let variables: [Variable]
        /// Inventory errors are per-file so one unreadable file does not hide the rest.
        let problem: Failure?
        let originalData: Data
        let identity: Identity?
        var id: String { name }
        var directoryPath: String? = nil
        var homePath: String? = nil
        var canEdit: Bool { problem == nil }
        var path: String { URL(fileURLWithPath: directoryPath ?? NSHomeDirectory()).appendingPathComponent(name).path }
        var shellKind: Kind { DeveloperShellService.kind(for: name) }
    }

    struct SaveResult {
        let profile: Profile
        let backupPath: String?
    }

    enum Failure: Error, Equatable {
        case unsupportedFile
        case unsafeFile
        case tooLarge
        case unreadable
        case invalidEncoding
        case changedOnDisk
        case invalidVariable
        case dynamicVariable
        case syntax(String)
        case validationUnavailable
        case writeFailed
    }

    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let mode: mode_t
    }

    static func scan(home: String = NSHomeDirectory()) -> [Profile] {
        fileNames.map { name in
            do { return try readProfile(name, home: home) }
            catch {
                return Profile(name: name, text: "", exists: true, variables: [],
                               problem: error as? Failure ?? .unreadable, originalData: Data(), identity: nil)
            }
        }
    }

    static func readProfile(_ name: String, home: String = NSHomeDirectory()) throws -> Profile {
        guard supportedFileNames.contains(name) else { throw Failure.unsupportedFile }
        let directory = try openHome(home)
        defer { close(directory) }
        var profile = try readProfile(name, directory: directory)
        profile.directoryPath = home
        profile.homePath = home
        return profile
    }

    static func readSourceProfile(path: String) throws -> Profile {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let directory = try openHome(url.deletingLastPathComponent().path)
        defer { close(directory) }
        var profile = try readProfile(url.lastPathComponent, directory: directory)
        guard profile.exists else { throw Failure.unreadable }
        profile.directoryPath = url.deletingLastPathComponent().path
        return profile
    }

    /// A single literal assignment is editable here; complex lines stay in the source editor.
    static func settingVariable(in profile: Profile, variable: Variable?, name: String,
                                value: String) throws -> String {
        guard profile.canEdit, isValidName(name), !value.contains("\n"),
              !value.contains("\r"), !value.contains("\0") else { throw Failure.invalidVariable }
        let quoted = "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        if let variable {
            guard variable.fileName == profile.name, variable.literalValue != nil else {
                throw Failure.dynamicVariable
            }
            var lines = profile.text.components(separatedBy: "\n")
            let index = variable.lineNumber - 1
            guard lines.indices.contains(index), lines[index] == variable.originalLine else {
                throw Failure.changedOnDisk
            }
            lines[index] = variable.assignmentPrefix + name + "=" + quoted + variable.commentSuffix
            return lines.joined(separator: "\n")
        }
        let separator = profile.text.isEmpty || profile.text.hasSuffix("\n") ? "" : "\n"
        return profile.text + separator + "export \(name)=\(quoted)\n"
    }

    static func removingVariable(in profile: Profile, variable: Variable) throws -> String {
        guard profile.canEdit, variable.fileName == profile.name, variable.isStructured else {
            throw Failure.dynamicVariable
        }
        var lines = profile.text.components(separatedBy: "\n")
        let index = variable.lineNumber - 1
        guard lines.indices.contains(index), lines[index] == variable.originalLine else {
            throw Failure.changedOnDisk
        }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    /// Parse-only zsh validation, protected backup, then atomic replacement. All writes require
    /// the original file's identity and bytes to match the inventory snapshot.
    static func save(_ text: String, replacing profile: Profile,
                     home: String = NSHomeDirectory()) throws -> SaveResult {
        guard supportedFileNames.contains(profile.name), profile.canEdit else { throw Failure.unsafeFile }
        let data = Data(text.utf8)
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        guard !text.contains("\0") else { throw Failure.invalidEncoding }
        try validateSyntax(text, kind: profile.shellKind)
        let directory = try openHome(profile.directoryPath ?? home)
        defer { close(directory) }
        try requireUnchanged(profile, directory: directory)
        let temporaryName = ".nori-shell-\(UUID().uuidString)"
        let descriptor = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.writeFailed }
        defer { close(descriptor); unlinkat(directory, temporaryName, 0) }
        try writeAll(data, descriptor: descriptor)
        let permission = profile.identity.map { $0.mode & 0o777 } ?? 0o600
        guard fchmod(descriptor, permission) == 0, fsync(descriptor) == 0 else { throw Failure.writeFailed }

        let targetPath = URL(fileURLWithPath: profile.directoryPath ?? home).appendingPathComponent(profile.name).path
        let ownerHome = profile.homePath ?? home
        let backupPath = profile.exists ? try DeveloperShellBackupStore.create(profile.originalData, targetPath: targetPath, home: ownerHome) : nil
        // Repeat the comparison after validation and backup work, immediately before replacing.
        try requireUnchanged(profile, directory: directory)
        let renamed: Int32
        if profile.exists {
            renamed = renameat(directory, temporaryName, directory, profile.name)
        } else {
            // Protect creation even if another application creates the file after the last check.
            renamed = renameatx_np(directory, temporaryName, directory, profile.name, UInt32(RENAME_EXCL))
        }
        guard renamed == 0 else {
            throw errno == EEXIST ? Failure.changedOnDisk : Failure.writeFailed
        }
        _ = fsync(directory)
        DeveloperShellBackupStore.rotate(targetPath: targetPath, home: ownerHome)
        var updated = try readProfile(profile.name, directory: directory)
        updated.directoryPath = profile.directoryPath ?? home
        updated.homePath = profile.homePath ?? home
        return SaveResult(profile: updated,
                          backupPath: backupPath)
    }

    static func validateSyntax(_ text: String, kind: Kind = .zsh) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nori-shell-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("profile.zsh")
        try Data(text.utf8).write(to: input)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let errors = temporary.appendingPathComponent("errors")
        FileManager.default.createFile(atPath: errors.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        guard let output = try? FileHandle(forWritingTo: errors) else { throw Failure.validationUnavailable }
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kind == .bash ? "/bin/bash" : "/bin/zsh")
        // -f disables user startup files; -n only parses. HOME/ZDOTDIR also point to an empty directory.
        process.arguments = kind == .bash ? ["--noprofile", "--norc", "-n", input.path] : ["-f", "-n", input.path]
        process.environment = ["HOME": temporary.path, "ZDOTDIR": temporary.path,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        do { try process.run() } catch { throw Failure.validationUnavailable }
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw Failure.validationUnavailable }
        guard process.terminationStatus == 0 else {
            // Report the location only: zsh diagnostics can echo a token from a secret-bearing line.
            let diagnostic = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            let linePattern = #"profile\.zsh:(\d+):"#
            let regex = try? NSRegularExpression(pattern: linePattern)
            let match = regex?.firstMatch(in: diagnostic, range: NSRange(diagnostic.startIndex..., in: diagnostic))
            let line = match.flatMap { Range($0.range(at: 1), in: diagnostic) }.map { String(diagnostic[$0]) }
            throw Failure.syntax(line ?? "")
        }
    }

    private static func openHome(_ home: String) throws -> Int32 {
        let descriptor = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unsafeFile }
        return descriptor
    }

    private static func readProfile(_ name: String, directory: Int32) throws -> Profile {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT {
                return Profile(name: name, text: "", exists: false, variables: [], problem: nil,
                               originalData: Data(), identity: nil)
            }
            throw errno == ELOOP ? Failure.unsafeFile : Failure.unreadable
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.unreadable }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw Failure.unsafeFile
        }
        guard info.st_size <= maximumBytes else { throw Failure.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw Failure.unreadable }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw Failure.tooLarge }
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0, identity(info) == identity(final),
              info.st_size == final.st_size, data.count == final.st_size else { throw Failure.changedOnDisk }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw Failure.invalidEncoding
        }
        return Profile(name: name, text: text, exists: true, variables: parseVariables(text, fileName: name),
                       problem: nil, originalData: data, identity: identity(final))
    }

    private static func requireUnchanged(_ profile: Profile, directory: Int32) throws {
        let current = try readProfile(profile.name, directory: directory)
        guard current.exists == profile.exists, current.identity == profile.identity,
              current.originalData == profile.originalData else { throw Failure.changedOnDisk }
    }

    private static func identity(_ info: stat) -> Identity {
        Identity(device: info.st_dev, inode: info.st_ino,
                 modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                 mode: info.st_mode)
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw Failure.writeFailed }
                guard count > 0 else { throw Failure.writeFailed }
                offset += count
            }
        }
    }

    private static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    private static func parseVariables(_ text: String, fileName: String) -> [Variable] {
        let pattern = #"^(\s*(?:export\s+)?)([A-Za-z_][A-Za-z0-9_]*)=(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var context = DeclarationContext()
        var variables: [Variable] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            // An export-looking line can be text in a heredoc, a multiline value, or a
            // continued command. Never expose that text as a separately editable declaration.
            if context.consumeHeredoc(line) { continue }
            let acceptsDeclaration = context.acceptsDeclaration
            context.consumeShellLine(line)
            guard acceptsDeclaration,
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let prefixRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line),
                  let valueRange = Range(match.range(at: 3), in: line) else { continue }
            let prefix = String(line[prefixRange])
            let name = String(line[nameRange])
            // PATH is already exported, so a bare assignment still changes the environment.
            guard prefix.contains("export") || name == "PATH" else { continue }
            let expression = String(line[valueRange])
            let parsed = literalValue(expression)
            let structured = structuredValue(expression)
            variables.append(Variable(fileName: fileName, lineNumber: index + 1, name: name,
                                      literalValue: parsed.value, parts: structured?.parts, originalLine: line,
                                      assignmentPrefix: prefix,
                                      commentSuffix: structured?.suffix ?? parsed.suffix))
        }
        return variables
    }

    /// Tracks only lexical regions that must not become independently editable rows.
    /// It does not interpret shell commands or decide which conditional branches run.
    struct DeclarationContext {
        private struct Heredoc {
            let delimiter: String
            let stripsTabs: Bool
        }
        private struct Substitution {
            var parentheses = 1
            let outerQuote: Character?
        }
        private var quote: Character?
        private var continued = false
        private var heredocs: [Heredoc] = []
        private var heredocActive = false
        private var substitutions: [Substitution] = []
        private var arithmeticDepth = 0
        /// An unsupported multiline delimiter cannot be safely bounded; leave the rest
        /// of that source file to the full editor rather than inventing editable rows.
        private var unsupportedContext = false

        var acceptsDeclaration: Bool {
            !unsupportedContext && quote == nil && !continued && substitutions.isEmpty && arithmeticDepth == 0
        }

        mutating func consumeHeredoc(_ line: String) -> Bool {
            guard heredocActive, let document = heredocs.first else { return false }
            let candidate = document.stripsTabs ? String(line.drop(while: { $0 == "\t" })) : line
            if candidate == document.delimiter {
                heredocs.removeFirst()
                heredocActive = !heredocs.isEmpty
            }
            return true
        }

        mutating func consumeShellLine(_ line: String) {
            guard !unsupportedContext else { return }
            let characters = Array(line)
            continued = false
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if quote == "'" {
                    if character == "'" { quote = nil }
                } else if character == "\\" {
                    if index + 1 == characters.count { continued = true }
                    index += 1
                } else if quote == "`" {
                    if character == "`" { quote = nil }
                } else if character == "$", index + 1 < characters.count,
                          characters[index + 1] == "(",
                          !(index + 2 < characters.count && characters[index + 2] == "(") {
                    substitutions.append(Substitution(outerQuote: quote))
                    quote = nil
                    index += 1
                } else if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "'" || character == "\"" || character == "`" {
                    quote = character
                } else if character == "#", index == 0 || characters[index - 1].isWhitespace
                            || ";|&()".contains(characters[index - 1]) {
                    break
                } else if character == "(", index + 1 < characters.count, characters[index + 1] == "(" {
                    arithmeticDepth += 1
                    index += 1
                } else if arithmeticDepth > 0 {
                    if character == ")", index + 1 < characters.count, characters[index + 1] == ")" {
                        arithmeticDepth -= 1
                        index += 1
                    }
                } else if character == "<", index + 1 < characters.count, characters[index + 1] == "<" {
                    if index + 2 < characters.count, characters[index + 2] == "<" {
                        index += 2 // A here-string has no following document body.
                    } else {
                        var wordStart = index + 2
                        let stripsTabs = wordStart < characters.count && characters[wordStart] == "-"
                        if stripsTabs { wordStart += 1 }
                        while wordStart < characters.count && characters[wordStart].isWhitespace { wordStart += 1 }
                        guard let word = heredocWord(characters, from: wordStart) else {
                            unsupportedContext = true
                            return
                        }
                        heredocs.append(Heredoc(delimiter: word.value, stripsTabs: stripsTabs))
                        index = word.end - 1
                    }
                } else if !substitutions.isEmpty {
                    let last = substitutions.count - 1
                    if character == "(" { substitutions[last].parentheses += 1 }
                    if character == ")" {
                        substitutions[last].parentheses -= 1
                        if substitutions[last].parentheses == 0 {
                            quote = substitutions.removeLast().outerQuote
                        }
                    }
                }
                index += 1
            }
            if !continued && quote == nil && !heredocs.isEmpty { heredocActive = true }
        }

        /// Shell quote removal for ordinary heredoc words, including <<EOF, <<'EOF',
        /// <<"EOF", <<-EOF and escaped/concatenated literal delimiters.
        private func heredocWord(_ characters: [Character], from start: Int) -> (value: String, end: Int)? {
            var value = ""
            var localQuote: Character?
            var index = start
            var hasWord = false
            while index < characters.count {
                let character = characters[index]
                if localQuote == "'" {
                    if character == "'" { localQuote = nil } else { value.append(character) }
                } else if character == "\\" {
                    guard index + 1 < characters.count else { return nil }
                    index += 1
                    let next = characters[index]
                    if localQuote == "\"", !["$", "`", "\"", "\\"].contains(next) { value.append("\\") }
                    value.append(next)
                } else if let activeQuote = localQuote {
                    if character == activeQuote { localQuote = nil } else { value.append(character) }
                } else if character == "'" || character == "\"" {
                    localQuote = character
                } else if character.isWhitespace || ";|&()< >".contains(character) {
                    break
                } else {
                    value.append(character)
                }
                hasWord = true
                index += 1
            }
            guard hasWord, localQuote == nil else { return nil }
            return (value, index)
        }
    }

    /// Tiny conservative lexer, deliberately not a shell interpreter. Quoted pieces may concatenate.
    private static func literalValue(_ expression: String) -> (value: String?, suffix: String) {
        let characters = Array(expression)
        var value = ""
        var quote: Character?
        var index = 0
        var dynamic = false
        while index < characters.count {
            let character = characters[index]
            if quote == "'" {
                if character == "'" { quote = nil } else { value.append(character) }
            } else if character == "\\" {
                guard index + 1 < characters.count else { return (nil, "") }
                index += 1
                let next = characters[index]
                if quote == "\"", !["$", "`", "\"", "\\"].contains(next) { value.append("\\") }
                value.append(next)
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                else {
                    if character == "$" || character == "`" { dynamic = true }
                    value.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == " " || character == "\t" || character == "\r" {
                let suffix = String(characters[index...])
                let remainder = suffix.trimmingCharacters(in: .whitespaces)
                guard remainder.isEmpty || remainder.hasPrefix("#") else { return (nil, "") }
                return (dynamic ? nil : value, suffix)
            } else {
                if character == "$" || character == "`" || character == "~" { dynamic = true }
                if [";", "|", "&", "(", ")", "<", ">"].contains(character) { return (nil, "") }
                value.append(character)
            }
            index += 1
        }
        return (quote == nil && !dynamic ? value : nil, "")
    }
}
