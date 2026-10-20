import Darwin
import Foundation

@main
struct AgentRemovalServiceTests {
    static var assertions = 0

    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--probe" {
            let ids = Set(CommandLine.arguments.dropFirst(2))
            let selected = ids.isEmpty ? Set(["opencode", "hermes", "factory"]) : ids
            let plan = AgentRemovalService.plan(agentIDs: selected, home: NSHomeDirectory())
            let report: [String: Any] = ["agentIDs": plan.agentIDs.sorted(), "paths": plan.items.map(\.record),
                "retainedPaths": plan.retainedPaths, "messages": plan.messages]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            return
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
        let fm = FileManager.default
        let idle = RunningApplicationSnapshot()
        let availableCore = NativeCore(cleanupOpenFileProbe: { [] })
        func home(_ name: String) throws -> String {
            let path = fixture + "/" + name + "/home with 'quotes $value"
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        func context(_ home: String) -> AgentPresenceContext {
            .init(applicationDirs: [home + "/Applications"], searchPath: [home + "/.local/bin"])
        }
        func write(_ path: String, _ value: String = "fixture") throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(value.utf8).write(to: URL(fileURLWithPath: path))
        }
        func executable(_ path: String) throws {
            try write(path, "#!/bin/sh\nexit 0\n")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        var trashMoves: [String: String] = [:]
        func trash(_ url: URL) throws {
            expect(url.path.hasPrefix(fixture + "/"), "Only disposable fixture paths reach Trash")
            let destination = fixture + "/fake-trash/" + UUID().uuidString
            try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: url.path, toPath: destination)
            trashMoves[url.path] = destination
        }
        func preview(_ id: String, _ path: String) -> AgentRemovalService.Plan {
            AgentRemovalService.plan(agentIDs: [id], home: path, presence: context(path))
        }
        func apply(_ plan: AgentRemovalService.Plan, _ path: String,
                   running: RunningApplicationSnapshot = RunningApplicationSnapshot(),
                   core: NativeCore? = nil) -> NativeCore.ApplySummary {
            AgentRemovalService.execute(plan, running: running, home: path, presence: context(path),
                                        core: core ?? availableCore, trashHandler: trash)
        }

        let complete = try home("complete")
        let factory = complete + "/.factory"
        try write(factory + "/settings.json", "{}")
        try write(factory + "/auth.json", "fixture credential")
        try write(factory + "/sessions/one/history.jsonl", "fixture history")
        try write(factory + "/unknown-private-file", "unknown product data")
        try write(complete + "/outside", "keep")
        let full = preview("factory", complete)
        expect(full.items.map(\.record) == [factory] && full.retainedPaths.isEmpty,
               "Preview includes the complete exclusive product root: \(full.messages)")
        let normal = availableCore.applyCleanup(items: full.items, permanent: false, homeDirectory: complete,
            allowedRoots: [factory], verifiedTargets: [factory], trashHandler: trash)
        expect(normal.removed == 0 && fm.fileExists(atPath: factory),
               "Normal cleanup still cannot bypass history and configuration protection")
        let removed = apply(full, complete)
        expect(removed.removedPaths == [factory] && removed.reclaimedBytes == 0 && removed.retainedPaths.isEmpty,
               "Dedicated removal moves the confirmed root without claiming disk space was permanently freed: \(removed.messages)")
        expect(!fm.fileExists(atPath: factory) && fm.fileExists(atPath: complete + "/outside"),
               "Complete removal does not touch unrelated files")
        let trashed = trashMoves[factory]!
        expect(fm.fileExists(atPath: trashed + "/auth.json")
               && fm.fileExists(atPath: trashed + "/sessions/one/history.jsonl")
               && fm.fileExists(atPath: trashed + "/unknown-private-file"),
               "Credentials, history and unknown product files remain recoverable together in Trash")

        let installed = try home("installed")
        try write(installed + "/.factory/settings.json", "{}")
        try executable(installed + "/.local/bin/droid")
        let installedPlan = preview("factory", installed)
        expect(installedPlan.items.isEmpty && installedPlan.retainedPaths.contains(installed + "/.factory")
               && installedPlan.messages.contains(where: { $0.contains("still installed") }),
               "A remaining installation blocks complete data removal")

