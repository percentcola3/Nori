import Darwin
import Foundation

@MainActor
private final class CLIWorkflowTrace {
    var identities: [String: String] = [:]
    var probes: [SoftwareUpdateProcesses.Probe] = []
    var events: [String] = []
    var probeCount = 0
    var probeHook: ((Int) -> Void)?
    var closeHook: (() -> Void)?
    var closeSucceeded = true
    var signalAttempts = 0
    var receivedSnapshot: RunningApplicationSnapshot?
    var removal = CLIUninstallService.Outcome(succeeded: true, messages: ["Fixture removed"], reclaimedBytes: 7)

    var environment: CLIUninstallWorkflow.Environment {
        .init(probe: { _ in
            self.events.append("probe")
            self.probeCount += 1
            precondition(!self.probes.isEmpty, "The workflow exceeded its expected probe count")
            let result = self.probes.removeFirst()
            await Task.yield()
            self.probeHook?(self.probeCount)
            return result
        }, close: { _, stillCurrent in
            self.events.append("close")
            guard stillCurrent() else { return false }
            await Task.yield()
            self.closeHook?()
            guard stillCurrent() else { return false }
            self.signalAttempts += 1 // Injected counter only; no OS signal is sent.
            return self.closeSucceeded
        }, remove: { _, running in
            self.events.append("remove")
            self.receivedSnapshot = running
            return self.removal
        }, identity: { self.identities[$0] })
    }
}

@main
struct CLIUninstallWorkflowTests {
    @MainActor
    static func main() async throws {
        let idle = SoftwareUpdateProcesses.Probe(processes: [], isComplete: true)
        let unknown = SoftwareUpdateProcesses.Probe(processes: [], isComplete: false)
        let tool = makeTool(.npm, path: "/fixture/prefix/lib/node_modules/@fixture/build")
        let original = "captured-installation"
        let process = sample(path: tool.path + "/cli.js")
        let active = SoftwareUpdateProcesses.Probe(processes: [process], isComplete: true)
        func trace(_ probes: [SoftwareUpdateProcesses.Probe]) -> CLIWorkflowTrace {
            let result = CLIWorkflowTrace()
            result.identities[tool.path] = original
            result.probes = probes
            return result
        }
        func execute(_ trace: CLIWorkflowTrace, mayClose: Bool = false) async -> CLIUninstallWorkflow.Result {
            await CLIUninstallWorkflow.execute(tool, identity: original, mayClose: mayClose,
                                               environment: trace.environment)
        }

        let unconfirmed = trace([active])
        let initialResult = await execute(unconfirmed)
        guard case .needsConfirmation(let discovered) = initialResult else {
            preconditionFailure("Running software must require consent before shutdown")
        }
        precondition(discovered.processes == [process] && unconfirmed.events == ["probe"]
                     && unconfirmed.signalAttempts == 0 && unconfirmed.receivedSnapshot == nil)

        let confirmed = trace([active, idle])
        let confirmedResult = await execute(confirmed, mayClose: true)
        expectFinished(confirmedResult, succeeded: true)
        precondition(confirmed.events == ["probe", "close", "probe", "remove"]
                     && confirmed.signalAttempts == 1)
        precondition(confirmed.receivedSnapshot == RunningApplicationSnapshot(),
                     "The remover receives only the final complete scoped snapshot")

        let noRuntime = trace([idle, idle])
        expectFinished(await execute(noRuntime), succeeded: true)
        precondition(noRuntime.events == ["probe", "probe", "remove"] && noRuntime.signalAttempts == 0)

        let initialUnknown = trace([unknown])
        expectFailed(await execute(initialUnknown, mayClose: true), "cli.uninstall.runtimeUnknown")
        precondition(initialUnknown.events == ["probe"] && initialUnknown.signalAttempts == 0)
        let finalUnknown = trace([idle, unknown])
        expectFailed(await execute(finalUnknown), "cli.uninstall.runtimeUnknown")
        precondition(finalUnknown.receivedSnapshot == nil)

        for identity in [nil, "", "different-installation"] as [String?] {
            let stale = trace([])
            let result = await CLIUninstallWorkflow.execute(tool, identity: identity, mayClose: true,
                                                            environment: stale.environment)
            expectFailed(result, "cli.uninstall.changed")
            precondition(stale.events.isEmpty && stale.signalAttempts == 0)
        }
        let missing = trace([])
        missing.identities[tool.path] = nil
        expectFailed(await execute(missing, mayClose: true), "cli.uninstall.changed")
        precondition(missing.events.isEmpty)
        for changedProbe in [1, 2] {
            let changed = trace([idle, idle])
            changed.probeHook = { index in
                if index == changedProbe { changed.identities[tool.path] = "replaced" }
            }
            expectFailed(await execute(changed), "cli.uninstall.changed")
            precondition(changed.receivedSnapshot == nil && changed.signalAttempts == 0)
        }
        for cancelledProbe in [1, 2] {
            let cancelled = trace([idle, idle])
            cancelled.probeHook = { index in
                if index == cancelledProbe { withUnsafeCurrentTask { $0?.cancel() } }
            }
            let task = Task { @MainActor in await execute(cancelled) }
            expectFailed(await task.value, "cli.uninstall.changed")
            precondition(cancelled.receivedSnapshot == nil && cancelled.signalAttempts == 0,
                         "Cancelling either idle probe must prevent removal")
        }

        let closeRefused = trace([active])
        closeRefused.closeSucceeded = false
        expectFailed(await execute(closeRefused, mayClose: true), "cli.uninstall.closeFailed")
        precondition(closeRefused.events == ["probe", "close"] && closeRefused.receivedSnapshot == nil)
        let changedDuringClose = trace([active])
        changedDuringClose.closeHook = { changedDuringClose.identities[tool.path] = "replaced" }
        expectFailed(await execute(changedDuringClose, mayClose: true), "cli.uninstall.changed")
        precondition(changedDuringClose.signalAttempts == 0 && changedDuringClose.receivedSnapshot == nil)

        for (probes, mayClose) in [([idle, active], false), ([active, active], true)] {
            let newRuntime = trace(probes)
            let result = await execute(newRuntime, mayClose: mayClose)
            guard case .needsConfirmation(let remaining) = result else {
                preconditionFailure("A new or persistent process requires a fresh confirmation")
            }
            precondition(remaining.processes == [process] && newRuntime.receivedSnapshot == nil)
        }
        let removalFailed = trace([idle, idle])
        removalFailed.removal = .init(succeeded: false, messages: ["Owned fixture removal refused"])
        expectFinished(await execute(removalFailed), succeeded: false)

        // Ownership is the installation, across languages and managers. The
        // display name shared by a desktop app does not enlarge that scope.
        for manager in [CommandLineTool.Manager.npm, .pnpm, .homebrew, .pipx, .uv, .cargo, .go] {
            let installation = makeTool(manager, path: "/fixture/\(manager.rawValue)/build")
            let scope = SoftwareUpdateProcesses.Scope.tool(installation)
            let desktop = sample(path: "/Applications/Build.app/Contents/MacOS/build", name: installation.name)
            let cli = sample(path: installation.path + "/bin/build", name: installation.name)
            let fixture = CLIWorkflowTrace()
            fixture.identities[installation.path] = original
            fixture.probes = [
                SoftwareUpdateProcesses.probe(scope, samples: [desktop], arguments: { _ in [] }),
                SoftwareUpdateProcesses.probe(scope, samples: [desktop], arguments: { _ in [] })
            ]
            precondition(SoftwareUpdateProcesses.probe(scope, samples: [desktop, cli], arguments: { _ in [] })
                .processes == [cli], "A same-name desktop process must stay outside CLI ownership")
            let result = await CLIUninstallWorkflow.execute(installation, identity: original, mayClose: false,
                                                            environment: fixture.environment)
            expectFinished(result, succeeded: true)
            precondition(fixture.signalAttempts == 0 && fixture.receivedSnapshot?.processNames.isEmpty == true)
        }

        try await testAgentIdentity(fixture: URL(fileURLWithPath: CommandLine.arguments[1]), idle: idle)
        print("CLI uninstall workflow: consent, scoped ownership, final recheck, identity changes and failure guards passed")
    }

