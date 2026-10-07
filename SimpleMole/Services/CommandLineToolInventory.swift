import Darwin
import Foundation

/// 软件页的命令行工具清单：先发现安装，再探测版本和容量。
/// 同名工具按物理安装目录区分，管理器操作绑定该目录。
struct CommandLineTool: Identifiable, Equatable, Sendable {
    enum Manager: String, CaseIterable, Sendable {
        case homebrew, npm, pnpm, pipx, uv, cargo, go, local

        var displayName: String {
            switch self {
            case .homebrew: return "Homebrew"
            case .npm: return "npm"
            case .pnpm: return "pnpm"
            case .pipx: return "pipx"
            case .uv: return "uv"
            case .cargo: return "cargo"
            case .go: return "go"
            case .local: return "Local"
            }
        }
    }

    let manager: Manager
    let name: String
    let version: String
    let path: String
    var bytes: UInt64
    let dependents: [String]
    let installedOnRequest: Bool
    var agentID: String? = nil
    var agentInstallationID: String? = nil
    var installationSource: String? = nil
    var updatePackageName: String? = nil
    var supportsPublicRegistryUpdates = true
    var executablePaths: [String] = []
    var agentInstallation: AgentCLIInstallation? = nil
    var sizeIsKnown = true
    var managerExecutable: String? = nil