        let appeared = try home("appeared-installation")
        try write(appeared + "/.factory/settings.json", "{}")
        let appearedPlan = preview("factory", appeared)
        try executable(appeared + "/.local/bin/droid")
        expect(apply(appearedPlan, appeared).removed == 0 && fm.fileExists(atPath: appeared + "/.factory"),
               "An installation appearing after confirmation revokes removal authority")

        let running = try home("running")
        try write(running + "/.factory/settings.json", "{}")
        let runningPlan = preview("factory", running)
        expect(apply(runningPlan, running, running: .init(processNames: ["droid"])).removed == 0,
               "Running owner processes block data removal")
        expect(apply(runningPlan, running, running: .unavailable).removed == 0,
               "Unknown process state fails closed")
        expect(apply(runningPlan, running, core: NativeCore(cleanupOpenFileProbe: { nil })).removed == 0,
               "Unknown open-file state fails closed")
        expect(apply(runningPlan, running,
                     core: NativeCore(cleanupOpenFileProbe: { [running + "/.factory/settings.json"] })).removed == 0,
               "An open descendant blocks its entire root")
        expect(fm.fileExists(atPath: running + "/.factory/settings.json"), "Runtime refusals retain all data")
        let parentOpen = apply(runningPlan, running,
                               core: NativeCore(cleanupOpenFileProbe: { [running] }))
        expect(parentOpen.removed == 1,
               "A shell whose cwd is the home directory does not occupy every product root")
        let lateOpen = try home("late-open")
        try write(lateOpen + "/.factory/file")
        let lateOpenPlan = preview("factory", lateOpen)
        var occupancyProbes = 0
        let lateCore = NativeCore(cleanupOpenFileProbe: {
            occupancyProbes += 1
            return occupancyProbes == 1 ? [] : [lateOpen + "/.factory/file"]
        })
        expect(apply(lateOpenPlan, lateOpen, core: lateCore).removed == 0,
               "The Trash boundary repeats occupancy checks after the initial runtime probe")

        let changed = try home("changed-deep-child")
        let child = changed + "/.factory/deep/history.json"
        try write(child, "before")
        let changedPlan = preview("factory", changed)
        let parentIdentity = DeletionPlan.Metadata.read(changed + "/.factory")
        let originalTime = (try fm.attributesOfItem(atPath: child))[.modificationDate] as! Date
        try write(child, "after!")
        try fm.setAttributes([.modificationDate: originalTime], ofItemAtPath: child)
        expect(DeletionPlan.Metadata.read(changed + "/.factory") == parentIdentity,
               "The deep-child fixture keeps the reviewed root's metadata unchanged")
        expect(apply(changedPlan, changed).removed == 0 && fm.fileExists(atPath: child),
               "Subtree ctime detects same-size child edits even when mtime is restored")

        let replaced = try home("replaced-root")
        try write(replaced + "/.factory/file")
        let replacedPlan = preview("factory", replaced)
        try fm.moveItem(atPath: replaced + "/.factory", toPath: replaced + "/original")
        try write(replaced + "/.factory/replacement")
        expect(apply(replacedPlan, replaced).removed == 0, "A replaced root cannot inherit confirmation")

        let alias = try home("root-alias")
        let outside = fixture + "/outside-alias"
        try write(outside + "/precious")
        try fm.createSymbolicLink(atPath: alias + "/.factory", withDestinationPath: outside)
        let aliasPlan = preview("factory", alias)
        expect(aliasPlan.items.isEmpty && aliasPlan.retainedPaths.contains(alias + "/.factory"),
               "A root alias cannot authorize moving its destination")
        let parentAlias = try home("parent-alias")
        try write(parentAlias + "/.config/opencode/opencode.json", "{}")
        let parentAliasPlan = preview("opencode", parentAlias)
        try fm.moveItem(atPath: parentAlias + "/.config", toPath: parentAlias + "/original-config")
        try write(outside + "/opencode/precious")
        try fm.createSymbolicLink(atPath: parentAlias + "/.config", withDestinationPath: outside)
        expect(apply(parentAliasPlan, parentAlias).removed == 0
               && fm.fileExists(atPath: outside + "/opencode/precious"),
               "A parent replaced by a symlink cannot redirect the Trash operation")

