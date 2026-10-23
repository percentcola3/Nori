import Darwin
import Foundation

/// Every installation is constructed under the runner's disposable fixture.
/// The scanner must never run any Agent launcher to establish ownership.
@main
struct AgentCLIOwnershipTests {
    private static let fm = FileManager.default
    private static let scripts = ["hermes": "hermes_cli.main:main", "hermes-agent": "run_agent:main",
                                  "hermes-acp": "acp_adapter.entry:main"]
    private static let idle = RunningApplicationSnapshot()

    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
        guard let hermes = AgentCatalog.definitions.first(where: { $0.id == "hermes" }) else {
            fatalError("The production catalog must declare Hermes")
        }
        try nativeOwnership(hermes, fixture: fixture)
        try missingLaunchers(hermes, fixture: fixture)
        try insufficientProof(hermes, fixture: fixture)
        try changedProof(hermes, fixture: fixture)
        try wrappersAndLinks(hermes, fixture: fixture)
        try wrapperVariants(hermes, fixture: fixture)
        try separateChannels(hermes, fixture: fixture)
        try pythonManagers(hermes, fixture: fixture)
        try otherAgentArtifacts(fixture: fixture)
        print("Agent CLI ownership: Hermes native/wrapper/venv/pipx/uv proofs, channel isolation and non-program remnants passed")
    }

    private static func nativeOwnership(_ agent: AgentDefinition, fixture: String) throws {
        let home = fixture + "/native home with 'quotes"
        let root = try native(home: home)
        for name in scripts.keys { try wrapper(home + "/.local/bin/" + name, target: root + "/venv/bin/" + name) }
        try write(home + "/.hermes/config.yaml", "user settings")
        try write(home + "/.hermes/sessions/keep.jsonl", "retained session")
        try write(home + "/.hermes/skills/keep/SKILL.md", "user skill")
        let rows = scan(agent, home: home)
        expect(rows.count == 1 && rows[0].managedPaths == [root], "The installer wrappers and source share one exclusive program root")
        let entries = Set(scripts.keys.flatMap { [root + "/venv/bin/" + $0, home + "/.local/bin/" + $0] })
        expect(Set(rows[0].executablePaths) == entries, "Bind all three internal entries and all three installer wrappers")
        expect(rows[0].identities[root + "/pyproject.toml"] != nil
               && rows[0].identities[root + "/.hermes-bootstrap-complete"] != nil
               && rows[0].identities[root + "/venv/pyvenv.cfg"] != nil,
               "The frozen uninstall plan binds the manifest, installer marker and virtual environment")
        expect(!AgentCatalog.exists(home + "/launcher-executed"), "Discovery must not run a launcher")
        let result = remove(rows[0], home: home)
        expect(result.succeeded && !AgentCatalog.exists(root)
               && entries.allSatisfy { !AgentCatalog.exists($0) }
               && AgentCatalog.exists(home + "/.hermes/config.yaml")
               && AgentCatalog.exists(home + "/.hermes/sessions/keep.jsonl")
               && AgentCatalog.exists(home + "/.hermes/skills/keep/SKILL.md"),
               "Native uninstall removes only the program and owned wrappers: \(result.messages)")
        expect(!AgentCatalog.exists(home + "/launcher-executed"), "Uninstall must not execute the Agent")
    }

    private static func missingLaunchers(_ agent: AgentDefinition, fixture: String) throws {
        for environment in ["venv", ".venv"] {
            let home = fixture + "/missing-launchers-" + environment
            let root = try native(home: home, environment: environment)
            try fm.removeItem(atPath: root + "/" + environment + "/bin/hermes-agent")
            let alias = home + "/.local/bin/hermes-agent"
            try link(alias, target: root + "/" + environment + "/bin/hermes-agent")
            let rows = scan(agent, home: home)
            expect(rows.count == 1 && rows[0].managedPaths == [root] && rows[0].executablePaths.contains(alias),
                   "Discover a remaining \(environment) program without its main launcher and bind its owned dangling alias")
            let result = remove(rows[0], home: home)
            expect(result.succeeded && !AgentCatalog.exists(root) && !AgentCatalog.isSymlink(alias),
                   "Remove the remaining program and its dangling alias: \(result.messages)")
        }
        let home = fixture + "/source-and-env-remnant"
        let root = try native(home: home)
        for name in scripts.keys { try fm.removeItem(atPath: root + "/venv/bin/" + name) }
        let rows = scan(agent, home: home)
        expect(rows.count == 1 && rows[0].executablePaths.isEmpty && rows[0].managedPaths == [root],
               "A proven source/venv program remains removable even after every command entry has disappeared")
        expect(remove(rows[0], home: home).succeeded, "Remove a remaining source installation without command entries")
    }

    private static func insufficientProof(_ agent: AgentDefinition, fixture: String) throws {
        for missing in [".hermes-bootstrap-complete", "pyproject.toml", "hermes_cli/main.py", "venv/pyvenv.cfg"] {
            let home = fixture + "/insufficient-" + missing.replacingOccurrences(of: "/", with: "-")
            let root = try native(home: home)
            try fm.removeItem(atPath: root + "/" + missing)
            let alias = home + "/.local/bin/hermes"
            try wrapper(alias, target: root + "/venv/bin/hermes")
            let rows = scan(agent, home: home)
            expect(rows.allSatisfy { $0.managedPaths == [alias] },
                   "Missing \(missing) cannot authorize deletion of the source tree")
            if let row = rows.first {
                expect(remove(row, home: home).succeeded && AgentCatalog.exists(root),
                       "An unproven wrapper may be removed without deleting its destination")
            }
        }
        let home = fixture + "/wrong-project"
        let root = try native(home: home)
        try write(root + "/pyproject.toml", manifest(name: "unrelated-project"))
        expect(scan(agent, home: home).isEmpty, "A similarly shaped unrelated project is not Hermes")
    }

    private static func changedProof(_ agent: AgentDefinition, fixture: String) throws {
        for evidence in ["pyproject.toml", ".hermes-bootstrap-complete", "hermes_cli/main.py", "venv/pyvenv.cfg"] {
            let home = fixture + "/changed-" + evidence.replacingOccurrences(of: "/", with: "-")
            let root = try native(home: home)
            let row = scan(agent, home: home)[0]
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: root + "/" + evidence)
            let result = remove(row, home: home)
            expect(!result.succeeded && result.requiresRescan && AgentCatalog.exists(root),
                   "Replaced or changed \(evidence) requires a fresh scan")
        }
    }

    private static func wrappersAndLinks(_ agent: AgentDefinition, fixture: String) throws {
        let home = fixture + "/untrusted-wrapper"
        let root = try native(home: home)
        let alias = home + "/.local/bin/hermes"
        try executable(alias, "#!/bin/bash\nexec \"" + root + "/venv/bin/hermes\" \"$@\"\n/bin/echo unrelated\n")
        let rows = scan(agent, home: home)
        let owned = rows.first { $0.managedPaths == [root] }!
        expect(!owned.executablePaths.contains(alias) && rows.contains { $0.managedPaths == [alias] },
               "A script with extra executable statements cannot confer whole-tree ownership")
        expect(remove(owned, home: home).succeeded && AgentCatalog.exists(alias),
               "Removing proven Hermes code leaves an unproven wrapper for separate review")

        let symlinkHome = fixture + "/linked-source"
        let externalHome = fixture + "/external-source"
        let externalRoot = try native(home: externalHome)
        try link(symlinkHome + "/.hermes/hermes-agent", target: externalRoot)
        let linkedAlias = symlinkHome + "/.local/bin/hermes"
        try link(linkedAlias, target: symlinkHome + "/.hermes/hermes-agent/venv/bin/hermes")
        let linkedRows = scan(agent, home: symlinkHome)
        expect(linkedRows.count == 1 && linkedRows[0].onlyUnlinksExecutable,
               "An external linked source root never becomes a recursive uninstall target")
        expect(remove(linkedRows[0], home: symlinkHome).succeeded && AgentCatalog.exists(externalRoot),
               "An unknown command link is unlinked while its external source survives")
    }

    private static func separateChannels(_ agent: AgentDefinition, fixture: String) throws {
        let home = fixture + "/two-channels"
        let nativeRoot = try native(home: home)
        try wrapper(home + "/.local/bin/hermes", target: nativeRoot + "/venv/bin/hermes")
        let uvRoot = try pythonTool(home: home, manager: "uv")
        let uvAlias = home + "/other-bin/hermes"
        try link(uvAlias, target: uvRoot + "/bin/hermes")
        let searchPath = [home + "/.local/bin", home + "/other-bin"]
        let rows = scan(agent, home: home, searchPath: searchPath)
        expect(rows.count == 2 && Set(rows.map { $0.manager.rawValue }) == ["native", "uv"],
               "Native and uv installations remain separate uninstall plans")
        let nativeRow = rows.first { $0.manager == .native }!
        let result = remove(nativeRow, home: home)
        expect(result.succeeded && !AgentCatalog.exists(nativeRoot)
               && AgentCatalog.exists(uvRoot) && AgentCatalog.isSymlink(uvAlias),
               "Removing native Hermes must preserve the separately installed uv channel")
    }

    private static func wrapperVariants(_ agent: AgentDefinition, fixture: String) throws {
        let shells = ["#!/bin/bash", "#!/bin/sh", "#!/bin/zsh",
                      "#!/usr/bin/env bash", "#!/usr/bin/env sh", "#!/usr/bin/env zsh"]
        let unsetVariants = [[], ["unset PYTHONPATH"], ["unset PYTHONHOME"],
                             ["unset PYTHONPATH", "unset PYTHONHOME"], ["unset PYTHONHOME", "unset PYTHONPATH"]]
        for (shellIndex, shell) in shells.enumerated() {
            for (unsetIndex, unsets) in unsetVariants.enumerated() {
                let home = fixture + "/wrapper-variant-\(shellIndex)-\(unsetIndex)"
                let root = try native(home: home)
                let alias = home + "/.local/bin/hermes"
                let target = root + "/venv/bin/hermes"
                try executable(alias, ([shell, "# installer wrapper"] + unsets + ["exec \"" + target + "\" \"$@\""])
                    .joined(separator: "\n") + "\n")
                let rows = scan(agent, home: home)
                expect(rows.count == 1 && rows[0].managedPaths == [root] && rows[0].executablePaths.contains(alias),
                       "Recognize supported shell and exact Python environment unsets as one Hermes installation")
                let context = AgentPresenceContext(applicationDirs: [], searchPath: [home + "/.local/bin"])
                expect(AgentCatalog.isInstalled(agent, home: home, presence: context),
                       "A live supported Hermes wrapper remains installation evidence")
                try fm.removeItem(atPath: target)
                expect(!AgentCatalog.isInstalled(agent, home: home, presence: context),
                       "A supported wrapper whose target disappeared is a command remnant")
            }
        }
        let invalid = ["unset PATH\n", "unset -v PYTHONPATH\n", "unset PYTHONPATH PYTHONHOME\n",
                       "unset PYTHONPATH\nunset PYTHONPATH\n", "export PYTHONPATH=\n", "PYTHONPATH=\n",
                       "unset PYTHONPATH; /bin/echo side-effect\n", "/bin/echo unrelated\n"]
        for (index, prefix) in invalid.enumerated() {
            let home = fixture + "/untrusted-unset-\(index)"
            let root = try native(home: home)
            let alias = home + "/.local/bin/hermes"
            let target = root + "/venv/bin/hermes"
            try executable(alias, "#!/usr/bin/env bash\n" + prefix + "exec \"" + target + "\" \"$@\"\n")
            let rows = scan(agent, home: home)
            expect(rows.contains { $0.managedPaths == [root] && !$0.executablePaths.contains(alias) }
                   && rows.contains { $0.managedPaths == [alias] },
                   "Unknown unset/options/assignment/statement cannot confer ownership of the program tree")
            try fm.removeItem(atPath: target)
            expect(AgentCatalog.isInstalled(agent, home: home,
                presence: .init(applicationDirs: [], searchPath: [home + "/.local/bin"])),
                   "Unknown wrappers remain conservative installation evidence")
        }
        for (index, shape) in ["#!/usr/bin/env -S bash", "#!/usr/bin/env bash -e", "#!/bin/bash -e"].enumerated() {
            let home = fixture + "/untrusted-shell-option-\(index)"
            let root = try native(home: home)
            let alias = home + "/.local/bin/hermes"
            try executable(alias, shape + "\nexec \"" + root + "/venv/bin/hermes\" \"$@\"\n")
            expect(scan(agent, home: home).contains { $0.managedPaths == [root] && !$0.executablePaths.contains(alias) },
                   "Shell interpreter options do not confer whole-tree ownership")
        }
        let home = fixture + "/unset-after-exec"
        let root = try native(home: home)
        let alias = home + "/.local/bin/hermes"
        try executable(alias, "#!/usr/bin/env bash\nexec \"" + root + "/venv/bin/hermes\" \"$@\"\nunset PYTHONPATH\n")
        expect(scan(agent, home: home).contains { $0.managedPaths == [root] && !$0.executablePaths.contains(alias) },
               "Python environment unsets are accepted only before the final exec")
    }

    private static func pythonManagers(_ agent: AgentDefinition, fixture: String) throws {
        for name in ["pipx", "uv"] {
            let home = fixture + "/python-manager-" + name
            let root = try pythonTool(home: home, manager: name)
            for command in scripts.keys { try link(home + "/.local/bin/" + command, target: root + "/bin/" + command) }
            let rows = scan(agent, home: home)
            expect(rows.count == 1 && rows[0].manager.rawValue == name && rows[0].packageName == "hermes-agent"
                   && rows[0].executablePaths.count == 6,
                   "Verified \(name) metadata binds all Hermes aliases to one managed installation")
            let result = remove(rows[0], home: home)
            expect(result.succeeded && !AgentCatalog.exists(root)
                   && scripts.keys.allSatisfy { !AgentCatalog.exists(home + "/.local/bin/" + $0) },
                   "Use only the fixture \(name) manager and verify its body and aliases disappeared: \(result.messages)")

            let badHome = fixture + "/unproven-python-manager-" + name
            let badRoot = try pythonTool(home: badHome, manager: name)
            let metadata = badRoot + "/lib/python3.13/site-packages/hermes_agent-1.0.dist-info/METADATA"
            try write(metadata, "Name: unrelated-agent\nVersion: 1.0\n")
            let badAlias = badHome + "/.local/bin/hermes"
            try link(badAlias, target: badRoot + "/bin/hermes")
            let badRows = scan(agent, home: badHome)
            expect(badRows.count == 1 && badRows[0].onlyUnlinksExecutable,
                   "A \(name) root name without matching installed distribution proof only allows unlinking its alias")

            let remnantHome = fixture + "/python-remnant-" + name
            let remnantRoot = try pythonTool(home: remnantHome, manager: name)
            let remnant = scan(agent, home: remnantHome)
            expect(remnant.count == 1 && remnant[0].managedPaths == [remnantRoot]
                   && remnant[0].manager.rawValue == name,
                   "A proven \(name) package remains discoverable after all public aliases disappear")
            expect(remove(remnant[0], home: remnantHome).succeeded && !AgentCatalog.exists(remnantRoot),
                   "Remove the remaining \(name) package with its own fixture manager")

            let wrapperHome = fixture + "/python-wrapper-" + name
            let wrapperRoot = try pythonTool(home: wrapperHome, manager: name)
            try wrapper(wrapperHome + "/.local/bin/hermes", target: wrapperRoot + "/bin/hermes")
            let wrapperRows = scan(agent, home: wrapperHome)
            expect(wrapperRows.count == 1 && wrapperRows[0].manager.rawValue == name
                   && wrapperRows[0].executablePaths.contains(wrapperHome + "/.local/bin/hermes"),
                   "A strict regular shell wrapper can be attributed to a proven \(name) Hermes distribution")
            expect(remove(wrapperRows[0], home: wrapperHome).succeeded,
                   "Remove a proven \(name) package and its fixture installer wrapper")
        }
    }

    private static func otherAgentArtifacts(fixture: String) throws {
        let home = fixture + "/other-artifacts"
        let factory = AgentCatalog.definitions.first { $0.id == "factory" }!
        let opencode = AgentCatalog.definitions.first { $0.id == "opencode" }!
        try executable(home + "/.factory/bin/rg", "#!/bin/sh\nexit 0\n")
        try executable(home + "/.opencode/node_modules/plugin/bin/opencode", "#!/bin/sh\nexit 0\n")
        try write(home + "/.factory/settings.json", "{}")
        try write(home + "/.config/opencode/opencode.json", "{}")
        expect(scan(factory, home: home).isEmpty && scan(opencode, home: home).isEmpty,
               "Droid's downloaded ripgrep and OpenCode's plugin dependencies are not installed Agent programs")
        try executable(home + "/.local/bin/droid", "#!/bin/sh\nexit 0\n")
        let droidRows = scan(factory, home: home)
        expect(droidRows.count == 1 && droidRows[0].managedPaths == [home + "/.local/bin/droid"],
               "Droid's native standalone command is a program independently of .factory data")
        expect(remove(droidRows[0], home: home).succeeded
               && AgentCatalog.exists(home + "/.factory/bin/rg")
               && AgentCatalog.exists(home + "/.factory/settings.json"), "Program removal preserves Droid's separate retained data")
        let openProgram = home + "/.opencode/bin/opencode"
        let otherProgram = home + "/tools/other"
        let otherEntry = home + "/.opencode/bin/other"
        try executable(openProgram, "#!/bin/sh\nexit 0\n")
        try executable(otherProgram, "#!/bin/sh\nexit 0\n")
        try link(otherEntry, target: otherProgram)
        let openRows = scan(opencode, home: home)
        expect(openRows.count == 1, "OpenCode's remaining private executable is discovered without a public launcher")
        expect(openRows[0].managedPaths == [openProgram],
               "Only OpenCode's verified executable belongs to its mixed bin removal plan")
        expect(remove(openRows[0], home: home).succeeded && !AgentCatalog.exists(openProgram)
               && AgentCatalog.exists(otherEntry) && AgentCatalog.exists(otherProgram)
               && AgentCatalog.exists(home + "/.opencode/node_modules/plugin/bin/opencode")
               && AgentCatalog.exists(home + "/.config/opencode/opencode.json"),
               "Removing OpenCode's private program preserves other tool entries, plugins and configuration data")
    }

    private static func native(home: String, environment: String = "venv") throws -> String {
        let root = home + "/.hermes/hermes-agent"
        try write(root + "/pyproject.toml", manifest())
        try write(root + "/.hermes-bootstrap-complete", "complete")
        for source in ["hermes_cli/main.py", "run_agent.py", "acp_adapter/entry.py"] { try write(root + "/" + source, "# fixture source\n") }
        try write(root + "/" + environment + "/pyvenv.cfg", "home = /fixture/python\n")
        for name in scripts.keys {
            try executable(root + "/" + environment + "/bin/" + name,
                           "#!/bin/sh\n/usr/bin/touch " + quote(home + "/launcher-executed") + "\nexit 71\n")
        }
        return root
    }

    private static func pythonTool(home: String, manager: String) throws -> String {
        let root = home + (manager == "pipx" ? "/.local/share/pipx/venvs/hermes-agent" : "/.local/share/uv/tools/hermes-agent")
        try write(root + "/pyvenv.cfg", "home = /fixture/python\n")
        let dist = root + "/lib/python3.13/site-packages/hermes_agent-1.0.dist-info"
        try write(dist + "/METADATA", "Metadata-Version: 2.4\nName: hermes-agent\nVersion: 1.0\n")
        try write(dist + "/entry_points.txt", "[console_scripts]\n" + scripts.sorted { $0.key < $1.key }
            .map { $0.key + " = " + $0.value }.joined(separator: "\n") + "\n")
        for name in scripts.keys { try executable(root + "/bin/" + name, "#!/bin/sh\nexit 71\n") }
        let condition = manager == "pipx" ? "[ \"$1\" = uninstall ] && [ \"$2\" = hermes-agent ]" :
            "[ \"$1\" = tool ] && [ \"$2\" = uninstall ] && [ \"$3\" = hermes-agent ]"
        try executable(home + "/.local/bin/" + manager,
                       "#!/bin/sh\n" + condition + " || exit 91\n/bin/rm -rf -- " + quote(root) + "\n"
                       + "/bin/rm -f -- " + scripts.keys.sorted().map { quote(home + "/.local/bin/" + $0) }.joined(separator: " ") + "\n")
        return root
    }

    private static func manifest(name: String = "hermes-agent") -> String {
        "[project]\nname = \"" + name + "\"\nversion = \"1.0\"\n[project.scripts]\n"
            + scripts.sorted { $0.key < $1.key }.map { $0.key + " = \"" + $0.value + "\"" }.joined(separator: "\n") + "\n"
    }

    private static func scan(_ agent: AgentDefinition, home: String, searchPath: [String]? = nil) -> [AgentCLIInstallation] {
        AgentCLIService.installations(for: agent, home: home,
            presence: .init(applicationDirs: [], searchPath: searchPath ?? [home + "/.local/bin"]))
    }

    private static func remove(_ installation: AgentCLIInstallation, home: String) -> AgentCLIService.Outcome {
        AgentCLIService.uninstall(installation, home: home, running: idle, permanent: true,
            core: NativeCore(cleanupOpenFileProbe: { [] }))
    }

    private static func wrapper(_ path: String, target: String) throws {
        try executable(path, "#!/usr/bin/env bash\nunset PYTHONPATH\nunset PYTHONHOME\nexec \"" + target + "\" \"$@\"\n")
    }
    private static func link(_ path: String, target: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: path, withDestinationPath: target)
    }
    private static func write(_ path: String, _ text: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
    private static func executable(_ path: String, _ text: String) throws {
        try write(path, text)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