    var installationRoot: String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return manager == .homebrew && url.lastPathComponent != name ? url.deletingLastPathComponent().path : url.path
    }
    var id: String {
        manager.rawValue + ":" + name + ":" + URL(fileURLWithPath: installationRoot).resolvingSymlinksInPath().path
    }
    var canUninstall: Bool { (manager != .local || agentInstallation != nil) && dependents.isEmpty }
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
        // No recursive sizing is allowed during discovery. A slow package can
        // only lose its size, never suppress another provider or installation.
        let discovery = CleanupScanControl(mode: .deep, totalBudget: 0, cancellationSource: control)
        var tools: [CommandLineTool] = []
        tools += homebrewFormulae(home: home, searchPath: searchPath, control: discovery)
        tools += nodeGlobals(.npm, home: home, searchPath: searchPath, control: discovery)
        tools += nodeGlobals(.pnpm, home: home, searchPath: searchPath, control: discovery)
        tools += pipxTools(home: home, searchPath: searchPath, control: discovery)
        tools += uvTools(home: home, searchPath: searchPath, control: discovery)
        tools += cargoTools(home: home, control: discovery, searchPath: searchPath)
        tools += goBinaries(home: home)
        tools += localTools(home: home, managed: tools)
        let installations = AgentCatalog.definitions.flatMap { AgentCLIService.installations(for: $0, home: home) }
        let collected = mergingAgents(tools, installations: installations, control: discovery)
        let sizing = CleanupScanControl(mode: .deep, totalBudget: control.totalBudget,
            directoryBudget: control.directoryBudget, onDirectory: { control.reportDirectory($0) },
            cancellationSource: control)
        let sized = sizeTools(deduplicated(collected), control: sizing)
        return sized
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
    }

    static func sizeTools(_ tools: [CommandLineTool], control: CleanupScanControl,
                          measure: (String, CleanupScanControl) -> CleanupScanWorker.Measurement = CleanupScanWorker.measure) -> [CommandLineTool] {
        var output = tools
        for index in output.indices where ![.cargo, .go].contains(output[index].manager)
            && (output[index].manager != .local || output[index].agentInstallation != nil) {
            guard !control.shouldStop else {
                output[index].sizeIsKnown = false
                continue
            }
            let paths = output[index].agentInstallation?.managedPaths ?? [output[index].path]
            let measurements = DeletionPlan.nonOverlappingPaths(paths).map { measure($0, control) }
            output[index].bytes = measurements.reduce(0) { $0 &+ $1.bytes }
            output[index].sizeIsKnown = measurements.allSatisfy(\.complete)
        }
        return output
    }

    static func deduplicated(_ tools: [CommandLineTool]) -> [CommandLineTool] {
        var output: [CommandLineTool] = []
        var locations: [String: Int] = [:]
        for tool in tools {
            let physical = URL(fileURLWithPath: tool.installationRoot).resolvingSymlinksInPath().path
            let key = tool.manager.rawValue + ":" + tool.name + ":" + physical
            if let index = locations[key] {
                if output[index].agentInstallation == nil, tool.agentInstallation != nil { output[index] = tool }
            } else { locations[key] = output.count; output.append(tool) }
        }
        return output
    }

    // MARK: - Discovery

    static func homebrewFormulae(home: String, searchPath: [String],
                                         control: CleanupScanControl, cellars supplied: [String]? = nil) -> [CommandLineTool] {
        // 直接读 Cellar 里的安装收据，不调用 brew：brew 在 Xcode 许可未接受等情况下会直接报错。
        let fm = FileManager.default
        let brewRoots = searchPath.filter { FileManager.default.isExecutableFile(atPath: $0 + "/brew") }
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("Cellar").path }
        let candidates = supplied ?? ([ProcessInfo.processInfo.environment["HOMEBREW_CELLAR"],
                          "/opt/homebrew/Cellar", "/usr/local/Cellar"].compactMap { $0 } + brewRoots)
        var seen = Set<String>()
        return candidates.filter { seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
            .flatMap { cellar -> [CommandLineTool] in
            guard let names = try? fm.contentsOfDirectory(atPath: cellar) else { return [] }
            var dependents: [String: [String]] = [:]
            var records: [(name: String, version: String, onRequest: Bool, path: String, publicSource: Bool)] = []
            for name in names.sorted() where !name.hasPrefix(".") {
                let formulaRoot = cellar + "/" + name
                guard let versions = try? fm.contentsOfDirectory(atPath: formulaRoot).filter({ !$0.hasPrefix(".") }),
                      let version = versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).last else { continue }
                let versionRoot = formulaRoot + "/" + version
                let receipt = (try? Data(contentsOf: URL(fileURLWithPath: versionRoot + "/INSTALL_RECEIPT.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let onRequest = receipt?["installed_on_request"] as? Bool ?? true
                for dependency in receipt?["runtime_dependencies"] as? [[String: Any]] ?? [] {
                    if let full = dependency["full_name"] as? String {
                        dependents[full.split(separator: "/").last.map(String.init) ?? full, default: []].append(name)
                    }
                }
                let source = receipt?["source"] as? [String: Any]
                let tap = source?["tap"] as? String
                records.append((name, version, onRequest, versions.count > 1 ? formulaRoot : versionRoot,
                                tap == nil || tap == "homebrew/core"))
            }
            return records.compactMap { record in
                guard !control.isCancelled else { return nil }
                let measurement = CleanupScanWorker.measure(record.path, control: control)
                return CommandLineTool(manager: .homebrew, name: record.name, version: record.version, path: record.path,
                                       bytes: measurement.bytes, dependents: Array(Set(dependents[record.name] ?? [])).sorted(),
                                       installedOnRequest: record.onRequest, supportsPublicRegistryUpdates: record.publicSource,
                                       sizeIsKnown: measurement.complete,
                                       managerExecutable: URL(fileURLWithPath: cellar).deletingLastPathComponent().appendingPathComponent("bin/brew").path)
            }
        }
    }

    static func nodeGlobals(_ manager: CommandLineTool.Manager, home: String, searchPath: [String],
                           control: CleanupScanControl, roots supplied: [String]? = nil) -> [CommandLineTool] {
        var roots = supplied ?? []
        var owners: [String: String] = [:]
        if supplied == nil {
            if let executable = AgentCatalog.resolveExecutable(manager.rawValue, searchPath: searchPath, home: home) {
                let result = run(executable, ["root", "-g"], searchPath: searchPath, home: home, timeout: 5)
                let root = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.succeeded, DeletionPlan.isLexicallySafePath(root) { roots.append(root); owners[root] = executable }
            }
            if manager == .npm {
                roots += searchPath.filter { URL(fileURLWithPath: $0).lastPathComponent == "bin" }.map {
                    URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("lib/node_modules").path
                }
                roots += [home + "/.npm-global/lib/node_modules"]
                if let prefix = ProcessInfo.processInfo.environment["NPM_CONFIG_PREFIX"] ?? ProcessInfo.processInfo.environment["npm_config_prefix"], prefix.hasPrefix("/") {
                    roots.append(prefix + "/lib/node_modules")
                }
                if let npmrc = try? String(contentsOfFile: home + "/.npmrc", encoding: .utf8) {
                    for line in npmrc.split(whereSeparator: \.isNewline) {
                        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        if parts.count == 2, parts[0] == "prefix" {
                            var prefix = parts[1].replacingOccurrences(of: "${HOME}", with: home)
                            if prefix.hasPrefix("~/") { prefix = home + String(prefix.dropFirst()) }
                            if prefix.hasPrefix("/") { roots.append(prefix + "/lib/node_modules") }
                        }
                    }
                }
            } else {
                for base in [ProcessInfo.processInfo.environment["PNPM_HOME"], home + "/Library/pnpm", home + "/.local/share/pnpm"].compactMap({ $0 }) {
                    let global = base + "/global"
                    roots += ((try? FileManager.default.contentsOfDirectory(atPath: global)) ?? []).map { global + "/" + $0 + "/node_modules" }
                }
            }
        }
        var seen = Set<String>()
        return roots.filter { DeletionPlan.isLexicallySafePath($0) && seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
            .flatMap { root -> [CommandLineTool] in
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }
            let packages = names.flatMap { name -> [String] in
                if name.hasPrefix("@") { return ((try? FileManager.default.contentsOfDirectory(atPath: root + "/" + name)) ?? []).map { name + "/" + $0 } }
                return [name]
            }
            return packages.compactMap { name in
                guard !control.isCancelled, name != "corepack", validPackageName(name) else { return nil }
                let path = root + "/" + name
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path + "/package.json")), data.count <= 1_048_576,
                      let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      manifest["name"] as? String == name else { return nil }
                let version = manifest["version"] as? String ?? ""
                let measurement = CleanupScanWorker.measure(path, control: control)
                let prefix = URL(fileURLWithPath: root).deletingLastPathComponent().deletingLastPathComponent().path
                let preferred = prefix + "/bin/" + manager.rawValue
                let executable = manager == .npm && FileManager.default.isExecutableFile(atPath: preferred)
                    ? preferred : owners[root]
                return CommandLineTool(manager: manager, name: name, version: version, path: path,
                                       bytes: measurement.bytes, dependents: [], installedOnRequest: true,
                                       supportsPublicRegistryUpdates: manifest["private"] as? Bool != true,
                                       sizeIsKnown: measurement.complete, managerExecutable: executable)
            }
        }
    }

    private static func validPackageName(_ value: String) -> Bool {
        value.range(of: #"^(?:@[A-Za-z0-9_.-]+/)?[A-Za-z0-9][A-Za-z0-9_.+-]{0,127}$"#, options: .regularExpression) != nil
    }

    static func pipxTools(home: String, searchPath: [String], control: CleanupScanControl,
                          roots supplied: [String]? = nil) -> [CommandLineTool] {
        // pipx keeps an authoritative receipt in each venv. Enumerate all known
        // roots even when pipx cannot start or its active home has changed.
        let env = ProcessInfo.processInfo.environment
        let roots = supplied ?? [env["PIPX_HOME"].map { $0 + "/venvs" },
            (env["XDG_DATA_HOME"] ?? home + "/.local/share") + "/pipx/venvs",
            home + "/.local/pipx/venvs", home + "/Library/Application Support/pipx/venvs"].compactMap { $0 }
        let executable = AgentCatalog.resolveExecutable("pipx", searchPath: searchPath, home: home)
        return uniqueRoots(roots).flatMap { root in
            directoryNames(root).compactMap { name -> CommandLineTool? in
                guard !control.isCancelled, validPackageName(name),
                      let metadata = jsonObject(root + "/" + name + "/pipx_metadata.json"),
                      let main = metadata["main_package"] as? [String: Any] else { return nil }
                let package = main["package"] as? String ?? name
                let source = main["package_or_url"] as? String ?? package
                let measured = CleanupScanWorker.measure(root + "/" + name, control: control)
                return .init(manager: .pipx, name: name, version: main["package_version"] as? String ?? "",
                    path: root + "/" + name, bytes: measured.bytes, dependents: [], installedOnRequest: true,
                    updatePackageName: package,
                    supportsPublicRegistryUpdates: !source.contains("://") && !source.hasPrefix("/")
                        && !source.hasPrefix("git+") && !source.hasPrefix("."),
                    sizeIsKnown: measured.complete, managerExecutable: executable)
            }
        }
    }

    static func uvTools(home: String, searchPath: [String], control: CleanupScanControl,
                        roots supplied: [String]? = nil) -> [CommandLineTool] {
        let env = ProcessInfo.processInfo.environment
        let executable = AgentCatalog.resolveExecutable("uv", searchPath: searchPath, home: home)
        var roots = supplied ?? [env["UV_TOOL_DIR"],
            (env["XDG_DATA_HOME"] ?? home + "/.local/share") + "/uv/tools"].compactMap { $0 }
        if supplied == nil, let executable, !control.isCancelled {
            let result = run(executable, ["tool", "dir"], searchPath: searchPath, home: home, timeout: 5)
            if result.succeeded, DeletionPlan.isLexicallySafePath(result.output) { roots.append(result.output) }
        }
        return uniqueRoots(roots).flatMap { root in
            directoryNames(root).compactMap { name -> CommandLineTool? in
                let path = root + "/" + name
                guard !control.isCancelled, validPackageName(name),
                      let receipt = try? String(contentsOfFile: path + "/uv-receipt.toml", encoding: .utf8) else { return nil }
                // Read distribution metadata instead of launching every tool.
                let version = pythonPackageVersion(name, environment: path)
                let measured = CleanupScanWorker.measure(path, control: control)
                return .init(manager: .uv, name: name, version: version, path: path,
                    bytes: measured.bytes, dependents: [], installedOnRequest: true,
                    supportsPublicRegistryUpdates: !receipt.contains("://") && !receipt.contains("git =")
                        && !receipt.contains("path =") && !receipt.contains("directory ="),
                    sizeIsKnown: measured.complete, managerExecutable: executable)
            }
        }
    }

    private static func pythonPackageVersion(_ package: String, environment: String) -> String {
        func normalized(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "[_.-]+", with: "-", options: .regularExpression)
        }
        for python in directoryNames(environment + "/lib") where python.hasPrefix("python") {
            let site = environment + "/lib/" + python + "/site-packages"
            for info in directoryNames(site) where info.hasSuffix(".dist-info") {
                guard let text = try? String(contentsOfFile: site + "/" + info + "/METADATA", encoding: .utf8) else { continue }
                let lines = text.split(whereSeparator: \.isNewline)
                let name = lines.first { $0.hasPrefix("Name: ") }.map { String($0.dropFirst(6)) }
                if name.map(normalized) == normalized(package) {
                    return lines.first { $0.hasPrefix("Version: ") }.map { String($0.dropFirst(9)) } ?? ""
                }
            }
        }
        return ""
    }

    private static func directoryNames(_ root: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private static func uniqueRoots(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        return roots.filter { DeletionPlan.isLexicallySafePath($0)
            && seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
    }

    private static func jsonObject(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 1_048_576 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func cargoTools(home: String, control: CleanupScanControl, searchPath: [String] = []) -> [CommandLineTool] {
        let candidates = [ProcessInfo.processInfo.environment["CARGO_HOME"], home + "/.cargo"].compactMap { $0 }
            + searchPath.filter { URL(fileURLWithPath: $0).lastPathComponent == "bin" }.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().path
            }
        return uniqueRoots(candidates).flatMap { cargoHome -> [CommandLineTool] in
            guard !control.isCancelled,
                  let text = try? String(contentsOfFile: cargoHome + "/.crates.toml", encoding: .utf8) else { return [] }
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
                                             bytes: bytes, dependents: [], installedOnRequest: true,
                                             supportsPublicRegistryUpdates: line.contains("registry+https://github.com/rust-lang/crates.io-index")
                                                || line.contains("registry+https://index.crates.io/"),
                                             executablePaths: binaries.filter {
                                                 $0 != "." && $0 != ".." && $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
                                             }.map { cargoHome + "/bin/" + $0 }))
            }
            return tools
        }
    }

    static func goBinaries(home: String) -> [CommandLineTool] {
        let env = ProcessInfo.processInfo.environment
        let roots = [env["GOBIN"]].compactMap { $0 }
            + (env["GOPATH"] ?? home + "/go").split(separator: ":").map { String($0) + "/bin" }
        return uniqueRoots(roots).flatMap { goBin -> [CommandLineTool] in
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
    }

    /// Surface unmanaged runtimes and shells without inventing an uninstall
    /// command. System and SDK-manager installations remain read-only here.
    static func localTools(home: String, managed: [CommandLineTool],
                           snapshot supplied: DeveloperCLISnapshot? = nil, versionBudget: TimeInterval = 12) -> [CommandLineTool] {
        let snapshot = supplied ?? DeveloperCLIService.discover(environment: [
            "PATH": AgentCatalog.executableSearchPath(home: home).joined(separator: ":")
        ], homePath: home)
        let managedRoots = managed.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        var result: [CommandLineTool] = []
        var measuredPaths = Set<String>()
        let deadline = Date().addingTimeInterval(versionBudget)
        for entry in snapshot.entries where entry.isFound {
            var seen = Set<String>()
            for location in entry.locations {
                guard seen.insert(location.resolvedPath).inserted,
                      !managedRoots.contains(where: {
                          location.resolvedPath == $0 || location.resolvedPath.hasPrefix($0 + "/")
                      }) else { continue }
                let single = DeveloperCLIEntry(tool: entry.tool, locations: [location], version: .pending)
                let inspected: DeveloperCLIVersion = Date() < deadline
                    ? DeveloperCLIService.inspectVersion(of: single, snapshot: snapshot, timeout: 0.3) : .deferred
                let version: String
                if case .value(let value) = inspected { version = value } else { version = "" }
                var metadata = stat()
                let bytes = measuredPaths.insert(location.resolvedPath).inserted && stat(location.resolvedPath, &metadata) == 0
                    ? UInt64(max(0, metadata.st_blocks)) * 512 : 0
                result.append(.init(manager: .local, name: entry.tool.id, version: version, path: location.path,
                                    bytes: bytes, dependents: [], installedOnRequest: true,
                                    installationSource: location.source, supportsPublicRegistryUpdates: false))
            }
        }
        return result
    }

    /// Reconcile by physical installation, not package name. Agent discovery
    /// also finds native commands and packages under other runtime prefixes.
    static func mergingAgents(_ tools: [CommandLineTool], installations: [AgentCLIInstallation],
                              control: CleanupScanControl) -> [CommandLineTool] {
        var result = tools
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        func overlaps(_ a: String, _ b: String) -> Bool {
            let a = canonical(a), b = canonical(b)
            return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
        }
        var seen = Set<String>()
        for installation in installations where seen.insert(installation.id).inserted && !control.isCancelled {
            if let index = result.firstIndex(where: { tool in
                (installation.managedPaths + installation.executablePaths).contains { overlaps(tool.path, $0) }
            }) {
                result[index].agentID = installation.agentID
                result[index].agentInstallationID = installation.id
                result[index].agentInstallation = installation
                if result[index].managerExecutable == nil { result[index].managerExecutable = installation.managerExecutable }
                result[index].executablePaths = Array(Set(result[index].executablePaths + installation.executablePaths)).sorted()
                continue
            }
            let manager: CommandLineTool.Manager
            switch installation.manager {
            case .npm: manager = .npm
            case .pnpm: manager = .pnpm
            case .homebrew: manager = .homebrew
            case .pipx: manager = .pipx
            case .uv: manager = .uv
            case .native, .bun: manager = .local
            }
            guard let path = installation.managedPaths.first ?? installation.executablePaths.first else { continue }
            var version = ""
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path + "/package.json")), data.count <= 1_048_576,
               let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               manifest["name"] as? String == installation.packageName {
                version = manifest["version"] as? String ?? ""
            }
            let measurements = DeletionPlan.nonOverlappingPaths(installation.managedPaths).map {
                CleanupScanWorker.measure($0, control: control)
            }
            result.append(.init(manager: manager, name: installation.packageName ?? installation.name,
                version: version, path: path, bytes: measurements.reduce(0) { $0 &+ $1.bytes }, dependents: [], installedOnRequest: true,
                agentID: installation.agentID, agentInstallationID: installation.id,
                installationSource: installation.manager == .native ? "Native" : installation.manager.rawValue,
                supportsPublicRegistryUpdates: manager != .local && !version.isEmpty,
                executablePaths: installation.executablePaths, agentInstallation: installation, sizeIsKnown: measurements.allSatisfy(\.complete),
                managerExecutable: installation.managerExecutable))
        }
        return result
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
        if tool.manager == .go {
            guard DeletionPlan.isLexicallySafePath(tool.path), tool.path.hasPrefix(home + "/"),
                  let identity = DeletionPlan.identity(at: tool.path) else {
                return Outcome(succeeded: false, messages: ["Go binaries outside the home folder are not removed."])
            }
            let summary = NativeCore.shared.applyCleanup(items: [.init(record: tool.path, identity: identity)],
                permanent: false, homeDirectory: home, verifiedTargets: [tool.path])
            return Outcome(succeeded: summary.removedPaths.contains(tool.path), messages: summary.messages,
                           reclaimedBytes: summary.removedPaths.contains(tool.path) ? before : 0)
        }
        guard let command = uninstallCommand(tool, home: home, searchPath: searchPath) else {
            return Outcome(succeeded: false, messages: ["This installation has no available package manager."])
        }
        if let probe = command.rootProbe, let expected = command.expectedRoot {
            let result = run(command.executable, probe, searchPath: searchPath, home: home, timeout: 10,
                             environment: command.environment)
            guard result.succeeded,
                  URL(fileURLWithPath: result.output).resolvingSymlinksInPath().path
                    == URL(fileURLWithPath: expected).resolvingSymlinksInPath().path else {
                return Outcome(succeeded: false, messages: ["The package manager installation root changed; scan again."])
            }
        }
        let result = run(command.executable, command.arguments, searchPath: searchPath, home: home, timeout: 120,
                         environment: command.environment)
        let gone = !FileManager.default.fileExists(atPath: tool.path)
        var messages = result.output.isEmpty ? [] : [result.output]
        if !gone { messages.append("The installation path still exists: " + tool.path) }
        return Outcome(succeeded: result.succeeded && gone, messages: messages, reclaimedBytes: gone ? before : 0)
    }

    struct ManagedCommand: Equatable {
        let executable: String
        let arguments: [String]
        var environment: [String: String] = [:]
        var rootProbe: [String]? = nil
        var expectedRoot: String? = nil
    }

    static func uninstallCommand(_ tool: CommandLineTool, home: String, searchPath: [String]) -> ManagedCommand? {
        guard validPackageName(tool.name) || (tool.manager == .homebrew && tool.name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.+@-]*$"#, options: .regularExpression) != nil),
              DeletionPlan.isLexicallySafePath(tool.path) else { return nil }
        let manager = tool.manager == .homebrew ? "brew" : tool.manager.rawValue
        guard tool.manager != .local, tool.manager != .go,
              let executable = tool.managerExecutable ?? AgentCatalog.resolveExecutable(manager, searchPath: searchPath, home: home) else { return nil }
        var root = URL(fileURLWithPath: tool.path).deletingLastPathComponent()
        switch tool.manager {
        case .homebrew:
            return .init(executable: executable, arguments: ["uninstall", "--formula", tool.name],
                rootProbe: ["--cellar", tool.name], expectedRoot: tool.installationRoot)
        case .npm, .pnpm:
            if tool.name.hasPrefix("@") { root.deleteLastPathComponent() }
            guard root.lastPathComponent == "node_modules" else { return nil }
            if tool.manager == .npm {
                guard root.deletingLastPathComponent().lastPathComponent == "lib" else { return nil }
                let prefix = root.deletingLastPathComponent().deletingLastPathComponent().path
                return .init(executable: executable, arguments: ["uninstall", "-g", tool.name],
                    environment: ["NPM_CONFIG_PREFIX": prefix], rootProbe: ["root", "-g"], expectedRoot: root.path)
            }
            let global = root.deletingLastPathComponent().path
            return .init(executable: executable, arguments: ["remove", "-g", tool.name, "--global-dir", global],
                rootProbe: ["root", "-g", "--global-dir", global], expectedRoot: root.path)
        case .pipx:
            guard root.lastPathComponent == "venvs" else { return nil }
            return .init(executable: executable, arguments: ["uninstall", tool.name],
                environment: ["PIPX_HOME": root.deletingLastPathComponent().path])
        case .uv:
            return .init(executable: executable, arguments: ["tool", "uninstall", tool.name], environment: ["UV_TOOL_DIR": root.path])
        case .cargo:
            guard root.lastPathComponent == "bin" else { return nil }
            let cargoHome = root.deletingLastPathComponent().path
            return .init(executable: executable, arguments: ["uninstall", tool.name, "--root", cargoHome],
                environment: ["CARGO_HOME": cargoHome])
        case .local, .go: return nil
        }
    }

    private static func run(_ executable: String, _ arguments: [String], searchPath: [String], home: String,
                            timeout: TimeInterval, environment overrides: [String: String] = [:]) -> (succeeded: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        environment["PATH"] = searchPath.joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NO_COLOR"] = "1"
        environment.merge(overrides) { _, value in value }
        environment["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path + ":" + searchPath.joined(separator: ":")
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