        let linked = try home("internal-link")
        try write(linked + "/.factory/settings.json", "{}")
        try fm.createSymbolicLink(atPath: linked + "/.factory/external-link", withDestinationPath: outside)
        let linkedResult = apply(preview("factory", linked), linked)
        expect(linkedResult.removed == 1 && fm.fileExists(atPath: outside + "/precious"),
               "Internal symlinks move as links without traversing their external targets")

        let whitelist = try home("whitelist")
        try write(whitelist + "/.factory/deep/keep-secret")
        try write(whitelist + "/.config/mole/whitelist", whitelist + "/.*/*/keep*\n")
        expect(preview("factory", whitelist).items.isEmpty,
               "A wildcard matching only a nested child protects the entire root")
        try Data([0xff, 0xfe]).write(to: URL(fileURLWithPath: whitelist + "/.config/mole/whitelist"))
        expect(preview("factory", whitelist).items.isEmpty, "Unreadable policy fails closed")
        let lateWhitelist = try home("late-whitelist")
        try write(lateWhitelist + "/.factory/file")
        let latePlan = preview("factory", lateWhitelist)
        try write(lateWhitelist + "/.config/mole/whitelist", lateWhitelist + "/.factory\n")
        expect(apply(latePlan, lateWhitelist).removed == 0,
               "Protection added after preview is checked again at execution")

        let shared = try home("shared-owner")
        try write(shared + "/.codeium/windsurf/cache/file")
        expect(preview("devin", shared).items.isEmpty, "Another product's retained data keeps a shared root")
        try executable(shared + "/.local/bin/windsurf")
        let both = AgentRemovalService.plan(agentIDs: ["devin", "windsurf"], home: shared, presence: context(shared))
        expect(both.items.isEmpty,
               "Selecting multiple products cannot hide an installed owner of their shared root")

        let skill = try home("shared-skill")
        try write(skill + "/.factory/skills/used/SKILL.md")
        try fm.createDirectory(atPath: skill + "/.agents/skills", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: skill + "/.agents/skills/shared", withDestinationPath: skill + "/.factory/skills/used")
        expect(preview("factory", skill).items.isEmpty,
               "A shared Skill link outside the product keeps its complete root")

        let declaration = try home("declared-skill")
        try write(declaration + "/.factory/skills/used/SKILL.md")
        let declaredPath = declaration + "/.factory/skills/used/SKILL.md"
        try write(declaration + "/.codex/config.toml", "[[skills.config]]\npath = \"" + declaredPath + "\"\nenabled = true\n")
        expect(preview("factory", declaration).items.isEmpty,
               "A configured Skill consumer outside the product keeps its root")

