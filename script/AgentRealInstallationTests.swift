import Foundation

/// Opt-in network integration: install two real packages into a disposable home,
/// then let the production service choose and run the real scoped npm uninstall.
@main struct AgentRealInstallationTests {
    static func main() throws {
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard fixture.lastPathComponent.hasPrefix(".agent-cli-fixture."), CommandLine.arguments.count == 4 else {
            throw NSError(domain: "UnsafeFixture", code: 1)
        }
        let home = fixture.appendingPathComponent("home").path
        let prefix = home + "/.npm-global"
        let bin = prefix + "/bin"
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        // Copy the runtime instead of creating a link to a real installation.
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[3]).resolvingSymlinksInPath(),
                        to: URL(fileURLWithPath: bin + "/node"))
        let npm = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath().path
        func run(_ executable: String, _ arguments: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            p.currentDirectoryURL = fixture
            p.environment = ["HOME": home, "PATH": bin + ":/usr/bin:/bin:/usr/sbin:/sbin",
                "npm_config_cache": fixture.path + "/npm-cache", "npm_config_userconfig": home + "/.npmrc",
                "npm_config_globalconfig": prefix + "/etc/npmrc", "npm_config_audit": "false",
                "npm_config_fund": "false", "npm_config_ignore_scripts": "false"]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw NSError(domain: "PackageCommand", code: Int(p.terminationStatus)) }
        }
        try run(bin + "/node", [npm, "install", "--global", "--prefix", prefix,
            "--include=optional", "npm@10.9.2", "@openai/codex", "@anthropic-ai/claude-code"])
        try run(bin + "/npm", ["list", "--global", "--prefix", prefix, "--depth=0"])
        try run(bin + "/codex", ["--version"])
        try run(bin + "/claude", ["--version"])
        let sentinel = home + "/must-keep.txt"
        try Data("unrelated user data".utf8).write(to: URL(fileURLWithPath: sentinel))
        let context = AgentPresenceContext(applicationDirs: [], searchPath: [bin])
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        for id in ["codex", "claude-code"] {
            let agent = AgentCatalog.definitions.first { $0.id == id }!
            let matches = AgentCLIService.installations(for: agent, home: home, presence: context)
                .filter { $0.manager == .npm && $0.managedPaths.allSatisfy { $0.hasPrefix(prefix + "/") } }
            guard matches.count == 1, let installation = matches.first,
                  installation.managerExecutable == bin + "/npm" else {
                throw NSError(domain: "InstallationDetection:" + id, code: 1)
            }
            let blocked = AgentCLIService.uninstall(installation, home: home,
                running: RunningApplicationSnapshot(processNames: [agent.owners.first!]),
                permanent: true, core: core)
            guard !blocked.succeeded, installation.managedPaths.allSatisfy(fm.fileExists(atPath:)) else {
                throw NSError(domain: "RunningGuard:" + id, code: 1)
            }
            let outcome = AgentCLIService.uninstall(installation, home: home,
                running: RunningApplicationSnapshot(), permanent: true, core: core)
            guard outcome.succeeded,
                  installation.managedPaths.allSatisfy({ !fm.fileExists(atPath: $0) }),
                  installation.executablePaths.allSatisfy({ !AgentCatalog.exists($0) }),
                  fm.fileExists(atPath: sentinel), fm.fileExists(atPath: bin + "/npm"),
                  fm.fileExists(atPath: bin + "/node") else {
                throw NSError(domain: "RealUninstall:" + id + ":" + outcome.messages.joined(separator: ";"), code: 1)
            }
            print("PASS: real " + id + " npm installation detected, running-owner refusal, scoped uninstall, launcher removal, unrelated data/runtime/manager preserved")
        }
        try run(bin + "/npm", ["list", "--global", "--prefix", prefix, "--depth=0"])
    }
}
