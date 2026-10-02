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

        var byID: [String: AgentCLIInstallation] = [:]
        for path in candidates.sorted() {
            let resolved = resolvedPath(path)
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
        "factory": ["droid"], "amp": ["amp"], "crush": ["crush"]
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
        "amp": ["@sourcegraph/amp"]
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
            return make(agent: agent, launchers: [launcher], paths: [root], manager: type,
                        managerExecutable: manager(command, preferred: home + "/.local/bin/" + command,
                                                   searchPath: searchPath, home: home),
                        package: String(first), idRoot: root)
        }
        return nil
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
        let paths = roots.isEmpty ? [launcher] : roots
        return make(agent: agent, launchers: [launcher], paths: paths, manager: .native,
                    managerExecutable: nil, package: nil, idRoot: roots.first ?? launcher)
    }

    private static func make(agent: AgentDefinition, launchers: [String], paths: [String],
                             manager: AgentCLIInstallation.Manager, managerExecutable: String?,
                             package: String?, idRoot: String, explicitID: Bool = false) -> AgentCLIInstallation {
        let commands = launchers + (managerExecutable.map { [$0] } ?? [])
        let manifests = paths.map { $0 + "/package.json" }.filter(AgentCatalog.exists)
        let boundPaths = Array(Set(commands + commands.map(resolvedPath) + paths + manifests)).sorted()
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
        let retry = removed > 0 && unlinked.failed + unlinked.skipped > 0
            ? partialRetryInstallation(installation, allocation: allocation) : nil
        return .init(removed: removed,
                     failed: unlinked.failed + unlinked.skipped,
                     messages: result.messages + unlinked.messages,
                     reclaimedBytes: result.reclaimedBytes &+ unlinked.reclaimedBytes,
                     retryInstallation: retry,
                     requiresRescan: removed > 0 && unlinked.failed + unlinked.skipped > 0 && retry == nil)
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
