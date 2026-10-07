import Darwin
import Foundation

/// Installation commands are fixed argv arrays, scoped to the existing manager
/// and install root. Discovery never executes these commands.
enum SoftwareUpdateExecution {
    struct Command: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        var rootProbe: [String]? = nil
        var expectedRoot: String? = nil
    }

    static func toolCommand(_ tool: CommandLineTool, latest: String, home: String = NSHomeDirectory(),
                            executable supplied: String? = nil) -> Command? {
        guard tool.supportsPublicRegistryUpdates, validName(tool.name),
              SoftwareUpdateService.stable(latest), tool.manager != .local, tool.manager != .go,
              DeletionPlan.isLexicallySafePath(tool.path) else { return nil }
        let paths = AgentCatalog.executableSearchPath(home: home)
        let manager = tool.manager == .homebrew ? "brew" : tool.manager.rawValue
        guard let executable = supplied ?? tool.managerExecutable ?? AgentCatalog.resolveExecutable(manager, searchPath: paths, home: home) else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        environment["PATH"] = paths.joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["NO_COLOR"] = "1"
        environment["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path + ":" + environment["PATH", default: ""]
        let root = URL(fileURLWithPath: tool.path).deletingLastPathComponent()
        switch tool.manager {
        case .homebrew:
            let formulaRoot = URL(fileURLWithPath: tool.path).lastPathComponent == tool.name
                ? tool.path : root.path
            return .init(executable: executable, arguments: ["upgrade", "--formula", tool.name],
                         environment: environment, rootProbe: ["--cellar", tool.name], expectedRoot: formulaRoot)
        case .npm:
            // Scoped names contribute two path components.
            return nodeCommand(tool, latest: latest, executable: executable, environment: environment)
        case .pnpm:
            return nodeCommand(tool, latest: latest, executable: executable, environment: environment)
        case .pipx:
            guard root.lastPathComponent == "venvs" else { return nil }
            environment["PIPX_HOME"] = root.deletingLastPathComponent().path
            return .init(executable: executable, arguments: ["upgrade", tool.name], environment: environment)
        case .uv:
            environment["UV_TOOL_DIR"] = root.path
            return .init(executable: executable, arguments: ["tool", "upgrade", tool.name], environment: environment)
        case .cargo:
            guard root.lastPathComponent == "bin" else { return nil }
            environment["CARGO_HOME"] = root.deletingLastPathComponent().path
            return .init(executable: executable,
                         arguments: ["install", tool.name, "--version", latest, "--force", "--root", root.deletingLastPathComponent().path],
                         environment: environment)
        case .local, .go: return nil
        }
    }

    private static func nodeCommand(_ tool: CommandLineTool, latest: String, executable: String,
                                    environment base: [String: String]) -> Command? {
        var root = URL(fileURLWithPath: tool.path).deletingLastPathComponent()
        if tool.name.hasPrefix("@") { root.deleteLastPathComponent() }
        guard root.lastPathComponent == "node_modules" else { return nil }
        var environment = base
        if tool.manager == .npm {
            guard root.deletingLastPathComponent().lastPathComponent == "lib" else { return nil }
            environment["NPM_CONFIG_PREFIX"] = root.deletingLastPathComponent().deletingLastPathComponent().path
            return .init(executable: executable, arguments: ["install", "--global", tool.name + "@" + latest],
                         environment: environment, rootProbe: ["root", "-g"], expectedRoot: root.path)
        }
        let global = root.deletingLastPathComponent().path
        return .init(executable: executable,
                     arguments: ["add", "--global", tool.name + "@" + latest, "--global-dir", global],
                     environment: environment, rootProbe: ["root", "-g", "--global-dir", global], expectedRoot: root.path)
    }

    static func appCommand(token: String, home: String = NSHomeDirectory(), executable supplied: String? = nil) -> Command? {
        guard validName(token), !token.contains("/") else { return nil }
        let paths = AgentCatalog.executableSearchPath(home: home)
        guard let executable = supplied ?? AgentCatalog.resolveExecutable("brew", searchPath: paths, home: home) else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home; environment["PATH"] = paths.joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"; environment["NO_COLOR"] = "1"
        return .init(executable: executable, arguments: ["upgrade", "--cask", "--greedy", token], environment: environment)
    }

    static func run(_ command: Command, engine: MoleEngine = .shared) async -> RunResult {
        if let probe = command.rootProbe, let expected = command.expectedRoot {
            let result = await engine.run(executable: URL(fileURLWithPath: command.executable), arguments: probe,
                                          environment: command.environment, timeout: 20)
            let actual = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.succeeded, actual.hasPrefix("/"),
                  URL(fileURLWithPath: actual).resolvingSymlinksInPath().path
                    == URL(fileURLWithPath: expected).resolvingSymlinksInPath().path else {
                return .init(output: "Software update install root changed.", exitCode: 1, timedOut: false)
            }
        }
        guard !Task.isCancelled else { return .init(output: "Software update cancelled.", exitCode: 1, timedOut: false) }
        return await engine.run(executable: URL(fileURLWithPath: command.executable), arguments: command.arguments,
                                environment: command.environment, timeout: 1800)
    }

    static func validName(_ value: String) -> Bool {
        value.range(of: #"^(?:@[A-Za-z0-9_.-]+/)?[A-Za-z0-9][A-Za-z0-9@_.+-]{0,127}$"#, options: .regularExpression) != nil
    }
}
