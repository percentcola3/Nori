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
        precondition(SoftwareUpdateExecution.toolCommand(npm, latest: "v2.0", home: root.path, executable: manager.path) != nil,
                     "A stable version with a v prefix retains the existing update contract")
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
        // Update and uninstall must share the captured manager, environment
        // and root probe across every supported package manager.
        let pairedTools = [npm, tool(.pnpm, name: "@fixture/tool",
            path: root.path + "/pnpm/global/5/node_modules/@fixture/tool")]
            + cases.map { tool($0.0, name: $0.1, path: $0.2) }
        for var installation in pairedTools {
            installation.managerExecutable = manager.path
            let update = SoftwareUpdateExecution.toolCommand(installation, latest: "2.0", home: root.path)!
            let remove = CLIManagedCommands.command(installation, action: .uninstall, home: root.path)!
            precondition(update.executable == remove.executable && update.environment == remove.environment
                         && update.expectedRoot == remove.expectedRoot && update.rootProbe == remove.rootProbe,
                         "Both actions must bind the same installation, not the active PATH installation")
            precondition(remove.environment["PATH"]?.hasPrefix(manager.deletingLastPathComponent().path + ":") == true
                         && remove.environment["HOME"] == root.path)
        }
        precondition(command.matchesExpectedRoot("  " + global.path + "\n"))
        for invalidRoot in ["relative/root", "", "/wrong/root", global.path + "-other"] {
            precondition(!command.matchesExpectedRoot(invalidRoot), "Root checks reject relative, empty and neighboring installations")
        }
        var privatePackage = npm
        privatePackage.supportsPublicRegistryUpdates = false
        privatePackage.managerExecutable = manager.path
        precondition(SoftwareUpdateExecution.toolCommand(privatePackage, latest: "2.0", home: root.path) == nil
                     && CLIManagedCommands.command(privatePackage, action: .uninstall, home: root.path) != nil,
                     "Registry update permission does not change a private package's uninstall route")
        for version in ["--latest", "2.0;touch injected", "2.0\n--force"] {
            precondition(CLIManagedCommands.command(npm, action: .update(version: version), home: root.path,
                executable: manager.path) == nil, "The shared builder rejects malformed version selectors")
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
        precondition(!SoftwareUpdateProcesses.scriptBelongs([scope.roots[0] + "/spoofed-argv-zero", "/other/script.js"], to: scope),
                     "Mutable argv[0] cannot replace physical executable ownership")
        for option in ["--watch-path", "--icu-data-dir", "--openssl-config", "--redirect-warnings", "--diagnostic-dir"] {
            precondition(!SoftwareUpdateProcesses.scriptBelongs(["node", option, scope.roots[0], "/other/script.js"], to: scope),
                         "A Node option's path value is not the running script")
            precondition(SoftwareUpdateProcesses.scriptBelongs(["node", option, "/other/config", scope.roots[0] + "/cli.js"], to: scope))
        }
        precondition(!SoftwareUpdateProcesses.scriptBelongs(["node", "--unknown-value-option", scope.roots[0], "/other/script.js"], to: scope),
                     "Unknown option syntax cannot authorize shutdown of an unrelated script")
        precondition(!SoftwareUpdateProcesses.scriptBelongs(["python3", "--check-hash-based-pycs", scope.roots[0], "/other/script.py"], to: scope))
        precondition(!SoftwareUpdateProcesses.scriptBelongs(["bash", "--rcfile", scope.roots[0], "/other/script.sh"], to: scope))
        precondition(!scope.contains(global.path + "/@fixture/tool-other/cli.js"))
        for argv in [["python3", "-c", scope.roots[0] + "/data"],
                     ["python3", "-mfixture", scope.roots[0] + "/data"],
                     ["python3", "-Bimfixture", scope.roots[0] + "/data"],
                     ["node", "--eval=" + scope.roots[0] + "/data"],
                     ["node", "-ie", scope.roots[0] + "/data"]] {
            precondition(!SoftwareUpdateProcesses.scriptBelongs(argv, to: scope),
                         "Inline and module execution cannot inherit ownership from arbitrary data argv")
        }
        for shell in ["sh", "bash", "zsh", "fish"] {
            precondition(SoftwareUpdateProcesses.scriptBelongs([shell, scope.roots[0] + "/tool.sh"], to: scope))
            precondition(SoftwareUpdateProcesses.scriptBelongs([shell, "tool.sh"], to: scope, directory: scope.roots[0]))
            precondition(!SoftwareUpdateProcesses.scriptBelongs([shell, "/other/script.sh", scope.roots[0] + "/data"], to: scope))
            precondition(!SoftwareUpdateProcesses.scriptBelongs([shell, "-lc", scope.roots[0] + "/data"], to: scope))
            precondition(!SoftwareUpdateProcesses.scriptBelongs([shell, "-s", scope.roots[0] + "/data"], to: scope))
        }
        precondition(SoftwareUpdateProcesses.scriptBelongs(["bash", "-e", scope.roots[0] + "/tool.sh"], to: scope))
        precondition(SoftwareUpdateProcesses.scriptBelongs(["java", "-Xmx512m", "-jar", scope.roots[0] + "/tool.jar"], to: scope))
        precondition(SoftwareUpdateProcesses.scriptBelongs(["java", "--source", "21", "Main.java"], to: scope, directory: scope.roots[0]))
        precondition(!SoftwareUpdateProcesses.scriptBelongs(["java", "-cp", scope.roots[0] + "/data.jar", "OtherMain"], to: scope))
        precondition(!SoftwareUpdateProcesses.scriptBelongs(["java", "-jar", "/other/tool.jar", scope.roots[0] + "/data"], to: scope))
        precondition(!SoftwareUpdateProcesses.scriptBelongs(["java", "-m", "fixture/module", scope.roots[0] + "/data"], to: scope))
        precondition(!SoftwareUpdateProcesses.scriptBelongs(["java", "--patch-module", "fixture=tools.java", "OtherMain"],
            to: scope, directory: scope.roots[0]), "A Java option value ending in .java is not a source-file entry point")
        precondition(!SoftwareUpdateProcesses.scriptBelongs(["java", "--unknown-value-option", scope.roots[0] + "/data.java", "OtherMain"], to: scope))
        precondition(!SoftwareUpdateProcesses.scriptBelongs(["java", "-Dconfig=" + scope.roots[0] + "/data", "-jar", "/other/tool.jar"], to: scope))

        func sample(_ pid: Int32, path: String, name: String = "same-name", start: UInt64 = 100,
                    uid: UInt32 = getuid(), parent: Int32 = 1) -> ProcessSample {
            .init(identity: .init(pid: pid, startTime: start, ppid: parent, uid: uid), name: name, path: path,
                  cpuPercent: 0, residentBytes: 0, isZombie: false, isExiting: false, elapsed: 0)
        }
        var boundNpm = npm
        boundNpm.executablePaths = [root.path + "/prefix/bin/tool"]
        let secondRoot = root.path + "/native-agent/version"
        boundNpm.agentInstallation = .init(id: "fixture", agentID: "fixture", name: "same-name",
            executablePaths: [root.path + "/extra/bin/tool"], managedPaths: [secondRoot], manager: .native,
            managerExecutable: nil, packageName: nil, identities: [:], detail: "fixture")
        let boundScope = SoftwareUpdateProcesses.Scope.tool(boundNpm)
        precondition([npm.path + "/cli.js", boundNpm.executablePaths[0], secondRoot + "/tool",
                      boundNpm.agentInstallation!.executablePaths[0]].allSatisfy(boundScope.contains),
                     "All captured package roots and launchers belong to the installation")
        let desktop = sample(22201, path: "/Applications/SameName.app/Contents/MacOS/tool")
        let otherPrefix = sample(22202, path: otherNpm.path + "/tool")
        let selected = sample(22203, path: secondRoot + "/tool")
        precondition(SoftwareUpdateProcesses.probe(boundScope, samples: [desktop, otherPrefix, selected]).processes == [selected],
                     "A desktop app or another installation with the same process name is outside the CLI scope")
        let formulaScope = SoftwareUpdateProcesses.Scope.tool(brewBefore)
        precondition(formulaScope.contains(brewBefore.installationRoot + "/2.0/bin/fixture")
                     && !formulaScope.contains(root.path + "/Cellar/fixture-other/2.0/bin/fixture"),
                     "Homebrew owns its complete formula root without neighboring packages")
        var multipleBins = tool(.cargo, name: "fixture", path: root.path + "/cargo/bin/first")
        multipleBins.executablePaths = [multipleBins.path, root.path + "/cargo/bin/second"]
        let cargoScope = SoftwareUpdateProcesses.Scope.tool(multipleBins)
        precondition(cargoScope.contains(multipleBins.executablePaths[1])
                     && !cargoScope.contains(root.path + "/cargo/bin/unrelated"),
                     "Cargo packages own all recorded binaries, never the entire shared bin directory")
        for (interpreter, argv) in [("/bin/sh", ["sh", npm.path + "/tool.sh"]),
                                    ("/usr/bin/java", ["java", "-jar", npm.path + "/tool.jar"])] {
            let process = sample(22204, path: interpreter)
            precondition(SoftwareUpdateProcesses.probe(SoftwareUpdateProcesses.Scope.tool(npm), samples: [process],
                arguments: { _ in argv }, workingDirectory: { _ in nil }).processes == [process])
        }
        let unreadable = sample(22205, path: "/usr/local/bin/node")
        precondition(!SoftwareUpdateProcesses.probe(boundScope, samples: [unreadable], arguments: { _ in nil }).isComplete,
                     "Unknown interpreter argv cannot be treated as a stopped installation")
        precondition(SoftwareUpdateProcesses.probe(boundScope, samples: [unreadable],
            arguments: { _ in [npm.path + "/spoofed-argv-zero", "/other/script.js"] }).processes.isEmpty,
                     "Physical interpreter ownership must survive a spoofed argv[0]")
        precondition(SoftwareUpdateProcesses.probe(boundScope, samples: [unreadable],
            arguments: { _ in ["custom-name", npm.path + "/cli.js"] }).processes == [unreadable],
                     "Interpreter aliases still use their first physical script argument")

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

        // Inject process state and signals for fault tests; no user process is stopped.
        let stoppedTarget = sample(22301, path: npm.path + "/native")
        let unrelatedTarget = sample(22302, path: otherNpm.path + "/native")
        var visible = [stoppedTarget, unrelatedTarget]
        var signals: [(Int32, Int32)] = []
        var closeEnvironment = SoftwareUpdateProcesses.Environment()
        closeEnvironment.sample = { visible }
        closeEnvironment.current = { identity in visible.first { $0.identity == identity } }
        closeEnvironment.signal = { pid, signal in
            signals.append((pid, signal))
            if signal == SIGKILL { visible.removeAll { $0.pid == pid } }
            return true
        }
        closeEnvironment.pause = {}
        let escalated = await SoftwareUpdateProcesses.close(SoftwareUpdateProcesses.Scope.tool(npm), ownPID: Int32.max,
            environment: closeEnvironment, stillCurrent: { true })
        precondition(escalated && visible == [unrelatedTarget] && signals.count == 16
                     && signals.prefix(15).allSatisfy { $0.0 == stoppedTarget.pid && $0.1 == SIGTERM }
                     && signals.last!.0 == stoppedTarget.pid && signals.last!.1 == SIGKILL,
                     "Only the selected installation receives TERM, then bounded KILL escalation")
        visible = [stoppedTarget, unrelatedTarget]; signals = []
        var reusedEnvironment = closeEnvironment
        reusedEnvironment.current = { _ in sample(stoppedTarget.pid, path: stoppedTarget.path, start: 200) }
        let reusedRefused = await SoftwareUpdateProcesses.close(SoftwareUpdateProcesses.Scope.tool(npm), ownPID: Int32.max,
            environment: reusedEnvironment, stillCurrent: { true })
        precondition(!reusedRefused && signals.isEmpty, "PID reuse is rejected immediately before a signal")
        var changedExecutable = closeEnvironment
        changedExecutable.current = { _ in sample(stoppedTarget.pid, path: unrelatedTarget.path) }
        let changedRefused = await SoftwareUpdateProcesses.close(SoftwareUpdateProcesses.Scope.tool(npm), ownPID: Int32.max,
            environment: changedExecutable, stillCurrent: { true })
        precondition(!changedRefused && signals.isEmpty, "An exec into another installation revokes shutdown ownership")
        var foreignUID = closeEnvironment
        foreignUID.ownUID = stoppedTarget.uid &+ 1
        let foreignRefused = await SoftwareUpdateProcesses.close(SoftwareUpdateProcesses.Scope.tool(npm), ownPID: Int32.max,
            environment: foreignUID, stillCurrent: { true })
        precondition(!foreignRefused && signals.isEmpty, "Shutdown never signals another user's process")
        var deniedSignal = closeEnvironment
        deniedSignal.signal = { pid, signal in signals.append((pid, signal)); return false }
        let signalRefused = await SoftwareUpdateProcesses.close(SoftwareUpdateProcesses.Scope.tool(npm), ownPID: Int32.max,
            environment: deniedSignal, stillCurrent: { true })
        precondition(!signalRefused && signals.count == 1, "A permission failure stops before removal")
        signals = []
        let staleRefused = await SoftwareUpdateProcesses.close(SoftwareUpdateProcesses.Scope.tool(npm), ownPID: Int32.max,
            environment: closeEnvironment, stillCurrent: { false })
        precondition(!staleRefused && signals.isEmpty, "Changed installation identity invalidates the accepted shutdown")
        visible = [sample(stoppedTarget.pid, path: stoppedTarget.path, parent: 22300)]
        let ownTreeRefused = await SoftwareUpdateProcesses.close(SoftwareUpdateProcesses.Scope.tool(npm), ownPID: 22300,
            environment: closeEnvironment, stillCurrent: { true })
        precondition(!ownTreeRefused && signals.isEmpty, "The current worker's process tree cannot be closed")
        var unavailableSnapshot = closeEnvironment
        unavailableSnapshot.sample = nil
        unavailableSnapshot.snapshot = { .init(processes: [], isComplete: false) }
        let snapshotRefused = await SoftwareUpdateProcesses.close(SoftwareUpdateProcesses.Scope.tool(npm), ownPID: Int32.max,
            environment: unavailableSnapshot, stillCurrent: { true })
        precondition(!snapshotRefused && signals.isEmpty, "An unreadable native process table is never treated as idle")
        visible = [stoppedTarget]
        var incompleteAfterClosure = closeEnvironment
        incompleteAfterClosure.sample = nil
        incompleteAfterClosure.snapshot = { .init(processes: visible, isComplete: !visible.isEmpty) }
        let finalSnapshotRefused = await SoftwareUpdateProcesses.close(SoftwareUpdateProcesses.Scope.tool(npm), ownPID: Int32.max,
            environment: incompleteAfterClosure, stillCurrent: { true })
        precondition(!finalSnapshotRefused && visible.isEmpty && signals.count == 16,
                     "The empty check after shutdown still requires a complete native snapshot")

        // Only owned fixture executables receive a signal; no installed tool is updated.
        let binaries = root.appendingPathComponent("binaries")
        try fm.createDirectory(at: binaries, withIntermediateDirectories: true)
        let target = binaries.appendingPathComponent("target")
        let other = root.appendingPathComponent("other")
        try OwnedProcessFixture.makeSleeper(at: target)
        try OwnedProcessFixture.makeSleeper(at: other)
        let a = Process(), b = Process()
        a.executableURL = target; a.arguments = ["20"]
        b.executableURL = other; b.arguments = ["20"]
        try a.run(); try b.run()
        defer {
            for process in [a, b] where process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        precondition(SoftwareUpdateProcesses.commandArguments(a.processIdentifier)?.last == "20")
        // An updater can replace a still-running executable. Only unlink the
        // test-owned sleeper; its kernel executable prefix must remain usable.
        try fm.removeItem(at: target)
        let nativeScope = SoftwareUpdateProcesses.Scope(roots: [binaries.path])
        let before = SoftwareUpdateProcesses.probe(nativeScope)
        precondition(before.isComplete && before.processes.map(\.pid) == [a.processIdentifier])
        precondition(before.processes.first?.path == target.path,
                     "An unlinked running executable keeps its kernel-owned launch path")
        let closed = await SoftwareUpdateProcesses.close(nativeScope, ownPID: Int32.max, stillCurrent: { true })
        a.waitUntilExit()
        precondition(closed && !a.isRunning && b.isRunning)
        let gone = SoftwareUpdateProcesses.probe(nativeScope)
        precondition(gone.isComplete && gone.processes.isEmpty, "An idle tool proceeds without needing a close prompt")
        print("Software update execution: fixed manager commands, exact install roots, shell/Java script ownership, scoped TERM/KILL, PID reuse, permission failures and unrelated-process isolation passed")
    }
}
