import Darwin
import Foundation

/// 软件页的命令行工具清单：各包管理器安装的工具及其占用、依赖关系。
/// 卸载只走对应包管理器的命令；Go 二进制没有管理器，移入废纸篓。
struct CommandLineTool: Identifiable, Equatable, Sendable {
    enum Manager: String, CaseIterable, Sendable {
        case homebrew, npm, pnpm, pipx, uv, cargo, go

        var displayName: String {
            switch self {
            case .homebrew: return "Homebrew"
            case .npm: return "npm"
            case .pnpm: return "pnpm"
            case .pipx: return "pipx"
            case .uv: return "uv"
            case .cargo: return "cargo"
            case .go: return "go"
            }
        }
    }

    let manager: Manager
    let name: String
    let version: String
    let path: String
    let bytes: UInt64
    let dependents: [String]
    let installedOnRequest: Bool
    var agentID: String? = nil
    var agentInstallationID: String? = nil

    var id: String { manager.rawValue + ":" + name }
    var canUninstall: Bool { dependents.isEmpty }
}

enum CommandLineToolInventory {
    struct Outcome: Sendable {
        let succeeded: Bool
        let messages: [String]
        var reclaimedBytes: UInt64 = 0
    }

    static func scan(home: String = NSHomeDirectory(),
                     control: CleanupScanControl = CleanupScanControl(mode: .deep, totalBudget: 60, directoryBudget: 20))
        -> [CommandLineTool] {
        let searchPath = AgentCatalog.executableSearchPath(home: home)
        var tools: [CommandLineTool] = []
        tools += homebrewFormulae(home: home, searchPath: searchPath, control: control)
        tools += nodeGlobals(.npm, home: home, searchPath: searchPath, control: control)
        tools += nodeGlobals(.pnpm, home: home, searchPath: searchPath, control: control)
        tools += pipxTools(home: home, searchPath: searchPath, control: control)
        tools += uvTools(home: home, searchPath: searchPath, control: control)
        tools += cargoTools(home: home, control: control)
        tools += goBinaries(home: home)
        return attachAgents(tools, home: home).sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
    }

    // MARK: - Discovery

