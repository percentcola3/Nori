import Darwin
import Foundation

/// Read install receipts and executable metadata. Recursive sizing and commands
/// that change installations belong to later stages.
enum CLIInstalledToolDiscovery {
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
                return CommandLineTool(manager: .homebrew, name: record.name, version: record.version, path: record.path,
                                       bytes: 0, dependents: Array(Set(dependents[record.name] ?? [])).sorted(),
                                       installedOnRequest: record.onRequest, supportsPublicRegistryUpdates: record.publicSource,
                                       sizeIsKnown: false,
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
                let result = CLICommandRunner.run(executable, ["root", "-g"], searchPath: searchPath, home: home, timeout: 5)
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
                guard !control.isCancelled, name != "corepack", CLIManagedCommands.validPackageName(name) else { return nil }
                let path = root + "/" + name
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path + "/package.json")), data.count <= 1_048_576,
                      let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      manifest["name"] as? String == name else { return nil }
                let version = manifest["version"] as? String ?? ""
                let prefix = URL(fileURLWithPath: root).deletingLastPathComponent().deletingLastPathComponent().path
                let preferred = prefix + "/bin/" + manager.rawValue
                let executable = manager == .npm && FileManager.default.isExecutableFile(atPath: preferred)
                    ? preferred : owners[root]
                return CommandLineTool(manager: manager, name: name, version: version, path: path,
                                       bytes: 0, dependents: [], installedOnRequest: true,
                                       supportsPublicRegistryUpdates: manifest["private"] as? Bool != true,
                                       sizeIsKnown: false, managerExecutable: executable)
            }
        }
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
                guard !control.isCancelled, CLIManagedCommands.validPackageName(name),
                      let metadata = jsonObject(root + "/" + name + "/pipx_metadata.json"),
                      let main = metadata["main_package"] as? [String: Any] else { return nil }
                let package = main["package"] as? String ?? name
                let source = main["package_or_url"] as? String ?? package
                return .init(manager: .pipx, name: name, version: main["package_version"] as? String ?? "",
                    path: root + "/" + name, bytes: 0, dependents: [], installedOnRequest: true,
                    updatePackageName: package,
                    supportsPublicRegistryUpdates: !source.contains("://") && !source.hasPrefix("/")
                        && !source.hasPrefix("git+") && !source.hasPrefix("."),
                    sizeIsKnown: false, managerExecutable: executable)
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
            let result = CLICommandRunner.run(executable, ["tool", "dir"], searchPath: searchPath, home: home, timeout: 5)
            if result.succeeded, DeletionPlan.isLexicallySafePath(result.output) { roots.append(result.output) }
        }
        return uniqueRoots(roots).flatMap { root in
            directoryNames(root).compactMap { name -> CommandLineTool? in
                let path = root + "/" + name
                guard !control.isCancelled, CLIManagedCommands.validPackageName(name),
                      let receipt = try? String(contentsOfFile: path + "/uv-receipt.toml", encoding: .utf8) else { return nil }
                // Read distribution metadata instead of launching every tool.
                let version = pythonPackageVersion(name, environment: path)
                return .init(manager: .uv, name: name, version: version, path: path,
                    bytes: 0, dependents: [], installedOnRequest: true,
                    supportsPublicRegistryUpdates: !receipt.contains("://") && !receipt.contains("git =")
                        && !receipt.contains("path =") && !receipt.contains("directory ="),
                    sizeIsKnown: false, managerExecutable: executable)
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
                           snapshot supplied: DeveloperCLISnapshot? = nil) -> [CommandLineTool] {
        let snapshot = supplied ?? DeveloperCLIService.discover(environment: [
            "PATH": AgentCatalog.executableSearchPath(home: home).joined(separator: ":")
        ], homePath: home)
        let managedRoots = managed.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        var result: [CommandLineTool] = []
        var measuredPaths = Set<String>()
        for entry in snapshot.entries where entry.isFound {
            var seen = Set<String>()
            for location in entry.locations {
                guard seen.insert(location.resolvedPath).inserted,
                      !managedRoots.contains(where: {
                          location.resolvedPath == $0 || location.resolvedPath.hasPrefix($0 + "/")
                      }) else { continue }
                var metadata = stat()
                let bytes = measuredPaths.insert(location.resolvedPath).inserted && stat(location.resolvedPath, &metadata) == 0
                    ? UInt64(max(0, metadata.st_blocks)) * 512 : 0
                result.append(.init(manager: .local, name: entry.tool.id, version: "", path: location.path,
                                    bytes: bytes, dependents: [], installedOnRequest: true,
                                    installationSource: location.source, supportsPublicRegistryUpdates: false))
            }
        }
        return result
    }

    static func inspectVersion(_ tool: CommandLineTool, home: String, searchPath: [String]) -> String? {
        guard tool.manager == .local, tool.agentInstallation == nil,
              let definition = DeveloperCLIService.tools.first(where: { $0.id == tool.name }) else { return nil }
        let location = DeveloperCLILocation(path: tool.path,
            resolvedPath: URL(fileURLWithPath: tool.path).resolvingSymlinksInPath().path,
            source: tool.installationSource ?? "Local",
            isInPATH: searchPath.contains(URL(fileURLWithPath: tool.path).deletingLastPathComponent().path))
        let entry = DeveloperCLIEntry(tool: definition, locations: [location], version: .pending)
        let snapshot = DeveloperCLISnapshot(entries: [entry], pathDirectories: searchPath,
            duplicatePATHDirectories: [], hasRelativePATHEntry: false, homePath: home)
        if case .value(let version) = DeveloperCLIService.inspectVersion(of: entry, snapshot: snapshot, timeout: 0.3) {
            return version
        }
        return nil
    }
}
