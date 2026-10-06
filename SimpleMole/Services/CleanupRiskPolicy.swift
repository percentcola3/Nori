import Darwin
import Foundation

/// 由调用方一次性采集的运行应用快照。风险策略只读这个值，不自行启动进程或访问 UI。
struct RunningApplicationSnapshot: Equatable, Sendable {
    let bundleIdentifiers: Set<String>
    let processNames: Set<String>
    /// 进程表不可读时必须为 false；不完整不能被当作“没有运行”。
    let isComplete: Bool

    init(bundleIdentifiers: some Sequence<String> = [],
         processNames: some Sequence<String> = [],
         isComplete: Bool = true) {
        self.bundleIdentifiers = Set(bundleIdentifiers.map(Self.normalize))
        self.processNames = Set(processNames.map(Self.normalize))
        self.isComplete = isComplete
    }

    static let unavailable = RunningApplicationSnapshot(isComplete: false)

    func contains(bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(Self.normalize(bundleIdentifier))
    }

    func contains(processName: String) -> Bool {
        processNames.contains(Self.normalize(processName))
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct CleanupPolicyDescriptor: Equatable, Sendable {
    let source: CleanupSource
    let risk: CleanupRisk
    let disposal: CleanupDisposal
    let applyRoute: CleanupApplyRoute
    let activityGuard: CleanupActivityGuard
    let reasonKey: String
}

struct CleanupRiskAssessment: Equatable, Sendable {
    let risk: CleanupRisk
    let reasonKey: String
}

enum CleanupExecutionMode: Sendable {
    case manual
    case quickClean
    case automatic
}

/// 保守的共享风险策略：未识别内容一律 Warning，Safe 只来自显式可再生缓存规则。
enum CleanupRiskPolicy {
    private static let protectedAbsoluteRoots = [
        "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
        "/private", "/var", "/etc", "/dev"
    ]
    private static let modelFileExtensions: Set<String> = [
        "gguf", "safetensors", "ckpt", "mlmodel", "mlmodelc",
        "pt", "pth", "onnx", "tflite"
    ]
    private static let modelBinaryNames: Set<String> = [
        "pytorch_model.bin", "adapter_model.bin", "model.bin"
    ]
    private static let modelDepots = [
        "/.ollama/models", "/.cache/huggingface", "/.cache/lm-studio/models", "/.cache/torch"
    ]
    private static let databaseFileExtensions: Set<String> = ["db", "sqlite", "sqlite3", "realm"]
    private static let databaseSidecarSuffixes = ["-wal", "-shm", "-journal"]
    private static let durableCleanupNames: Set<String> = [
        "credentials", "credential", "sessions", "session", "databases", "database",
        "models", "model", "auth.json", "history.jsonl", "cookies", "history",
        "preferences", "settings.json", "tokens", "secrets", "local storage",
        "indexeddb", "session storage", "keychains", "conversations", "userdata",
        "user data", "skills", "skill.md", "mcp", "mcp.json", "mcp-config.json",
        "mcp_config.json", "config.toml", "config.json", "settings", "config", "configuration"
    ]
    private static let templateSourceNames: Set<String> = [
        "models", "model", "settings.json", "config.toml", "config.json",
        "settings", "config", "configuration"
    ]
    private static let sensitiveAutomationComponents: Set<String> = [
        ".git", "models", "sessions", "conversations", "userdata",
        "user data", "docker", "vms"
    ]
    private static let sensitiveAutomationFragments = [
        "/.codex/sessions", "/.codex/log", "/.codex/auth.json",
        "/.codex/history.jsonl", "/.claude/projects", "/.claude/todos",
        "/.claude/shell-snapshots", "/.gemini/",
        "/.local/share/opencode/project",
        "/library/application support/codex", "/.ollama/models",
        "/.cache/huggingface", "/.cache/lm-studio/models", "/.cache/torch",
        "/library/containers/com.docker", "/library/group containers/group.com.docker",
        "/.docker/contexts", "/.docker/config.json"
    ]

    enum SystemCleanupKind: Sendable {
        case cache, temporary, archivedLog, archivedPowerlog
        case unifiedLog, powerlogTelemetry, codeSignClone
    }

    /// Audited exceptions to system-directory protection. Discovery and the
    /// privileged worker use this same shape policy; metadata/activity checks
    /// remain mandatory at the native deletion edge.
    static func systemCleanupKind(for rawPath: String,
                                  homeDirectory: String = NSHomeDirectory()) -> SystemCleanupKind? {
        if rawPath == homeDirectory || rawPath.hasPrefix(homeDirectory + "/") { return nil }
        guard DeletionPlan.isLexicallySafePath(rawPath) else { return nil }
        let path = normalize(rawPath), home = normalize(homeDirectory)
        guard path != home, !isStrictDescendant(path, of: home) else { return nil }
        if isStrictDescendant(path, of: "/Library/Caches") { return .cache }
        if isStrictDescendant(path, of: "/private/tmp")
            || isStrictDescendant(path, of: "/private/var/tmp") { return .temporary }
        let folders = "/private/var/folders/"
        if path.hasPrefix(folders) {
            let parts = String(path.dropFirst(folders.count)).split(separator: "/")
            // macOS allocates a two-level per-user directory. Only its T/C
            // children qualify, never the user container or either root.
            if parts.count >= 4, parts[0].count == 2 {
                if parts[2] == "T" || parts[2] == "C" { return .temporary }
                // 浏览器更新遗留的代码签名副本：X 下仅 *.code_sign_clone 及其后代。
                if parts[2] == "X", parts[3].hasSuffix(".code_sign_clone") {
                    return .codeSignClone
                }
            }
        }
        let powerRoot = "/private/var/db/powerlog/"
        if path.hasPrefix(powerRoot) {
            if isPowerlogTelemetryPath(path) { return .powerlogTelemetry }
            if isArchivedPowerlogPath(path) { return .archivedPowerlog }
        }
        if isUnifiedLogPath(path) { return .unifiedLog }
        if isStrictDescendant(path, of: "/private/var/log") {
            let name = (path as NSString).lastPathComponent.lowercased()
            if name.range(of: #"^.+\.[0-9]+(?:\.(?:gz|bz2|xz))?$"#,
                          options: .regularExpression) != nil
                || name.range(of: #"^\d{4}\.\d{2}\.\d{2}.+\.asl$"#,
                              options: .regularExpression) != nil {
                return .archivedLog
            }
        }
        return nil
    }

    static func isArchivedPowerlogPath(_ path: String) -> Bool {
        let archives = "/private/var/db/powerlog/Library/BatteryLife/Archives"
        guard path == archives || isStrictDescendant(path, of: archives) else { return false }
        if path == archives { return true }
        let name = (path as NSString).lastPathComponent.lowercased()
        // Current telemetry databases and their companions can be reopened
        // by KeepAlive services even when lsof happens to report no handle.
        guard !name.hasPrefix("current"), !name.hasSuffix("-wal"),
              !name.hasSuffix("-shm"), !name.hasSuffix("-journal") else { return false }
        return name.range(of: #"^powerlog_\d{4}-\d{2}-\d{2}_[0-9a-f]{8}\.plsql(?:\.gz)?$"#,
                          options: .regularExpression) != nil
    }

    /// powerlog 遥测主库及其 SQLite 伴随文件。精确匹配：目录里还有
    /// 别的遥测库、统计分片和 powerlogd 的当前句柄，一概不认领。
    static let powerlogTelemetryDatabase =
        "/private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/CurrentBackgroundProcessingDB.BGSQL"

    static func isPowerlogTelemetryPath(_ path: String) -> Bool {
        path == powerlogTelemetryDatabase
            || path == powerlogTelemetryDatabase + "-wal"
            || path == powerlogTelemetryDatabase + "-shm"
    }

    /// 统一日志旧分片：四个已知子目录本身（供发现层按子目录聚合认领）及其
    /// 直接子级 *.tracev3。uuidtext、timesync、logd、嵌套目录与其它扩展名
    /// 一律不认领。目录本身永远是保留壳——预检不成项、删除不可达，只回收
    /// 其子级分片（与用户 T/C 根"只认子项、不认根"一致）。
    static let unifiedLogDirectories = [
        "/private/var/db/diagnostics/Persist",
        "/private/var/db/diagnostics/Special",
        "/private/var/db/diagnostics/Signpost",
        "/private/var/db/diagnostics/HighVolume"
    ]

    static func isUnifiedLogDirectory(_ path: String) -> Bool {
        unifiedLogDirectories.contains(path)
    }

    static func isUnifiedLogPath(_ path: String) -> Bool {
        unifiedLogDirectories.contains {
            path == $0 || (isDirectChild(path, of: $0) && path.hasSuffix(".tracev3"))
        }
    }

    static func systemCleanupRetention(for path: String,
                                       homeDirectory: String = NSHomeDirectory()) -> TimeInterval? {
        guard let kind = systemCleanupKind(for: path, homeDirectory: homeDirectory) else { return nil }
        switch kind {
        case .powerlogTelemetry, .codeSignClone:
            // 遥测库按体积门槛出现，签名副本浏览器按需重建：都无年龄门槛。
            return nil
        case .unifiedLog:
            return 24 * 60 * 60
        case .temporary:
            // 当前用户自己的 T/C 临时目录 24 小时即可回收；系统级
            // /private/tmp、/private/var/tmp 仍是 7 天。
            return path.hasPrefix("/private/var/folders/") ? 24 * 60 * 60 : 7 * 24 * 60 * 60
        case .cache, .archivedLog, .archivedPowerlog:
            return 7 * 24 * 60 * 60
        }
    }

    /// Mandatory system age/owner gate. Manual selection does not bypass it.
    /// The caller supplies fstat metadata from the no-follow descriptor.
    static func systemCleanupMetadataEligible(path: String, ownerUID: UInt32, userUID: UInt32,
                                             modified: Date, accessed: Date, now: Date = Date(),
                                             homeDirectory: String = NSHomeDirectory()) -> Bool {
        guard let kind = systemCleanupKind(for: path, homeDirectory: homeDirectory),
              let retention = systemCleanupRetention(for: path, homeDirectory: homeDirectory) else { return true }
        guard ownerUID == userUID || ownerUID == 0 else { return false }
        // 统一日志只看 mtime：logd、备份与 Spotlight 会刷新 atime，
        // 用 atime 会把全部旧分片误判成"活跃"。
        let latest = kind == .unifiedLog ? modified : max(modified, accessed)
        return modified.timeIntervalSince1970 > 0 && accessed.timeIntervalSince1970 > 0
            && latest <= now && now.timeIntervalSince(latest) >= retention
    }

    /// Explicit cache leaves inside otherwise durable Agent data. Never
    /// promote the surrounding profile, workspace state or checkpoints.
    private static let auditedRootLock = NSLock()
    private static var auditedRootCache: [String: [String]] = [:]

    static func auditedRebuildableRoots(homeDirectory: String = NSHomeDirectory()) -> [String] {
        let home = normalize(homeDirectory)
        auditedRootLock.lock()
        let existing = auditedRootCache[home]
        auditedRootLock.unlock()
        if let existing { return existing }
        var roots = aiCacheRoots(homeDirectory: home) + [
            home + "/Library/Caches/com.openai.codex",
            home + "/Library/Caches/com.todesktop.230313mzl4w4u92",
            home + "/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt",
            home + "/Library/Caches/cursor-compile-cache",
            home + "/Library/Caches/Zed", home + "/Library/Caches/dev.zed.Zed",
            home + "/Library/Logs/Zed", home + "/Library/Logs/com.openai.codex",
            home + "/Library/Caches/org.blenderfoundation.blender",
            home + "/Library/Application Support/Zed/Cache",
            home + "/Library/Application Support/Zed/hang_traces",
            home + "/Library/Application Support/Zed/node/cache",
            home + "/Library/Application Support/Zed/prettier",
            home + "/Library/Application Support/Zed/languages",
            home + "/Library/Application Support/Zed/extensions/work"
        ]
        for app in ["Codex", "Cursor"] {
            for leaf in ["Cache", "Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs",
                         "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache",
                         "GraphiteDawnCache", "ShaderCache", "logs", "Crashpad/completed"] {
                roots.append(home + "/Library/Application Support/" + app + "/" + leaf)
            }
        }
        roots = Array(Set(roots)).sorted { $0.count > $1.count }
        auditedRootLock.lock()
        auditedRootCache[home] = roots
        auditedRootLock.unlock()
        return roots
    }

    static func auditedRebuildableRoot(containing path: String, homeDirectory: String = NSHomeDirectory()) -> String? {
        let home = normalize(homeDirectory)
        let zedNode = home + "/Library/Application Support/Zed/node/"
        if path.hasPrefix(zedNode) {
            let parts = String(path.dropFirst(zedNode.count)).split(separator: "/").map(String.init)
            if parts.count >= 2, parts[0].hasPrefix("node-v"), parts[1] == "cache" {
                return zedNode + parts[0] + "/cache"
            }
        }
        return auditedRebuildableRoots(homeDirectory: home).first {
            path == $0 || isStrictDescendant(path, of: $0)
        }
    }

    static func downloadedRuntimeRoot(containing path: String, homeDirectory: String = NSHomeDirectory()) -> String? {
        let home = normalize(homeDirectory)
        return [home + "/Library/Caches/ms-playwright", home + "/Library/Caches/Cypress",
                home + "/.cache/puppeteer", home + "/Library/Application Support/Zed/node/cache",
                home + "/Library/Application Support/Zed/prettier",
                home + "/Library/Application Support/Zed/languages"].first {
            path == $0 || isStrictDescendant(path, of: $0)
        }
    }

    private static func hasModelFileSignature(_ component: String) -> Bool {
        // Components already belong to a normalized path. Creating relative
        // file URLs here needlessly resolves each name against the working directory.
        modelBinaryNames.contains(component)
            || modelFileExtensions.contains((component as NSString).pathExtension)
    }
    static func core(section: String,
                     path: String,
                     homeDirectory: String = NSHomeDirectory()) -> CleanupPolicyDescriptor {
        guard (path as NSString).isAbsolutePath else { return protectedUnknown(source: .core) }
        let normalized = normalize(path)

        if isProtectedContent(normalized, homeDirectory: homeDirectory) {
            return protectedDescriptor(source: .core, reasonKey: "cleanup.risk.protectedContent")
        }

        let home = normalize(homeDirectory)

        if let kind = systemCleanupKind(for: normalized, homeDirectory: home) {
            switch kind {
            case .unifiedLog:
                return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                             applyRoute: .genericTrash, activityGuard: .openFile,
                             reasonKey: "cleanup.risk.unifiedLog")
            case .powerlogTelemetry:
                return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                             applyRoute: .genericTrash, activityGuard: .openFile,
                             reasonKey: "cleanup.risk.powerlogTelemetry")
            case .codeSignClone:
                return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                             applyRoute: .genericTrash, activityGuard: .browser,
                             reasonKey: "cleanup.risk.codeSignClone")
            default:
                return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                             applyRoute: .genericTrash, activityGuard: .openFile,
                             reasonKey: "cleanup.risk.rebuildableCache")
            }
        }
        if auditedRebuildableRoot(containing: normalized, homeDirectory: home) != nil {
            return .init(source: .aiCache, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .aiTrash, activityGuard: .openFile,
                         reasonKey: "cleanup.risk.rebuildableCache")
        }

        if let knowledgeDescriptor = appCacheKnowledgeDescriptor(normalized, home: home) {
            return knowledgeDescriptor
        }

        let trashRoot = home + "/.Trash"
        if isDirectChild(normalized, of: trashRoot) {
            // `Parsers` promotes ordinary top-level Trash entries for the
            // cleanup page (age gate 0). Direct callers that do not make that
            // promotion stay Warning by default.
            return warningDescriptor(source: .core, route: .genericTrash,
                                     reasonKey: "cleanup.risk.unknown")
        }

        if isExplicitDeveloperCachePath(normalized, home: home) {
            return developerCache(path: normalized, homeDirectory: homeDirectory)
        }
        let aiDescriptor = ai(kind: "cache", path: normalized,
                              homeDirectory: homeDirectory)
        if aiDescriptor.risk == .safe { return aiDescriptor }
        // These cache-named parents are actually browser profiles. If their
        // rebuildable leaves are absent, never fall back to cleaning cookies
        // and local storage through the broad Library/Caches rule.
        let profileRoots = [home + "/Library/Caches/Codex", home + "/.cache/chrome-devtools-mcp"]
        if profileRoots.contains(where: { normalized == $0 || isStrictDescendant(normalized, of: $0) }) {
            return protectedDescriptor(source: .aiCache, reasonKey: "cleanup.risk.protectedContent")
        }
        if isExplicitXcodeCachePath(normalized, home: home) {
            return xcode(kind: "clean", path: normalized,
                         homeDirectory: homeDirectory)
        }

        let cachePrefix = home + "/Library/Caches/"
        if normalized.hasPrefix(cachePrefix) {
            let remainder = String(normalized.dropFirst(cachePrefix.count))
            let owner = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            let guardKind: CleanupActivityGuard
            if isValidReverseDNSOwner(owner) {
                guardKind = .reverseDNSCache
            } else if isBrowserCacheOwner(owner) {
                guardKind = .browser
            } else {
                // The macOS Caches contract makes the data rebuildable. The
                // final sink still checks one shared open-file snapshot.
                guardKind = .openFile
            }
            return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .genericTrash, activityGuard: guardKind,
                         reasonKey: "cleanup.risk.rebuildableCache")
        }

        // Nori 自己留下的原子写孤儿临时文件按可再生缓存处理；其余支持目录
        // 内容仍由下方的精确根清单认领。
        if NoriOwnedStorage.isOrphanTemporaryFile(normalized, home: home) {
            return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .genericTrash, activityGuard: .openFile,
                         reasonKey: NoriOwnedStorage.reasonKey)
        }

        if let reasonKey = userRebuildableReason(normalized, home: home) {
            return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .genericTrash, activityGuard: .openFile,
                         reasonKey: reasonKey)
        }

        if let owner = containerCacheOwner(normalized, home: home) {
            return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .genericTrash,
                         activityGuard: isValidReverseDNSOwner(owner)
                            ? .reverseDNSCache : .openFile,
                         reasonKey: "cleanup.risk.rebuildableCache")
        }

        if isApplicationSupportCachePath(normalized, home: home) {
            let guardKind: CleanupActivityGuard = isBrowserPath(normalized, section: section)
                ? .browser : .openFile
            return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .genericTrash, activityGuard: guardKind,
                         reasonKey: "cleanup.risk.rebuildableCache")
        }

        let logPrefix = home + "/Library/Logs/"
        if normalized.hasPrefix(logPrefix) {
            return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .genericTrash, activityGuard: .openFile,
                         reasonKey: "cleanup.risk.rebuildableCache")
        }

        let diagnosticPrefix = home + "/Library/DiagnosticReports/"
        if normalized.hasPrefix(diagnosticPrefix) {
            return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .genericTrash, activityGuard: .openFile,
                         reasonKey: "cleanup.risk.diagnosticReport")
        }

        let lowerSection = section.lowercased()
        let reason = lowerSection.contains("backup") ? "cleanup.risk.backup" :
            lowerSection.contains("project") ? "cleanup.risk.projectArtifact" :
            lowerSection.contains("leftover") ? "cleanup.risk.appLeftover" :
            "cleanup.risk.unknown"
        return warningDescriptor(source: .core, route: .genericTrash, reasonKey: reason)
    }

    static func installer() -> CleanupPolicyDescriptor {
        warningDescriptor(source: .installer, route: .installerTrash,
                          reasonKey: "cleanup.risk.installer")
    }

    /// `~/.Trash` 的顶层条目是用户已经决定丢弃的整体（等价于 Finder「清空
    /// 废纸篓」）。其子树不再接受 `.app`、数据库、持久目录名等内容类保护，
    /// 只保留路径、设备、占用与权限等硬安全检查。返回条目根路径。
    static func trashEntryRoot(containing path: String, homeDirectory: String) -> String? {
        let trash = normalizedPathLiteral(homeDirectory) + "/.Trash"
        let normalized = normalizedPathLiteral(path)
        guard normalized.hasPrefix(trash + "/"),
              let first = normalized.dropFirst(trash.count + 1)
                .split(separator: "/", maxSplits: 1).first else { return nil }
        return trash + "/" + first
    }

    /// 整体丢弃、不做内容类保护的根：废纸篓顶层条目，以及 SwiftUI 拖拽在
    /// `~/Library/Caches/com.apple.SwiftUI.Drag-<UUID>` 留下的临时副本目录
    /// （常含整份 .app 拷贝）。正在被读取的文件仍由占用检查保留。
    static func discardedEntryRoot(containing path: String, homeDirectory: String) -> String? {
        if let trash = trashEntryRoot(containing: path, homeDirectory: homeDirectory) { return trash }
        let caches = normalizedPathLiteral(homeDirectory) + "/Library/Caches"
        let normalized = normalizedPathLiteral(path)
        guard normalized.hasPrefix(caches + "/"),
              let first = normalized.dropFirst(caches.count + 1)
                .split(separator: "/", maxSplits: 1).first,
              first.hasPrefix("com.apple.SwiftUI.Drag-") else { return nil }
        return caches + "/" + first
    }

    static func recommendedTrash() -> CleanupPolicyDescriptor {
        .init(source: .core, risk: .safe, disposal: .permanentDelete,
              applyRoute: .genericTrash, activityGuard: .openFile,
              reasonKey: "cleanup.risk.rebuildableCache")
    }

    /// A trashed application with no live bundle match is strong ownership
    /// evidence. Only exact bundle-owned cache/log locations are safe for the
    /// cleanup page; preferences, containers and application support remain
    /// manual analysis data.
    static func appLeftover(path: String,
                            bundleIdentifier: String,
                            homeDirectory: String = NSHomeDirectory()) -> CleanupPolicyDescriptor {
        guard (path as NSString).isAbsolutePath else {
            return protectedUnknown(source: .appLeftover)
        }
        let normalized = normalize(path)
        if isProtectedContent(normalized, homeDirectory: homeDirectory) {
            return protectedDescriptor(source: .appLeftover,
                                       reasonKey: "cleanup.risk.protectedContent")
        }

        let home = normalize(homeDirectory)
        guard isValidReverseDNSOwner(bundleIdentifier) else {
            return warningDescriptor(source: .appLeftover, route: .genericTrash,
                                     reasonKey: "cleanup.risk.appLeftover")
        }
        let safeDirectoryRoots = [
            home + "/Library/Caches/" + bundleIdentifier,
            home + "/Library/Logs/" + bundleIdentifier,
            home + "/Library/Caches/com.apple.nsurlsessiond/Downloads/" + bundleIdentifier,
            // 沙盒容器的缓存/日志叶子同样可再生：归属由容器目录名精确
            // 指向该 Bundle ID，且应用已确认不在安装清单中。
            home + "/Library/Containers/" + bundleIdentifier + "/Data/Library/Caches",
            home + "/Library/Containers/" + bundleIdentifier + "/Data/Library/Logs"
        ]
        if safeDirectoryRoots.contains(where: {
            normalized == $0 || isStrictDescendant(normalized, of: $0)
        }) {
            return .init(source: .appLeftover, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .genericTrash, activityGuard: .none,
                         reasonKey: "cleanup.risk.appLeftover")
        }
        // Application Support is a mixed tree. The orphan bridge splits out
        // explicit cache/log leaves (Cache, Code Cache, GPUCache, Crashpad
        // completed, etc.); only those leaves are safe, while the surrounding
        // app data remains a review-only Warning.
        if isApplicationSupportCachePath(normalized, home: home) {
            return .init(source: .appLeftover, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .genericTrash, activityGuard: .openFile,
                         reasonKey: "cleanup.risk.appLeftover")
        }
        return warningDescriptor(source: .appLeftover, route: .genericTrash,
                                 reasonKey: "cleanup.risk.appLeftover")
    }

    /// 已卸载 AI 工具的数据残留。与“废纸篓关联残留”不同：这里的存在性
    /// 证据是应用本体（bundle 与 PATH 命令）都已确认不存在，整个数据根
    /// 目录含历史、配置和凭据，手动确认后开放清理，不进入快速或自动清理。
    static func uninstalledAgentLeftover(path: String,
                                         homeDirectory: String = NSHomeDirectory(),
                                         verifiedPaths: Set<String> = []) -> CleanupPolicyDescriptor {
        guard (path as NSString).isAbsolutePath else {
            return protectedUnknown(source: .appLeftover)
        }
        let normalized = normalize(path)
        let roots = agentOwnedRoots(homeDirectory: homeDirectory)
        guard roots.contains(where: { normalized == $0 || isStrictDescendant(normalized, of: $0) })
                || verifiedPaths.contains(normalized) else {
            return protectedUnknown(source: .appLeftover)
        }
        return .init(source: .appLeftover, risk: .warning, disposal: .permanentDelete,
                     applyRoute: .genericTrash, activityGuard: .aiAgent,
                     reasonKey: "cleanup.risk.agentLeftover")
    }

    static let appDataReviewThreshold: UInt64 = 300 * 1024 * 1024
    static let appDataLeftoverThreshold: UInt64 = 1024 * 1024

    private static let appleSupportNames: Set<String> = [
        "addressbook", "callhistorydb", "callhistorytransactions", "clouddocs", "crashreporter",
        "dock", "fileprovider", "knowledge", "mobilesync", "syncservices", "icloud", "accounts",
        "differentialprivacy", "facetime", "animoji", "icdd", "applemediaservices", "caches",
        "nori", "com.nori.app", "quick look", "spotlight", "networkserviceproxy", "familycircle",
        "homeenergyd", "locationaccessstored", "screentimeagent", "contextstoreagent", "callservices"
    ]

    static func isAppDataRoot(_ path: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        guard DeletionPlan.isLexicallySafePath(path) else { return false }
        let home = normalize(homeDirectory), normalized = normalize(path)
        let name = (normalized as NSString).lastPathComponent
        let lower = name.lowercased()
        guard !name.isEmpty, !name.hasPrefix("."), !lower.hasPrefix("com.apple."),
              !lower.hasPrefix("group.com.apple."), !lower.contains(".com.apple."),
              !appleSupportNames.contains(lower) else { return false }
        let parent = (normalized as NSString).deletingLastPathComponent
        switch parent {
        case home + "/Library/Application Support", home + "/Library/Containers",
             home + "/Library/Group Containers", home + "/Library/HTTPStorages", home + "/Library/WebKit":
            return true
        case home + "/Library/Saved Application State":
            return lower.hasSuffix(".savedstate")
        case home + "/Library/Preferences":
            return lower.hasSuffix(".plist") && lower != ".globalpreferences.plist"
        default:
            return (parent as NSString).deletingLastPathComponent == home + "/Library/Application Support"
                && isAppDataRoot(parent, homeDirectory: home)
        }
    }

    static func appDataReview(leftover: Bool) -> CleanupPolicyDescriptor {
        .init(source: leftover ? .appLeftover : .core, risk: .warning, disposal: .permanentDelete,
              applyRoute: .genericTrash, activityGuard: .appData,
              reasonKey: leftover ? "cleanup.risk.appDataLeftover" : "cleanup.risk.largeAppData")
    }

    enum ReviewTargetKind: Equatable { case appData, projectArtifact, deviceBackup, mailDownloads, brokenLaunchAgent }

    static func launchAgentProgram(_ plistPath: String) -> String? {
        guard let plist = NSDictionary(contentsOfFile: plistPath) else { return nil }
        if let program = plist["Program"] as? String { return program }
        return (plist["ProgramArguments"] as? [String])?.first
    }

    static func isBrokenLaunchAgent(_ path: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let home = normalize(homeDirectory), normalized = normalize(path)
        guard isDirectChild(normalized, of: home + "/Library/LaunchAgents"),
              normalized.lowercased().hasSuffix(".plist"),
              let program = launchAgentProgram(normalized), program.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: program) else { return false }
        if program.hasPrefix("/Volumes/") {
            let volume = program.split(separator: "/").prefix(2).joined(separator: "/")
            return FileManager.default.fileExists(atPath: "/" + volume)
        }
        return true
    }

    static let projectArtifactMarkers: [String: [String]] = [
        "node_modules": ["package.json"], ".next": ["package.json"], ".nuxt": ["package.json"],
        ".svelte-kit": ["package.json"], ".turbo": ["package.json"], ".parcel-cache": ["package.json"],
        ".angular": ["angular.json"], "target": ["Cargo.toml", "pom.xml"], "Pods": ["Podfile"],
        ".gradle": ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
        ".dart_tool": ["pubspec.yaml"], ".venv": [], "venv": []
    ]

    static func isProjectArtifact(_ path: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let home = normalize(homeDirectory), normalized = normalize(path)
        guard DeletionPlan.isLexicallySafePath(normalized), isStrictDescendant(normalized, of: home),
              !isStrictDescendant(normalized, of: home + "/Library"),
              !isStrictDescendant(normalized, of: home + "/.Trash") else { return false }
        let name = (normalized as NSString).lastPathComponent
        guard let markers = projectArtifactMarkers[name] else { return false }
        let ancestors = normalized.dropFirst(home.count).split(separator: "/").dropLast()
        guard !ancestors.contains(where: { projectArtifactMarkers[String($0)] != nil || $0 == ".git" }) else { return false }
        let fm = FileManager.default
        if markers.isEmpty { return fm.fileExists(atPath: normalized + "/pyvenv.cfg") }
        let parent = (normalized as NSString).deletingLastPathComponent
        return markers.contains { fm.fileExists(atPath: parent + "/" + $0) }
    }

    static func reviewTargetKind(_ path: String, homeDirectory: String = NSHomeDirectory()) -> ReviewTargetKind? {
        let home = normalize(homeDirectory), normalized = normalize(path)
        if normalized == home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads" { return .mailDownloads }
        if isDirectChild(normalized, of: home + "/Library/Application Support/MobileSync/Backup") { return .deviceBackup }
        if isAppDataRoot(normalized, homeDirectory: home) { return .appData }
        if isProjectArtifact(normalized, homeDirectory: home) { return .projectArtifact }
        if isBrokenLaunchAgent(normalized, homeDirectory: home) { return .brokenLaunchAgent }
        return nil
    }

    static func reviewDescriptor(_ kind: ReviewTargetKind) -> CleanupPolicyDescriptor {
        switch kind {
        case .appData: return appDataReview(leftover: false)
        case .projectArtifact:
            return .init(source: .developerCache, risk: .warning, disposal: .permanentDelete,
                         applyRoute: .genericTrash, activityGuard: .appData, reasonKey: "cleanup.risk.projectArtifact")
        case .deviceBackup:
            return .init(source: .core, risk: .warning, disposal: .permanentDelete,
                         applyRoute: .genericTrash, activityGuard: .appData, reasonKey: "cleanup.risk.deviceBackup")
        case .mailDownloads:
            return .init(source: .core, risk: .warning, disposal: .permanentDelete,
                         applyRoute: .genericTrash, activityGuard: .appData, reasonKey: "cleanup.risk.mailDownloads")
        case .brokenLaunchAgent:
            return .init(source: .appLeftover, risk: .warning, disposal: .permanentDelete,
                         applyRoute: .genericTrash, activityGuard: .appData, reasonKey: "cleanup.risk.brokenLaunchAgent")
        }
    }

    static func developerCache(path: String,
                               homeDirectory: String = NSHomeDirectory()) -> CleanupPolicyDescriptor {
        guard (path as NSString).isAbsolutePath else {
            return protectedUnknown(source: .developerCache)
        }
        let normalized = normalize(path)
        if isProtectedContent(normalized, homeDirectory: homeDirectory) {
            return protectedDescriptor(source: .developerCache,
                                       reasonKey: "cleanup.risk.protectedContent")
        }

        let home = normalize(homeDirectory)
        // Dependency stores that builds resolve from directly (Maven local
        // repository, NuGet global packages, Dart pub cache, Cargo git
        // checkouts, Gradle module cache) are review-only, matching Mole's
        // recovery-contract rule: emptying them is not a cache refresh but a
        // forced full re-download, and ~/.m2 may hold locally installed
        // SNAPSHOT artifacts that exist on no remote at all.
        if dependencyStoreRoots(home: home).contains(where: {
            normalized == $0 || isStrictDescendant(normalized, of: $0)
        }) && !isGradleBuildCachePath(normalized, home: home) {
            return warningDescriptor(source: .developerCache, route: .developerCacheTrash,
                                     reasonKey: "cleanup.risk.dependencyStore")
        }
        let explicitSafeRoots = developerCacheRoots(home: home)
        if explicitSafeRoots.contains(where: { normalized == $0 || isStrictDescendant(normalized, of: $0) })
            || isGradleBuildCachePath(normalized, home: home) {
            return .init(source: .developerCache, risk: .safe, disposal: .permanentDelete,
                         // Shared package caches can be touched by arbitrary
                         // build processes.  A process-name guard would hide
                         // all caches behind unrelated `node`/`python`/`java`
                         // services, so the bridge uses one lsof snapshot for
                         // the selected subtree and fails closed when it is
                         // unavailable.
                         applyRoute: .developerCacheTrash, activityGuard: .openFile,
                         reasonKey: "cleanup.risk.rebuildableDeveloperCache")
        }

        let reverseDNSCachePrefix = home + "/Library/Caches/"
        if normalized.hasPrefix(reverseDNSCachePrefix) {
            let remainder = String(normalized.dropFirst(reverseDNSCachePrefix.count))
            let owner = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if isValidReverseDNSOwner(owner) {
                return .init(source: .developerCache, risk: .safe, disposal: .permanentDelete,
                             applyRoute: .developerCacheTrash, activityGuard: .reverseDNSCache,
                             reasonKey: "cleanup.risk.rebuildableDeveloperCache")
            }
        }

        return warningDescriptor(source: .developerCache, route: .developerCacheTrash,
                                 reasonKey: "cleanup.risk.unverifiedDeveloperCache")
    }

    static func ai(kind: String,
                   path: String,
                   homeDirectory: String = NSHomeDirectory()) -> CleanupPolicyDescriptor {
        let normalizedKind = kind.lowercased()
        let source: CleanupSource = normalizedKind == "session" ? .aiSession :
            (normalizedKind == "model" || normalizedKind == "keep" ? .aiModel : .aiCache)
        guard (path as NSString).isAbsolutePath else {
            return protectedUnknown(source: source)
        }
        let normalized = normalize(path)
        if isProtectedContent(normalized, homeDirectory: homeDirectory) {
            return protectedDescriptor(source: source, reasonKey: "cleanup.risk.protectedContent")
        }
        switch normalizedKind {
        case "model", "keep":
            return protectedDescriptor(source: .aiModel, reasonKey: "cleanup.risk.model")
        case "session":
            return warningDescriptor(source: .aiSession, route: .aiTrash,
                                     reasonKey: "cleanup.risk.userSession")
        case "cache":
            if aiCacheRoots(homeDirectory: homeDirectory).contains(where: {
                normalized == $0 || isStrictDescendant(normalized, of: $0)
            }) {
                return .init(source: .aiCache, risk: .safe, disposal: .permanentDelete,
                             applyRoute: .aiTrash, activityGuard: .ide,
                             reasonKey: "cleanup.risk.rebuildableCache")
            }
            return warningDescriptor(source: .aiCache, route: .aiTrash,
                                     reasonKey: "cleanup.risk.unverifiedCache")
        default:
            return warningDescriptor(source: .aiCache, route: .aiTrash,
                                     reasonKey: "cleanup.risk.unknown")
        }
    }

    /// Discovery and deletion classification share the same audited leaves.
    static func aiCacheRoots(homeDirectory: String = NSHomeDirectory()) -> [String] {
        let home = normalize(homeDirectory)
        return [
                home + "/.claude/statsig",
                // Codex Desktop keeps a rebuildable Chromium/electron cache
                // under Library/Caches.  Its settings, auth and session data
                // live elsewhere (Application Support / ~/.codex) and remain
                // outside this allowlist.
                // Keep this in lockstep with vendor/mole's audited Codex
                // Desktop catalog. The profile parent also contains durable
                // browser state and must never be blanket-cleaned.
                home + "/Library/Caches/Codex/Default/Cache",
                home + "/Library/Caches/Codex/Default/Code Cache",
                home + "/Library/Caches/Codex/Default/Partitions/codex-browser-app/Cache",
                home + "/Library/Caches/Codex/Default/Partitions/codex-browser-app/Code Cache",
                home + "/Library/Caches/Codex/codex-browser-app/Cache",
                home + "/Library/Caches/Codex/codex-browser-app/Code Cache",
                home + "/Library/Application Support/Code/Cache",
                home + "/Library/Application Support/Code/Code Cache",
                home + "/Library/Application Support/Code/GPUCache",
                home + "/Library/Application Support/Code/CachedData",
                home + "/Library/Application Support/Code/logs",
                home + "/Library/Application Support/Code/CachedExtensionVSIXs",
                home + "/Library/Application Support/Cursor/Cache",
                home + "/Library/Application Support/Cursor/Code Cache",
                home + "/Library/Application Support/Cursor/GPUCache",
                home + "/Library/Application Support/Cursor/CachedData",
                home + "/Library/Application Support/Cursor/logs",
                home + "/Library/Application Support/Cursor/CachedExtensionVSIXs",
                // Electron AI clients. Keep this list at cache leaves rather
                // than app-support parents: preferences, credentials,
                // extensions and project state are durable user data.
                home + "/Library/Application Support/Antigravity/Cache",
                home + "/Library/Application Support/Antigravity/Code Cache",
                home + "/Library/Application Support/Antigravity/GPUCache",
                home + "/Library/Application Support/Antigravity/DawnGraphiteCache",
                home + "/Library/Application Support/Antigravity/DawnWebGPUCache",
                home + "/Library/Application Support/Filo/production/Cache",
                home + "/Library/Application Support/Filo/production/Code Cache",
                home + "/Library/Application Support/Filo/production/GPUCache",
                home + "/Library/Application Support/Filo/production/DawnGraphiteCache",
                home + "/Library/Application Support/Filo/production/DawnWebGPUCache",
                home + "/Library/Application Support/Claude/Cache",
                home + "/Library/Application Support/Claude/Code Cache",
                home + "/Library/Application Support/Claude/GPUCache",
                home + "/Library/Application Support/Claude/DawnGraphiteCache",
                home + "/Library/Application Support/Claude/DawnWebGPUCache",
                home + "/Library/Application Support/Claude/sentry",
                home + "/Library/Application Support/Qoder/Cache",
                home + "/Library/Application Support/Qoder/CachedData",
                home + "/Library/Application Support/Qoder/CachedExtensionVSIXs",
                home + "/Library/Application Support/Qoder/Code Cache",
                home + "/Library/Application Support/Qoder/GPUCache",
                home + "/Library/Application Support/Qoder/DawnGraphiteCache",
                home + "/Library/Application Support/Qoder/DawnWebGPUCache",
                home + "/Library/Application Support/Qoder/logs",
                home + "/.cache/prisma",
                // OpenCode keeps durable project/session state under
                // ~/.local/share/opencode/project; only its XDG cache root is
                // included here.
                home + "/.cache/opencode",
                home + "/Library/Caches/ms-playwright",
                home + "/Library/Caches/Cypress",
                home + "/.cache/puppeteer",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/Cache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/Code Cache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/GPUCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/DawnGraphiteCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/DawnWebGPUCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/DawnCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/GrShaderCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/GraphiteDawnCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/GraphiteDawnCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/component_crx_cache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/extensions_crx_cache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/Service Worker/CacheStorage",
                home + "/Library/Caches/electron",
                home + "/Library/Caches/electron-builder"
        ]
    }

    /// Agent 专清接管的根：磁盘清理默认流程不再发现、计量或推荐这些路径，
    /// 它们只在 Agent 页按目录逐项呈现。与 `AgentCatalog` 的目录保持一致。
    static func agentOwnedRoots(homeDirectory: String = NSHomeDirectory()) -> [String] {
        let home = normalize(homeDirectory)
        let support = [
            "Cursor", "Claude", "Codex", "Antigravity", "Devin", "Windsurf",
            "Qoder", "Kiro", "Trae", "Zed", "dev.warp.Warp-Stable"
        ].map { home + "/Library/Application Support/" + $0 }
        let dotted = [
            ".cache/opencode", ".cache/chrome-devtools-mcp", ".claude", ".codex", ".cursor",
            ".grok", ".gemini", ".copilot", ".kimi", ".kimi-code", ".pi", ".factory", ".claude.json",
            ".qoder", ".kiro", ".trae", ".warp", ".devin", ".codeium", ".opencode",
            ".config/opencode", ".config/amp", ".config/crush", ".config/devin", ".config/zed",
            ".cache/amp", ".cache/crush", ".cache/.gemini", ".cache/chrome-devtools-mcp-cli",
            ".cache/codex-blender", ".cache/codex-runtimes",
            ".local/share/amp", ".local/share/crush", ".local/state/opencode",
            ".local/share/opencode", ".local/share/claude", ".local/share/cursor-agent"
        ].map { home + "/" + $0 }
        let warp = ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"].map {
            home + "/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/" + $0
        }
        return support + dotted + warp
    }

    static func isCoveredByGlobalCleanup(_ path: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let home = normalize(homeDirectory), normalized = normalize(path)
        if auditedRebuildableRoot(containing: normalized, homeDirectory: home) != nil { return true }
        for root in [home + "/Library/Caches", home + "/Library/Logs"] where isStrictDescendant(normalized, of: root) {
            guard let owner = normalized.dropFirst(root.count + 1).split(separator: "/").first else { return false }
            return core(section: "Cache", path: root + "/" + owner, homeDirectory: home).risk == .safe
        }
        return false
    }

    static func isAgentOwnedPath(_ path: String,
                                 homeDirectory: String = NSHomeDirectory()) -> Bool {
        let normalized = normalize(path)
        if auditedRebuildableRoot(containing: normalized, homeDirectory: homeDirectory) != nil { return false }
        return agentOwnedRoots(homeDirectory: homeDirectory).contains {
            normalized == $0 || isStrictDescendant(normalized, of: $0)
        }
    }

    static func xcode(kind: String,
                      path: String,
                      homeDirectory: String = NSHomeDirectory()) -> CleanupPolicyDescriptor {
        let normalizedKind = kind.lowercased()
        let source: CleanupSource = normalizedKind == "keep" ? .xcodeArchive : .xcodeCache
        guard (path as NSString).isAbsolutePath else {
            return protectedUnknown(source: source)
        }
        let normalized = normalize(path)
        let home = normalize(homeDirectory)
        let archiveRoot = home + "/Library/Developer/Xcode/Archives"
        if normalizedKind == "keep" || normalized == archiveRoot ||
            isStrictDescendant(normalized, of: archiveRoot) {
            return protectedDescriptor(source: .xcodeArchive, reasonKey: "cleanup.risk.archive")
        }
        if isProtectedContent(normalized, homeDirectory: homeDirectory) {
            return protectedDescriptor(source: .xcodeCache,
                                       reasonKey: "cleanup.risk.protectedContent")
        }
        let simulatorCacheRoot = home + "/Library/Developer/CoreSimulator/Caches"
        let safeRoots = xcodeCacheRoots(home: home)
        if safeRoots.contains(where: {
            normalized == $0 || isStrictDescendant(normalized, of: $0)
        }) {
            let guardKind: CleanupActivityGuard =
                normalized == simulatorCacheRoot || isStrictDescendant(normalized, of: simulatorCacheRoot)
                ? .simulator : .xcode
            return .init(source: .xcodeCache, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .xcodeTrash, activityGuard: guardKind,
                         reasonKey: "cleanup.risk.rebuildableDeveloperCache")
        }
        // DeviceSupport keeps one symbol tree per connected OS build. The
        // scanner offers only versions beyond the newest two as `clean`
        // (Mole's MOLE_XCODE_DEVICE_SUPPORT_KEEP); Xcode copies symbols again
        // from a device the next time it is attached, so the version
        // directories themselves are rebuildable. The root and anything
        // deeper stay review-only.
        if normalizedKind == "clean", isStaleDeviceSupportVersion(normalized, home: home) {
            return .init(source: .xcodeCache, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .xcodeTrash, activityGuard: .xcode,
                         reasonKey: "cleanup.risk.staleDeviceSupport")
        }
        return warningDescriptor(source: .xcodeCache, route: .xcodeTrash,
                                 reasonKey: "cleanup.risk.deviceSupport")
    }

    /// Rebuildable Xcode roots shared by the native scanner, the Xcode bridge
    /// and the policy. XCTestDevices holds per-run simulator clones that Xcode
    /// recreates inside the root on the next test run.
    static func xcodeCacheRoots(home: String) -> [String] {
        [
            home + "/Library/Developer/Xcode/DerivedData",
            home + "/Library/Developer/Xcode/SourcePackages",
            home + "/Library/Caches/com.apple.dt.Xcode",
            home + "/Library/Developer/CoreSimulator/Caches",
            home + "/Library/Developer/XCTestDevices"
        ]
    }

    static func deviceSupportRoots(home: String) -> [String] {
        [
            home + "/Library/Developer/Xcode/iOS DeviceSupport",
            home + "/Library/Developer/Xcode/watchOS DeviceSupport",
            home + "/Library/Developer/Xcode/tvOS DeviceSupport",
            home + "/Library/Developer/Xcode/visionOS DeviceSupport"
        ]
    }

    private static func isStaleDeviceSupportVersion(_ path: String, home: String) -> Bool {
        deviceSupportRoots(home: home).contains { isDirectChild(path, of: $0) }
    }

    // MARK: - 缓存地图（macOS 应用缓存知识库）
    //
    // 每条规则来自实际清理审计：是什么、能否重建、删除前提、连带禁区。
    // 地图上没有的路径保持默认 Warning——查清楚之前不动。

    /// Chromium 系浏览器的 profile 根（Application Support 下相对路径）。
    /// ChromeDebug 是自动化调试用独立 user-data-dir，整个目录可重建。
    private static let browserProfileRelativeRoots = [
        "Google/Chrome",
        "Google/Chrome Beta",
        "Google/Chrome Canary",
        "Google/ChromeDebug",
        "Chromium",
        "Microsoft Edge",
        "BraveSoftware/Brave-Browser",
        "Arc/User Data",
        "Dia/User Data",
        "Vivaldi",
        "com.operasoftware.Opera",
        "Yandex/YandexBrowser",
        "QQBrowser3",
        "net.imput.helium"
    ]

    /// 浏览器 profile 内的持久用户数据：登录态、站点数据库、偏好、书签。
    /// 与 Service Worker 同级共存，误删等于丢登录态。
    private static let durableBrowserComponents: Set<String> = [
        "indexeddb", "local storage", "login data", "login data for account",
        "cookies", "cookies-journal", "preferences", "secure preferences",
        "bookmarks", "bookmarks.bak", "web data", "sessions", "databases"
    ]

    /// Chromium 系浏览器的端侧 AI 模型目录（OptGuide / Gemini Nano）。
    /// 浏览器在需要时重新下载，删除前提与 Service Worker 缓存相同。
    private static let browserOnDeviceModelLeaves: Set<String> = [
        "optguideondevicemodel", "optguideondeviceclassifiermodel",
        "optimization_guide_model_store"
    ]

    private static let telegramGroupRootName = "6N38VWS5BX.ru.keepcoder.Telegram"
    private static let larkShellRelativeRoot = "LarkShell"

    /// 缓存地图裁决：命中返回描述符，未命中返回 nil 走通用规则。
    /// 顺序即优先级：禁区先于可清项。
    static func appCacheKnowledgeDescriptor(_ path: String, home: String) -> CleanupPolicyDescriptor? {
        let appSupport = home + "/Library/Application Support/"
        let groupContainers = home + "/Library/Group Containers/"

        // --- Telegram：只有 account-*/postbox/media 是可再生媒体缓存。
        // postbox/db 是本地消息数据库，其余目录同样是聊天数据。
        let telegramPrefix = groupContainers + telegramGroupRootName + "/"
        if path == groupContainers + telegramGroupRootName
            || path.hasPrefix(telegramPrefix) {
            let components = path == groupContainers + telegramGroupRootName
                ? [] : splitComponents(String(path.dropFirst(telegramPrefix.count)))
            if components.count == 3,
               components[0].hasPrefix("account-"),
               components[1] == "postbox",
               components[2] == "media" {
                return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                              applyRoute: .genericTrash, activityGuard: .messenger,
                              reasonKey: "cleanup.risk.messengerCache")
            }
            return protectedDescriptor(source: .core, reasonKey: "cleanup.risk.durableIMData")
        }

        // --- 飞书：只认 aha/users/<id>/profile_explorer（文档预览缓存）。
        // sdk_storage/database 是消息数据，profile_main 里有登录态。
        let larkPrefix = appSupport + larkShellRelativeRoot + "/"
        if path == appSupport + larkShellRelativeRoot || path.hasPrefix(larkPrefix) {
            let components = path == appSupport + larkShellRelativeRoot
                ? [] : splitComponents(String(path.dropFirst(larkPrefix.count)))
            if components.count == 4,
               components[0] == "aha",
               components[1] == "users",
               components[3] == "profile_explorer" {
                return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                              applyRoute: .genericTrash, activityGuard: .messenger,
                              reasonKey: "cleanup.risk.messengerCache")
            }
            return protectedDescriptor(source: .core, reasonKey: "cleanup.risk.durableIMData")
        }

        // --- 微信 4.x：xwechat_files/<账号>/ 下 cache、temp 是可再生缓存；
        // msg/video、msg/attach 是聊天视频/图片，可重新下载但过期内容无法找回，
        // 默认不勾选。db_storage、config、msg/file、all_users、Backup 等一律保护。
        // 守卫用 openFile：数据库不在可清范围，正在写入的文件由删除边界的
        // 占用检查保留，微信运行中也能清理闲置媒体。
        let wechatRoot = home + "/" + WeChatStorage.filesRelativeRoot
        if path == wechatRoot || path.hasPrefix(wechatRoot + "/") {
            let components = path == wechatRoot
                ? [] : splitComponents(String(path.dropFirst(wechatRoot.count + 1)))
            if components.count >= 2, WeChatStorage.isAccountDirectory(components[0]) {
                let relative = components.dropFirst().joined(separator: "/")
                for leaf in WeChatStorage.leaves
                    where relative == leaf.relative || relative.hasPrefix(leaf.relative + "/") {
                    return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                                  applyRoute: .genericTrash, activityGuard: .openFile,
                                  reasonKey: leaf.reasonKey)
                }
            }
            return protectedDescriptor(source: .core, reasonKey: "cleanup.risk.durableIMData")
        }

        // --- 浏览器更新器已下载的组件包缓存：下次检查更新时重新拉取。
        for updaterCache in ["Google/GoogleUpdater/crx_cache",
                             "Microsoft/EdgeUpdater/crx_cache"] {
            let root = appSupport + updaterCache
            if path == root || isStrictDescendant(path, of: root) {
                return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                              applyRoute: .genericTrash, activityGuard: .openFile,
                              reasonKey: "cleanup.risk.rebuildableCache")
            }
        }

        // --- Chromium 系浏览器 profile。
        for relative in browserProfileRelativeRoots {
            let root = appSupport + relative
            guard path == root || isStrictDescendant(path, of: root) else { continue }
            let components = splitComponents(String(path.dropFirst(appSupport.count)))
            // 调试用独立 profile 整体可再生（下次调试启动自动重建）。
            if relative == "Google/ChromeDebug" {
                return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                              applyRoute: .genericTrash, activityGuard: .browser,
                              reasonKey: "cleanup.risk.rebuildableCache")
            }
            // 持久用户数据（IndexedDB/Login Data/Cookies/Preferences…）。
            if components.dropFirst().contains(where: {
                durableBrowserComponents.contains($0)
            }) {
                return protectedDescriptor(source: .core,
                                           reasonKey: "cleanup.risk.durableIMData")
            }
            // Service Worker 目录整体可再生（含 ScriptCache/CacheStorage）。
            if components.dropFirst().contains("service worker") {
                return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                              applyRoute: .genericTrash, activityGuard: .browser,
                              reasonKey: "cleanup.risk.rebuildableCache")
            }
            // 端侧 AI 模型整体可再生：浏览器按需重新下载。
            if components.dropFirst().contains(where: browserOnDeviceModelLeaves.contains) {
                return .init(source: .core, risk: .safe, disposal: .permanentDelete,
                              applyRoute: .genericTrash, activityGuard: .browser,
                              reasonKey: "cleanup.risk.browserOnDeviceModel")
            }
            // 其余部分（Cache/Code Cache 等）交给通用 Application Support
            // 缓存叶子规则裁决。
            return nil
        }
        return nil
    }

    private static func splitComponents(_ value: String) -> [String] {
        value.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.lowercased() }
    }

    static func tool() -> CleanupPolicyDescriptor {
        .init(source: .tool, risk: .warning, disposal: .command,
              applyRoute: .toolCommand, activityGuard: .unsupported,
              reasonKey: "cleanup.risk.ownerCommand")
    }

    /// Audited rebuildable filesystem items use the actual file-activity guard
    /// at the deletion edge. A running owner alone does not make its idle cache
    /// files unsafe. Whole uninstall leftovers remain sensitive even when an
    /// older inventory incorrectly stored their risk as Safe.
    static func usesFileActivityGuard(_ category: CleanupCategory) -> Bool {
        guard category.risk == .safe, category.disposal == .permanentDelete,
              category.activityGuard != .unsupported, category.source != .appLeftover,
              category.reasonKey != "cleanup.risk.agentLeftover" else { return false }
        switch category.applyRoute {
        case .genericTrash, .installerTrash, .developerCacheTrash, .aiTrash, .xcodeTrash:
            return true
        case .toolCommand, .none:
            return false
        }
    }

    /// 应用执行前使用新快照重判。风险只会保持或升高，不会在旧扫描上降级。
    static func reassess(_ category: CleanupCategory,
                         running snapshot: RunningApplicationSnapshot,
                         homeDirectory: String = NSHomeDirectory()) -> CleanupRiskAssessment {
        let risk = currentRisk(category)
        // Agent 用户可选项同样要在执行前复核归属者；风险保持 Warning，
        // 只可能升级为 Protected，不会被降成 Safe。
        let agentReview = risk == .warning
            && (category.activityGuard == .aiAgent || category.activityGuard == .appData)
        guard risk == .safe || agentReview else {
            return .init(risk: risk, reasonKey: category.reasonKey)
        }
        guard category.activityGuard != .unsupported else {
            return .init(risk: .protected, reasonKey: "cleanup.risk.runtimeUnsupported")
        }
        if usesFileActivityGuard(category) {
            return .init(risk: .safe, reasonKey: category.reasonKey)
        }
        guard category.activityGuard != .none else {
            return .init(risk: risk, reasonKey: category.reasonKey)
        }
        guard snapshot.isComplete else {
            return .init(risk: .protected, reasonKey: "cleanup.risk.runtimeUnknown")
        }
        if ownerIsRunning(for: category, snapshot: snapshot, homeDirectory: homeDirectory) {
            return .init(risk: .protected, reasonKey: "cleanup.risk.runningApplication")
        }
        return .init(risk: risk, reasonKey: category.reasonKey)
    }

    private static func currentRisk(_ category: CleanupCategory) -> CleanupRisk {
        category.risk == .safe && category.reasonKey == "cleanup.risk.agentLeftover"
            ? .warning : category.risk
    }

    /// Use the same ownership policy as execution to name prerequisites before
    /// a manual task begins. Reading a snapshot never mutates the selection.
    static func blockingOwners(_ requested: [CleanupCategory],
                               running snapshot: RunningApplicationSnapshot,
                               homeDirectory: String = NSHomeDirectory()) -> [String] {
        guard snapshot.isComplete else { return [] }
        let categories = requested.filter {
            $0.selectedPathCount > 0 && !usesFileActivityGuard($0)
                && (currentRisk($0) == .safe || (currentRisk($0) == .warning && $0.activityGuard == .aiAgent))
        }
        let processes = snapshot.processNames.filter { owner in
            let single = RunningApplicationSnapshot(processNames: [owner])
            return categories.contains {
                ownerIsRunning(for: $0, snapshot: single, homeDirectory: homeDirectory)
            }
        }
        let bundles = snapshot.bundleIdentifiers.filter { owner in
            let single = RunningApplicationSnapshot(bundleIdentifiers: [owner])
            return categories.contains {
                ownerIsRunning(for: $0, snapshot: single, homeDirectory: homeDirectory)
            }
        }
        return Array(Set(processes).union(bundles)).sorted()
    }

    /// 可再生缓存保留用户选择，由执行边界核对实际文件占用。
    /// 敏感数据仍按运行归属者裁剪选择，分类和总容量保留在结果中。
    static func runtimeEligibleSubset(
        _ category: CleanupCategory,
        running snapshot: RunningApplicationSnapshot,
        homeDirectory: String = NSHomeDirectory()
    ) -> CleanupCategory? {
        var category = category
        category.risk = currentRisk(category)
        if usesFileActivityGuard(category) { return category }
        if category.activityGuard == .aiAgent || category.activityGuard == .appData, category.risk != .protected {
            guard snapshot.isComplete,
                  !ownerIsRunning(for: category, snapshot: snapshot,
                                  homeDirectory: homeDirectory) else {
                return category.clearingSelection()
            }
            return category
        }
        guard category.risk == .safe else { return category }
        switch category.activityGuard {
        case .none, .openFile, .packageManager:
            // `.packageManager` is retained for decoding older cached
            // snapshots.  New scans use `.openFile`; treating the legacy
            // value the same way prevents a generic runtime process from
            // hiding every developer cache.  The apply bridge remains the
            // authoritative open-file check.
            return category
        case .unsupported:
            return nil
        case .reverseDNSCache:
            guard snapshot.isComplete else { return category.clearingSelection() }
            let selectable = category.paths.filter { path in
                pathOwnerRunning(path, snapshot: snapshot,
                                 homeDirectory: homeDirectory) == false
            }
            return category.selectingPaths(selectable)
        case .browser, .xcode, .simulator, .ide, .messenger, .aiAgent, .appData:
            guard snapshot.isComplete else { return category.clearingSelection() }
            guard !ownerIsRunning(for: category, snapshot: snapshot,
                                  homeDirectory: homeDirectory) else {
                return category.clearingSelection()
            }
            return category
        }
    }

    static func isEligible(_ category: CleanupCategory,
                           mode: CleanupExecutionMode,
                           running snapshot: RunningApplicationSnapshot,
                           homeDirectory: String = NSHomeDirectory()) -> Bool {
        let assessment = reassess(category, running: snapshot, homeDirectory: homeDirectory)
        switch mode {
        case .manual:
            switch category.disposal {
            case .permanentDelete:
                // Warning 文件删除只对带归属守卫的 Agent 目录项开放：
                // 它们的归属者刚被复核过且未运行，其余 Warning 仍不可执行。
                return assessment.risk == .safe
                    || ((category.activityGuard == .aiAgent || category.activityGuard == .appData)
                        && assessment.risk == .warning)
            case .command:
                return assessment.risk != .protected
            case .none:
                return false
            }
        case .quickClean, .automatic:
            return assessment.risk == .safe && category.disposal == .permanentDelete
        }
    }

    /// 自动目录不得与模型、用户会话、Docker 数据或系统根目录重叠。
    static func isForbiddenAutomationPath(_ path: String,
                                          homeDirectory: String = NSHomeDirectory()) -> Bool {
        guard (path as NSString).isAbsolutePath else { return true }
        let normalized = normalize(path)
        let protectedRoots = protectedContentRoots(homeDirectory: homeDirectory) + protectedAbsoluteRoots
        return protectedRoots.contains { pathsOverlap(normalized, normalize($0)) }
    }

    /// Shared discovery/deletion content guard. A rebuildable root changes
    /// only the structural context; it does not grant deletion authorization.
    /// Model weights, databases and credentials stay protected even in a cache.
    static func isProtectedCleanupPath(
        _ rawPath: String,
        homeDirectory: String = NSHomeDirectory(),
        rebuildableRoot: String? = nil,
        rootIsVerifiedRebuildable: Bool = false,
        allowApplicationBundle: Bool = false,
        rebuildableRootPolicy: CleanupPolicyDescriptor? = nil
    ) -> Bool {
        guard DeletionPlan.isLexicallySafePath(rawPath) else { return true }
        let path = normalize(rawPath)
        let home = normalize(homeDirectory)
        let fullComponents = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased() }
        // A split inventory may submit a metadata child as its own cache root.
        // Check immutable model signatures before any ancestor is stripped.
        if fullComponents.contains(where: hasModelFileSignature) { return true }
        // Catalog verification never overrides a real model depot, even if a
        // caller accidentally labels a descendant as a rebuildable cache.
        let lowerPath = path.lowercased()
        if modelDepots.contains(where: { lowerPath.hasSuffix($0) || lowerPath.contains($0 + "/") }) {
            return true
        }
        let root = rebuildableRoot.flatMap {
            DeletionPlan.isLexicallySafePath($0) ? normalize($0) : nil
        }
        let verifiedRoot = root.flatMap { root -> String? in
            guard DeletionPlan.isLexicallySafePath(root),
                  path == root || isStrictDescendant(path, of: root) else { return nil }
            if rootIsVerifiedRebuildable { return root }
            let descriptor = rebuildableRootPolicy ?? core(section: "Cache", path: root, homeDirectory: home)
            return descriptor.risk == .safe && descriptor.disposal == .permanentDelete ? root : nil
        }
        let templateSource = verifiedRoot != nil && isDisposablePackageTemplateSourcePath(path, home: home)
        let downloadedRuntime = verifiedRoot != nil && downloadedRuntimeRoot(containing: path, homeDirectory: home) != nil
        let runtimeSource = downloadedRuntime && (fullComponents.contains("node_modules")
            || fullComponents.contains("site-packages")
            || fullComponents.enumerated().contains { index, name in
                name.hasSuffix(".app") && index + 1 < fullComponents.count && fullComponents[index + 1] == "contents"
            })
        let archivedDatabase = isArchivedPowerlogPath(path) || isPowerlogTelemetryPath(path)
        let homeRelativePath = isStrictDescendant(path, of: home) ? String(path.dropFirst(home.count)) : path
        if !templateSource && !runtimeSource && homeRelativePath.split(separator: "/").contains(where: {
            $0.lowercased() == "models" || $0.lowercased() == "model"
        }) { return true }
        // Ordinary cached child records must retain durable ancestry. Only a
        // catalog-verified root may shed its data parent's context; rebasing a
        // generic scan root is never evidence that those ancestors are junk.
        let contextPath = rootIsVerifiedRebuildable ? (verifiedRoot.map {
            "/nori-rebuildable-cache/" + URL(fileURLWithPath: $0).lastPathComponent + String(path.dropFirst($0.count))
        } ?? path) : "/nori-home-context" + homeRelativePath
        // `models` in a downloaded SPA template denotes source-code models,
        // not model weights. Only this precise generated source tree gets the
        // name exception; known model files are still checked below.
        let structuralPath = templateSource
            ? "/" + contextPath.split(separator: "/").filter { $0.lowercased() != "models" }.joined(separator: "/")
            : contextPath
        let runtimeStructuralPath = runtimeSource
            ? "/" + structuralPath.split(separator: "/").filter { !["models", "model"].contains($0.lowercased()) }.joined(separator: "/")
            : structuralPath
        if isSensitiveAutomationPath(runtimeStructuralPath) { return true }

        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let extensionName = url.pathExtension.lowercased()
        if !archivedDatabase && (contextPath.split(separator: "/").contains(where: {
            databaseFileExtensions.contains((String($0) as NSString).pathExtension.lowercased())
        })
            || databaseSidecarSuffixes.contains(where: name.hasSuffix)) { return true }
        if extensionName == "app" { return !allowApplicationBundle && !downloadedRuntime }
        return contextPath.split(separator: "/").contains { component in
            let component = component.lowercased()
            return durableCleanupNames.contains(component)
                && !((templateSource || runtimeSource) && templateSourceNames.contains(component))
        }
    }

    /// The pnpm dlx cache contains downloaded packages. Recognize source
    /// templates by the package boundary as well as `templates/<name>/src`;
    /// an arbitrary cache directory named `models` receives no exemption.
    private static func isDisposablePackageTemplateSourcePath(_ path: String, home: String) -> Bool {
        let prefix = home + "/Library/Caches/pnpm/dlx/"
        guard path.hasPrefix(prefix) else { return false }
        let components = String(path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        for index in components.indices where components[index] == "node_modules" {
            guard index > 0, index + 1 < components.count else { continue }
            let packageIndex = index + 1
            let templateIndex = packageIndex + (components[packageIndex].hasPrefix("@") ? 2 : 1)
            guard templateIndex + 2 < components.count,
                  components[templateIndex] == "templates",
                  !components[templateIndex + 1].isEmpty,
                  components[templateIndex + 2] == "src" else { continue }
            return true
        }
        return false
    }

    /// Sensitive automation content is protected by structure wherever it
    /// appears. Automation retains this strict rule without cache exceptions.
    static func isSensitiveAutomationPath(_ rawPath: String) -> Bool {
        let path = normalize(rawPath)
        let lower = path.lowercased()
        let components = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased() }
        if components.contains(where: sensitiveAutomationComponents.contains) { return true }
        if sensitiveAutomationFragments.contains(where: {
            lower == String($0.dropLast($0.hasSuffix("/") ? 1 : 0)) || lower.contains($0)
        }) {
            return true
        }
        return components.contains(where: hasModelFileSignature)
    }

    private static func ownerIsRunning(for category: CleanupCategory,
                                       snapshot: RunningApplicationSnapshot,
                                       homeDirectory: String) -> Bool {
        switch category.activityGuard {
        case .none, .openFile, .unsupported:
            return false
        case .reverseDNSCache:
            // A runtime-filtered category may keep protected siblings visible
            // while selecting only idle paths. Reassess the submitted subset,
            // not every path that remains on screen.
            let pathsToCheck = category.paths.filter(category.isPathSelected)
            return pathsToCheck.contains { path in
                pathOwnerRunning(path, snapshot: snapshot,
                                 homeDirectory: homeDirectory) != false
            }
        case .browser:
            return snapshotMatches(snapshot,
                                   bundles: ["com.google.Chrome", "com.google.Chrome.beta",
                                             "com.google.Chrome.canary", "org.chromium.Chromium",
                                             "org.mozilla.firefox", "com.microsoft.edgemac",
                                             "company.thebrowser.Browser", "company.thebrowser.dia",
                                             "com.brave.Browser", "com.vivaldi.Vivaldi",
                                             "com.operasoftware.Opera",
                                             "ru.yandex.desktop.yandex-browser",
                                             "com.tencent.QQBrowser", "net.imput.helium",
                                             "app.zen-browser.zen"],
                                   processes: ["Google Chrome", "Google Chrome Beta",
                                               "Google Chrome Canary", "Chromium", "Firefox",
                                               "Microsoft Edge", "Arc", "Dia", "Brave Browser",
                                               "Vivaldi", "Opera", "Yandex", "QQBrowser",
                                               "Helium", "zen"])
        case .messenger:
            // Telegram / 飞书 / 微信运行期间，其媒体与文档缓存一律保护：
            // 边写边删既损坏缓存，也可能干扰消息库。保护只落在路径能够
            // 认领的具体应用上——微信在跑不应冻结 Telegram 的缓存处理；
            // 归属不可辨认时才退回整族检查。
            return messengerOwnerIsRunning(for: category, snapshot: snapshot)
        case .xcode:
            return snapshotMatches(snapshot, bundles: ["com.apple.dt.Xcode"],
                                   processes: ["Xcode", "xcodebuild", "swift-frontend", "SourceKitService"])
        case .simulator:
            return snapshotMatches(snapshot, bundles: ["com.apple.iphonesimulator"],
                                   processes: ["Simulator", "CoreSimulatorService", "simctl"])
        case .packageManager:
            // Legacy cached categories used this guard.  Do not infer cache
            // ownership from a generic runtime process; the final bridge
            // checks whether the selected subtree is actually open.
            return false
        case .ide:
            return snapshotMatches(snapshot,
                                   bundles: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"],
                                   processes: ["Code", "Cursor", "Electron", "Antigravity",
                                               "Filo", "Claude", "Qoder"])
        case .aiAgent:
            // 空归属者是目录显式声明的：旧版本目录、Skill 等不绑定进程，
            // 只由执行边界的打开文件快照把关（快照不可用时同样拒绝）。
            return snapshotMatches(snapshot, bundles: category.activityOwners,
                                   processes: category.activityOwners)
        case .appData:
            return snapshotMatches(snapshot, bundles: category.activityOwners,
                                   processes: category.activityOwners)
        }
    }

    /// messenger 守卫的按应用收窄：从类目路径辨认归属（Telegram / Lark /
    /// 飞书 / 微信 / QQ / 钉钉），只检查对应应用的运行状态。
    private static func messengerOwnerIsRunning(for category: CleanupCategory,
                                                snapshot: RunningApplicationSnapshot) -> Bool {
        struct Owner {
            let markers: [String]
            let bundles: [String]
            let processes: [String]
        }
        let owners = [
            Owner(markers: ["ru.keepcoder.Telegram", "org.telegram.desktop",
                            "Telegram Desktop", "Telegram Media"],
                  bundles: ["ru.keepcoder.Telegram", "org.telegram.desktop"],
                  processes: ["Telegram", "Telegram Desktop"]),
            Owner(markers: ["LarkShell", "com.bytedance.feishu", "com.bytedance.lark",
                            "com.electron.lark", "com.ss.lark", "/Lark", "/Feishu",
                            "Lark Doc Cache"],
                  bundles: ["com.bytedance.feishu", "com.bytedance.lark",
                            "com.electron.lark", "com.ss.lark"],
                  processes: ["Lark", "LarkHelper", "Feishu", "飞书"]),
            Owner(markers: ["com.tencent.xinWeChat", "/WeChat"],
                  bundles: ["com.tencent.xinWeChat"],
                  processes: ["WeChat", "微信"]),
            Owner(markers: ["com.tencent.qq", "Tencent/QQ"],
                  bundles: ["com.tencent.qq"],
                  processes: ["QQ"]),
            Owner(markers: ["com.alibaba.DingTalkMac", "/DingTalk"],
                  bundles: ["com.alibaba.DingTalkMac"],
                  processes: ["DingTalk", "钉钉"])
        ]
        var bundles: [String] = []
        var processes: [String] = []
        var recognized = false
        for owner in owners {
            guard category.paths.contains(where: { path in
                owner.markers.contains { path.contains($0) }
            }) else { continue }
            recognized = true
            bundles.append(contentsOf: owner.bundles)
            processes.append(contentsOf: owner.processes)
        }
        guard recognized else {
            // 归属不可辨认：保持旧的整族保护（宁可多等，不误删）。
            return snapshotMatches(snapshot,
                                   bundles: ["ru.keepcoder.Telegram", "org.telegram.desktop",
                                             "com.electron.lark", "com.ss.lark",
                                             "com.bytedance.feishu", "com.bytedance.lark",
                                             "com.tencent.xinWeChat", "com.tencent.qq",
                                             "com.alibaba.DingTalkMac"],
                                   processes: ["Telegram", "Telegram Desktop", "Lark",
                                               "LarkHelper", "Feishu", "飞书",
                                               "WeChat", "微信", "QQ", "DingTalk", "钉钉"])
        }
        return snapshotMatches(snapshot, bundles: bundles, processes: processes)
    }

    private static func snapshotMatches(_ snapshot: RunningApplicationSnapshot,
                                        bundles: [String],
                                        processes: [String]) -> Bool {
        bundles.contains(where: snapshot.contains(bundleIdentifier:)) ||
            processes.contains(where: snapshot.contains(processName:))
    }

    private static func pathOwnerRunning(
        _ path: String,
        snapshot: RunningApplicationSnapshot,
        homeDirectory: String
    ) -> Bool? {
        guard let owner = cacheOwner(for: normalize(path), home: normalize(homeDirectory)) else {
            return nil
        }
        let leaf = owner.split(separator: ".").last.map(String.init) ?? owner
        return snapshot.contains(bundleIdentifier: owner) || snapshot.contains(processName: leaf)
    }

    static func isProtectedContent(_ path: String, homeDirectory: String) -> Bool {
        if systemCleanupKind(for: path, homeDirectory: homeDirectory) != nil
            || auditedRebuildableRoot(containing: path, homeDirectory: homeDirectory) != nil { return false }
        if protectedAbsoluteRoots.contains(where: { path == $0 || isStrictDescendant(path, of: $0) }) {
            return true
        }
        return protectedContentRoots(homeDirectory: homeDirectory).contains {
            path == $0 || isStrictDescendant(path, of: $0)
        }
    }

    private static func protectedContentRoots(homeDirectory: String) -> [String] {
        let home = normalize(homeDirectory)
        return [
            home + "/.codex/sessions",
            home + "/.codex/log",
            home + "/.claude/projects",
            home + "/.claude/shell-snapshots",
            home + "/.claude/todos",
            home + "/.local/share/opencode/project",
            home + "/.gemini/tmp",
            home + "/.ollama/models",
            home + "/.cache/huggingface",
            home + "/.cache/lm-studio/models",
            home + "/.cache/torch",
            home + "/Library/Application Support/Codex",
            home + "/Library/Containers/com.docker.docker",
            home + "/Library/Group Containers/group.com.docker",
            home + "/.docker",
            // 缓存地图禁止清单：钥匙串任何情况下都不动。
            home + "/Library/Keychains"
        ]
    }

    private static func developerCacheRoots(home: String) -> [String] {
        var roots = [
            home + "/.npm/_cacache",
            home + "/.npm/_logs",
            home + "/.swiftpm/cache",
            home + "/.cache/node/corepack",
            home + "/Library/Caches/org.carthage.CarthageKit",
            home + "/.bun/install/cache",
            home + "/Library/Caches/pnpm",
            home + "/Library/pnpm/store",
            home + "/.pnpm-store",
            home + "/.local/share/pnpm/store",
            home + "/.yarn/cache",
            home + "/Library/Caches/Yarn",
            // Gradle: only the build cache, daemon logs, worker scratch and
            // notification state are rebuildable. The module cache under
            // ~/.gradle/caches is a dependency store (see dependencyStoreRoots)
            // and its build-cache-* children are admitted separately.
            home + "/.gradle/daemon",
            home + "/.gradle/workers",
            home + "/.gradle/notifications",
            home + "/Library/Caches/go-build",
            // Only the download cache (zips + VCS mirrors) is offered here; the
            // extracted module tree is reset through `go clean -modcache`.
            home + "/go/pkg/mod/cache",
            home + "/.cargo/registry/cache",
            home + "/Library/Caches/NuGet",
            home + "/Library/Caches/pip",
            home + "/.cache/pip",
            home + "/Library/Caches/pypoetry",
            home + "/.cache/uv",
            home + "/.composer/cache",
            home + "/Library/Caches/composer",
            home + "/.cache/bazel",
            home + "/.cache/zig",
            home + "/Library/Caches/org.swift.swiftpm",
            home + "/Library/Caches/Homebrew/downloads",
            home + "/Library/Caches/node-gyp",
            home + "/Library/Caches/typescript",
            home + "/.hex/cache",
            home + "/.tnpm/_cacache",
            home + "/.tnpm/_logs",
            home + "/.cache/poetry",
            home + "/.cache/ruff",
            home + "/.cache/mypy",
            home + "/.pytest_cache",
            home + "/.jupyter/runtime",
            home + "/.rbenv/cache",
            home + "/.gem/specs",
            home + "/.bundle/cache",
            home + "/.cpan/build",
            home + "/.kube/cache",
            home + "/.aws/cli/cache",
            home + "/.config/gcloud/logs",
            home + "/.azure/logs",
            home + "/.cache/typescript",
            home + "/.cache/electron",
            home + "/.cache/node-gyp",
            home + "/.node-gyp",
            home + "/.turbo/cache",
            home + "/.vite/cache",
            home + "/.cache/vite",
            home + "/.cache/webpack",
            home + "/.parcel-cache",
            home + "/.cache/eslint",
            home + "/.cache/prettier",
            home + "/.android/build-cache",
            home + "/.android/cache",
            home + "/.cache/swift-package-manager",
            home + "/.expo/expo-go",
            home + "/.expo/android-apk-cache",
            home + "/.expo/ios-simulator-app-cache",
            home + "/.expo/native-modules-cache",
            home + "/.expo/schema-cache",
            home + "/.expo/template-cache",
            home + "/.expo/versions-cache",
            home + "/Library/Logs/JetBrains"
        ]
        // 工具配置声明的自定义缓存位置与默认位置同级可信：发现层会枚举
        // 它们，策略层也必须承认它们（否则出现“扫得到却被保护拦下”）。
        let locations = DeveloperCacheLocations.current(home: home)
        for custom in [locations.npmCache, locations.yarnCache, locations.pipCache,
                       locations.poetryCache, locations.goModCache, locations.goBuildCache, locations.pnpmStore] {
            if let custom { roots.append(custom) }
        }
        if let cargoHome = locations.cargoHome {
            roots.append(cargoHome + "/registry/cache")
        }
        return roots
    }

    /// Stores that builds consume directly. They are inventoried for review
    /// but never enter the one-click cleanup; Mole keeps the same list off its
    /// blanket delete path and resets them only through owner commands.
    static func dependencyStoreRoots(home: String) -> [String] {
        var roots = [
            home + "/.m2/repository",
            home + "/.ivy2/cache",
            home + "/.gradle/caches",
            home + "/.nuget/packages",
            home + "/.pub-cache",
            home + "/.cargo/git",
            home + "/.cargo/registry/src",
            home + "/.cabal/packages",
            home + "/.cpan/sources",
            home + "/.sbt/boot",
            home + "/.sbt/launchers"
        ]
        // 自定义 GRADLE_USER_HOME 的模块缓存与默认位置同等对待：
        // 依赖仓库只复核，build-cache-* 仍按可重建缓存放行。
        if let gradleHome = DeveloperCacheLocations.current(home: home).gradleUserHome {
            roots.append(gradleHome + "/caches")
        }
        if let cargoHome = DeveloperCacheLocations.current(home: home).cargoHome {
            roots.append(cargoHome + "/registry/src")
            roots.append(cargoHome + "/git")
        }
        return roots
    }

    /// `~/.gradle/caches/build-cache-*`（或自定义 GRADLE_USER_HOME 下的同
    /// 结构）持有按输入哈希键化的任务输出，下次构建自动重建；同级的模块
    /// 缓存是依赖仓库，保持复核态。
    static func isGradleBuildCachePath(_ path: String, home: String) -> Bool {
        let locations = DeveloperCacheLocations.current(home: home)
        var gradleHomes = [home + "/.gradle"]
        if let custom = locations.gradleUserHome, custom != home + "/.gradle" {
            gradleHomes.append(custom)
        }
        for gradleHome in gradleHomes {
            let cachesRoot = gradleHome + "/caches/"
            guard path.hasPrefix(cachesRoot) else { continue }
            let child = String(path.dropFirst(cachesRoot.count))
                .split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if child.hasPrefix("build-cache-") { return true }
        }
        return false
    }

    private static func isExplicitDeveloperCachePath(_ path: String, home: String) -> Bool {
        isGradleBuildCachePath(path, home: home) || developerCacheRoots(home: home).contains {
            path == $0 || isStrictDescendant(path, of: $0)
        }
    }

    /// Explicit user-level roots outside Library/Caches whose contents macOS
    /// re-downloads or regenerates on demand. Firmware images are fetched
    /// again by Finder/iTunes for the next restore; Messages preview/sticker
    /// caches are rebuilt from the attachments they were derived from.
    static func userRebuildableRoots(home: String) -> [(path: String, reasonKey: String)] {
        [
            (home + "/Library/iTunes/iPhone Software Updates", "cleanup.risk.firmwareCache"),
            (home + "/Library/iTunes/iPad Software Updates", "cleanup.risk.firmwareCache"),
            (home + "/Library/iTunes/iPod Software Updates", "cleanup.risk.firmwareCache"),
            (home + "/Library/iTunes/Apple TV Software Updates", "cleanup.risk.firmwareCache"),
            (home + "/Library/iTunes/Apple Watch Software Updates", "cleanup.risk.firmwareCache"),
            (home + "/Library/Messages/StickerCache", "cleanup.risk.rebuildableCache"),
            (home + "/Library/Messages/Caches/Previews/Attachments", "cleanup.risk.rebuildableCache"),
            (home + "/Library/Messages/Caches/Previews/StickerCache", "cleanup.risk.rebuildableCache")
        ] + NoriOwnedStorage.fileTreeRoots(home: home).map {
            ($0, NoriOwnedStorage.reasonKey)
        }
    }

    private static func userRebuildableReason(_ path: String, home: String) -> String? {
        userRebuildableRoots(home: home).first {
            path == $0.path || isStrictDescendant(path, of: $0.path)
        }?.reasonKey
    }

    private static func isExplicitXcodeCachePath(_ path: String, home: String) -> Bool {
        xcodeCacheRoots(home: home).contains { path == $0 || isStrictDescendant(path, of: $0) }
    }

    private static func cacheOwner(for path: String, home: String) -> String? {
        let directPrefix = home + "/Library/Caches/"
        if path.hasPrefix(directPrefix) {
            let remainder = String(path.dropFirst(directPrefix.count))
            let owner = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return isValidReverseDNSOwner(owner) ? owner : nil
        }
        return containerCacheOwner(path, home: home)
    }

    private static func containerCacheOwner(_ path: String, home: String) -> String? {
        let prefix = home + "/Library/Containers/"
        guard path.hasPrefix(prefix) else { return nil }
        let remainder = String(path.dropFirst(prefix.count))
        let components = remainder.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 2, components[1] == "Data" else { return nil }
        // <id>/Data/Library/{Caches,Logs}/<child>: the sandbox cache contract.
        if components.count >= 5, components[2] == "Library",
           components[3] == "Caches" || components[3] == "Logs" {
            return components[0]
        }
        // <id>/Data/tmp/<child>: the sandboxed app's NSTemporaryDirectory. Only
        // entries below tmp qualify, never the tmp directory itself.
        if components.count >= 4, components[2] == "tmp" {
            return components[0]
        }
        return nil
    }

    private static func isApplicationSupportCachePath(_ path: String, home: String) -> Bool {
        let prefix = home + "/Library/Application Support/"
        guard path.hasPrefix(prefix) else { return false }
        let components = String(path.dropFirst(prefix.count))
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.lowercased() }
        guard components.count >= 2 else { return false }
        // Chromium/Electron cache leaves audited in Mole's browser catalog:
        // GPU shader caches (Dawn/Graphite/GrShader), component and extension
        // CRX download caches, and the legacy HTML5 "Application Cache".
        let cacheComponents: Set<String> = [
            "cache", "caches", "code cache", "gpucache", "dawncache",
            "dawngraphitecache", "dawnwebgpucache", "gpupersistentcache",
            "graphitedawncache", "grshadercache", "shadercache", "cacheddata",
            "cachedextensionvsixs", "blob_storage", "logs",
            "component_crx_cache", "extensions_crx_cache", "application cache"
        ]
        if components.dropFirst().contains(where: cacheComponents.contains) { return true }
        for index in 1 ..< components.count {
            if components[index] == "cachestorage" || components[index] == "scriptcache",
               components[index - 1] == "service worker" { return true }
            if components[index] == "completed",
               components[index - 1] == "crashpad" { return true }
        }
        return false
    }

    private static func isBrowserPath(_ path: String, section: String) -> Bool {
        if section.lowercased().contains("browser") { return true }
        let lower = path.lowercased()
        if lower.contains("/google/chrome/") || lower.contains("/mozilla/firefox/")
            || lower.contains("/microsoft edge/") || lower.contains("/arc/") { return true }
        // Every Chromium profile root in the cache map shares the browser guard.
        return browserProfileRelativeRoots.contains { lower.contains("/" + $0.lowercased() + "/") }
    }

    private static func isBrowserCacheOwner(_ owner: String) -> Bool {
        ["Google", "Mozilla", "Firefox", "Chrome", "Chromium", "Microsoft Edge", "Arc", "Dia",
         "BraveSoftware", "Vivaldi", "Yandex", "QQBrowser3", "Opera"]
            .contains { owner.caseInsensitiveCompare($0) == .orderedSame }
    }

    private static func warningDescriptor(source: CleanupSource,
                                          route: CleanupApplyRoute,
                                          reasonKey: String) -> CleanupPolicyDescriptor {
        .init(source: source, risk: .warning, disposal: .permanentDelete,
              applyRoute: route, activityGuard: .unsupported, reasonKey: reasonKey)
    }

    private static func protectedDescriptor(source: CleanupSource,
                                            reasonKey: String) -> CleanupPolicyDescriptor {
        .init(source: source, risk: .protected, disposal: .none,
              applyRoute: .none, activityGuard: .unsupported, reasonKey: reasonKey)
    }

    private static func protectedUnknown(source: CleanupSource) -> CleanupPolicyDescriptor {
        protectedDescriptor(source: source, reasonKey: "cleanup.risk.invalidPath")
    }

    /// Lexical normalization must not ask Foundation to shorten existing
    /// /private paths to symlink aliases. Native fd traversal deliberately
    /// requires physical /private spelling and rejects symlink components.
    static func normalizedPathLiteral(_ path: String) -> String {
        DeletionPlan.normalizedPathLiteral(path)
    }

    static func canonicalOpenFilePath(_ path: String) -> String {
        if let pointer = realpath(path, nil) {
            defer { free(pointer) }
            return normalizedPathLiteral(String(cString: pointer))
        }
        // lsof can name a vanished/open file. Keep its absolute literal and
        // normalize only macOS's known root aliases, never guess other links.
        if path == "/var" || path.hasPrefix("/var/")
            || path == "/tmp" || path.hasPrefix("/tmp/")
            || path == "/etc" || path.hasPrefix("/etc/") {
            return "/private" + normalizedPathLiteral(path)
        }
        return normalizedPathLiteral(path)
    }

    static func systemCleanupAccountScopeEligible(path: String, homeDirectory: String) -> Bool {
        let prefix = "/private/var/folders/"
        guard path.hasPrefix(prefix) else { return true }
        let parts = String(path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0].count == 2 else { return false }
        guard parts[2] == "T" || parts[2] == "C" || parts[2] == "X" else { return false }
        var account = stat(), container = stat(), scratch = stat()
        let userRoot = prefix + parts[0] + "/" + parts[1]
        return lstat(homeDirectory, &account) == 0 && lstat(userRoot, &container) == 0
            && lstat(userRoot + "/" + parts[2], &scratch) == 0
            && container.st_mode & S_IFMT == S_IFDIR && scratch.st_mode & S_IFMT == S_IFDIR
            && container.st_uid == account.st_uid && scratch.st_uid == account.st_uid
    }

    private static func normalize(_ path: String) -> String { normalizedPathLiteral(path) }

    /// Keep the same intentionally narrow ASCII grammar as the final shell
    /// guard. A dotted but malformed cache owner is Warning, never Safe.
    static func isValidReverseDNSOwner(_ owner: String) -> Bool {
        guard owner.contains("."),
              !owner.hasPrefix("."),
              !owner.hasSuffix("."),
              !owner.contains("..") else { return false }
        return owner.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte)
                || (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
        }
    }

    private static func isStrictDescendant(_ path: String, of root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func isDirectChild(_ path: String, of root: String) -> Bool {
        guard isStrictDescendant(path, of: root) else { return false }
        let remainder = path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1)
        return !remainder.isEmpty && !remainder.contains("/")
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || isStrictDescendant(lhs, of: rhs) || isStrictDescendant(rhs, of: lhs)
    }
}

