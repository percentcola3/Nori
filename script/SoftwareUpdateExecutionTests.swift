import Darwin
import Foundation

@main
struct SoftwareUpdateExecutionTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("commands")
        let manager = root.appendingPathComponent("manager")
        let global = root.appendingPathComponent("prefix/lib/node_modules")
        try fm.createDirectory(at: global, withIntermediateDirectories: true)
        func write(_ text: String) throws {
            try text.write(to: manager, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: manager.path)
        }
        try write("#!/bin/sh\nif [ \"$1\" = root ]; then printf '%s\\n' '\(global.path)'; exit 0; fi\nprintf '%s\\n' \"$@\" > '\(log.path)'\n")
        func tool(_ type: CommandLineTool.Manager, name: String, path: String) -> CommandLineTool {
            .init(manager: type, name: name, version: "1.0", path: path, bytes: 1, dependents: [], installedOnRequest: true)
        }
        let npm = tool(.npm, name: "@fixture/tool", path: global.appendingPathComponent("@fixture/tool").path)
        let command = SoftwareUpdateExecution.toolCommand(npm, latest: "2.0", home: root.path, executable: manager.path)!
        precondition(command.arguments == ["install", "--global", "@fixture/tool@2.0"])
        precondition(command.environment["NPM_CONFIG_PREFIX"] == root.appendingPathComponent("prefix").path)
        var ownedNpm = npm
        ownedNpm.managerExecutable = manager.path
        precondition(SoftwareUpdateExecution.toolCommand(ownedNpm, latest: "2.0", home: root.path)?.executable == manager.path,
                     "Updates use the manager captured during discovery instead of another PATH manager")
        let otherNpm = tool(.npm, name: npm.name, path: root.path + "/another-prefix/lib/node_modules/@fixture/tool")
        precondition(otherNpm.id != npm.id)
        let otherCommand = SoftwareUpdateExecution.toolCommand(otherNpm, latest: "2.0", home: root.path, executable: manager.path)!
        precondition(otherCommand.environment["NPM_CONFIG_PREFIX"] == root.path + "/another-prefix"
                     && otherCommand.expectedRoot == root.path + "/another-prefix/lib/node_modules",
                     "The same scoped package in another prefix gets its own update target")
        let brewBefore = tool(.homebrew, name: "fixture", path: root.path + "/Cellar/fixture/1.0")
        let brewAfter = tool(.homebrew, name: "fixture", path: root.path + "/Cellar/fixture/2.0")
        precondition(brewBefore.id == brewAfter.id, "Formula identity survives an upgrade's version-directory change")
        let pnpmCommand = SoftwareUpdateExecution.toolCommand(tool(.pnpm, name: "fixture-cli",
            path: root.path + "/pnpm/global/5/node_modules/fixture-cli"), latest: "2.0", home: root.path, executable: manager.path)!
        precondition(pnpmCommand.arguments.suffix(2) == ["--global-dir", root.path + "/pnpm/global/5"]
                     && pnpmCommand.expectedRoot == root.path + "/pnpm/global/5/node_modules")
        let ran = await SoftwareUpdateExecution.run(command)
        let recorded = try String(contentsOf: log, encoding: .utf8)
        precondition(ran.succeeded && recorded == "install\n--global\n@fixture/tool@2.0\n")
        try write("#!/bin/sh\nif [ \"$1\" = root ]; then printf '/wrong/root\\n'; exit 0; fi\nprintf 'UNSAFE' > '\(log.path)'\n")
        let refused = await SoftwareUpdateExecution.run(command)
        let afterRefusal = try String(contentsOf: log, encoding: .utf8)
        precondition(!refused.succeeded && afterRefusal != "UNSAFE", "Never update a different global installation")
        let cases: [(CommandLineTool.Manager, String, String, [String])] = [
            (.homebrew, "openjdk@21", "/opt/homebrew/Cellar/openjdk@21/21.0.8", ["upgrade", "--formula", "openjdk@21"]),
            (.pipx, "black", root.path + "/pipx/venvs/black", ["upgrade", "black"]),
            (.uv, "ruff", root.path + "/uv/tools/ruff", ["tool", "upgrade", "ruff"]),
            (.cargo, "ripgrep", root.path + "/cargo/bin/rg", ["install", "ripgrep", "--version", "2.0", "--force", "--root", root.path + "/cargo"])
        ]
        for (type, name, path, expected) in cases {
            precondition(SoftwareUpdateExecution.toolCommand(tool(type, name: name, path: path), latest: "2.0",
                home: root.path, executable: manager.path)?.arguments == expected)
        }
        for name in ["--all", "fixture;touch injected", "bad name"] {
            precondition(SoftwareUpdateExecution.toolCommand(tool(.npm, name: name, path: global.path + "/" + name),
                latest: "2.0", executable: manager.path) == nil)
        }
        precondition(SoftwareUpdateExecution.appCommand(token: "cursor", executable: manager.path)?.arguments
                     == ["upgrade", "--cask", "--greedy", "cursor"])
        precondition(SoftwareUpdateExecution.appCommand(token: "--all", executable: manager.path) == nil)
        let scope = SoftwareUpdateProcesses.Scope(roots: [global.path + "/@fixture/tool"], matchesScripts: true)
        precondition(SoftwareUpdateProcesses.scriptBelongs(["/usr/local/bin/node", scope.roots[0] + "/cli.js"], to: scope))
        precondition(SoftwareUpdateProcesses.scriptBelongs(["node", "cli.js"], to: scope, directory: scope.roots[0]))
        precondition(!SoftwareUpdateProcesses.scriptBelongs(["node", "/other/script.js", "--input", scope.roots[0] + "/data"], to: scope))
        precondition(!SoftwareUpdateProcesses.scriptBelongs(["node", "-r", scope.roots[0] + "/module.js", "/other/script.js"], to: scope))
        precondition(!SoftwareUpdateProcesses.scriptBelongs(["node", "-e", "require('fixture')"], to: scope))
        precondition(!scope.contains(global.path + "/@fixture/tool-other/cli.js"))
        let cloneIdentity = ProcessIdentity(pid: 22222, startTime: 100, ppid: 1, uid: getuid())
        let clone = ProcessSample(identity: cloneIdentity, name: "Browser", path: "/private/code-sign-clone/Browser",
            cpuPercent: 0, residentBytes: 0, isZombie: false, isExiting: false, elapsed: 0)
        var appScope = SoftwareUpdateProcesses.Scope(roots: ["/Applications/Browser.app"])
        appScope.applicationIdentities = [cloneIdentity]
        precondition(SoftwareUpdateProcesses.probe(appScope, samples: [clone]).processes.count == 1,
                     "System app ownership includes code-sign clones without broad path matching")
        let reused = ProcessSample(identity: .init(pid: 22222, startTime: 200, ppid: 1, uid: getuid()), name: clone.name,
            path: clone.path, cpuPercent: 0, residentBytes: 0, isZombie: false, isExiting: false, elapsed: 0)
        precondition(SoftwareUpdateProcesses.probe(appScope, samples: [reused]).processes.isEmpty,
                     "Reused PIDs cannot inherit an old app's close authorization")

        // Only owned fixture executables receive a signal; no installed tool is updated.
        let binaries = root.appendingPathComponent("binaries")
        try fm.createDirectory(at: binaries, withIntermediateDirectories: true)
        let target = binaries.appendingPathComponent("target")
        let other = root.appendingPathComponent("other")
        try fm.copyItem(atPath: "/bin/sleep", toPath: target.path)
        try fm.copyItem(atPath: "/bin/sleep", toPath: other.path)
        let a = Process(), b = Process()
        a.executableURL = target; a.arguments = ["20"]
        b.executableURL = other; b.arguments = ["20"]
        try a.run(); try b.run()
        defer {
            for process in [a, b] where process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let nativeScope = SoftwareUpdateProcesses.Scope(roots: [binaries.path])
        let before = SoftwareUpdateProcesses.probe(nativeScope)
        precondition(before.isComplete && before.processes.map(\.pid) == [a.processIdentifier])
        precondition(SoftwareUpdateProcesses.commandArguments(a.processIdentifier)?.last == "20")
        let closed = await SoftwareUpdateProcesses.close(nativeScope, ownPID: Int32.max, stillCurrent: { true })
        a.waitUntilExit()
        precondition(closed && !a.isRunning && b.isRunning)
        let gone = SoftwareUpdateProcesses.probe(nativeScope)
        precondition(gone.isComplete && gone.processes.isEmpty, "An idle tool proceeds without needing a close prompt")
        print("Software update execution: fixed manager commands, exact install roots, injection refusal, script ownership, unrelated processes, native argv and scoped closure passed")
    }
}
