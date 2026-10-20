import Foundation
import Darwin

/// 一次扫描看到的 CLI 安装本体。用户数据根不属于卸载计划，卸载后进入清理页。
struct AgentCLIInstallation: Identifiable, Equatable, Sendable {
    enum Manager: String, Equatable, Sendable {
        case native, npm, homebrew, pipx, uv, pnpm, bun
    }

    let id: String
    let agentID: String
    let name: String
    let executablePaths: [String]
    let managedPaths: [String]
    let manager: Manager
    let managerExecutable: String?
    let packageName: String?
    let identities: [String: String]
    let detail: String
    fileprivate var partialRemovalProof: AgentCLIPartialRemovalProof? = nil

    /// Installation metadata is shared across inventories and presentations.
    /// Retry authority stays file-private and is issued only after this service
    /// observes partial removal; callers cannot construct it through this API.
    init(id: String, agentID: String, name: String, executablePaths: [String], managedPaths: [String],
         manager: Manager, managerExecutable: String?, packageName: String?,
         identities: [String: String], detail: String) {
        self.id = id
        self.agentID = agentID
        self.name = name
        self.executablePaths = executablePaths
        self.managedPaths = managedPaths
        self.manager = manager
        self.managerExecutable = managerExecutable
        self.packageName = packageName
        self.identities = identities
        self.detail = detail
    }

    var onlyUnlinksExecutable: Bool {
        manager == .native && Set(managedPaths) == Set(executablePaths)
            && managedPaths.allSatisfy(AgentCatalog.isSymlink)
    }
}

/// Issued only after this service has observed its own uninstall remove part
/// of the accepted installation. It cannot enlarge the original path plan.
fileprivate struct AgentCLIPartialRemovalProof: Equatable, Sendable {
    let absentPaths: Set<String>
    let directoryPaths: Set<String>
}

enum AgentCLIService {
    struct Outcome: Sendable {
        let removed: Int
        let failed: Int
        let messages: [String]
        var reclaimedBytes: UInt64 = 0
        var retryInstallation: AgentCLIInstallation? = nil
        var requiresRescan = false
        var succeeded: Bool { removed > 0 && failed == 0 }
    }

