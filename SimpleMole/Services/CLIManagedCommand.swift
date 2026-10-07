import Foundation

/// A fixed argv operation and the installation-root check required before it.
/// Both update and uninstall use the same manager binding and environment.
struct CLIManagedCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    var rootProbe: [String]? = nil
    var expectedRoot: String? = nil

    func matchesExpectedRoot(_ output: String) -> Bool {
        let actual = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expectedRoot, DeletionPlan.isLexicallySafePath(actual) else { return false }
        return URL(fileURLWithPath: actual).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: expectedRoot).resolvingSymlinksInPath().path
    }
}

enum CLICommandEnvironment {
    static func make(home: String, searchPath: [String], executable: String,
                     overrides: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        environment["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path
            + ":" + searchPath.joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NO_COLOR"] = "1"
        environment.merge(overrides) { _, value in value }
        return environment
    }
}

enum CLIManagedCommands {
    enum Action { case update(version: String), uninstall }

    static func command(_ tool: CommandLineTool, action: Action, home: String,
                        searchPath suppliedPaths: [String]? = nil, executable supplied: String? = nil) -> CLIManagedCommand? {
        guard (tool.manager == .homebrew ? validName(tool.name) : validPackageName(tool.name)),
              DeletionPlan.isLexicallySafePath(tool.path),
              tool.manager != .local, tool.manager != .go else { return nil }
        let version: String?
        switch action {
        case .update(let value):
            guard tool.supportsPublicRegistryUpdates,
                  value.range(of: #"^v?[0-9][A-Za-z0-9_.+-]*$"#, options: .regularExpression) != nil else { return nil }
            version = value
        case .uninstall: version = nil
        }
        let paths = suppliedPaths ?? AgentCatalog.executableSearchPath(home: home)
        let manager = tool.manager == .homebrew ? "brew" : tool.manager.rawValue
        guard let executable = supplied ?? tool.managerExecutable
            ?? AgentCatalog.resolveExecutable(manager, searchPath: paths, home: home) else { return nil }
        var environment = CLICommandEnvironment.make(home: home, searchPath: paths, executable: executable)
        var root = URL(fileURLWithPath: tool.path).deletingLastPathComponent()
        switch tool.manager {
        case .homebrew:
            return .init(executable: executable,
                arguments: [version == nil ? "uninstall" : "upgrade", "--formula", tool.name],
                environment: environment, rootProbe: ["--cellar", tool.name], expectedRoot: tool.installationRoot)
        case .npm, .pnpm:
            // A scoped package name occupies two components under node_modules.
            if tool.name.hasPrefix("@") { root.deleteLastPathComponent() }
            guard root.lastPathComponent == "node_modules" else { return nil }
            if tool.manager == .npm {
                guard root.deletingLastPathComponent().lastPathComponent == "lib" else { return nil }
                environment["NPM_CONFIG_PREFIX"] = root.deletingLastPathComponent().deletingLastPathComponent().path
                return .init(executable: executable,
                    arguments: version.map { ["install", "--global", tool.name + "@" + $0] }
                        ?? ["uninstall", "-g", tool.name], environment: environment,
                    rootProbe: ["root", "-g"], expectedRoot: root.path)
            }
            let global = root.deletingLastPathComponent().path
            return .init(executable: executable,
                arguments: (version.map { ["add", "--global", tool.name + "@" + $0] }
                    ?? ["remove", "-g", tool.name]) + ["--global-dir", global], environment: environment,
                rootProbe: ["root", "-g", "--global-dir", global], expectedRoot: root.path)
        case .pipx:
            guard root.lastPathComponent == "venvs" else { return nil }
            environment["PIPX_HOME"] = root.deletingLastPathComponent().path
            return .init(executable: executable,
                arguments: [version == nil ? "uninstall" : "upgrade", tool.name], environment: environment)
        case .uv:
            environment["UV_TOOL_DIR"] = root.path
            return .init(executable: executable,
                arguments: ["tool", version == nil ? "uninstall" : "upgrade", tool.name], environment: environment)
        case .cargo:
            guard root.lastPathComponent == "bin" else { return nil }
            let cargoHome = root.deletingLastPathComponent().path
            environment["CARGO_HOME"] = cargoHome
            return .init(executable: executable,
                arguments: version.map { ["install", tool.name, "--version", $0, "--force", "--root", cargoHome] }
                    ?? ["uninstall", tool.name, "--root", cargoHome], environment: environment)
        case .local, .go: return nil
        }
    }

    static func validPackageName(_ value: String) -> Bool {
        value.range(of: #"^(?:@[A-Za-z0-9_.-]+/)?[A-Za-z0-9][A-Za-z0-9_.+-]{0,127}$"#, options: .regularExpression) != nil
    }

    static func validName(_ value: String) -> Bool {
        value.range(of: #"^(?:@[A-Za-z0-9_.-]+/)?[A-Za-z0-9][A-Za-z0-9@_.+-]{0,127}$"#, options: .regularExpression) != nil
    }
}
