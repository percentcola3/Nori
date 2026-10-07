import Foundation

/// Package removal verifies process state, dependencies and the captured install
/// root before submitting a command. Inventory discovery never removes files.
enum CLIUninstallService {
    struct Outcome: Sendable {
        let succeeded: Bool
        let messages: [String]
        var reclaimedBytes: UInt64 = 0
    }

    static func uninstall(_ tool: CommandLineTool, home: String = NSHomeDirectory(),
                          running: RunningApplicationSnapshot) -> Outcome {
        guard running.isComplete else {
            return Outcome(succeeded: false, messages: ["Process state is unavailable; try again."])
        }
        guard !running.contains(processName: tool.name) else {
            return Outcome(succeeded: false, messages: ["\(tool.name) is running. Quit it before uninstalling."])
        }
        guard tool.dependents.isEmpty else {
            return Outcome(succeeded: false, messages: ["Other packages depend on \(tool.name): "
                + tool.dependents.joined(separator: ", ")])
        }
        let searchPath = AgentCatalog.executableSearchPath(home: home)
        if tool.manager == .go {
            guard DeletionPlan.isLexicallySafePath(tool.path), tool.path.hasPrefix(home + "/"),
                  let identity = DeletionPlan.identity(at: tool.path) else {
                return Outcome(succeeded: false, messages: ["Go binaries outside the home folder are not removed."])
            }
            let before = CleanupScanWorker.measure(tool.path, control: CleanupScanControl(mode: .deep)).bytes
            let summary = NativeCore.shared.applyCleanup(items: [.init(record: tool.path, identity: identity)],
                permanent: false, homeDirectory: home, verifiedTargets: [tool.path])
            return Outcome(succeeded: summary.removedPaths.contains(tool.path), messages: summary.messages,
                           reclaimedBytes: summary.removedPaths.contains(tool.path) ? before : 0)
        }
        guard let command = CLIManagedCommands.command(tool, action: .uninstall, home: home, searchPath: searchPath) else {
            return Outcome(succeeded: false, messages: ["This installation has no available package manager."])
        }
        if let probe = command.rootProbe, command.expectedRoot != nil {
            let result = CLICommandRunner.run(command.executable, probe, searchPath: searchPath, home: home, timeout: 10,
                             environment: command.environment)
            guard result.succeeded, command.matchesExpectedRoot(result.output) else {
                return Outcome(succeeded: false, messages: ["The package manager installation root changed; scan again."])
            }
        }
        let before = CleanupScanWorker.measure(tool.path, control: CleanupScanControl(mode: .deep)).bytes
        let result = CLICommandRunner.run(command.executable, command.arguments, searchPath: searchPath, home: home, timeout: 120,
                         environment: command.environment)
        let gone = !FileManager.default.fileExists(atPath: tool.path)
        var messages = result.output.isEmpty ? [] : [result.output]
        if !gone { messages.append("The installation path still exists: " + tool.path) }
        return Outcome(succeeded: result.succeeded && gone, messages: messages, reclaimedBytes: gone ? before : 0)
    }
}
