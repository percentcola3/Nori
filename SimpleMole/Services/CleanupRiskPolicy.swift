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
    static func core(section: String,
                     path: String,
                     homeDirectory: String = NSHomeDirectory()) -> CleanupPolicyDescriptor {
        guard (path as NSString).isAbsolutePath else { return protectedUnknown(source: .core) }
        let normalized = normalize(path)

        if isProtectedContent(normalized, homeDirectory: homeDirectory) {
            return protectedDescriptor(source: .core, reasonKey: "cleanup.risk.protectedContent")
        }

        let home = normalize(homeDirectory)

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

    static func projectArtifact(risk: CleanupRisk = .warning,
                                runtimeReasonKey: String? = nil) -> CleanupPolicyDescriptor {
        if let runtimeReasonKey {
            return protectedDescriptor(source: .projectArtifact,
                                       reasonKey: runtimeReasonKey)
        }
        switch risk {
        case .safe:
            return .init(source: .projectArtifact, risk: .safe, disposal: .permanentDelete,
                         applyRoute: .projectArtifactTrash, activityGuard: .none,
                         reasonKey: "cleanup.risk.rebuildableDeveloperCache")
        case .warning:
            return warningDescriptor(source: .projectArtifact, route: .projectArtifactTrash,
                                     reasonKey: "cleanup.risk.projectArtifact")
        case .protected:
            return protectedDescriptor(source: .projectArtifact,
                                       reasonKey: "cleanup.risk.protectedContent")
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

    static func system() -> CleanupPolicyDescriptor {
        .init(source: .system, risk: .warning, disposal: .privileged,
              applyRoute: .systemPrivileged, activityGuard: .unsupported,
              reasonKey: "cleanup.risk.system")
    }

    static func tool() -> CleanupPolicyDescriptor {
        .init(source: .tool, risk: .warning, disposal: .command,
              applyRoute: .toolCommand, activityGuard: .unsupported,
              reasonKey: "cleanup.risk.ownerCommand")
    }

    static func slim() -> CleanupPolicyDescriptor {
        .init(source: .slim, risk: .warning, disposal: .transform,
              applyRoute: .imageTransform, activityGuard: .unsupported,
              reasonKey: "cleanup.risk.transform")
    }

    /// 应用执行前使用新快照重判。风险只会保持或升高，不会在旧扫描上降级。
    static func reassess(_ category: CleanupCategory,
                         running snapshot: RunningApplicationSnapshot,
                         homeDirectory: String = NSHomeDirectory()) -> CleanupRiskAssessment {
        guard category.risk == .safe else {
            return .init(risk: category.risk, reasonKey: category.reasonKey)
        }
        guard category.activityGuard != .unsupported else {
            return .init(risk: .protected, reasonKey: "cleanup.risk.runtimeUnsupported")
        }
        guard category.activityGuard != .none else {
            return .init(risk: .safe, reasonKey: category.reasonKey)
        }
        guard snapshot.isComplete else {
            return .init(risk: .protected, reasonKey: "cleanup.risk.runtimeUnknown")
        }
        if ownerIsRunning(for: category, snapshot: snapshot, homeDirectory: homeDirectory) {
            return .init(risk: .protected, reasonKey: "cleanup.risk.runningApplication")
        }
        return .init(risk: .safe, reasonKey: category.reasonKey)
    }

    /// 运行态保护按路径裁剪。分类和总容量始终保留在结果中；当前运行的
    /// 应用只会清空对应选择，避免把数 GB 的缓存从页面中隐藏。
    static func runtimeEligibleSubset(
        _ category: CleanupCategory,
        running snapshot: RunningApplicationSnapshot,
        homeDirectory: String = NSHomeDirectory()
    ) -> CleanupCategory? {
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
        case .browser, .xcode, .simulator, .ide, .messenger:
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
                return assessment.risk == .safe
            case .command, .privileged, .transform:
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

    /// Sensitive content is protected by structure wherever it appears, not
    /// only at its conventional location under the current home directory.
    static func isSensitiveAutomationPath(_ rawPath: String) -> Bool {
        let path = normalize(rawPath)
        let lower = path.lowercased()
        let components = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased() }
        let sensitiveComponents: Set<String> = [
            ".git", "models", "sessions", "conversations", "userdata",
            "user data", "docker", "vms"
        ]
        if components.contains(where: sensitiveComponents.contains) { return true }
        let protectedFragments = [
            "/.codex/sessions", "/.codex/log", "/.codex/auth.json",
            "/.codex/history.jsonl", "/.claude/projects", "/.claude/todos",
            "/.claude/shell-snapshots", "/.gemini/",
            "/.local/share/opencode/project",
            "/library/application support/codex", "/.ollama/models",
            "/.cache/huggingface", "/.cache/lm-studio/models", "/.cache/torch",
            "/library/containers/com.docker", "/library/group containers/group.com.docker",
            "/.docker/contexts", "/.docker/config.json"
        ]
        if protectedFragments.contains(where: {
            lower == String($0.dropLast($0.hasSuffix("/") ? 1 : 0)) || lower.contains($0)
        }) {
            return true
        }
        let leaf = URL(fileURLWithPath: lower).lastPathComponent
        if ["pytorch_model.bin", "adapter_model.bin", "model.bin"].contains(leaf) {
            return true
        }
        let protectedExtensions = [
            "gguf", "safetensors", "ckpt", "mlmodel", "mlmodelc",
            "pt", "pth", "onnx", "tflite"
        ]
        return protectedExtensions.contains(URL(fileURLWithPath: lower).pathExtension)
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
                       locations.poetryCache, locations.goModCache, locations.goBuildCache] {
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
        ]
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

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

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