/// 微信 4.x 的账号存储布局：`xwechat_files/<账号>/`。只列可再生的叶子；
/// 其余目录（消息库、配置、聊天文件、登录信息、备份）由策略整体保护。
enum WeChatStorage {
    static let filesRelativeRoot = "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
    static let cacheReasonKey = "cleanup.risk.messengerCache"
    static let mediaReasonKey = "cleanup.risk.messengerMedia"
    static let leaves: [(relative: String, label: String, reasonKey: String)] = [
        ("cache", "WeChat Cache", cacheReasonKey),
        ("temp", "WeChat Cache", cacheReasonKey),
        ("msg/video", "WeChat Chat Videos", mediaReasonKey),
        ("msg/attach", "WeChat Chat Images", mediaReasonKey)
    ]
    private static let sharedDirectories: Set<String> = ["all_users", "backup"]

    static func isAccountDirectory(_ name: String) -> Bool {
        !name.hasPrefix(".") && !sharedDirectories.contains(name.lowercased())
    }
}

/// Nori 自身的可再生存储。只列确定可重建的内容；密钥、Shell 备份、剪贴板
/// 历史与会话文件永远不在这里。
enum NoriOwnedStorage {
    static let displayName = "Nori"
    static let reasonKey = "cleanup.risk.noriCache"
    static let orphanMinimumAge: TimeInterval = 3600
    /// `Data.write(atomic:)` 在同目录留下的临时文件片段标识。
    private static let orphanMarker = ".sb-"
    private static let screenshotPrefix = "com.nori.screenshot."