        let mcp = try home("shared-mcp")
        try executable(mcp + "/.factory/mcp-server")
        let config: [String: Any] = ["mcpServers": ["shared": ["command": mcp + "/.factory/mcp-server"]]]
        try write(mcp + "/.claude.json", String(data: JSONSerialization.data(withJSONObject: config), encoding: .utf8)!)
        expect(preview("factory", mcp).items.isEmpty, "A shared MCP executable keeps its product root")
        let scriptMCP = try home("shared-mcp-script")
        try write(scriptMCP + "/.factory/server.py")
        let scriptConfig: [String: Any] = ["mcpServers": ["shared": ["command": "python3", "args": [scriptMCP + "/.factory/server.py"]]]]
        try write(scriptMCP + "/.claude.json", String(data: JSONSerialization.data(withJSONObject: scriptConfig), encoding: .utf8)!)
        expect(preview("factory", scriptMCP).items.isEmpty,
               "A shared MCP script is protected even when it is not a separately uninstallable package")
        let escapedTOML = try home("escaped-toml-mcp")
        try write(escapedTOML + "/.factory/server.py")
        let escapedScript = (escapedTOML + "/.factory/server.py").replacingOccurrences(of: "/", with: "\\u002f")
        try write(escapedTOML + "/.codex/config.toml",
                  "[mcp_servers.shared]\ncommand = \"python3\"\nargs = [\"" + escapedScript + "\"]\n")
        expect(preview("factory", escapedTOML).items.isEmpty,
               "TOML unicode-escaped script paths protect their decoded product root")
        let escapedJSON = try home("escaped-jsonc-mcp")
        try write(escapedJSON + "/.factory/server.py")
        let escapedJSONScript = (escapedJSON + "/.factory/server.py").replacingOccurrences(of: "/", with: "\\u002f")
        try write(escapedJSON + "/.config/opencode/opencode.jsonc",
                  "{ // JSONC\n\"mcp\": {\"shared\": {\"command\": \"python3\", \"args\": [\"" + escapedJSONScript + "\"]}}}\n")
        expect(preview("factory", escapedJSON).items.isEmpty,
               "JSONC comments and unicode escapes cannot hide shared script ownership")
        let nestedEnv = try home("escaped-nested-env-mcp")
        try write(nestedEnv + "/.factory/server.py")
        let escapedEnvScript = (nestedEnv + "/.factory/server.py").replacingOccurrences(of: "/", with: "\\u002f")
        try write(nestedEnv + "/.codex/config.toml",
                  "[mcp_servers.shared]\ncommand = \"python3\"\n[mcp_servers.shared.env]\nSCRIPT = \"" + escapedEnvScript + "\"\n")
        expect(preview("factory", nestedEnv).items.isEmpty,
               "Nested MCP environment values are decoded before shared-path checks")
        let goose = try home("goose-readonly-mcp")
        try write(goose + "/.factory/server.py")
        try write(goose + "/.config/goose/config.yaml",
                  "extensions:\n  shared:\n    enabled: true\n    type: stdio\n    cmd: python3\n    args: [\"" + goose + "/.factory/server.py\"]\n")
        expect(preview("factory", goose).items.isEmpty,
               "Read-only Goose YAML references protect data despite having no editable MCP source")
        let escapedSpace = try home("yaml-escaped-space")
        try write(escapedSpace + "/.factory/server.py")
        let spaceScript = (escapedSpace + "/.factory/server.py").replacingOccurrences(of: " ", with: "\\ ")
        try write(escapedSpace + "/.config/goose/config.yaml",
                  "extensions:\n  shared:\n    cmd: python3\n    args: [\"" + spaceScript + "\"]\n")
        expect(preview("factory", escapedSpace).items.isEmpty,
               "YAML escaped spaces cannot hide a shared root with spaces in its path")
        for escape in ["\\x2f", "\\u002f", "\\U0000002f"] {
            let yaml = try home("yaml-escaped-" + UUID().uuidString)
            try write(yaml + "/.factory/server.py")
            let script = (yaml + "/.factory/server.py").replacingOccurrences(of: "/", with: escape)
            try write(yaml + "/.config/goose/config.yaml", "extensions:\n  shared:\n    cmd: python3\n    args: [\"" + script + "\"]\n")
            expect(preview("factory", yaml).items.isEmpty,
                   "YAML escaped path separators protect their decoded root: " + escape)
        }
        let continueConfig = try home("continue-multifile-mcp")
        try write(continueConfig + "/.factory/server.py")
        try write(continueConfig + "/.continue/mcpServers/local.yaml",
                  "name: shared\ncommand: python3\nargs: [\"" + continueConfig + "/.factory/server.py\"]\n")
        expect(preview("factory", continueConfig).items.isEmpty,
               "Known Continue multi-file MCP sources are included in read-only shared-reference protection")
        let quotedAlias = try home("yaml-quoted-alias")
        try write(quotedAlias + "/.factory/server.py")
        try fm.createSymbolicLink(atPath: quotedAlias + "/alias\"folder", withDestinationPath: quotedAlias + "/.factory")
        let quotedArguments = try JSONSerialization.data(withJSONObject: [quotedAlias + "/alias\"folder/server.py"])
        try write(quotedAlias + "/.config/goose/config.yaml",
                  "extensions:\n  shared:\n    cmd: python3\n    args: " + String(data: quotedArguments, encoding: .utf8)! + "\n")
        expect(preview("factory", quotedAlias).items.isEmpty,
               "Escaped quotes in a YAML path alias do not hide its shared physical target")
        let secret = try home("credentials-not-reference-source")
        try write(secret + "/.factory/file")
        try write(secret + "/.config/goose/secrets.yaml")
        try Data([0xff, 0xfe]).write(to: URL(fileURLWithPath: secret + "/.config/goose/secrets.yaml"))
        expect(preview("factory", secret).items.map(\.record) == [secret + "/.factory"],
               "Credential files are not read as configuration reference sources")
        let aliasedConfig = try home("aliased-mcp-config")
        try write(aliasedConfig + "/.factory/file")
        try write(aliasedConfig + "/external-config", "{}")
        try fm.createSymbolicLink(atPath: aliasedConfig + "/.claude.json", withDestinationPath: aliasedConfig + "/external-config")
        expect(preview("factory", aliasedConfig).items.isEmpty,
               "Shared configuration symlinks fail closed without reading the destination")
        let fifoConfig = try home("fifo-mcp-config")
        try write(fifoConfig + "/.factory/file")
        expect(mkfifo(fifoConfig + "/.claude.json", 0o600) == 0, "Create a fixture-only FIFO configuration")
        let fifoStarted = Date()
        expect(preview("factory", fifoConfig).items.isEmpty && Date().timeIntervalSince(fifoStarted) < 2,
               "Nonblocking configuration reads reject FIFO replacements without hanging")
        let unknownMCP = try home("unknown-mcp")
        try write(unknownMCP + "/.factory/file")
        try write(unknownMCP + "/.claude.json", "{")
        expect(preview("factory", unknownMCP).items.isEmpty, "Unparseable external registrations keep unknown shared content")
        let emptyMCP = try home("empty-mcp")
        try write(emptyMCP + "/.factory/file")
        try write(emptyMCP + "/.gemini/antigravity/mcp_config.json", " \n\t")
        expect(preview("factory", emptyMCP).items.map(\.record) == [emptyMCP + "/.factory"],
               "A readable empty MCP placeholder proves there are no shared registrations")