    private static func makeTool(_ manager: CommandLineTool.Manager, path: String) -> CommandLineTool {
        .init(manager: manager, name: "build", version: "1.0", path: path, bytes: 7,
              dependents: [], installedOnRequest: true)
    }

    private static func sample(path: String, name: String = "build") -> ProcessSample {
        .init(identity: .init(pid: 42, startTime: 100, ppid: 1, uid: getuid()), name: name, path: path,
              cpuPercent: 0, residentBytes: 0, isZombie: false, isExiting: false, elapsed: 1)
    }

    private static func expectFailed(_ result: CLIUninstallWorkflow.Result, _ key: String) {
        guard case .failed(let reason) = result else { preconditionFailure("Expected refusal: \(key)") }
        precondition(reason == key)
    }

    private static func expectFinished(_ result: CLIUninstallWorkflow.Result, succeeded: Bool) {
        guard case .finished(let outcome) = result else { preconditionFailure("Expected low-level outcome") }
        precondition(outcome.succeeded == succeeded)
    }

    @MainActor
    private static func testAgentIdentity(fixture: URL, idle: SoftwareUpdateProcesses.Probe) async throws {
        // Read-only discovery of an owned native fixture supplies real captured
        // identities. The workflow's injected remover never deletes its files.
        let home = fixture.appendingPathComponent("home")
        let launcher = home.appendingPathComponent(".local/bin/claude")
        let target = home.appendingPathComponent(".local/share/claude/versions/fixture")
        let fm = FileManager.default
        try fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try fm.createSymbolicLink(at: launcher, withDestinationURL: target)
        let agent = AgentCatalog.definitions.first { $0.id == "claude-code" }!
        let record = AgentCLIService.installations(for: agent, home: home.path,
            presence: .init(applicationDirs: [], searchPath: [launcher.deletingLastPathComponent().path])).first!
        var tool = makeTool(.local, path: launcher.path)
        tool.agentInstallation = record
        tool.executablePaths = record.executablePaths
        let original = record.identities[tool.path]!
        precondition(record.identities.count > 1)
        let valid = CLIWorkflowTrace()
        valid.identities = record.identities
        valid.probes = [idle, idle]
        expectFinished(await CLIUninstallWorkflow.execute(tool, identity: original, mayClose: false,
                                                          environment: valid.environment), succeeded: true)
        for path in record.identities.keys where path != tool.path {
            let changed = CLIWorkflowTrace()
            changed.identities = record.identities
            changed.identities[path] = "replaced-managed-path"
            expectFailed(await CLIUninstallWorkflow.execute(tool, identity: original, mayClose: true,
                environment: changed.environment), "cli.uninstall.changed")
            precondition(changed.events.isEmpty && changed.signalAttempts == 0)
        }
        precondition(fm.fileExists(atPath: launcher.path) && fm.fileExists(atPath: target.path))
    }
}