    static func supportDirectory(home: String) -> String {
        CleanupRiskPolicy.normalizedPathLiteral(home) + "/Library/Application Support/Nori"
    }

    static func legacySupportDirectories(home: String) -> [String] {
        let base = CleanupRiskPolicy.normalizedPathLiteral(home) + "/Library/Application Support/"
        return [base + "ForgeSweep", base + "SimpleMole"]
    }

    /// 走原生删除边界的根：DirectorySizes、Analysis、两个旧品牌目录。
    static func fileTreeRoots(home: String) -> [String] {
        let support = supportDirectory(home: home)
        return [support + "/DirectorySizes", support + "/Analysis"]
            + legacySupportDirectories(home: home)
    }

    /// 目录大小缓存与文件名索引目录；搜索索引由进程内 SQL 清空，不走原生 unlink。
    static func searchIndexDirectory(home: String) -> String {
        supportDirectory(home: home) + "/DirectoryIndex"
    }

    static func isSearchIndexPath(_ path: String, home: String) -> Bool {
        let normalized = CleanupRiskPolicy.normalizedPathLiteral(path)
        let root = searchIndexDirectory(home: home)
        return normalized == root || normalized.hasPrefix(root + "/")
    }

    static func isScreenshotTemporaryPath(_ path: String,
                                          temporaryDirectory: String = NSTemporaryDirectory()) -> Bool {
        let normalized = CleanupRiskPolicy.normalizedPathLiteral(path)
        return (normalized as NSString).deletingLastPathComponent
                == CleanupRiskPolicy.normalizedPathLiteral(temporaryDirectory)
            && (normalized as NSString).lastPathComponent.hasPrefix(screenshotPrefix)
    }

