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
            _ = try DeveloperShellService.removingVariable(in: profile, variable: profile.variables.first { $0.name == "PATH" }!)
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
        print("Developer shell tests passed: parsing contexts, heredocs, multiline values, preservation, backups, syntax, no execution, conflicts, symlinks, hardlinks.")
    }
}