    /// 只认 Agent 自己的 CLI，不把 Electron 应用内置的可执行文件当作独立安装。
    static func installations(for agent: AgentDefinition, home: String,
                              presence context: AgentPresenceContext? = nil) -> [AgentCLIInstallation] {
        guard let commands = cliCommands[agent.id] else { return [] }
        let context = context ?? AgentCatalog.defaultPresenceContext(home: home)
        var candidates = Set<String>()
        for command in commands {
            for directory in context.searchPath {
                let path = directory + "/" + command
                if AgentCatalog.isExecutableCommandFile(path) { candidates.insert(path) }
            }
        }
        for relative in AgentCatalog.nativeLaunchers(for: agent) {
            let path = AgentCatalog.absolute(relative, home: home)
            guard AgentCatalog.isExecutableCommandFile(path) else { continue }
            // 通用 agent 别名只有实际指向本工具安装目录时才归属。
            let resolved = resolvedPath(path)
            if commands.contains((path as NSString).lastPathComponent)
                || nativeRoots[agent.id, default: []].contains(where: {
                    let root = AgentCatalog.absolute($0, home: home)
                    return resolved == root || resolved.hasPrefix(root + "/")
                }) { candidates.insert(path) }
        }
        // Grok keeps native release executables separately from its command
        // entry. A removed entry must not hide an otherwise removable program.
        if agent.id == "grok" {
            let root = AgentCatalog.absolute(".grok/downloads", home: home)
            if safeAncestors(root), !AgentCatalog.isSymlink(root) {
                for name in AgentCatalog.childNames(of: root) where isGrokReleaseName(name) {
                    let path = root + "/" + name
                    if !AgentCatalog.isSymlink(path), AgentCatalog.isExecutableCommandFile(path) {
                        candidates.insert(path)
                    }
                }
            }
        }
        if agent.id == "hermes" {
            // The public pipx/uv aliases can be removed independently of the
            // package environment. Inspect only known package roots and require
            // distribution evidence before considering their internal entries.
            for relative in [".local/share/pipx/venvs/hermes-agent", ".local/pipx/venvs/hermes-agent",
                             ".local/share/uv/tools/hermes-agent"] {
                let root = home + "/" + relative
                guard !hermesPythonToolProof(root: root).isEmpty else { continue }
                for name in hermesScripts.keys {
                    let path = root + "/bin/" + name
                    if regularPhysicalFile(path), AgentCatalog.isExecutableCommandFile(path) { candidates.insert(path) }
                }
            }
        }

        var byID: [String: AgentCLIInstallation] = [:]
        if agent.id == "hermes", let native = hermesNativeInstallation(agent: agent, home: home,
                                                                        searchPath: context.searchPath) {
            byID[native.id] = native
        }
        for path in candidates.sorted() {
            // A verified Hermes installer wrapper is a command entry, not the
            // program itself. Never execute it to discover its destination.
            if agent.id == "hermes", byID.values.contains(where: { $0.executablePaths.contains(path) }) { continue }
            let resolved = agent.id == "hermes" ? hermesWrapperTarget(path) ?? resolvedPath(path) : resolvedPath(path)
            guard !resolved.contains(".app/Contents/"), safeAncestors(path) else { continue }
            let record = managedInstallation(agent: agent, launcher: path, resolved: resolved,
                                             searchPath: context.searchPath, home: home)
                ?? nativeInstallation(agent: agent, launcher: path, resolved: resolved, home: home)
            guard let record else { continue }
            if let previous = byID[record.id] {
                let launchers = Array(Set(previous.executablePaths + record.executablePaths)).sorted()
                let paths = Array(Set(previous.managedPaths + record.managedPaths)).sorted()
                byID[record.id] = make(agent: agent, launchers: launchers, paths: paths,
                    manager: record.manager, managerExecutable: record.managerExecutable,
                    package: record.packageName, idRoot: record.id, explicitID: true)
            } else {
                byID[record.id] = record
            }
        }
        if agent.id == "grok" {
            let downloadRoot = AgentCatalog.absolute(".grok/downloads", home: home)
            let binRoot = AgentCatalog.absolute(".grok/bin", home: home)
            let aliases = (AgentCatalog.nativeLaunchers(for: agent) + [".local/bin/agent"]).compactMap { relative -> String? in
                let path = AgentCatalog.absolute(relative, home: home)
                guard safeAncestors(path), AgentCatalog.isSymlink(path),
                      let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
                let target = URL(fileURLWithPath: (destination as NSString).isAbsolutePath
                    ? destination : (path as NSString).deletingLastPathComponent + "/" + destination).standardizedFileURL.path
                guard safeAncestors(target), target == binRoot + "/agent" || target == binRoot + "/grok"
                    || (target as NSString).deletingLastPathComponent == downloadRoot
                        && isGrokReleaseName((target as NSString).lastPathComponent) else { return nil }
                return path
            }
            // Include owned dangling links only after a native program has
            // been found. A broken link alone is not an installed program.
            for record in Array(byID.values) where record.manager == .native
                && record.managedPaths.contains(where: { $0 == downloadRoot || $0 == binRoot }) {
                byID[record.id] = make(agent: agent,
                    launchers: Array(Set(record.executablePaths + aliases)).sorted(), paths: record.managedPaths,
                    manager: .native, managerExecutable: nil, package: nil, idRoot: record.id, explicitID: true)
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// 重新识别包归属并比较安装对象身份；确认后替换过的命令不进入卸载操作。
    static func uninstall(_ installation: AgentCLIInstallation, home: String,
                          running: RunningApplicationSnapshot = .unavailable,
                          permanent: Bool = false,
                          core: NativeCore = .shared,
                          onCurrentFile: ((String) -> Void)? = nil) -> Outcome {
        onCurrentFile?(installation.managedPaths.first ?? installation.executablePaths.first ?? "")
        guard let agent = AgentCatalog.definitions.first(where: { $0.id == installation.agentID }) else {
            return .init(removed: 0, failed: 1, messages: ["CLI Agent is not recognized; scan again before uninstalling."])
        }
        guard running.isComplete else {
            return .init(removed: 0, failed: 1, messages: ["CLI uninstall was blocked because process state is unavailable."])
        }
        let activeOwners = agent.owners.filter {
            running.contains(processName: $0) || running.contains(bundleIdentifier: $0)
        }
        guard activeOwners.isEmpty else {
            return .init(removed: 0, failed: 1, messages: ["Quit running Agent owners before uninstalling CLI: "
                + activeOwners.joined(separator: ", ")])
        }
        // npm / pnpm 等入口经常通过 /usr/bin/env 查找同一安装中的运行时。
        // Set 会打乱 PATH 顺序，GUI 启动时也可能缺少安装器所在的 bin。
        // 优先使用已确认的包管理器和命令目录，再保留原 PATH 的顺序。
        let managerDirectories = installation.managerExecutable.map {
            [($0 as NSString).deletingLastPathComponent]
        } ?? []
        var seenDirectories = Set<String>()
        let searchPath = (managerDirectories
            + installation.executablePaths.map { ($0 as NSString).deletingLastPathComponent }
            + AgentCatalog.executableSearchPath(home: home))
            .filter { seenDirectories.insert($0).inserted }
        let context = AgentPresenceContext(applicationDirs: [], searchPath: searchPath)
        let acceptsInstallation: Bool
        if installation.partialRemovalProof != nil {
            acceptsInstallation = validatesPartialInstallation(installation)
        } else if let current = installations(for: agent, home: home, presence: context)
            .first(where: { $0.id == installation.id }) {
            acceptsInstallation = current.manager == installation.manager
                && current.managerExecutable == installation.managerExecutable
                && current.packageName == installation.packageName
                && Set(current.managedPaths) == Set(installation.managedPaths)
                && Set(current.executablePaths) == Set(installation.executablePaths)
                && !installation.identities.isEmpty
                && installation.identities.allSatisfy({ DeletionPlan.identity(at: $0.key) == $0.value })
        } else { acceptsInstallation = false }
        guard acceptsInstallation else {
            return .init(removed: 0, failed: 1,
                messages: ["CLI installation changed; scan again before uninstalling."], requiresRescan: true)
        }
        if installation.manager == .native || installation.managerExecutable == nil {
            return uninstallNative(installation, home: home, permanent: permanent,
                                   core: core, onCurrentFile: onCurrentFile)
        }
        guard let executable = installation.managerExecutable,
              let package = installation.packageName,
              let arguments = uninstallArguments(installation, package: package) else {
            return .init(removed: 0, failed: 1, messages: ["Package manager is unavailable for this installation."])
        }
        let allocation = allocationSnapshot(paths: installation.managedPaths + installation.executablePaths)
        let command = run(executable, arguments: arguments, searchPath: searchPath, home: home)
        let confirmed = confirmedRemoval(allocation)
        let remaining = installation.executablePaths.filter { AgentCatalog.exists($0) }
            + installation.managedPaths.filter { AgentCatalog.exists($0) }
        let succeeded = command.succeeded && remaining.isEmpty
        var messages = command.output.isEmpty ? [] : [command.output]
        if !remaining.isEmpty {
            messages.append("CLI uninstall left installation paths in place: "
                + Array(Set(remaining)).sorted().joined(separator: "\n"))
        }
        let retry = !succeeded && confirmed.count > 0
            ? partialRetryInstallation(installation, allocation: allocation) : nil
        return .init(removed: succeeded || confirmed.count > 0 ? 1 : 0, failed: succeeded ? 0 : 1,
                     messages: messages, reclaimedBytes: confirmed.bytes, retryInstallation: retry,
                     requiresRescan: !succeeded && confirmed.count > 0 && retry == nil)
    }

    private static func validatesPartialInstallation(_ installation: AgentCLIInstallation) -> Bool {
        guard let proof = installation.partialRemovalProof,
              !installation.identities.isEmpty,
              installation.managedPaths.allSatisfy({ safeAncestors($0) }),
              installation.executablePaths.allSatisfy({ safeAncestors($0) }) else { return false }
        if installation.manager != .native {
            guard let managerPath = installation.managerExecutable,
                  installation.identities[managerPath] != nil,
                  !proof.absentPaths.contains(managerPath),
                  !proof.directoryPaths.isEmpty else { return false }
        }
        for (path, expected) in installation.identities {
            guard safeAncestors(path) else { return false }
            if proof.absentPaths.contains(path) {
                guard isAbsent(path) else { return false }
            } else if proof.directoryPaths.contains(path) {
                var metadata = stat()
                guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                      sameObject(expected, DeletionPlan.identity(at: path)) else { return false }
            } else if DeletionPlan.identity(at: path) != expected { return false }
        }
        switch installation.manager {
        case .npm, .pnpm, .bun:
            guard let package = installation.packageName,
                  installation.managedPaths.contains(where: { root in
                      let manifest = root + "/package.json"
                      guard installation.identities[manifest] != nil,
                            !proof.absentPaths.contains(manifest),
                            let data = FileManager.default.contents(atPath: manifest),
                            let content = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                      else { return false }
                      return content["name"] as? String == package
                  }) else { return false }
        case .homebrew, .pipx, .uv:
            // The accepted package root itself remains the same physical
            // object, and the original manager and package arguments are frozen.
            guard installation.managedPaths.contains(where: { proof.directoryPaths.contains($0) }),
                  installation.packageName != nil else { return false }
        case .native:
            guard installation.managedPaths.contains(where: { proof.directoryPaths.contains($0) })
                || installation.executablePaths.contains(where: {
                    !proof.absentPaths.contains($0) && AgentCatalog.isSymlink($0)
                }) else { return false }
        }
        return true
    }

    private static func partialRetryInstallation(_ installation: AgentCLIInstallation,
                                                allocation: [AllocationRecord]) -> AgentCLIInstallation? {
        let capturedMissing = Set(allocation.filter { isAbsent($0.path) }.map(\.path))
        var absent = installation.partialRemovalProof?.absentPaths ?? []
        var directories = Set<String>()
        for (path, expected) in installation.identities {
            var metadata = stat()
            if lstat(path, &metadata) != 0 {
                guard isAbsent(path), absent.contains(path) || capturedMissing.contains(path) else { return nil }
                absent.insert(path)
            } else if metadata.st_mode & S_IFMT == S_IFDIR {
                guard sameObject(expected, DeletionPlan.identity(at: path)) else { return nil }
                directories.insert(path)
            } else if DeletionPlan.identity(at: path) != expected { return nil }
        }
        var retry = installation
        retry.partialRemovalProof = .init(absentPaths: absent, directoryPaths: directories)
        return validatesPartialInstallation(retry) ? retry : nil
    }

    private static func sameObject(_ expected: String, _ current: String?) -> Bool {
        guard let current else { return false }
        let original = expected.split(separator: ":")
        let actual = current.split(separator: ":")
        return original.count == 3 && actual.count == 3 && original.prefix(2).elementsEqual(actual.prefix(2))
    }

    private static func isAbsent(_ path: String) -> Bool {
        var metadata = stat()
        guard lstat(path, &metadata) != 0 else { return false }
        return errno == ENOENT || errno == ENOTDIR
    }

    private static let cliCommands: [String: [String]] = [
        "claude-code": ["claude"], "codex": ["codex"], "cursor-cli": ["cursor-agent"],
        "copilot": ["copilot"], "gemini": ["gemini"], "opencode": ["opencode"],
        "grok": ["grok"], "pi": ["pi"], "kimi": ["kimi", "kimi-cli"],
        "factory": ["droid"], "amp": ["amp"], "crush": ["crush"],
        "hermes": ["hermes", "hermes-agent", "hermes-acp"]
    ]
    private static let nativeRoots: [String: [String]] = [
        "claude-code": [".local/share/claude/versions"],
        "cursor-cli": [".local/share/cursor-agent"], "copilot": [".copilot/pkg"],
        "grok": [".grok/downloads", ".grok/bin"], "opencode": [".opencode/bin"],
        "kimi": [".kimi-code/bin"], "amp": [".amp/bin"]
    ]
    private static let packages: [String: [String]] = [
        "claude-code": ["@anthropic-ai/claude-code"], "codex": ["@openai/codex"],
        "copilot": ["@github/copilot", "@githubnext/github-copilot-cli"],
        "gemini": ["@google/gemini-cli"], "opencode": ["opencode-ai"],
        "pi": ["@mariozechner/pi-coding-agent", "@earendil-works/pi-coding-agent"], "kimi": ["kimi-cli"],
        "amp": ["@sourcegraph/amp"], "hermes": ["hermes-agent"]
    ]

    static func ownsNPMPackage(_ name: String) -> Bool {
        packages.values.contains { $0.contains(name) }
    }

    private static func managedInstallation(agent: AgentDefinition, launcher: String, resolved: String,
                                            searchPath: [String], home: String) -> AgentCLIInstallation? {
        let parts = resolved.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "Cellar"), index > 0, index + 2 < parts.count {
            let prefix = "/" + parts[..<index].joined(separator: "/")
            let token = parts[index + 1]
            let allowed: [String: [String]] = [
                "claude-code": ["claude-code"], "codex": ["codex"],
                "gemini": ["gemini-cli"], "opencode": ["opencode"],
                "copilot": ["copilot-cli", "github-copilot-cli"], "crush": ["crush"],
                "amp": ["amp", "ampcode"], "kimi": ["kimi-cli"]
            ]
            guard allowed[agent.id, default: []].contains(token) else { return nil }
            let root = prefix + "/Cellar/" + token
            return make(agent: agent, launchers: [launcher], paths: [root], manager: .homebrew,
                        managerExecutable: manager("brew", preferred: prefix + "/bin/brew", searchPath: searchPath, home: home),
                        package: token, idRoot: root)
        }
        if let package = enclosingPackage(resolved), packages[agent.id, default: []].contains(package.name),
           let marker = package.path.range(of: "/node_modules/", options: .backwards) {
            let before = String(package.path[..<marker.lowerBound])
            var type: AgentCLIInstallation.Manager = .npm
            var prefix = before.hasSuffix("/lib") ? String(before.dropLast(4)) : before
            var command = "npm"
            if before.contains("/.bun/install/global") { type = .bun; command = "bun" }
            if before.contains("/pnpm/global/") || before.contains("/Library/pnpm/global/") {
                type = .pnpm; command = "pnpm"
            }
            // 非全局项目中的依赖不能用全局 uninstall；作为直接命令解除链接处理。
            guard before.hasSuffix("/lib") || before.contains("/global/")
                    || before.hasSuffix("/global") else { return nil }
            if type != .npm { prefix = (launcher as NSString).deletingLastPathComponent }
            return make(agent: agent, launchers: [launcher], paths: [package.path], manager: type,
                        managerExecutable: manager(command, preferred: prefix + "/bin/" + command,
                                                   searchPath: searchPath, home: home),
                        package: package.name, idRoot: package.path)
        }
        for (marker, type, command) in [("/pipx/venvs/", AgentCLIInstallation.Manager.pipx, "pipx"),
                                        ("/uv/tools/", .uv, "uv")] {
            guard let range = resolved.range(of: marker) else { continue }
            let suffix = resolved[range.upperBound...].split(separator: "/")
            guard let first = suffix.first, packages[agent.id, default: []].contains(String(first)) else { continue }
            let root = String(resolved[..<range.upperBound]) + first
            if agent.id == "hermes" {
                guard hermesScripts.keys.contains(where: { resolved == root + "/bin/" + $0 }),
                      regularPhysicalFile(resolved), !hermesPythonToolProof(root: root).isEmpty else { continue }
            }
            return make(agent: agent, launchers: [launcher], paths: [root], manager: type,
                        managerExecutable: manager(command, preferred: home + "/.local/bin/" + command,
                                                   searchPath: searchPath, home: home),
                        package: String(first), idRoot: root)
        }
        return nil
    }

    private static let hermesScripts = [
        "hermes": "hermes_cli.main:main",
        "hermes-agent": "run_agent:main",
        "hermes-acp": "acp_adapter.entry:main"
    ]

    /// The official source installer keeps code and a virtual environment in
    /// this one child. ~/.hermes itself contains user history and credentials.
    private static func hermesNativeInstallation(agent: AgentDefinition, home: String,
                                                 searchPath: [String]) -> AgentCLIInstallation? {
        let root = home + "/.hermes/hermes-agent"
        let proof = hermesNativeProof(root: root)
        guard !proof.isEmpty else { return nil }
        let environments = ["venv", ".venv"].map { root + "/" + $0 }
            .filter { regularPhysicalFile($0 + "/pyvenv.cfg") }
        let entries = environments.flatMap { environment in
            hermesScripts.keys.map { environment + "/bin/" + $0 }
        }
        var launchers = Set(entries.filter { safeAncestors($0) && AgentCatalog.isExecutableCommandFile($0) })
        for directory in Set(searchPath + [home + "/.local/bin"]) {
            for command in hermesScripts.keys {
                let path = directory + "/" + command
                guard safeAncestors(path) else { continue }
                if AgentCatalog.isSymlink(path) {
                    // Resolving a dangling final link does not always retain
                    // its lexical target, so inspect the link without running it.
                    guard let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { continue }
                    let target = URL(fileURLWithPath: (raw as NSString).isAbsolutePath ? raw : directory + "/" + raw)
                        .standardizedFileURL.path
                    if entries.contains(target) || entries.contains(resolvedPath(path)) { launchers.insert(path) }
                } else if AgentCatalog.isExecutableCommandFile(path),
                          let target = hermesWrapperTarget(path), entries.contains(target) {
                    launchers.insert(path)
                }
            }
        }
        return make(agent: agent, launchers: Array(launchers), paths: [root], manager: .native,
                    managerExecutable: nil, package: nil, idRoot: root)
    }

    private static func hermesNativeProof(root: String) -> [String] {
        let marker = root + "/.hermes-bootstrap-complete"
        let manifest = root + "/pyproject.toml"
        let sources = ["hermes_cli/main.py", "run_agent.py", "acp_adapter/entry.py"].map { root + "/" + $0 }
        guard safeAncestors(root), AgentCatalog.isDirectory(root), !AgentCatalog.isSymlink(root),
              regularPhysicalFile(marker), sources.allSatisfy(regularPhysicalFile),
              let text = boundedPhysicalText(manifest), let statements = AgentTOMLStatements.read(text) else { return [] }
        var table: [String] = []
        var name: String?
        var scripts: [String: String] = [:]
        for statement in statements {
            if let header = AgentTOMLStatements.header(statement.text) {
                table = header.array ? [] : header.path
            } else if let item = AgentTOMLStatements.assignment(statement.text) {
                let key = table + item.path
                if key == ["project", "name"] { name = AgentTOMLStatements.stringValue(item.value) }
                if key.count == 3, key.prefix(2).elementsEqual(["project", "scripts"]),
                   hermesScripts[key[2]] != nil {
                    scripts[key[2]] = AgentTOMLStatements.stringValue(item.value)
                }
            }
        }
        let environments = ["venv", ".venv"].map { root + "/" + $0 + "/pyvenv.cfg" }
            .filter(regularPhysicalFile)
        guard name == "hermes-agent", scripts == hermesScripts, !environments.isEmpty else { return [] }
        return [marker, manifest] + sources + environments
    }

    /// pipx/uv directory spelling alone is insufficient: bind the package's
    /// metadata and all declared console entry points before invoking a manager.
    private static func hermesPythonToolProof(root: String) -> [String] {
        guard safeAncestors(root), AgentCatalog.isDirectory(root), !AgentCatalog.isSymlink(root),
              regularPhysicalFile(root + "/pyvenv.cfg") else { return [] }
        let library = root + "/lib"
        guard safeAncestors(library), !AgentCatalog.isSymlink(library) else { return [] }
        for python in AgentCatalog.childNames(of: library)
        where python.range(of: "^python[0-9]+\\.[0-9]+$", options: .regularExpression) != nil {
            let site = library + "/" + python + "/site-packages"
            guard safeAncestors(site), !AgentCatalog.isSymlink(site) else { continue }
            for name in AgentCatalog.childNames(of: site)
            where name.hasPrefix("hermes_agent-") && name.hasSuffix(".dist-info") {
                let metadata = site + "/" + name + "/METADATA"
                let entryPoints = site + "/" + name + "/entry_points.txt"
                guard let information = boundedPhysicalText(metadata),
                      let entries = boundedPhysicalText(entryPoints) else { continue }
                let names = information.components(separatedBy: .newlines).prefix { !$0.isEmpty }
                    .filter { $0.hasPrefix("Name:") }
                guard names == ["Name: hermes-agent"] else { continue }
                var console = false
                var scripts: [String: String] = [:]
                var valid = true
                for raw in entries.components(separatedBy: .newlines) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("[") { console = line == "[console_scripts]"; continue }
                    guard console, !line.isEmpty, !line.hasPrefix("#") else { continue }
                    let parts = line.split(separator: "=", maxSplits: 1).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    guard parts.count == 2 else { valid = false; break }
                    if hermesScripts[parts[0]] != nil {
                        if scripts[parts[0]] != nil { valid = false; break }
                        scripts[parts[0]] = parts[1]
                    }
                }
                if valid, scripts == hermesScripts { return [root + "/pyvenv.cfg", metadata, entryPoints] }
            }
        }
        return []
    }

    /// Only the installer shape is accepted, including its two exact Python
    /// environment unsets. Extra shell statements, expansion, redirection or
    /// command substitution cannot confer ownership of a tree.
    private static func hermesWrapperTarget(_ path: String) -> String? {
        guard let text = boundedPhysicalText(path, maximumBytes: 16_384) else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let shells = ["#!/bin/bash", "#!/bin/sh", "#!/bin/zsh",
                      "#!/usr/bin/env bash", "#!/usr/bin/env sh", "#!/usr/bin/env zsh"]
        guard let first = lines.first, shells.contains(first) else { return nil }
        let statements = lines.dropFirst().filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let statement = statements.last else { return nil }
        let unsets = Array(statements.dropLast())
        guard unsets.allSatisfy({ $0 == "unset PYTHONPATH" || $0 == "unset PYTHONHOME" }),
              Set(unsets).count == unsets.count else { return nil }
        let prefix = "exec \"", suffix = "\" \"$@\""
        guard statement.hasPrefix(prefix), statement.hasSuffix(suffix) else { return nil }
        let target = String(statement.dropFirst(prefix.count).dropLast(suffix.count))
        guard (target as NSString).isAbsolutePath, !target.contains(where: { "\"\\$`\n\r".contains($0) }),
              DeletionPlan.isLexicallySafePath(target), safeAncestors(target),
              URL(fileURLWithPath: target).standardizedFileURL.path == target else { return nil }
        return target
    }

    private static func regularPhysicalFile(_ path: String) -> Bool {
        guard safeAncestors(path) else { return false }
        var metadata = stat()
        return lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG
    }

    private static func boundedPhysicalText(_ path: String, maximumBytes: Int = 1_048_576) -> String? {
        guard safeAncestors(path) else { return nil }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= maximumBytes,
              let data = try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func nativeInstallation(agent: AgentDefinition, launcher: String, resolved: String,
                                           home: String) -> AgentCLIInstallation? {
        let roots = nativeRoots[agent.id, default: []].map { AgentCatalog.absolute($0, home: home) }
            .filter { resolved == $0 || resolved.hasPrefix($0 + "/") }
        let parent = (launcher as NSString).deletingLastPathComponent
        let allowedBins = [home + "/.local/bin", home + "/.bun/bin", home + "/.cargo/bin",
                           home + "/go/bin", home + "/.volta/bin", home + "/.asdf/shims",
                           home + "/.local/share/mise/shims", home + "/.deno/bin",
                           home + "/.npm-global/bin", home + "/Library/pnpm",
                           home + "/.local/share/pnpm", "/usr/local/bin", "/opt/homebrew/bin"]
        // 无可识别包结构的 PATH 命令允许解除入口；其指向的未知实体不被递归删除。
        guard !roots.isEmpty || allowedBins.contains(parent) else { return nil }
        if agent.id == "grok", !roots.isEmpty {
            let paths = nativeRoots[agent.id, default: []].map { AgentCatalog.absolute($0, home: home) }
                .filter { safeAncestors($0) && !AgentCatalog.isSymlink($0) && AgentCatalog.isDirectory($0) }
            return make(agent: agent, launchers: [launcher], paths: paths, manager: .native,
                        managerExecutable: nil, package: nil, idRoot: AgentCatalog.absolute(".grok", home: home))
        }
        let paths = roots.isEmpty ? [launcher] : roots
        return make(agent: agent, launchers: [launcher], paths: paths, manager: .native,
                    managerExecutable: nil, package: nil, idRoot: roots.first ?? launcher)
    }

    private static func isGrokReleaseName(_ name: String) -> Bool {
        name.range(of: "^grok-[0-9][0-9A-Za-z.+_-]*-macos-(aarch64|arm64|x86_64|amd64)$",
                   options: .regularExpression) != nil
    }

    private static func make(agent: AgentDefinition, launchers: [String], paths: [String],
                             manager: AgentCLIInstallation.Manager, managerExecutable: String?,
                             package: String?, idRoot: String, explicitID: Bool = false) -> AgentCLIInstallation {
        let commands = launchers + (managerExecutable.map { [$0] } ?? [])
        let manifests = paths.map { $0 + "/package.json" }.filter(AgentCatalog.exists)
        let hermesProof = agent.id == "hermes" ? paths.flatMap { root in
            manager == .native ? hermesNativeProof(root: root) : hermesPythonToolProof(root: root)
        } : []
        let boundPaths = Array(Set(commands + commands.map(resolvedPath) + paths + manifests + hermesProof)).sorted()
        let identities = Dictionary(uniqueKeysWithValues: boundPaths.compactMap { path in
            DeletionPlan.identity(at: path).map { (path, $0) }
        })
        let linksOnly = manager == .native && Set(paths) == Set(launchers)
            && paths.allSatisfy(AgentCatalog.isSymlink)
        let detail = linksOnly ? "Remove command link only; keep the linked installation: "
            + launchers.map(resolvedPath).joined(separator: "\n")
            : manager == .native ? paths.joined(separator: "\n")
            : manager.rawValue + " · " + (package ?? "")
        return .init(id: explicitID ? idRoot : agent.id + "|" + manager.rawValue + "|" + idRoot,
                     agentID: agent.id, name: agent.name, executablePaths: launchers.sorted(),
                     managedPaths: paths.sorted(), manager: manager,
                     managerExecutable: managerExecutable, packageName: package,
                     identities: identities, detail: detail)
    }

    private static func uninstallArguments(_ installation: AgentCLIInstallation, package: String) -> [String]? {
        switch installation.manager {
        case .homebrew: return ["uninstall", "--formula", package]
        case .npm:
            guard let root = installation.managedPaths.first,
                  let range = root.range(of: "/lib/node_modules/") else { return nil }
            return ["uninstall", "--global", "--prefix", String(root[..<range.lowerBound]), package]
        case .pnpm: return ["remove", "--global", package]
        case .bun: return ["remove", "--global", package]
        case .pipx: return ["uninstall", package]
        case .uv: return ["tool", "uninstall", package]
        case .native: return nil
        }
    }

    private static func uninstallNative(_ installation: AgentCLIInstallation, home: String, permanent: Bool,
                                         core: NativeCore,
                                         onCurrentFile: ((String) -> Void)?) -> Outcome {
        let paths = DeletionPlan.nonOverlappingPaths((installation.managedPaths + installation.executablePaths)
            .sorted { $0.count < $1.count })
        guard paths.allSatisfy({ safeAncestors($0) && DeletionPlan.isLexicallySafePath($0) }) else {
            return .init(removed: 0, failed: 1, messages: ["CLI installation path is no longer physical."])
        }
        let physical = paths.filter { !AgentCatalog.isSymlink($0) }
        let allocation = allocationSnapshot(paths: installation.managedPaths + installation.executablePaths)
        func nativeIdentity(_ path: String) -> String {
            if installation.partialRemovalProof?.directoryPaths.contains(path) == true {
                // The service-created proof already checked this original
                // directory object. Supply its current mtime to NativeCore's
                // strict non-cache deletion edge after our own partial work.
                let current = DeletionPlan.identity(at: path)
                guard sameObject(installation.identities[path] ?? "", current) else { return "" }
                return current ?? ""
            }
            return installation.identities[path] ?? ""
        }
        let result = core.applyCleanup(
            items: physical.filter { installation.partialRemovalProof?.absentPaths.contains($0) != true }
                .map { .init(record: $0, identity: nativeIdentity($0)) },
            permanent: permanent, homeDirectory: home, allowedRoots: physical,
            verifiedTargets: Set(physical), onCurrentFile: onCurrentFile)
        let failed = result.failed + result.skipped
        guard failed == 0 else {
            let retry = result.removed > 0 ? partialRetryInstallation(installation, allocation: allocation) : nil
            return .init(removed: result.removed, failed: failed, messages: result.messages,
                         reclaimedBytes: result.reclaimedBytes, retryInstallation: retry,
                         requiresRescan: result.removed > 0 && retry == nil)
        }
        // 先删除本体会让链接变成 dangling；lstat 的身份仍然能验证并解除该链接。
        let links = paths.filter(AgentCatalog.isSymlink).map {
            DeletionPlan.Item(record: $0, identity: installation.identities[$0] ?? "")
        }
        let unlinked = core.applyAgentSkillLinks(
            items: links, homeDirectory: home,
            allowedDirectories: Array(Set(links.map { ($0.record as NSString).deletingLastPathComponent })))
        let removed = result.removed + unlinked.removed
        let remaining = Array(Set(installation.managedPaths + installation.executablePaths))
            .filter { !isAbsent($0) }.sorted()
        let failures = unlinked.failed + unlinked.skipped + remaining.count
        let retry = removed > 0 && failures > 0
            ? partialRetryInstallation(installation, allocation: allocation) : nil
        return .init(removed: removed,
                     failed: failures,
                     messages: result.messages + unlinked.messages + (remaining.isEmpty ? []
                        : ["CLI uninstall left installation paths in place: " + remaining.joined(separator: "\n")]),
                     reclaimedBytes: result.reclaimedBytes &+ unlinked.reclaimedBytes,
                     retryInstallation: retry,
                     requiresRescan: removed > 0 && failures > 0 && retry == nil)
    }

    private struct AllocationIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }
    private struct AllocationRecord {
        let path: String
        let identity: AllocationIdentity
        let bytes: UInt64
        let links: UInt64
    }

    /// Snapshot only the accepted installation tree, without following any
    /// symbolic link. Package managers return no trustworthy byte counter.
    private static func allocationSnapshot(paths: [String]) -> [AllocationRecord] {
        var records: [AllocationRecord] = []
        func visit(parent: Int32, name: String, path: String, depth: Int) {
            guard depth < 128 else { return }
            var metadata = stat()
            guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { return }
            let directory = metadata.st_mode & S_IFMT == S_IFDIR
            let record = AllocationRecord(path: path,
                identity: .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino)),
                bytes: UInt64(max(0, metadata.st_blocks)) * 512,
                links: directory ? 1 : UInt64(metadata.st_nlink))
            guard directory else { records.append(record); return }
            let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            var current = stat()
            guard fstat(descriptor, &current) == 0,
                  current.st_dev == metadata.st_dev, current.st_ino == metadata.st_ino else { return }
            records.append(record)
            let streamDescriptor = dup(descriptor)
            guard streamDescriptor >= 0, let stream = fdopendir(streamDescriptor) else {
                if streamDescriptor >= 0 { close(streamDescriptor) }
                return
            }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                let child = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                guard child != ".", child != ".." else { continue }
                visit(parent: descriptor, name: child, path: path + "/" + child, depth: depth + 1)
            }
        }
        for path in DeletionPlan.nonOverlappingPaths(paths) {
            guard DeletionPlan.isLexicallySafePath(path) else { continue }
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parent >= 0 else { continue }
            for component in components.dropLast() {
                let next = openat(parent, component, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
                close(parent)
                parent = next
                if next < 0 { break }
            }
            if parent >= 0 {
                visit(parent: parent, name: components.last!, path: path, depth: 0)
                close(parent)
            }
        }
        return records
    }

    private static func confirmedRemoval(_ records: [AllocationRecord]) -> (count: Int, bytes: UInt64) {
        func absent(_ path: String) -> Bool {
            var metadata = stat()
            guard lstat(path, &metadata) != 0 else { return false }
            return errno == ENOENT || errno == ENOTDIR
        }
        let missing = records.filter { absent($0.path) }
        let groups = Dictionary(grouping: records, by: \.identity)
        let bytes = groups.values.reduce(UInt64(0)) { total, entries in
            // A hard link outside the accepted tree keeps its allocation.
            guard UInt64(entries.count) >= (entries.map(\.links).max() ?? 0),
                  entries.allSatisfy({ absent($0.path) }) else { return total }
            return total &+ (entries.map(\.bytes).max() ?? 0)
        }
        return (missing.count, bytes)
    }

    private static func enclosingPackage(_ resolved: String) -> (path: String, name: String)? {
        var current = (resolved as NSString).deletingLastPathComponent
        for _ in 0..<12 {
            if let data = FileManager.default.contents(atPath: current + "/package.json"),
               let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let name = root["name"] as? String { return (current, name) }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    private static func manager(_ command: String, preferred: String, searchPath: [String], home: String) -> String? {
        AgentCatalog.isExecutableCommandFile(preferred) ? preferred
            : AgentCatalog.resolveExecutable(command, searchPath: searchPath, home: home)
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 末级链接可以解除；父级链接不能成为删除入口。
    private static func safeAncestors(_ path: String) -> Bool {
        var current = (path as NSString).deletingLastPathComponent
        while current != "/" && !current.isEmpty {
            if AgentCatalog.isSymlink(current) { return false }
            current = (current as NSString).deletingLastPathComponent
        }
        return true
    }

    private static func run(_ executable: String, arguments: [String], searchPath: [String], home: String)
        -> (succeeded: Bool, output: String) {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("nori-cli-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return (false, "Cannot create uninstall log.") }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        environment["PATH"] = searchPath.joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() }
        catch { return (false, error.localizedDescription) }
        if finished.wait(timeout: .now() + 90) == .timedOut {
            process.terminate()
            return (false, "Package manager uninstall timed out.")
        }
        let data = (try? Data(contentsOf: output)) ?? Data()
        let text = String(data: data.suffix(4096), encoding: .utf8) ?? ""
        let diagnostic = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 {
            return (false, "Package manager exited with status \(process.terminationStatus)."
                + (diagnostic.isEmpty ? "" : "\n" + diagnostic))
        }
        return (true, diagnostic)
    }
}
