import Foundation
import Darwin

@main
struct DeveloperShellTests {
    static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data(("FAIL: \(message)\n").utf8))
            exit(1)
        }
    }

    static func expectFailure(_ expected: DeveloperShellService.Failure,
                              _ operation: () throws -> Void) {
        do { try operation(); expect(false, "expected failure: \(expected)") }
        catch { expect(error as? DeveloperShellService.Failure == expected, "unexpected failure: \(error)") }
    }

    static func structureTests(fixture: URL, sentinel: URL) throws {
        typealias Shell = DeveloperShellService
        let home = fixture.appendingPathComponent("structure-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent(".zshrc")
        let text = """
        export PATH="$HOME/bin:$PATH"
        PATH=~/tools:/usr/local/bin:$PATH # local tools
        export PATH="/opt/a::$PATH"
        export JAVA_HOME="${HOME}x/jdk"
        export GOBIN=$GOPATH/bin
        export CMD=$(touch '\(sentinel.path)')
        alias gs='git status'
        PLAIN=not-exported

        """
        try text.write(to: file, atomically: false, encoding: .utf8)
        let profile = try Shell.readProfile(".zshrc", home: home.path)
        expect(!FileManager.default.fileExists(atPath: sentinel.path), "structure parsing must not execute")
        let declarations = Shell.pathDeclarations(in: profile)
        expect(declarations.count == 2, "unsupported empty PATH segments must stay out of the PATH editor")
        expect(declarations[0].items == [.directory([.reference("HOME"), .literal("/bin")]), .inherited],
               "PATH segments split around references")
        expect(declarations[1].items == [.directory([.reference("HOME"), .literal("/tools")]),
                                          .directory([.literal("/usr/local/bin")]), .inherited],
               "bare PATH assignment and tilde are recognized")
        expect(!profile.variables.contains { $0.name == "PLAIN" }, "bare non-PATH assignments are not environment variables")
        expect(profile.variables.first { $0.name == "JAVA_HOME" }?.structuredParts
               == [.reference("HOME"), .literal("x/jdk")], "braced references")
        expect(profile.variables.first { $0.name == "CMD" }?.isStructured == false, "command substitution stays dynamic")

        let reordered = try Shell.settingPath(in: profile, declaration: declarations[1],
                                              items: [.directory([.literal("/usr/local/bin")]),
                                                      .directory([.reference("HOME"), .literal("/tools")]), .inherited])
        expect(reordered.contains("\nPATH=\"/usr/local/bin:$HOME/tools:$PATH\" # local tools\n"),
               "reordering rewrites one line and keeps prefix and comment")
        let emptied = try Shell.settingPath(in: profile, declaration: declarations[0], items: [.inherited])
        expect(!emptied.contains("$HOME/bin"), "removing every directory removes the line")
        expect(emptied.components(separatedBy: "\n").count == text.components(separatedBy: "\n").count - 1,
               "only the PATH line is removed")
        let added = try Shell.addingPathDirectory(in: profile, directory: [.reference("HOME"), .literal("/.bun/bin")])
        expect(added.hasSuffix("PLAIN=not-exported\nexport PATH=\"$HOME/.bun/bin:$PATH\"\n"), "new PATH directory goes first")
        expectFailure(.invalidVariable) {
            _ = try Shell.addingPathDirectory(in: profile, directory: [.literal("/a:/b")])
        }

        let javaHome = profile.variables.first { $0.name == "JAVA_HOME" }!
        let javaText = try Shell.settingVariable(in: profile, variable: javaHome, name: "JAVA_HOME",
                                                 parts: [.reference("HOME"), .literal("_jdk $1")])
        expect(javaText.contains("export JAVA_HOME=\"${HOME}_jdk \\$1\""), "references are braced and literal dollars escaped")
        let literalText = try Shell.settingVariable(in: profile, variable: nil, name: "TOKEN",
                                                    parts: [.literal("a'b$c")])
        expect(literalText.hasSuffix("export TOKEN='a'\\''b$c'\n"), "literal-only values keep single quotes")
        expectFailure(.invalidVariable) {
            _ = try Shell.settingVariable(in: profile, variable: nil, name: "PATH", parts: [.literal("/x")])
        }
        let gobin = profile.variables.first { $0.name == "GOBIN" }!
        let removed = try Shell.removingVariable(in: profile, variable: gobin)
        expect(!removed.contains("GOBIN"), "structured variables with references can be deleted")

        let editable = Shell.editableText([.reference("HOME"), .literal("/a$b\\"), .reference("GOPATH"), .literal("x")])
        expect(editable == "~/a\\$b\\\\${GOPATH}x", "editable text escapes literals")
        expect(Shell.parseEditableText(editable) == [.reference("HOME"), .literal("/a$b\\"),
                                                    .reference("GOPATH"), .literal("x")], "editable text round trips")
        expect(Shell.parseEditableText("cost $") == nil, "a bare dollar is rejected")
        let environment = Shell.knownEnvironment([profile], home: "/Users/test")
        expect(environment["JAVA_HOME"] == "/Users/testx/jdk", "literal declarations feed previews")
        expect(Shell.expand([.reference("JAVA_HOME"), .literal("/bin")], environment: environment) == "/Users/testx/jdk/bin",
               "expansion uses known declarations")
        expect(Shell.otherLines(in: profile).map(\.lineNumber) == [7, 8], "other lines exclude declarations")

        // Generated syntax must pass the same parse-only check before replacing the file.
        let saved = try Shell.save(reordered, replacing: profile, home: home.path)
        expect(Shell.pathDeclarations(in: saved.profile)[1].items.first == .directory([.literal("/usr/local/bin")]),
               "saved PATH order reads back")
        expect(!FileManager.default.fileExists(atPath: sentinel.path), "saving must not execute")
    }

    static func declarationEnvironmentTests(fixture: URL, sentinel: URL) throws {
        typealias Shell = DeveloperShellService
        let home = fixture.appendingPathComponent("environment-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let contents = [
            ".zshenv": "export ROOT=\"$HOME/env\"\n",
            ".zprofile": "export ROOT=\"$HOME/login\"\nexport PROFILE_BIN=\"$ROOT/tools\"\n",
            ".zshrc": """
            export TOOL_BIN="$ROOT/first"
            export PATH="$TOOL_BIN:$PATH"
            export TOOL_BIN="$HOME/later"
            export PATH="$TOOL_BIN:$PATH"
            export TOOL_BIN=$(touch '\(sentinel.path)')
            export PATH="$TOOL_BIN:$PATH"
            export TOOL_BIN="/restored"
            export TOOL_BIN="$UNKNOWN/tools"
            export PATH="$TOOL_BIN:$PATH"
            export FUTURE="/future"

            """,
            ".zlogin": "export ROOT='/too-late'\nexport LOGIN_ONLY='/future'\n",
        ]
        for (name, text) in contents {
            try text.write(to: home.appendingPathComponent(name), atomically: false, encoding: .utf8)
        }
        // Input order is deliberately reversed: startup order comes from the file names.
        let profiles = Array(Shell.scan(home: home.path).reversed())
        let profile = profiles.first { $0.name == ".zshrc" }!
        let declarations = Shell.pathDeclarations(in: profile)
        expect(declarations.count == 4, "all PATH reference fixtures are recognized")
        let first = Shell.knownEnvironment(before: declarations[0].variable, in: profiles, home: "/Users/test")
        expect(first["ROOT"] == "/Users/test/login" && first["PROFILE_BIN"] == "/Users/test/login/tools",
               "reference previews follow prior startup files in zsh order")
        expect(Shell.expand([.reference("TOOL_BIN")], environment: first) == "/Users/test/login/first",
               "a PATH reference uses the value before its own declaration, not a later assignment")
        expect(first["FUTURE"] == nil && first["LOGIN_ONLY"] == nil,
               "later lines and later startup files do not affect an earlier PATH declaration")
        let later = Shell.knownEnvironment(before: declarations[1].variable, in: profiles, home: "/Users/test")
        expect(later["TOOL_BIN"] == "/Users/test/later", "later PATH declarations see prior reassignment")
        expect(later["PATH"] == nil, "PATH is never treated as a resolvable scalar directory reference")
        let dynamic = Shell.knownEnvironment(before: declarations[2].variable, in: profiles, home: "/Users/test")
        expect(dynamic["TOOL_BIN"] == nil, "a dynamic reassignment clears an earlier known value")
        let unresolved = Shell.knownEnvironment(before: declarations[3].variable, in: profiles, home: "/Users/test")
        expect(unresolved["TOOL_BIN"] == nil, "an unresolved reassignment clears an earlier known value")
        let rootAssignment = profiles.first { $0.name == ".zprofile" }!.variables[0]
        let beforeRoot = Shell.knownEnvironment(before: rootAssignment, in: profiles, home: "/Users/test")
        expect(beforeRoot["ROOT"] == "/Users/test/env", "the target declaration itself is excluded")
        expect(!FileManager.default.fileExists(atPath: sentinel.path), "reference previews never execute shell values")
    }

    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        let home = fixture.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let profileURL = home.appendingPathComponent(".zshrc")
        let sentinel = fixture.appendingPathComponent("must-not-execute")
        let original = """
        # Keep user comments and aliases.
        alias ll='ls -l'
          export EDITOR="vim" # preferred editor
        export API_TOKEN='secret$token'
        export PATH="$HOME/bin:$PATH"
        export DYNAMIC=$(touch '\(sentinel.path)')
        export MULTI=value OTHER=value
        export ESCAPED=a\\ b
        export COMBINED='hello'\\''world'
        touch '\(sentinel.path)'

        """
        try original.write(to: profileURL, atomically: false, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: profileURL.path)
        let profiles = DeveloperShellService.scan(home: home.path)
        expect(profiles.count == 4, "all four startup files must be represented")
        let profile = profiles.first { $0.name == ".zshrc" }!
        expect(profile.exists && profile.canEdit, "regular file must be editable")
        expect(profiles.filter { !$0.exists }.count == 3, "missing startup files can be created")
        expect(!fm.fileExists(atPath: sentinel.path), "inventory must not execute configuration")
        expect(profile.variables.count == 7, "standalone export lines must be recognized")
        let editor = profile.variables.first { $0.name == "EDITOR" }!
        expect(editor.literalValue == "vim" && editor.lineNumber == 3, "quoted literal and source location")
        expect(profile.variables.first { $0.name == "API_TOKEN" }?.literalValue == "secret$token", "single-quoted dollars are literal")
        expect(profile.variables.first { $0.name == "PATH" }?.isDynamic == true, "expansion must not be presented as an effective value")
        expect(profile.variables.first { $0.name == "DYNAMIC" }?.isDynamic == true, "command substitution must stay unevaluated")
        expect(profile.variables.first { $0.name == "MULTI" }?.isDynamic == true, "multiple assignments require source editing")
        expect(profile.variables.first { $0.name == "ESCAPED" }?.literalValue == "a b", "escaped literal spaces")
        expect(profile.variables.first { $0.name == "COMBINED" }?.literalValue == "hello'world", "concatenated quoted pieces")
        let candidate = try DeveloperShellService.settingVariable(in: profile, variable: editor, name: "EDITOR", value: "Joe's editor $HOME")
        expect(candidate.contains("  export EDITOR='Joe'\\''s editor $HOME' # preferred editor"), "literal edit must preserve indent/comment and escape apostrophe")
        expect(candidate.contains("alias ll='ls -l'"), "other source lines must survive")
        let saved = try DeveloperShellService.save(candidate, replacing: profile, home: home.path)
        expect(saved.profile.variables.first { $0.name == "EDITOR" }?.literalValue == "Joe's editor $HOME", "saved apostrophe must round trip")
        expect(!fm.fileExists(atPath: sentinel.path), "syntax checking must not execute configuration")
        expect(saved.backupPath != nil, "existing file must be backed up")
        let backup = URL(fileURLWithPath: saved.backupPath!)
        expect(try String(contentsOf: backup, encoding: .utf8) == original, "backup must be exact original")
        let backupPermissions = try fm.attributesOfItem(atPath: backup.path)[.posixPermissions] as! NSNumber
        let profilePermissions = try fm.attributesOfItem(atPath: profileURL.path)[.posixPermissions] as! NSNumber
        expect(backupPermissions.intValue == 0o600, "secret-bearing backups must be owner-only")
        expect(profilePermissions.intValue == 0o640, "original file permissions must be preserved")

        let current = saved.profile
        let newVariableText = try DeveloperShellService.settingVariable(in: current, variable: nil,
                                                                      name: "NEW_VAR", value: "$(touch '\(sentinel.path)')")
        let added = try DeveloperShellService.save(newVariableText, replacing: current, home: home.path)
        expect(!fm.fileExists(atPath: sentinel.path), "new variable is a literal, never executed by validation")
        expect(added.profile.variables.contains { $0.name == "NEW_VAR" && !$0.isDynamic }, "literal command syntax stays literal")
        let addedVariable = added.profile.variables.first { $0.name == "NEW_VAR" }!
        let removedText = try DeveloperShellService.removingVariable(in: added.profile, variable: addedVariable)
        expect(!removedText.contains("export NEW_VAR="), "removing a declaration must remove exactly its line")
        expect(removedText.contains("export API_TOKEN='secret$token'"), "deleting a declaration must preserve neighboring lines")
        expectFailure(.invalidVariable) {
            _ = try DeveloperShellService.settingVariable(in: current, variable: nil, name: "1BAD", value: "x")
        }
        expectFailure(.invalidVariable) {
            _ = try DeveloperShellService.settingVariable(in: current, variable: nil, name: "GOOD", value: "x\ny")
        }
        expectFailure(.dynamicVariable) {
            _ = try DeveloperShellService.removingVariable(in: profile, variable: profile.variables.first { $0.name == "DYNAMIC" }!)
        }

        // A syntax failure must not touch the original, make a backup, or expose its token in diagnostics.
        let beforeFailure = try Data(contentsOf: profileURL)
        let beforeFiles = try fm.contentsOfDirectory(atPath: home.path).count
        do {
            _ = try DeveloperShellService.save("export SECRET='token-that-must-not-leak\n", replacing: added.profile, home: home.path)
            expect(false, "invalid syntax must fail")
        } catch {
            guard case .syntax(let location) = error as? DeveloperShellService.Failure else {
                expect(false, "expected syntax error"); return
            }
            expect(!location.contains("token-that-must-not-leak"), "diagnostics must not expose a value")
        }
        expect(try Data(contentsOf: profileURL) == beforeFailure, "syntax failure must keep original")
        expect(try fm.contentsOfDirectory(atPath: home.path).count == beforeFiles, "syntax failure must not create backups")

        // Detect external changes even when the user has an already-open editor.
        try "# external change\n".write(to: profileURL, atomically: false, encoding: .utf8)
        expectFailure(.changedOnDisk) {
            _ = try DeveloperShellService.save(removedText, replacing: added.profile, home: home.path)
        }
        expect(try String(contentsOf: profileURL, encoding: .utf8) == "# external change\n", "external content must survive conflict")

        // Missing file must not overwrite a file newly created by another process.
        let empty = try DeveloperShellService.readProfile(".zprofile", home: home.path)
        let zprofile = home.appendingPathComponent(".zprofile")
        try "# another editor\n".write(to: zprofile, atomically: false, encoding: .utf8)
        expectFailure(.changedOnDisk) {
            _ = try DeveloperShellService.save("export X='x'\n", replacing: empty, home: home.path)
        }
        let missing = try DeveloperShellService.readProfile(".zlogin", home: home.path)
        let created = try DeveloperShellService.save("export CREATED='yes'\n", replacing: missing, home: home.path)
        expect(created.profile.exists && created.backupPath == nil, "new files save without inventing a prior backup")

        // Reject symlinks and hardlinks both during inventory and after a snapshot was obtained.
        let replacementSnapshot = try DeveloperShellService.readProfile(".zshrc", home: home.path)
        let outside = fixture.appendingPathComponent("outside")
        try "sentinel\n".write(to: outside, atomically: false, encoding: .utf8)
        try fm.removeItem(at: profileURL)
        try fm.createSymbolicLink(at: profileURL, withDestinationURL: outside)
        expectFailure(.unsafeFile) { _ = try DeveloperShellService.readProfile(".zshrc", home: home.path) }
        expectFailure(.unsafeFile) {
            _ = try DeveloperShellService.save("export X='x'\n", replacing: replacementSnapshot, home: home.path)
        }
        expect(try String(contentsOf: outside, encoding: .utf8) == "sentinel\n", "symlink target must never be changed")
        try fm.removeItem(at: profileURL)
        try fm.linkItem(at: outside, to: profileURL)
        expectFailure(.unsafeFile) { _ = try DeveloperShellService.readProfile(".zshrc", home: home.path) }
        expectFailure(.unsupportedFile) { _ = try DeveloperShellService.readProfile("../outside", home: home.path) }

        // Export-looking documentation and multiline values must never become editable variables.
        let contextualHome = fixture.appendingPathComponent("context-home")
        try fm.createDirectory(at: contextualHome, withIntermediateDirectories: true)
        let contextualFile = contextualHome.appendingPathComponent(".zshrc")
        func contextualProfile(_ text: String) throws -> DeveloperShellService.Profile {
            try text.write(to: contextualFile, atomically: false, encoding: .utf8)
            return try DeveloperShellService.readProfile(".zshrc", home: contextualHome.path)
        }
        let documentation = """
        export BEFORE='one'
        cat <<EOF
        export SAMPLE_UNQUOTED='not-a-declaration'
        EOF
        export AFTER_UNQUOTED='two'
        cat <<'SINGLE'
        export SAMPLE_SINGLE='not-a-declaration'
        SINGLE
        export AFTER_SINGLE='three'
        cat <<"DOUBLE"
        export SAMPLE_DOUBLE='not-a-declaration'
        DOUBLE
        export AFTER_DOUBLE='four'
        cat <<-TABS
        \texport SAMPLE_TABS='not-a-declaration'
        \tTABS
        export AFTER_TABS='five'
        MULTILINE_SINGLE='line one
        export SAMPLE_MULTILINE_SINGLE=sample
        line three'
        export AFTER_MULTILINE_SINGLE='six'
        MULTILINE_DOUBLE="line one
        export SAMPLE_MULTILINE_DOUBLE=sample
        line three"
        export AFTER_MULTILINE_DOUBLE='seven'
        export OUTER_MULTILINE='line one
        export SAMPLE_IN_EXPORTED_VALUE=sample
        line three'
        export LAST='eight'

        """
        let contextual = try contextualProfile(documentation)
        expect(contextual.variables.map(\.name) == ["BEFORE", "AFTER_UNQUOTED", "AFTER_SINGLE", "AFTER_DOUBLE",
                                                   "AFTER_TABS", "AFTER_MULTILINE_SINGLE", "AFTER_MULTILINE_DOUBLE",
                                                   "OUTER_MULTILINE", "LAST"],
               "heredoc/string contents must be excluded without hiding real exports after their end")
        let outerMultiline = contextual.variables.first { $0.name == "OUTER_MULTILINE" }!
        expect(outerMultiline.isDynamic, "the opening declaration of a multiline value must require source editing")
        expectFailure(.dynamicVariable) {
            _ = try DeveloperShellService.removingVariable(in: contextual, variable: outerMultiline)
        }
        let finalVariable = contextual.variables.first { $0.name == "LAST" }!
        let safelyEdited = try DeveloperShellService.settingVariable(in: contextual, variable: finalVariable,
                                                                    name: "LAST", value: "changed")
        expect(safelyEdited == documentation.replacingOccurrences(of: "export LAST='eight'", with: "export LAST='changed'"),
               "editing a real declaration must preserve heredoc and multiline samples byte for byte")

        let multipleDocuments = try contextualProfile("""
        cat <<'FIRST' <<SECOND
        export FIRST_SAMPLE=sample
        FIRST
        export SECOND_SAMPLE=sample
        SECOND
        cat <<'END MARK'
        export SPACED_DELIMITER_SAMPLE=sample
        END MARK
        cat <<\\ESCAPED
        export ESCAPED_DELIMITER_SAMPLE=sample
        ESCAPED
        cat <<E"O"F
        export CONCATENATED_DELIMITER_SAMPLE=sample
        EOF
        export REAL='literal'

        """)
        expect(multipleDocuments.variables.map(\.name) == ["REAL"],
               "multiple, escaped, concatenated and space-bearing heredoc delimiters must be bounded correctly")
        let ordinarySyntax = try contextualProfile("""
        # cat <<EOF is just a comment
        echo 'cat <<EOF is just quoted text'
        echo "cat <<EOF is just quoted text"
        print <<< 'export HERE_STRING_SAMPLE=sample'
        INTEGER=$((1 << 2))
        (( INTEGER = INTEGER << 1 ))
        export REAL='literal' # <<EOF in a comment
        export HASH_LITERAL=a#b

        """)
        expect(ordinarySyntax.variables.map(\.name) == ["REAL", "HASH_LITERAL"],
               "comments, quoted operators, here-strings and arithmetic shifts must not create phantom heredocs")
        let continuedCommands = try contextualProfile("""
        echo example \\
            export CONTINUATION_SAMPLE=sample
        cat <<'END' \\
          -n
        export CONTINUED_HEREDOC_SAMPLE=sample
        END
        RESULT=$(
          export SUBSTITUTION_SAMPLE=sample
          printf '%s' 'value'
        )
        DOUBLE_RESULT="$(
          export DOUBLE_SUBSTITUTION_SAMPLE=sample
          printf '%s' "value"
        )"
        export REAL='literal'

        """)
        expect(continuedCommands.variables.map(\.name) == ["REAL"],
               "continued commands and multiline command substitutions must not become editable declarations")
        let unclosed = try contextualProfile("""
        export BEFORE='literal'
        cat <<'UNCLOSED
        export UNBOUNDED_SAMPLE=sample
        """)
        expect(unclosed.variables.map(\.name) == ["BEFORE"],
               "an unsupported multiline delimiter must conservatively leave the rest to source editing")
        try structureTests(fixture: fixture, sentinel: sentinel)
        try declarationEnvironmentTests(fixture: fixture, sentinel: sentinel)
        try enhancedShellTests(fixture: fixture, sentinel: sentinel)
        print("Developer shell tests passed: structured PATH and references, parsing contexts, heredocs, multiline values, preservation, backups, syntax, no execution, conflicts, symlinks, hardlinks.")
    }
}