    /// 进程内执行、不进原生 unlink 的路径：DirectoryIndex 目录（连接常开、
    /// *.sqlite 被拒绝）与临时目录下闲置超过 orphanMinimumAge 的截图暂存目录。
    static func managedPaths(home: String, temporaryDirectory: String = NSTemporaryDirectory(),
                             now: Date = Date()) -> [String] {
        var result: [String] = []
        let index = searchIndexDirectory(home: home)
        var metadata = stat()
        if lstat(index, &metadata) == 0 { result.append(index) }
        let temporary = CleanupRiskPolicy.normalizedPathLiteral(temporaryDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: temporary) else {
            return result
        }
        for name in names.sorted() {
            let path = temporary + "/" + name
            guard isScreenshotTemporaryPath(path, temporaryDirectory: temporary),
                  lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                  now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)))
                    >= orphanMinimumAge else { continue }
            result.append(path)
        }
        return result
    }

    static func isManagedPath(_ path: String, home: String) -> Bool {
        isSearchIndexPath(path, home: home) || isScreenshotTemporaryPath(path)
    }

    /// 父目录 == Nori 支持目录、文件名含 ".sb-"、mtime 早于 minimumAge 的普通
    /// 文件：原子写留下的孤儿临时文件。密钥、备份、剪贴板与会话文件不以此
    /// 命名，且不在支持目录直属位置，天然排除在外。
    static func isOrphanTemporaryFile(_ path: String, home: String, now: Date = Date(),
                                      minimumAge: TimeInterval = 3600) -> Bool {
        let normalized = CleanupRiskPolicy.normalizedPathLiteral(path)
        guard (normalized as NSString).deletingLastPathComponent == supportDirectory(home: home),
              (normalized as NSString).lastPathComponent.contains(orphanMarker) else { return false }
        var metadata = stat()
        guard lstat(normalized, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return false }
        let modified = Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec))
        return modified <= now && now.timeIntervalSince(modified) >= minimumAge
    }

    static func orphanTemporaryFiles(home: String, now: Date = Date()) -> [String] {
        let support = supportDirectory(home: home)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: support) else { return [] }
        return names.sorted().map { support + "/" + $0 }
            .filter { isOrphanTemporaryFile($0, home: home, now: now) }
    }
}
