import Foundation

/// Installation commands are fixed argv arrays, scoped to the existing manager
/// and install root. Discovery never executes these commands.
enum SoftwareUpdateExecution {
    typealias Command = CLIManagedCommand

    static func toolCommand(_ tool: CommandLineTool, latest: String, home: String = NSHomeDirectory(),
                            executable supplied: String? = nil) -> Command? {
        guard SoftwareUpdateService.stable(latest) else { return nil }
        return CLIManagedCommands.command(tool, action: .update(version: latest), home: home, executable: supplied)
    }

    static func appCommand(token: String, home: String = NSHomeDirectory(), executable supplied: String? = nil) -> Command? {
        guard CLIManagedCommands.validName(token), !token.contains("/") else { return nil }
        let paths = AgentCatalog.executableSearchPath(home: home)
        guard let executable = supplied ?? AgentCatalog.resolveExecutable("brew", searchPath: paths, home: home) else { return nil }
        let environment = CLICommandEnvironment.make(home: home, searchPath: paths, executable: executable)
        return .init(executable: executable, arguments: ["upgrade", "--cask", "--greedy", token], environment: environment)
    }

    static func run(_ command: Command, engine: MoleEngine = .shared) async -> RunResult {
        if let probe = command.rootProbe, command.expectedRoot != nil {
            let result = await engine.run(executable: URL(fileURLWithPath: command.executable), arguments: probe,
                                          environment: command.environment, timeout: 20)
            guard result.succeeded, command.matchesExpectedRoot(result.output) else {
                return .init(output: "Software update install root changed.", exitCode: 1, timedOut: false)
            }
        }
        guard !Task.isCancelled else { return .init(output: "Software update cancelled.", exitCode: 1, timedOut: false) }
        return await engine.run(executable: URL(fileURLWithPath: command.executable), arguments: command.arguments,
                                environment: command.environment, timeout: 1800)
    }
}