extension DeveloperShellTests {
    static func enhancedShellTests(fixture: URL, sentinel: URL) throws {
        typealias Shell = DeveloperShellService
        let fm = FileManager.default
        let home = fixture.appendingPathComponent("enhanced")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let bashText = "export FIRST='login'\nsource ~/.bashrc\n"
        try bashText.write(to: home.appendingPathComponent(".bash_profile"), atomically: false, encoding: .utf8)
        try "export FIRST='ignored'\n".write(to: home.appendingPathComponent(".profile"), atomically: false, encoding: .utf8)
        try "export SECOND='interactive'\nsource ~/.bash_profile\nsource $(touch '\(sentinel.path)')\n".write(to: home.appendingPathComponent(".bashrc"), atomically: false, encoding: .utf8)
        let bash = Shell.inventory(home: home.path, shellPath: "/bin/bash", environment: [:])
        expect(bash.kind == .bash && bash.profiles.count == 4 && bash.loginFile == ".bash_profile", "bash startup files and precedence")
        expect(Shell.startupNames(in: bash.profiles) == [".bash_profile"], "bash login must not combine fallback files or automatically load bashrc")
        expect(Shell.knownEnvironment(bash.profiles, home: home.path)["FIRST"] == "login", "ignored profile must not override effective login declarations")
        expect(bash.included.count == 1, "source graph records bashrc once and breaks cycles")
        let root = try Shell.readProfile(".bash_profile", home: home.path)
        let included = Shell.includedFiles(in: [root], home: home.path)
        expect(included.count == 1 && included[0].profile?.variables.first?.name == "SECOND", "source reads literal file and breaks cycles")
        expect(!fm.fileExists(atPath: sentinel.path), "source inventory must not evaluate command substitution")
        let bashSaved = try Shell.save(bashText + "export THIRD='saved'\n", replacing: root)
        expect(bashSaved.profile.variables.contains { $0.name == "THIRD" }, "bash config validated by bash and saved safely")

        let config = home.appendingPathComponent("zsh-config")
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try "ZDOTDIR='$HOME/zsh-config'\n".write(to: home.appendingPathComponent(".zshenv"), atomically: false, encoding: .utf8)
        let zsh = Shell.inventory(home: home.path, shellPath: "/bin/zsh", environment: ["ZDOTDIR": config.path])
        expect(zsh.usesCustomZdotdir && zsh.directory == config.standardizedFileURL.path && zsh.profiles.allSatisfy { $0.directoryPath == config.standardizedFileURL.path }, "custom ZDOTDIR determines actual target paths")
        expect(Shell.inventory(home: home.path, shellPath: "/usr/local/bin/fish", environment: [:]).kind == .unsupported, "unsupported default shell stays explicit")

        let arrayText = "path=(~/first /second $path /last) # keep\npath+=(~/extra)\npath=(\"$(touch '\(sentinel.path)')\")\n"
        try arrayText.write(to: config.appendingPathComponent(".zshrc"), atomically: false, encoding: .utf8)
        let arrayProfile = try Shell.readProfile(".zshrc", home: config.path)
        let declarations = Shell.pathDeclarations(in: arrayProfile)
        expect(declarations.count == 2 && declarations[0].style == .array && declarations[1].style == .arrayAppend, "literal zsh path arrays recognized without dynamic expressions")
        let original = declarations[0].items
        let reordered = [original[1], original[0], original[2], original[3]]
        let edited = try Shell.settingPath(in: arrayProfile, declaration: declarations[0], items: reordered)
        expect(edited.hasPrefix("path=("), "array editing preserves the user's syntax")
        expect(edited.contains("$path") && edited.contains("# keep"), "hidden inherited reference and comment preserved")
        expectFailure(.invalidVariable) {
            _ = try Shell.settingPath(in: arrayProfile, declaration: declarations[0], items: [original[0], original[2], original[1], original[3]])
        }
        expectFailure(.invalidVariable) {
            _ = try Shell.settingPath(in: arrayProfile, declaration: declarations[0], items: original.filter { $0 != .inherited })
        }
        expect(!fm.fileExists(atPath: sentinel.path), "path array parsing never executes")

        let aliasText = "alias gs='git status' # status\nalias complex=\"$(touch '\(sentinel.path)')\"\n"
        try aliasText.write(to: home.appendingPathComponent(".bashrc"), atomically: false, encoding: .utf8)
        let aliasesProfile = try Shell.readProfile(".bashrc", home: home.path)
        let aliases = Shell.aliasDeclarations(in: aliasesProfile)
        expect(aliases.count == 1 && aliases[0].command == "git status", "simple alias declarations editable; dynamic alias stays read-only")
        let aliasEdited = try Shell.settingAlias(in: aliasesProfile, alias: aliases[0], name: "gss", command: "git status --short")
        expect(aliasEdited.contains("alias gss='git status --short' # status"), "alias edit preserves comment and unrelated lines")
        expectFailure(.invalidVariable) { _ = try Shell.settingAlias(in: aliasesProfile, alias: nil, name: "x;touch", command: "ls") }

        var current = bashSaved.profile
        for value in 0..<12 {
            current = try Shell.save("export VALUE='\(value)'\n", replacing: current).profile
        }
        let history = try DeveloperShellBackupStore.history(targetPath: current.path, home: home.path)
        expect(history.count == 10, "shell backup rotation keeps ten per target")
        expect(history.allSatisfy { $0.path.contains("/Library/Application Support/Nori/Backups/") }, "backups stay out of home root")
        let directory = DeveloperShellBackupStore.directoryPath(targetPath: current.path, home: home.path)
        expect((try fm.attributesOfItem(atPath: directory)[.posixPermissions] as! NSNumber).intValue == 0o700, "backup directories are owner-only")
        let restoredText = try DeveloperShellBackupStore.read(history[0], targetPath: current.path, home: home.path)
        expect(restoredText == "export VALUE='10'\n", "latest backup contains exact pre-save bytes")
        let restored = try Shell.save(restoredText, replacing: current)
        expect(restored.profile.text == restoredText, "backup restoration uses normal validated replacement")
        let stale = restored.profile
        try "# external\n".write(to: home.appendingPathComponent(".bash_profile"), atomically: false, encoding: .utf8)
        expectFailure(.changedOnDisk) { _ = try Shell.save(restoredText, replacing: stale) }
        expect(!DeveloperShellBackupStore.redactedDiff(current: "export API_TOKEN='old'\n", backup: "export API_TOKEN='new'\n", hidden: "hidden").contains("old"), "backup diffs mask sensitive lines")
        expect(!fm.fileExists(atPath: sentinel.path), "all advanced shell operations remain parse-only")
    }
}