    static func homebrewFormulae(home: String, searchPath: [String],
                                         control: CleanupScanControl) -> [CommandLineTool] {
        // 直接读 Cellar 里的安装收据，不调用 brew：brew 在 Xcode 许可未接受等情况下会直接报错。
        let fm = FileManager.default
        let candidates = [ProcessInfo.processInfo.environment["HOMEBREW_CELLAR"],
                          AgentCatalog.resolveExecutable("brew", searchPath: searchPath, home: home).map {
                              URL(fileURLWithPath: $0).resolvingSymlinksInPath()
                                  .deletingLastPathComponent().deletingLastPathComponent().path + "/Cellar"
                          }, "/opt/homebrew/Cellar", "/usr/local/Cellar"].compactMap { $0 }
        guard let cellar = candidates.first(where: { fm.fileExists(atPath: $0) }),
              let names = try? fm.contentsOfDirectory(atPath: cellar) else { return [] }
        var dependents: [String: [String]] = [:]
        var records: [(name: String, version: String, onRequest: Bool, path: String)] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let formulaRoot = cellar + "/" + name
            guard let versions = try? fm.contentsOfDirectory(atPath: formulaRoot).filter({ !$0.hasPrefix(".") }),
                  let version = versions.sorted().last else { continue }
            let versionRoot = formulaRoot + "/" + version
            let receipt = (try? Data(contentsOf: URL(fileURLWithPath: versionRoot + "/INSTALL_RECEIPT.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let onRequest = receipt?["installed_on_request"] as? Bool ?? true
            for dependency in receipt?["runtime_dependencies"] as? [[String: Any]] ?? [] {
                if let full = dependency["full_name"] as? String {
                    dependents[full.split(separator: "/").last.map(String.init) ?? full, default: []].append(name)
                }
            }
            records.append((name, version, onRequest, versions.count > 1 ? formulaRoot : versionRoot))
        }
        return records.compactMap { record in
            guard !control.shouldStop else { return nil }
            let bytes = CleanupScanWorker.measure(record.path, control: control).bytes
            return CommandLineTool(manager: .homebrew, name: record.name, version: record.version, path: record.path,
                                   bytes: bytes, dependents: Array(Set(dependents[record.name] ?? [])).sorted(),
                                   installedOnRequest: record.onRequest)
        }
    }

    private static func nodeGlobals(_ manager: CommandLineTool.Manager, home: String, searchPath: [String],
                                    control: CleanupScanControl) -> [CommandLineTool] {
        let command = manager.rawValue
        guard let executable = AgentCatalog.resolveExecutable(command, searchPath: searchPath, home: home) else { return [] }
        let root = run(executable, ["root", "-g"], searchPath: searchPath, home: home, timeout: 20).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.hasPrefix("/") else { return [] }
        let listArguments = manager == .npm ? ["ls", "-g", "--depth=0", "--json"] : ["ls", "-g", "--depth", "0", "--json"]
        guard let data = run(executable, listArguments, searchPath: searchPath, home: home, timeout: 40)
            .output.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let dependencies: [String: Any]
        if let object = json as? [String: Any] {
            dependencies = object["dependencies"] as? [String: Any] ?? [:]
        } else if let array = json as? [[String: Any]] {
            dependencies = array.first?["dependencies"] as? [String: Any] ?? [:]
        } else { return [] }
        return dependencies.compactMap { name, value in
            guard !control.shouldStop, name != "corepack" else { return nil }
            let version = (value as? [String: Any])?["version"] as? String ?? ""
            let path = root + "/" + name
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let bytes = CleanupScanWorker.measure(path, control: control).bytes
            return CommandLineTool(manager: manager, name: name, version: version, path: path,
                                   bytes: bytes, dependents: [], installedOnRequest: true)
        }
    }

    private static func pipxTools(home: String, searchPath: [String],
                                  control: CleanupScanControl) -> [CommandLineTool] {
        guard let pipx = AgentCatalog.resolveExecutable("pipx", searchPath: searchPath, home: home),
              let data = run(pipx, ["list", "--json"], searchPath: searchPath, home: home, timeout: 40)
                .output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let venvs = root["venvs"] as? [String: Any] else { return [] }
        let venvRoot = ProcessInfo.processInfo.environment["PIPX_HOME"].map { $0 + "/venvs" }
            ?? [home + "/.local/pipx/venvs", home + "/Library/Application Support/pipx/venvs"]
                .first { FileManager.default.fileExists(atPath: $0) } ?? home + "/.local/pipx/venvs"
        return venvs.compactMap { name, value in
            guard !control.shouldStop else { return nil }
            let metadata = (value as? [String: Any])?["metadata"] as? [String: Any]
            let main = metadata?["main_package"] as? [String: Any]
            let version = main?["package_version"] as? String ?? ""
            let path = venvRoot + "/" + name
            let bytes = CleanupScanWorker.measure(path, control: control).bytes
            return CommandLineTool(manager: .pipx, name: name, version: version, path: path,
                                   bytes: bytes, dependents: [], installedOnRequest: true)
        }
    }

    private static func uvTools(home: String, searchPath: [String],
                                control: CleanupScanControl) -> [CommandLineTool] {
        guard let uv = AgentCatalog.resolveExecutable("uv", searchPath: searchPath, home: home) else { return [] }
        let output = run(uv, ["tool", "list"], searchPath: searchPath, home: home, timeout: 30).output
        let toolRoot = run(uv, ["tool", "dir"], searchPath: searchPath, home: home, timeout: 20).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard toolRoot.hasPrefix("/") else { return [] }
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("-"), !line.hasPrefix(" "), !control.shouldStop else { return nil }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let name = parts.first.map(String.init), !name.isEmpty else { return nil }
            let version = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "v ")) : ""
            let path = toolRoot + "/" + name
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let bytes = CleanupScanWorker.measure(path, control: control).bytes
            return CommandLineTool(manager: .uv, name: name, version: version, path: path,
                                   bytes: bytes, dependents: [], installedOnRequest: true)
        }
    }

    static func cargoTools(home: String, control: CleanupScanControl) -> [CommandLineTool] {
        let cargoHome = ProcessInfo.processInfo.environment["CARGO_HOME"] ?? home + "/.cargo"
        guard let text = try? String(contentsOfFile: cargoHome + "/.crates.toml", encoding: .utf8) else { return [] }
        var tools: [CommandLineTool] = []
        // "name version (registry+https://…)" = ["bin-a", "bin-b"]
        guard let pattern = try? NSRegularExpression(pattern: #"^"([^ "]+) ([^ "]+) [^"]*" = \[(.*)\]$"#) else { return [] }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let versionRange = Range(match.range(at: 2), in: line),
                  let binaryRange = Range(match.range(at: 3), in: line) else { continue }
            let name = String(line[nameRange]), version = String(line[versionRange])
            let binaries = line[binaryRange].split(separator: ",").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            }.filter { !$0.isEmpty }
            var bytes: UInt64 = 0
            var firstPath = cargoHome + "/bin/" + name
            for (index, binary) in binaries.enumerated() {
                let path = cargoHome + "/bin/" + binary
                var metadata = stat()
                guard lstat(path, &metadata) == 0 else { continue }
                if index == 0 { firstPath = path }
                bytes &+= UInt64(max(0, metadata.st_blocks)) * 512
            }
            tools.append(CommandLineTool(manager: .cargo, name: name, version: version, path: firstPath,
                                         bytes: bytes, dependents: [], installedOnRequest: true))
        }
        return tools
    }

    static func goBinaries(home: String) -> [CommandLineTool] {
        let goBin = ProcessInfo.processInfo.environment["GOBIN"]
            ?? (ProcessInfo.processInfo.environment["GOPATH"] ?? home + "/go") + "/bin"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: goBin) else { return [] }
        return names.compactMap { name in
            let path = goBin + "/" + name
            var metadata = stat()
            guard !name.hasPrefix("."), lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_mode & S_IXUSR != 0 else { return nil }
            return CommandLineTool(manager: .go, name: name, version: "", path: path,
                                   bytes: UInt64(max(0, metadata.st_blocks)) * 512, dependents: [],
                                   installedOnRequest: true)
        }
    }

    /// Agent 的 CLI 与包管理器清单是同一个安装：按包名或可执行路径对上，
    /// 卸载时交给 Agent CLI 服务，并在界面上链接到它的数据。
    private static func attachAgents(_ tools: [CommandLineTool], home: String) -> [CommandLineTool] {
        let installations = AgentCatalog.definitions.flatMap { AgentCLIService.installations(for: $0, home: home) }
        guard !installations.isEmpty else { return tools }
        return tools.map { tool in
            guard let match = installations.first(where: { installation in
                if let package = installation.packageName, package == tool.name { return true }
                return installation.managedPaths.contains { $0 == tool.path || tool.path.hasPrefix($0 + "/") || $0.hasPrefix(tool.path + "/") }
            }) else { return tool }
            var attached = tool
            attached.agentID = match.agentID
            attached.agentInstallationID = match.id
            return attached
        }
    }

    // MARK: - Uninstall

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
        let before = CleanupScanWorker.measure(tool.path, control: CleanupScanControl(mode: .deep)).bytes
        let arguments: [String]
        switch tool.manager {
        case .homebrew: arguments = ["uninstall", "--formula", tool.name]
        case .npm: arguments = ["uninstall", "-g", tool.name]
        case .pnpm: arguments = ["remove", "-g", tool.name]
        case .pipx: arguments = ["uninstall", tool.name]
        case .uv: arguments = ["tool", "uninstall", tool.name]
        case .cargo: arguments = ["uninstall", tool.name]
        case .go:
            guard DeletionPlan.isLexicallySafePath(tool.path), tool.path.hasPrefix(home + "/") else {
                return Outcome(succeeded: false, messages: ["Go binaries outside the home folder are not removed."])
            }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: tool.path), resultingItemURL: nil)
                return Outcome(succeeded: true, messages: [], reclaimedBytes: before)
            } catch {
                return Outcome(succeeded: false, messages: [error.localizedDescription])
            }
        }
        guard let executable = AgentCatalog.resolveExecutable(tool.manager == .homebrew ? "brew" : tool.manager.rawValue,
                                                              searchPath: searchPath, home: home) else {
            return Outcome(succeeded: false, messages: ["\(tool.manager.displayName) is not available."])
        }
        let result = run(executable, arguments, searchPath: searchPath, home: home, timeout: 120)
        let gone = !FileManager.default.fileExists(atPath: tool.path)
        var messages = result.output.isEmpty ? [] : [result.output]
        if !gone { messages.append("The installation path still exists: " + tool.path) }
        return Outcome(succeeded: result.succeeded && gone, messages: messages, reclaimedBytes: gone ? before : 0)
    }

    private static func run(_ executable: String, _ arguments: [String], searchPath: [String], home: String,
                            timeout: TimeInterval) -> (succeeded: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        environment["PATH"] = searchPath.joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (false, error.localizedDescription) }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
