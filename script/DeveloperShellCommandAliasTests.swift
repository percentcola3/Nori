import Foundation

@main
struct DeveloperShellCommandAliasTests {
    typealias Shell = DeveloperShellService

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data(("FAIL: \(message)\n").utf8))
            exit(1)
        }
    }

    static func main() throws {
        let manager = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let home = fixture.appendingPathComponent("alias-home", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        let sentinel = fixture.appendingPathComponent("must-not-execute")
        let zshenv = """
        alias overridden='/old/bin/overridden'
        alias startup='/env/bin/startup'
        alias removed='/old/bin/removed'
        alias dependsOnRemoved=removed
        alias python3=python
        alias quoted='"/quoted/bin/quoted"'
        alias unresolved=unknownCommand
        alias loopA=loopB
        alias loopB=loopA
        alias selfCycle=selfCycle
        """
        let zprofile = """
        alias startup='/profile/bin/startup'
        alias homeDouble="$HOME/bin/double"
        alias homeSingle='$HOME/bin/single'
        alias homeBraced='${HOME}/bin/braced'
        alias homeTilde='~/bin/tilde'
        alias unknownReference="$UNKNOWN/bin/unknown"
        export UNKNOWN='/should/not/be/used'
        """
        let zshrc = """
        alias python="/opt/homebrew/opt/python@3.11/bin/python3.11"
        alias python3="python"
        alias third=python3
        alias overridden='/new/bin/overridden'
        alias removed='python --version'
        alias invalid='/foo/bin/tool;touch \(sentinel.path)'
        alias glob='/foo/bin/py*'
        alias options='--version'
        alias dynamic="$(touch '\(sentinel.path)')"
        alias backticks='`touch \(sentinel.path)`'
        alias commandWithSpaces='/directory with spaces/python'
        alias normalComment='/comment/bin/tool' # description
        cat <<'EOF'
        alias heredoc='/fake/bin/heredoc'
        EOF
        MESSAGE='
        alias multiline='/fake/bin/multiline'
        '
        printf '%s' \\
        alias continuation='/fake/bin/continuation'
        alias afterRegions='/real/bin/after-regions'
        """
        let zlogin = """
        alias startup='/login/bin/startup'
        alias loginChain=startup
        alias overridden='/last/bin/overridden'
        alias sameLine='/first/bin/sameLine'
        alias sameLine='/second/bin/sameLine'
        """
        for (name, text) in [(".zshenv", zshenv), (".zprofile", zprofile), (".zshrc", zshrc), (".zlogin", zlogin)] {
            try text.write(to: home.appendingPathComponent(name), atomically: false, encoding: .utf8)
        }
        let profiles = Shell.scan(home: home.path)
        let aliases = Shell.commandAliases(in: Array(profiles.reversed()), home: home.path)
        let byName = Dictionary(uniqueKeysWithValues: aliases.map { ($0.name, $0) })
        expect(aliases.map(\.name) == aliases.map(\.name).sorted(), "alias names have deterministic ordering")
        for name in ["python", "python3", "third"] {
            expect(byName[name] == Shell.CommandAlias(name: name,
                                                     targetPath: "/opt/homebrew/opt/python@3.11/bin/python3.11",
                                                     targetCommand: "python3.11"),
                   "absolute aliases and alias chains preserve actual target command names")
        }
        expect(byName["startup"]?.targetPath == "/login/bin/startup"
               && byName["loginChain"]?.targetPath == "/login/bin/startup",
               "startup file order is independent of the passed profile order")
        expect(byName["overridden"]?.targetPath == "/last/bin/overridden"
               && byName["sameLine"]?.targetPath == "/second/bin/sameLine",
               "the last assignment wins in startup and line order")
        expect(byName["quoted"]?.targetPath == "/quoted/bin/quoted", "one command word can retain its own quotes")
        for (name, command) in [("homeDouble", "double"), ("homeSingle", "single"),
                                ("homeBraced", "braced"), ("homeTilde", "tilde")] {
            expect(byName[name]?.targetPath == home.appendingPathComponent("bin/\(command)").standardizedFileURL.path,
                   "only HOME references and supported quotes expand safely")
        }
        for name in ["removed", "dependsOnRemoved", "invalid", "glob", "options", "dynamic", "backticks",
                     "commandWithSpaces", "unknownReference", "unresolved", "loopA", "loopB", "selfCycle",
                     "heredoc", "multiline", "continuation"] {
            expect(byName[name] == nil, "unsupported, shadowed, cyclical, or text-only alias is excluded: \(name)")
        }
        expect(byName["normalComment"]?.targetPath == "/comment/bin/tool"
               && byName["afterRegions"]?.targetPath == "/real/bin/after-regions",
               "comments and completed lexical regions allow following real aliases")
        expect(!manager.fileExists(atPath: sentinel.path), "alias discovery must never source profiles or evaluate bodies")

        let removalHome = fixture.appendingPathComponent("removal-home", isDirectory: true)
        try manager.createDirectory(at: removalHome, withIntermediateDirectories: true)
        let removals = """
        alias beforeClear='/old/bin/tool'
        unalias -a # clear all aliases configured so far
        alias removed='/old/bin/removed'
        alias removedToo='/old/bin/removed-too'
        unalias removed removedToo # remove individual names
        alias multishadow='/old/bin/tool'
        alias multi='/new/bin/multi' multishadow='/new/bin/tool'
        alias bodytext='/real/bin/bodytext'
        alias unsupported='echo bodytext=/fake/bin/tool'
        alias optionShadow='/old/bin/option'
        alias -g optionShadow='/new/bin/option'
        alias substitutionShadow='/old/bin/substitution'
        alias dynamic="$(echo bodytext=/fake/bin/tool)" substitutionShadow='/new/bin/substitution'
        cat <<'EOF'
        unalias bodytext
        EOF
        alias retained='/new/bin/retained'
        """
        try removals.write(to: removalHome.appendingPathComponent(".zshrc"), atomically: false, encoding: .utf8)
        let remaining = Shell.commandAliases(in: Shell.scan(home: removalHome.path), home: removalHome.path)
        expect(remaining.map(\.name) == ["bodytext", "retained"],
               "unalias and unsupported multiple assignments remove stale mappings without treating body text as assignments")
        expect(!manager.fileExists(atPath: sentinel.path), "alias overrides must still never execute source")
        print("Developer Shell command alias tests passed")
    }
}