        let expansion = try home("no-expansion")
        try write(expansion + "/.config/opencode/opencode.json", "{}")
        let expansionPlan = preview("opencode", expansion)
        try write(expansion + "/.cache/opencode/new-cache")
        let expansionResult = apply(expansionPlan, expansion)
        expect(expansionResult.removedPaths == [expansion + "/.config/opencode"]
               && fm.fileExists(atPath: expansion + "/.cache/opencode/new-cache"),
               "Execution cannot expand the confirmed roots with newly discovered data")

        let noOp = try home("no-op-trash")
        try write(noOp + "/.factory/file")
        let noOpResult = AgentRemovalService.execute(preview("factory", noOp), running: idle, home: noOp,
            presence: context(noOp), core: availableCore, trashHandler: { _ in })
        expect(noOpResult.failed == 1 && noOpResult.removed == 0 && !noOpResult.retainedPaths.isEmpty,
               "A no-op Trash handler cannot report successful removal")

        let generic = try home("generic-shared")
        try write(generic + "/.agents/skills/custom/SKILL.md")
        expect(preview("shared", generic).items.isEmpty, "Shared resource collections cannot grant product removal authority")
        expect(AgentRemovalService.plan(agentIDs: ["factory"], home: "/").items.isEmpty,
               "The filesystem root cannot act as a removable user home")
        if geteuid() == 0 {
            let foreign = try home("foreign-owned-child")
            try write(foreign + "/.factory/plugins/marketplaces/fixture")
            expect(chown(foreign + "/.factory/plugins", 501, 20) == 0
                   && chown(foreign + "/.factory/plugins/marketplaces", 501, 20) == 0,
                   "Create readable fixture children with a different owner")
            let foreignResult = apply(preview("factory", foreign), foreign)
            expect(foreignResult.removedPaths == [foreign + "/.factory"],
                   "Readable installer-owned children can move with their user-owned exclusive root")
        } else {
            print("SKIP: foreign-owned child chown fixture requires root; root ownership guard and uid/gid fingerprint inspected")
        }
        let wrongHome = try home("wrong-home")
        let wrongHomeResult = AgentRemovalService.execute(preview("factory", noOp), running: idle,
            home: wrongHome, presence: context(wrongHome), core: availableCore, trashHandler: trash)
        expect(wrongHomeResult.removed == 0, "A plan cannot be replayed against another home")

        if AgentCatalog.definitions.contains(where: { $0.id == "hermes" }) {
            let hermes = try home("hermes")
            try write(hermes + "/.hermes/config.yaml", "fixture: true")
            try write(hermes + "/.hermes/sessions/history.jsonl")
            let result = apply(preview("hermes", hermes), hermes)
            expect(result.removedPaths == [hermes + "/.hermes"], "Hermes uses the same complete-root removal policy")
        }
        print("PASS: AgentRemovalService \(assertions) assertions; all Trash moves stayed inside disposable fixtures")
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fatalError("FAIL: " + message) }
    }
}
