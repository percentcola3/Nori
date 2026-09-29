import AppKit
import Darwin
import Foundation
import OSLog

/// Thread-safe sink used by the native scanner to publish lightweight progress
/// without coupling the filesystem worker to the UI actor.
struct CleanupScanProgressEvent: Sendable {
    let phase: String
    let completed: Int
    let total: Int
    let currentPath: String
}

final class CleanupScanProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (CleanupScanProgressEvent) -> Void
    private var lastSentAt = Date.distantPast

    init(handler: @escaping (CleanupScanProgressEvent) -> Void) {
        self.handler = handler
    }

    func send(_ event: CleanupScanProgressEvent) {
        // Directory roots can contain thousands of children. Coalesce updates
        // here, before creating a MainActor task, while always forwarding the
        // final item so the bar can reach its terminal state.
        let now = Date()
        lock.lock()
        let shouldSend = (event.total > 0 && event.completed == event.total)
            || now.timeIntervalSince(lastSentAt) >= 0.08
        if shouldSend { lastSentAt = now }
        lock.unlock()
        guard shouldSend else { return }
        handler(event)
    }
}

/// 原生核心服务。
///
/// 五条核心流程不通过外部命令路由转发。清理、卸载和磁盘分析只使用系统
/// API；优化任务只调用明确列出的系统命令。特色能力
/// （图片、Docker、Simulator、AI 等）仍由各自的 bridge 负责。
final class NativeCore: @unchecked Sendable {
    static let shared = NativeCore()

    struct CleanupScan: Sendable {
        let categories: [CleanupCategory]
        let succeeded: Bool
        let error: String?
        var deferredPaths: [String] = []
        var diagnostics: String = ""
    }

    struct ApplySummary: Sendable {
        let removed: Int
        let skipped: Int
        let failed: Int
        let messages: [String]
        var removedPaths: Set<String> = []
        var remainingPaths: [String] = []
        var retainedPaths: [String] = []

        var succeeded: Bool { failed == 0 }
    }

    struct OptimizeTask: Identifiable, Equatable, Sendable {
        enum State: String, Sendable {
            case pending
            case applied
            case unchanged
            case unavailable
            case failed
        }

        /// `admin` 任务统一走一次提权桥接；`report` 任务只读，永远不可勾选执行。
        enum Kind: String, Sendable {
            case action
            case admin
            case report
        }

        /// 执行前的只读预检：是否需要、将改动什么。
        struct Preview: Equatable, Sendable {
            enum Need: String, Sendable {
                case needed
                case clean
                case blocked
                case unavailable
            }

            let need: Need
            let summary: String
            var items: [String] = []
            /// 执行时唯一允许作用的证据（`identity<TAB>path`、bundle ID、偏好键等）。
            var plan: [String] = []
        }

        let id: String
        let title: String
        let detail: String
        var kind: Kind = .action
        /// 预检发现需要时是否默认勾选。清除历史记录类任务保持不勾选。
        var defaultOn = true
        var selected = false
        var preview: Preview?
        var state: State = .pending
        var message: String = ""

        var selectable: Bool {
            guard kind != .report, let preview else { return false }
            return preview.need == .needed
        }
    }

    struct OptimizeReport: Sendable {
        let tasks: [OptimizeTask]
        let finishedAt: Date
    }

    private static let cleanupLogger = Logger(subsystem: "com.nori.app", category: "cleanup")
    let fileManager = FileManager.default
    private let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey
    ]
    private let maxTraversalEntries = 200_000
    private let maxTraversalSeconds: TimeInterval = 3
    private let largeFileThreshold: UInt64 = 100 * 1024 * 1024

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct TreeMeasure {
        var bytes: UInt64 = 0
        var files: Int = 0
        var largeFiles: [AnalyzeReport.LargeFile] = []
        var truncated = false
    }

    private init() {}

    // MARK: Cleanup

    func scanCleanup(homeDirectory: String = NSHomeDirectory(),
                     progress: CleanupScanProgressSink? = nil,
                     mode: CleanupScanMode = .quick,
                     control: CleanupScanControl? = nil) async -> CleanupScan {
        let control = control ?? CleanupScanControl(mode: mode)
        return await Task.detached(priority: .utility) { [self] in
            let home = URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .standardizedFileURL
            guard self.fileManager.fileExists(atPath: home.path) else {
                return CleanupScan(categories: [], succeeded: false,
                                   error: "Home directory is unavailable.")
            }

            let orphanNames = self.cleanupOrphanNames(home: home, mode: mode, control: control)
            let roots = self.cleanupRoots(home: home, mode: mode, control: control,
                                          orphanNames: orphanNames)
            let whitelist = self.loadWhitelist(homeDirectory: homeDirectory)
            let broadRoots = Set(["Library/Caches", "Library/Logs", "Library/DiagnosticReports",
                                  ".cache", ".Trash"].map { home.appendingPathComponent($0).path })
            var candidates: [CleanupScanCandidate] = []
            var seen = Set<String>()
            for (root, label, _, _, retention) in roots {
                guard !control.shouldStop else { break }
                guard self.cleanupPathIsPhysical(root, home: home) else { continue }
                let entries = broadRoots.contains(root.path) ? self.directChildren(of: root) : [root]
                for entry in entries {
                    let path = entry.standardizedFileURL.path
                    // AI Agent 的缓存、版本与会话只在 Agent 专清页呈现。
                    guard self.isAllowedCleanupPath(entry, home: home),
                          self.cleanupPathIsPhysical(entry, home: home),
                          !CleanupRiskPolicy.isAgentOwnedPath(path, homeDirectory: home.path),
                          !self.matchesWhitelist(path, entries: whitelist) else { continue }
                    // A precise leaf replaces an overlapping broad parent before
                    // traversal. Never size or offer that parent for deletion.
                    if broadRoots.contains(root.path), roots.contains(where: {
                        $0.0 != root && (path == $0.0.path || $0.0.path.hasPrefix(path + "/"))
                    }) { continue }
                    let descriptor: CleanupPolicyDescriptor
                    let name: String
                    if let orphan = orphanNames[path] {
                        descriptor = CleanupRiskPolicy.appLeftover(
                            path: path, bundleIdentifier: orphan.bundleID, homeDirectory: homeDirectory)
                        name = orphan.name + " leftovers"
                    } else {
                        let base = CleanupRiskPolicy.core(section: label, path: path,
                                                          homeDirectory: homeDirectory)
                        descriptor = entry.deletingLastPathComponent().path == home.path + "/.Trash"
                            && base.risk != .protected ? CleanupRiskPolicy.recommendedTrash() : base
                        if broadRoots.contains(root.path), root.lastPathComponent != ".Trash" {
                            let identifier = entry.lastPathComponent
                            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                            name = app?.deletingPathExtension().lastPathComponent ?? identifier
                        } else {
                            let supportPrefix = home.path + "/Library/Application Support/"
                            let cachePrefix = home.path + "/Library/Caches/"
                            if path.hasPrefix(supportPrefix) {
                                name = String(path.dropFirst(supportPrefix.count).split(separator: "/").first ?? "")
                            } else if path.hasPrefix(cachePrefix) {
                                name = String(path.dropFirst(cachePrefix.count).split(separator: "/").first ?? "")
                            } else {
                                name = label
                            }
                        }
                    }
                    // Classify first: sessions, models and unverified roots do
                    // not consume the quick scan's I/O budget.
                    guard descriptor.risk == .safe, seen.insert(path).inserted else { continue }
                    candidates.append(CleanupScanCandidate(path: path, name: name,
                                                          policy: descriptor,
                                                          retention: retention))
                }
            }
            candidates = Self.nonOverlappingCleanupCandidates(candidates)
            let discoverySeconds = control.elapsed
            let measurements = CleanupScanWorker.measure(candidates.map(\.path), control: control) {
                completed, path in
                progress?.send(CleanupScanProgressEvent(phase: "native", completed: completed,
                    total: candidates.count, currentPath: path))
            }
            var deferred: [String] = []
            var groups: [String: [Int]] = [:]
            for index in candidates.indices {
                guard measurements[index].complete else {
                    deferred.append(candidates[index].path)
                    continue
                }
                guard measurements[index].bytes > 0, measurements[index].files > 0 else { continue }
                let candidate = candidates[index]
                let policy = candidate.policy
                let key = [candidate.name, policy.source.rawValue, policy.applyRoute.rawValue,
                           policy.activityGuard.rawValue,
                           String(format: "%.0f", candidate.retention)].joined(separator: "\t")
                groups[key, default: []].append(index)
            }
            let scanNow = Date()
            let categories = groups.values.map { indices -> CleanupCategory in
                let first = candidates[indices[0]]
                let sizes = Dictionary(uniqueKeysWithValues: indices.map {
                    (candidates[$0].path, measurements[$0].bytes)
                })
                var category = CleanupCategory(name: first.name, paths: indices.map { candidates[$0].path },
                    bytes: sizes.values.reduce(0, &+), pathBytes: sizes, selected: true,
                    source: first.policy.source, risk: first.policy.risk,
                    disposal: first.policy.disposal, applyRoute: first.policy.applyRoute,
                    activityGuard: first.policy.activityGuard, retention: first.retention,
                    reasonKey: first.policy.reasonKey)
                // 7 天活跃门按“可独立清理的单元”逐条生效：活跃条目保留在
                // 页面上但默认不勾选；证据缺失（时间为空/未来）同样不推荐。
                if first.retention > 0 {
                    var hasActive = false
                    for index in indices {
                        let stale = CleanupAgePolicy.isStale(
                            measurements[index].activityEvidence,
                            now: scanNow, retention: first.retention)
                        if !stale {
                            hasActive = true
                            category.setPathSelected(candidates[index].path, selected: false)
                        }
                    }
                    if hasActive { category.reasonKey = "cleanup.risk.recentlyActive" }
                }
                return category
            }
            // Discovery itself may exhaust the deadline. Do not cache such a
            // snapshot as complete, even if every admitted candidate was sized.
            if discoverySeconds >= control.totalBudget { deferred.append(home.path) }
            let ageGated = candidates.filter { $0.retention > 0 }.count
            return CleanupScan(categories: categories.sorted(by: CleanupCategory.sizeDescending),
                succeeded: !control.isCancelled,
                error: control.isCancelled ? "Scan cancelled." : nil,
                deferredPaths: deferred,
                diagnostics: String(format: "cleanup[%@] discovery=%.2fs sizing=%.2fs paths=%d deferred=%d files=%d ageGated=%d",
                    mode.rawValue, discoverySeconds, control.elapsed - discoverySeconds,
                    candidates.count, deferred.count,
                    measurements.reduce(0) { $0 + $1.files }, ageGated))
        }.value
    }

    struct CleanupScanCandidate {
        let path: String
        let name: String
        let policy: CleanupPolicyDescriptor
        /// 年龄门（秒）。0 表示该候选不按活跃时间过滤。
        var retention: TimeInterval = 0
    }

    static func nonOverlappingCleanupCandidates(_ input: [CleanupScanCandidate]) -> [CleanupScanCandidate] {
        // Prefer narrow paths. An ancestor is never retained with an excluded
        // descendant, because the apply step deletes the entire selected path.
        let paths = Set(input.map(\.path))
        var ancestors = Set<String>()
        for path in paths {
            var parent = (path as NSString).deletingLastPathComponent
            while parent != "/" && !parent.isEmpty {
                if paths.contains(parent) { ancestors.insert(parent) }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        var seen = Set<String>()
        return input.filter { !ancestors.contains($0.path) && seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    private func cleanupPathIsPhysical(_ url: URL, home: URL) -> Bool {
        guard url.path.hasPrefix(home.path + "/") else { return false }
        var probe = url
        while probe.path != home.path {
            if isSymlink(probe) { return false }
            probe.deleteLastPathComponent()
        }
        return fileManager.fileExists(atPath: url.path)
    }

    /// Find cache/log leftovers for applications that are present in Trash.
    /// The trashed bundle is the ownership proof; directory names alone are
    /// never treated as evidence. Only rebuildable cache and log leaves are
    /// offered to the clean flow, while app data remains available through the
    /// uninstall/analyze review surfaces.
    ///
    /// 深度扫描补充第二种证据：反向 DNS 命名的沙盒容器，其归属应用既不在
    /// 已安装清单里、也不是 Apple 系统组件时，按“疑似历史残留”标注它的
    /// Caches/Logs 叶子（废纸篓已清空也能发现）。叶子内容本身可再生，风险
    /// 由 appLeftover 按精确归属路径裁决；容器根与其余数据保持复核态。
    private func cleanupOrphanNames(home: URL, mode: CleanupScanMode,
                                    control: CleanupScanControl)
        -> [String: (name: String, bundleID: String)] {
            var names: [String: (name: String, bundleID: String)] = [:]
            let trash = home.appendingPathComponent(".Trash", isDirectory: true)
            guard cleanupPathIsPhysical(trash, home: home) else { return names }
            let trashedApps = self.directChildren(of: trash)
                .filter { $0.pathExtension.lowercased() == "app" && !self.isSymlink($0) }

            let containers = home.appendingPathComponent("Library/Containers", isDirectory: true)
            let containerScan = mode == .deep && cleanupPathIsPhysical(containers, home: home)
            // Avoid preparing the installed-app inventory when there is neither
            // a trashed bundle nor a container to correlate.
            guard !control.shouldStop, !trashedApps.isEmpty || containerScan else { return names }

            var installedBundleIDs = Set<String>()
            for (root, _) in self.applicationRoots(home: home) {
                guard !control.shouldStop else { return names }
                for item in self.directChildren(of: root)
                    where item.pathExtension.lowercased() == "app" && !self.isSymlink(item) {
                    guard !control.shouldStop else { return names }
                    if let bundleID = self.applicationMetadata(at: item)?.bundleID {
                        installedBundleIDs.insert(bundleID)
                    }
                }
            }

            for item in trashedApps {
                guard !control.shouldStop else { return names }
                guard let metadata = self.applicationMetadata(at: item),
                      !metadata.bundleID.isEmpty,
                      !installedBundleIDs.contains(metadata.bundleID) else { continue }

                let candidates = [
                    home.appendingPathComponent("Library/Caches/\(metadata.bundleID)", isDirectory: true),
                    home.appendingPathComponent("Library/Logs/\(metadata.bundleID)", isDirectory: true)
                ]
                for candidate in candidates {
                    let path = candidate.standardizedFileURL.path
                    names[path] = (metadata.name, metadata.bundleID)
                }
            }

            if containerScan {
                for container in self.directChildren(of: containers) {
                    guard !control.shouldStop else { return names }
                    let owner = container.lastPathComponent
                    guard owner != ".DS_Store",
                          !owner.hasPrefix("com.apple."),
                          CleanupRiskPolicy.isValidReverseDNSOwner(owner),
                          !installedBundleIDs.contains(owner),
                          !self.isSymlink(container) else { continue }
                    // 只标注可再生的缓存/日志叶子；容器根与用户数据留给
                    // 磁盘分析复核。
                    for leaf in ["Data/Library/Caches", "Data/Library/Logs"] {
                        let path = container.appendingPathComponent(leaf, isDirectory: true)
                            .standardizedFileURL.path
                        guard self.fileManager.fileExists(atPath: path) else { continue }
                        names[path] = (owner, owner)
                    }
                }
            }
            return names
    }

    /// The native cleanup inventory deliberately contains only rebuildable
    /// leaves.  App data, project sources and system-owned paths are handled by
    /// their dedicated feature or shown as review-only items.  Keeping this
    /// list in Swift makes the core route independent from the vendored Mole
    /// shell catalog while retaining the same conservative path model.
    ///
    /// 每个条目同时声明该类内容的默认保留期（retention）：开发者缓存与构建
    /// 产物默认 7 天未活跃才进入推荐；通用应用缓存不按年龄过滤，由运行态
    /// 守卫与执行前复核把关。
    private func cleanupRoots(home: URL, mode: CleanupScanMode, control: CleanupScanControl,
                              orphanNames: [String: (name: String, bundleID: String)] = [:])
        -> [(URL, String, CleanupSource, CleanupActivityGuard, TimeInterval)] {
        var roots: [(URL, String, CleanupSource, CleanupActivityGuard, TimeInterval)] = []
        var seen = Set<String>()
        let retention = CleanupAgePolicy.developerRetention

        func add(_ url: URL, _ label: String, _ source: CleanupSource,
                 _ guardKind: CleanupActivityGuard, _ retention: TimeInterval = 0) {
            let path = url.standardizedFileURL.path
            guard !control.shouldStop, self.cleanupPathIsPhysical(url, home: home),
                  seen.insert(path).inserted else { return }
            roots.append((url, label, source, guardKind, retention))
        }

        add(home.appendingPathComponent("Library/Caches", isDirectory: true),
            "User Caches", .core, .openFile)
        add(home.appendingPathComponent("Library/Logs", isDirectory: true),
            "User Logs", .core, .openFile)
        add(home.appendingPathComponent("Library/DiagnosticReports", isDirectory: true),
            "Diagnostic Reports", .core, .openFile)
        // DerivedData 按项目单元枚举：一个活跃项目不会冻结其他项目的
        // 构建产物回收；每个单元独立适用 7 天门槛。
        let derivedData = home.appendingPathComponent("Library/Developer/Xcode/DerivedData",
                                                      isDirectory: true)
        if cleanupPathIsPhysical(derivedData, home: home) {
            for project in directChildren(of: derivedData) where !isSymlink(project) {
                add(project, "Xcode DerivedData", .xcodeCache, .xcode, retention)
            }
        }
        add(home.appendingPathComponent("Library/Developer/Xcode/SourcePackages", isDirectory: true),
            "Xcode SourcePackages", .xcodeCache, .xcode, retention)
        add(home.appendingPathComponent("Library/Caches/com.apple.dt.Xcode", isDirectory: true),
            "Xcode Cache", .xcodeCache, .xcode)
        add(home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true),
            "Simulator Caches", .developerCache, .simulator, retention)
        // XCTestDevices accumulates one simulator clone per test run. Offer
        // each clone separately and leave the root for Xcode to reuse.
        let xctestDevices = home.appendingPathComponent("Library/Developer/XCTestDevices",
                                                        isDirectory: true)
        if cleanupPathIsPhysical(xctestDevices, home: home) {
            for clone in directChildren(of: xctestDevices) where !isSymlink(clone) {
                add(clone, "Xcode Test Devices", .xcodeCache, .xcode, retention)
            }
        }
        add(home.appendingPathComponent(".cache", isDirectory: true),
            "User Cache", .core, .openFile)
        add(home.appendingPathComponent(".npm/_cacache", isDirectory: true),
            "npm Cache", .developerCache, .packageManager, retention)
        add(home.appendingPathComponent(".yarn/cache", isDirectory: true),
            "Yarn Cache", .developerCache, .packageManager, retention)
        add(home.appendingPathComponent(".bun/install/cache", isDirectory: true),
            "Bun Cache", .developerCache, .packageManager, retention)
        // Gradle: the module cache under ~/.gradle/caches and the Maven local
        // repository are dependency stores (review-only, see
        // CleanupRiskPolicy.dependencyStoreRoots). Only the hash-keyed build
        // cache, daemon logs, worker scratch and notifications are offered.
        // 自定义 GRADLE_USER_HOME 同样处理：发现与策略共用同一位置解析。
        let locations = DeveloperCacheLocations.current(home: home.path)
        var gradleHomes = [home.appendingPathComponent(".gradle", isDirectory: true)]
        if let customGradle = locations.gradleUserHome {
            gradleHomes.append(URL(fileURLWithPath: customGradle, isDirectory: true))
        }
        for gradleHome in gradleHomes {
            let gradleCaches = gradleHome.appendingPathComponent("caches", isDirectory: true)
            if cleanupPathIsPhysical(gradleCaches, home: home) {
                for entry in directChildren(of: gradleCaches)
                    where entry.lastPathComponent.hasPrefix("build-cache-") && !isSymlink(entry) {
                    add(entry, "Gradle Build Cache", .developerCache, .packageManager, retention)
                }
            }
            for (relative, label) in [("daemon", "Gradle Daemon Logs"),
                                      ("workers", "Gradle Worker Cache"),
                                      ("notifications", "Gradle Notifications")] {
                add(gradleHome.appendingPathComponent(relative, isDirectory: true),
                    label, .developerCache, .packageManager, retention)
            }
        }
        add(home.appendingPathComponent(".cargo/registry/cache", isDirectory: true),
            "Cargo Cache", .developerCache, .packageManager, retention)
        add(home.appendingPathComponent(".swiftpm/cache", isDirectory: true),
            "Swift Package Cache", .developerCache, .packageManager, retention)
        add(home.appendingPathComponent(".cache/pip", isDirectory: true),
            "pip Cache", .developerCache, .packageManager, retention)
        add(home.appendingPathComponent(".cache/uv", isDirectory: true),
            "uv Cache", .developerCache, .packageManager, retention)
        add(home.appendingPathComponent(".cache/node/corepack", isDirectory: true),
            "Corepack Cache", .developerCache, .packageManager, retention)
        add(home.appendingPathComponent("Library/Caches/Homebrew/downloads", isDirectory: true),
            "Homebrew Cache", .developerCache, .packageManager, retention)
        add(home.appendingPathComponent("Library/Caches/org.carthage.CarthageKit", isDirectory: true),
            "Carthage Cache", .developerCache, .packageManager, retention)
        add(home.appendingPathComponent("go/pkg/mod/cache", isDirectory: true),
            "Go Module Cache", .developerCache, .packageManager, retention)
        add(home.appendingPathComponent(".Trash", isDirectory: true),
            "Trash", .core, .openFile)

        // Device firmware downloaded for restores (several GB per .ipsw) and
        // Messages preview/sticker caches. Both are re-fetched or regenerated
        // by macOS on demand; Messages attachments themselves are never listed.
        for entry in CleanupRiskPolicy.userRebuildableRoots(home: home.path) {
            let label = entry.reasonKey == "cleanup.risk.firmwareCache"
                ? "Device Firmware" : "Messages Cache"
            add(URL(fileURLWithPath: entry.path, isDirectory: true), label, .core, .openFile)
        }

        // Sandboxed apps keep their NSTemporaryDirectory in Data/tmp. Mole's
        // audited list: media analysis, geo, wallpaper, Configurator and
        // Apple Media Services agents, Office, and UTM. Only children are
        // offered; the policy never admits the tmp directory itself.
        let containerTempOwners = [
            "com.apple.mediaanalysisd", "com.apple.geod",
            "com.apple.wallpaper.extension.aerials",
            "com.apple.configurator.xpc.InternetService",
            "com.apple.AppleMediaServicesUI.UtilityExtension",
            "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
            "com.utmapp.UTM"
        ]
        for owner in containerTempOwners {
            let temp = home.appendingPathComponent("Library/Containers/\(owner)/Data/tmp",
                                                   isDirectory: true)
            guard !control.shouldStop, cleanupPathIsPhysical(temp, home: home) else { continue }
            for child in directChildren(of: temp) where !isSymlink(child) {
                add(child, owner + " tmp", .core, .openFile)
            }
        }

        // Additional fixed developer cache locations. These are all
        // rebuildable package/build caches; project sources and installed
        // runtimes are intentionally not included in the quick inventory.
        let developerCaches: [(String, String)] = [
            ("Library/Caches/pnpm", "pnpm Cache"),
            ("Library/Caches/Yarn", "Yarn Cache"),
            ("Library/Caches/go-build", "Go Build Cache"),
            ("Library/Caches/pip", "pip Cache"),
            ("Library/Caches/pypoetry", "Poetry Cache"),
            ("Library/Caches/NuGet", "NuGet Cache"),
            ("Library/Caches/composer", "Composer Cache"),
            ("Library/Caches/node-gyp", "node-gyp Cache"),
            ("Library/Caches/typescript", "TypeScript Cache"),
            ("Library/Caches/org.swift.swiftpm", "SwiftPM Cache"),
            (".node-gyp", "node-gyp Cache"),
            (".cache/bazel", "Bazel Cache"),
            (".cache/zig", "Zig Cache"),
            (".cache/electron", "Electron Cache"),
            (".cache/node-gyp", "node-gyp Cache"),
            (".turbo/cache", "Turborepo Cache"),
            (".vite/cache", "Vite Cache"),
            (".cache/vite", "Vite Cache"),
            (".cache/webpack", "Webpack Cache"),
            (".parcel-cache", "Parcel Cache"),
            (".cache/eslint", "ESLint Cache"),
            (".cache/prettier", "Prettier Cache"),
            (".cache/swift-package-manager", "SwiftPM Cache")
        ]
        for (relative, label) in developerCaches {
            add(home.appendingPathComponent(relative, isDirectory: true),
                label, .developerCache, .packageManager, retention)
        }
        // 工具配置声明的自定义缓存位置（npmrc / yarnrc / pip.conf / 各类
        // *_HOME 环境变量）与默认位置同等进入清单，同样适用 7 天门槛。
        for (custom, label) in [(locations.npmCache, "npm Cache"),
                                (locations.yarnCache, "Yarn Cache"),
                                (locations.pipCache, "pip Cache"),
                                (locations.poetryCache, "Poetry Cache"),
                                (locations.goModCache, "Go Module Cache"),
                                (locations.goBuildCache, "Go Build Cache")] {
            guard let custom else { continue }
            add(URL(fileURLWithPath: custom, isDirectory: true),
                label, .developerCache, .packageManager, retention)
        }
        if let cargoHome = locations.cargoHome {
            add(URL(fileURLWithPath: cargoHome + "/registry/cache", isDirectory: true),
                "Cargo Cache", .developerCache, .packageManager, retention)
        }

        // 缓存地图：大体积、可重建的应用级缓存。发现层只负责枚举形状
        // （浏览器各 profile、Telegram 各账号、飞书各用户），风险与守卫
        // 由 CleanupRiskPolicy 的知识库裁决；禁区路径不会出现在这里。
        let appSupport = home.appendingPathComponent("Library/Application Support",
                                                     isDirectory: true)
        let browserProfileParents: [(String, String)] = [
            ("Google/Chrome", "Chrome Service Worker"),
            ("Microsoft Edge", "Edge Service Worker"),
            ("BraveSoftware/Brave-Browser", "Brave Service Worker"),
            ("Arc/User Data", "Arc Service Worker")
        ]
        for (relative, label) in browserProfileParents {
            let parentURL = appSupport.appendingPathComponent(relative, isDirectory: true)
            guard !control.shouldStop, cleanupPathIsPhysical(parentURL, home: home) else { continue }
            for profile in directChildren(of: parentURL)
                where !isSymlink(profile) && isDirectory(profile) {
                add(profile.appendingPathComponent("Service Worker", isDirectory: true),
                    label, .core, .browser)
            }
        }
        // 自动化调试的独立 user-data-dir，整个目录可再生。
        add(appSupport.appendingPathComponent("Google/ChromeDebug", isDirectory: true),
            "ChromeDebug Profile", .core, .browser)
        // Telegram 媒体缓存：每个账号一条（老的账号往往最大）；postbox/db
        // 是消息数据库，由策略知识库保护，不会进入发现层。
        let telegramRoot = home.appendingPathComponent(
            "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram", isDirectory: true)
        if cleanupPathIsPhysical(telegramRoot, home: home) {
            for account in directChildren(of: telegramRoot)
                where account.lastPathComponent.hasPrefix("account-") && !isSymlink(account) {
                add(account.appendingPathComponent("postbox/media", isDirectory: true),
                    "Telegram Media Cache", .core, .messenger)
            }
        }
        // 飞书文档预览缓存：多账号各自堆积，只认 profile_explorer。
        let larkUsers = appSupport.appendingPathComponent("LarkShell/aha/users",
                                                          isDirectory: true)
        if cleanupPathIsPhysical(larkUsers, home: home) {
            for user in directChildren(of: larkUsers) where !isSymlink(user) {
                add(user.appendingPathComponent("profile_explorer", isDirectory: true),
                    "Lark Doc Cache", .core, .messenger)
            }
        }

        // Common IM clients, Office suites and virtualization apps keep
        // disposable thumbnails and web caches in sandbox containers rather
        // than ~/Library/Caches. The policy guards each container by its
        // reverse-DNS owner, so a running app keeps its own cache untouched.
        let imContainerCaches: [(String, String)] = [
            ("com.tencent.xinWeChat", "WeChat Cache"),
            ("com.tencent.qq", "QQ Cache"),
            ("com.tencent.meeting", "Tencent Meeting Cache"),
            ("com.alibaba.DingTalkMac", "DingTalk Cache"),
            ("com.bytedance.feishu", "Feishu Cache"),
            ("com.bytedance.lark", "Lark Cache"),
            ("net.whatsapp.WhatsApp", "WhatsApp Cache"),
            ("org.telegram.desktop", "Telegram Cache"),
            ("org.signal.Signal", "Signal Cache"),
            ("com.microsoft.teams2", "Microsoft Teams Cache"),
            ("com.skype.skype", "Skype Cache"),
            ("com.microsoft.Word", "Microsoft Word Cache"),
            ("com.microsoft.Excel", "Microsoft Excel Cache"),
            ("com.microsoft.Powerpoint", "Microsoft PowerPoint Cache"),
            ("com.microsoft.Outlook", "Microsoft Outlook Cache"),
            ("com.microsoft.onenote.mac", "Microsoft OneNote Cache"),
            ("com.apple.iWork.Pages", "Pages Cache"),
            ("com.apple.iWork.Numbers", "Numbers Cache"),
            ("com.apple.iWork.Keynote", "Keynote Cache"),
            ("com.utmapp.UTM", "UTM Cache"),
            ("com.apple.AppStore", "App Store Cache"),
            ("com.apple.stocks", "Stocks Cache"),
            ("com.apple.mediaanalysisd", "Media Analysis Cache"),
            ("com.apple.AMPArtworkAgent", "Music Artwork Cache")
        ]
        // The policy admits entries *below* a container's Caches directory
        // (`<id>/Data/Library/Caches/<child>`), never the directory itself, so
        // enumerate children here; adding the root would classify as Warning
        // and silently drop the whole container from the quick inventory.
        for (identifier, label) in imContainerCaches {
            let cachesRoot = home.appendingPathComponent(
                "Library/Containers/\(identifier)/Data/Library/Caches", isDirectory: true)
            guard !control.shouldStop, cleanupPathIsPhysical(cachesRoot, home: home) else { continue }
            for child in directChildren(of: cachesRoot) where !isSymlink(child) {
                add(child, label, .core, .reverseDNSCache)
            }
        }
        let imSupportCaches: [(String, String)] = [
            ("WeChat", "WeChat Cache"), ("Tencent/QQ", "QQ Cache"),
            ("Tencent/Meeting", "Tencent Meeting Cache"),
            ("DingTalk", "DingTalk Cache"), ("Feishu", "Feishu Cache"),
            ("Lark", "Lark Cache"), ("WhatsApp", "WhatsApp Cache"),
            ("Telegram Desktop", "Telegram Cache"), ("Signal", "Signal Cache"),
            ("Microsoft Teams", "Microsoft Teams Cache"),
            ("Microsoft Teams 2", "Microsoft Teams Cache"),
            ("Skype", "Skype Cache"), ("Zoom.us", "Zoom Cache"),
            ("Messenger", "Messenger Cache"), ("Rocket.Chat", "Rocket.Chat Cache"),
            ("Mattermost", "Mattermost Cache")
        ]
        for (relative, label) in imSupportCaches {
            add(home.appendingPathComponent("Library/Application Support/\(relative)/Cache",
                                           isDirectory: true), label, .core, .browser)
        }
        let safariCaches = home.appendingPathComponent(
            "Library/Containers/com.apple.Safari/Data/Library/Caches", isDirectory: true)
        if cleanupPathIsPhysical(safariCaches, home: home) {
            for child in directChildren(of: safariCaches) where !isSymlink(child) {
                add(child, "Safari Cache", .core, .reverseDNSCache)
            }
        }

        // Chromium-family profiles all use the same rebuildable cache leaves.
        // Discover profiles instead of assuming that only Default exists.
        let browsers: [(String, String)] = [
            ("Google/Chrome", "Chrome"),
            ("Google/Chrome Beta", "Chrome Beta"),
            ("Google/Chrome Canary", "Chrome Canary"),
            ("Chromium", "Chromium"),
            ("Microsoft Edge", "Edge"),
            ("BraveSoftware/Brave-Browser", "Brave"),
            ("Arc/User Data", "Arc"),
            ("Dia/User Data", "Dia"),
            ("Vivaldi", "Vivaldi"),
            ("com.operasoftware.Opera", "Opera"),
            ("Yandex/YandexBrowser", "Yandex Browser"),
            ("QQBrowser3", "QQBrowser"),
            ("net.imput.helium", "Helium"),
            ("Firefox/Profiles", "Firefox")
        ]
        // Chromium leaves from Mole's browser catalog: web/code caches, the
        // GPU shader caches (GPUCache, GrShader, Dawn/Graphite variants),
        // Service Worker script/storage caches, CRX download caches and
        // completed crash reports. Firefox uses cache2 and startupCache.
        let cacheLeaves = ["Cache", "Code Cache", "GPUCache", "GrShaderCache", "ShaderCache",
                           "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
                           "GraphiteDawnCache", "GPUPersistentCache", "Application Cache",
                           "Service Worker/CacheStorage", "Service Worker/ScriptCache",
                           "component_crx_cache", "extensions_crx_cache",
                           "Crashpad/completed", "cache2", "startupCache"]
        for (relative, label) in browsers {
            let browserRoot = home.appendingPathComponent("Library/Application Support/\(relative)",
                                                         isDirectory: true)
            guard !control.shouldStop, cleanupPathIsPhysical(browserRoot, home: home) else { continue }
            for profile in [browserRoot] + directChildren(of: browserRoot)
                where isDirectory(profile) && cleanupPathIsPhysical(profile, home: home) {
                for leaf in cacheLeaves {
                    add(profile.appendingPathComponent(leaf, isDirectory: true),
                        "\(label) \(leaf)",
                        .core, .browser)
                }
            }
        }

        // Electron and IDE applications put rebuildable caches below
        // Application Support rather than Library/Caches.
        let appCacheRoots: [(String, String)] = [
            ("Slack/Cache", "Slack Cache"), ("Slack/Code Cache", "Slack Code Cache"),
            ("Slack/GPUCache", "Slack GPU Cache"),
            ("discord/Cache", "Discord Cache"), ("discord/Code Cache", "Discord Code Cache"),
            ("discord/GPUCache", "Discord GPU Cache"),
            ("WhatsApp/Cache", "WhatsApp Cache"), ("WhatsApp/Code Cache", "WhatsApp Code Cache"),
            ("WhatsApp/GPUCache", "WhatsApp GPU Cache"),
            ("Telegram Desktop/cache", "Telegram Cache"),
            ("Telegram Desktop/Cache", "Telegram Cache"),
            ("Signal/Cache", "Signal Cache"), ("Signal/Code Cache", "Signal Code Cache"),
            ("Microsoft Teams/Cache", "Microsoft Teams Cache"),
            ("Microsoft Teams/Code Cache", "Microsoft Teams Code Cache"),
            ("Microsoft Teams/GPUCache", "Microsoft Teams GPU Cache"),
            ("Microsoft Teams 2/Cache", "Microsoft Teams Cache"),
            ("Skype/Cache", "Skype Cache"), ("Zoom.us/Cache", "Zoom Cache"),
            ("Messenger/Cache", "Messenger Cache"),
            ("Code/Cache", "VS Code Cache"), ("Code/CachedData", "VS Code Cached Data"),
            ("Code/GPUCache", "VS Code GPU Cache"), ("Zed/Cache", "Zed Cache"),
            ("Feishu/Cache", "Feishu Cache"), ("Lark/Cache", "Lark Cache")
        ]
        for (relative, label) in appCacheRoots {
            add(home.appendingPathComponent("Library/Application Support/\(relative)",
                                           isDirectory: true), label, .core, .browser)
        }

        // Broader app discovery is opt-in. Only cache/log leaves become jobs.
        if mode == .deep {
            let containers = home.appendingPathComponent("Library/Containers", isDirectory: true)
            if cleanupPathIsPhysical(containers, home: home) {
                for container in directChildren(of: containers) {
                    guard !control.shouldStop else { break }
                    // Data/tmp is the sandboxed NSTemporaryDirectory; like the
                    // cache/log leaves it is admitted per child by owner.
                    for (relative, leaf) in [("Data/Library/Caches", "Caches"),
                                             ("Data/Library/Logs", "Logs"),
                                             ("Data/tmp", "tmp")] {
                        let root = container.appendingPathComponent(relative)
                        // 疑似已卸载应用的容器：Caches/Logs 以整叶作为“历史
                        // 残留”候选（见下方 orphanNames），不再拆成通用子项，
                        // 避免同一目录双重计量。
                        if relative != "Data/tmp",
                           orphanNames[root.standardizedFileURL.path] != nil {
                            continue
                        }
                        guard cleanupPathIsPhysical(root, home: home) else { continue }
                        for child in directChildren(of: root) {
                            add(child, container.lastPathComponent + " " + leaf, .core, .openFile)
                        }
                    }
                }
                // 废纸篓已清空的历史残留：未安装应用容器的缓存/日志叶子。
                for (path, owner) in orphanNames
                    where path.hasPrefix(containers.standardizedFileURL.path + "/") {
                    add(URL(fileURLWithPath: path, isDirectory: true),
                        owner.name + " leftovers", .appLeftover, .openFile)
                }
            }
            let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            if cleanupPathIsPhysical(support, home: home) {
                for app in directChildren(of: support) {
                    guard !control.shouldStop, cleanupPathIsPhysical(app, home: home) else { continue }
                    // Inspect only known cache leaf names. No recursive search
                    // through conversations, models or arbitrary user files.
                    for leaf in cacheLeaves + ["Caches", "CachedData", "CachedExtensionVSIXs",
                                                "ShaderCache", "logs", "Crashpad/completed"] {
                        add(app.appendingPathComponent(leaf), app.lastPathComponent + " " + leaf,
                            .core, .openFile)
                    }
                }
            }
        }

        return roots
    }

    /// Apply a previously confirmed deletion plan. Each item carries the
    /// identity captured at confirmation time; a changed identity is skipped.
    ///
    /// `verifiedTargets` only lifts the leaf name/extension block (sessions,
    /// `*.sqlite`, …) for paths the Agent catalog re-derived at execution
    /// time; every other check still applies. Paths in one `atomicFamilies`
    /// entry (a SQLite file and its -wal/-shm/-journal) are removed together
    /// or not at all.
    func applyCleanup(items: [DeletionPlan.Item], permanent: Bool,
                      homeDirectory: String = NSHomeDirectory(),
                      allowedRoots: [String] = [],
                      allowApplicationBundle: Bool = false,
                      verifiedTargets: Set<String> = [],
                      atomicFamilies: [[String]] = []) -> ApplySummary {
        let home = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        let whitelist = loadWhitelist(homeDirectory: homeDirectory)
        let normalizedRoots = allowedRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var removed = 0
        var skipped = 0
        var failed = 0
        var messages: [String] = []
        let probeStart = Date()
        var removedPaths = Set<String>()
        Self.cleanupLogger.notice("Open-file safety check started")
        let openFiles = openFileSnapshot()
        let probeSeconds = Date().timeIntervalSince(probeStart)
        Self.cleanupLogger.notice("Open-file safety check finished in \(probeSeconds, privacy: .public)s; available=\(openFiles != nil, privacy: .public)")
        messages.append(String(format: "Open-file check %.2fs; available=%@", probeSeconds, openFiles == nil ? "no" : "yes"))

        let nonOverlapping = DeletionPlan.nonOverlappingPaths(items.map(\.record))
        let itemByRecord = Dictionary(items.map { ($0.record, $0) },
                                      uniquingKeysWith: { first, _ in first })
        // 整族预检：任一成员被打开、身份变化或探测不可用，整族保留。
        var blockedFamilyMembers = Set<String>()
        for family in atomicFamilies where family.count > 1 {
            let intact = family.allSatisfy { member in
                guard let expected = itemByRecord[member]?.identity, !expected.isEmpty,
                      let openFiles,
                      DeletionPlan.identity(at: member) == expected else { return false }
                return !openFiles.contains(URL(fileURLWithPath: member).standardizedFileURL.path)
            }
            if !intact { blockedFamilyMembers.formUnion(family) }
        }
        for rawPath in nonOverlapping {
            let expectedIdentity = itemByRecord[rawPath]?.identity ?? ""
            if blockedFamilyMembers.contains(rawPath) {
                skipped += 1
                messages.append("Skipped database family that is open or changed: \(rawPath)")
                continue
            }
            // 第一道：词法校验（绝对路径、无控制字符、无 "."/".." 分量）。
            guard DeletionPlan.isLexicallySafePath(rawPath) else {
                skipped += 1
                messages.append("Skipped unsafe path literal: \(rawPath)")
                continue
            }
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            let path = url.path
            let isHomePath = path.hasPrefix(home + "/")
            let isAllowedRoot = normalizedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
            guard isHomePath || isAllowedRoot else {
                skipped += 1
                messages.append("Skipped outside authorized roots: \(path)")
                continue
            }
            guard fileManager.fileExists(atPath: path), !isSymlink(url),
                  verifiedTargets.contains(rawPath)
                    || !isProtectedCleanupItem(url, allowApplicationBundle: allowApplicationBundle),
                  !matchesWhitelist(path, entries: whitelist) else {
                skipped += 1
                continue
            }
            guard !expectedIdentity.isEmpty,
                  let identity = DeletionPlan.identity(at: path),
                  identity == expectedIdentity else {
                skipped += 1
                messages.append("Skipped changed or unavailable path: \(path)")
                continue
            }
            guard !isOwnedByRunningApplication(path: path) else {
                skipped += 1
                messages.append("Skipped while owning application is running: \(path)")
                continue
            }
            guard let openFiles else {
                skipped += 1
                messages.append("Skipped because open-file state was unavailable: \(path)")
                continue
            }
            guard !openFiles.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) else {
                skipped += 1
                messages.append("Skipped while the path is open: \(path)")
                continue
            }

            if permanent {
                // 永久删除走 fd 链：从 "/" 开始逐级 openat(O_NOFOLLOW) 打开，
                // 任何一级是符号链接或最终身份与计划不一致都拒绝；递归删除
                // 在已打开的目录描述符下进行，全程不重新解析路径字符串，
                // 扫描与删除之间被替换的路径删不到别处。
                guard let identity = Self.parseIdentity(expectedIdentity),
                      removeTreeSecurely(path, expectedDevice: identity.device,
                                         expectedInode: identity.inode) else {
                    failed += 1
                    messages.append("Failed secure removal of \(path)")
                    continue
                }
                removed += 1
                removedPaths.insert(rawPath)
            } else {
                do {
                    var resultingURL: NSURL?
                    try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
                    removed += 1
                    removedPaths.insert(rawPath)
                } catch {
                    failed += 1
                    messages.append("Failed to remove \(path): \(error.localizedDescription)")
                }
            }
        }
        return ApplySummary(removed: removed, skipped: skipped,
                            failed: failed, messages: messages, removedPaths: removedPaths)
    }

    /// `device:inode:mtime` 身份串的前两个字段。
    private static func parseIdentity(_ identity: String) -> (device: UInt64, inode: UInt64)? {
        let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let device = UInt64(parts[0]),
              let inode = UInt64(parts[1]) else { return nil }
        return (device, inode)
    }

    /// 逐级 openat(O_NOFOLLOW|O_DIRECTORY) 打开到目标的父目录，再打开目标
    /// 本身并核对 (device, inode)。链上任何一级是符号链接（openat 失败）或
    /// 身份不一致都返回 false，不做任何删除。
    private func removeTreeSecurely(_ path: String,
                                    expectedDevice: UInt64,
                                    expectedInode: UInt64) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.count >= 2 else { return false }
        var directoryFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { return false }
        var opened = true
        for component in components.dropLast() {
            let next = openat(directoryFD, component,
                              O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            guard next >= 0 else { opened = false; break }
            close(directoryFD)
            directoryFD = next
        }
        defer { if opened { close(directoryFD) } }
        guard opened else { return false }

        let leaf = components[components.count - 1]
        let targetFD = openat(directoryFD, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard targetFD >= 0 else { return false }
        defer { close(targetFD) }
        var target = stat()
        guard fstat(targetFD, &target) == 0,
              UInt64(target.st_dev) == expectedDevice,
              UInt64(target.st_ino) == expectedInode else { return false }

        if (target.st_mode & S_IFMT) == S_IFDIR {
            guard removeContents(of: targetFD) else { return false }
            return unlinkat(directoryFD, leaf, AT_REMOVEDIR) == 0
        }
        return unlinkat(directoryFD, leaf, 0) == 0
    }

    /// 在已打开的目录描述符下清空全部内容。不跟随符号链接：链接本身作为
    /// 一个条目被 unlink，指向的外部内容不受影响。
    private func removeContents(of directoryFD: Int32) -> Bool {
        // fdopendir 会接管传入的描述符，先复制一份给目录流。
        let streamFD = dup(directoryFD)
        guard streamFD >= 0, let stream = fdopendir(streamFD) else {
            if streamFD >= 0 { close(streamFD) }
            return false
        }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            var entryStat = stat()
            let isDirectory: Bool
            if Int32(entry.pointee.d_type) == DT_UNKNOWN {
                // 个别文件系统不提供 d_type：退回 fstatat(AT_SYMLINK_NOFOLLOW)。
                guard fstatat(directoryFD, name, &entryStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                    return false
                }
                isDirectory = (entryStat.st_mode & S_IFMT) == S_IFDIR
            } else {
                isDirectory = Int32(entry.pointee.d_type) == DT_DIR
            }
            if isDirectory {
                let childFD = openat(directoryFD, name,
                                     O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
                guard childFD >= 0, removeContents(of: childFD),
                      unlinkat(directoryFD, name, AT_REMOVEDIR) == 0 else {
                    if childFD >= 0 { close(childFD) }
                    return false
                }
                close(childFD)
            } else if unlinkat(directoryFD, name, 0) != 0 {
                return false
            }
        }
        return true
    }

    // MARK: Analyze

    func scanAnalyze(path: String, overview: Bool,
                     control: CleanupScanControl = CleanupScanControl(mode: .deep),
                     progress: ((AnalyzeReport) -> Void)? = nil) async -> AnalyzeReport {
        await Task.detached(priority: .utility) {
            DiskAnalysisWorker.scan(path, control: control, progress: progress)
        }.value
    }

    // MARK: Uninstall

    func scanInstalledApps(homeDirectory: String = NSHomeDirectory()) async -> [UninstallApp] {
        await Task.detached(priority: .utility) { [self] in
            let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
            let roots = self.applicationRoots(home: home)
            return self.installedApps(in: roots)
        }.value
    }

    /// Scan canonical roots once; names and Bundle IDs are not unique installs.
    func installedApps(in roots: [(URL, String)]) -> [UninstallApp] {
        var apps: [UninstallApp] = []
        var seen = Set<String>()
        for (root, source) in uniqueApplicationRoots(roots) {
            for item in self.directChildren(of: root) {
                guard item.pathExtension.lowercased() == "app",
                      !self.isSymlink(item),
                      let metadata = self.applicationMetadata(at: item),
                      !metadata.bundleID.isEmpty,
                      metadata.bundleID != Bundle.main.bundleIdentifier,
                      !metadata.bundleID.hasPrefix("com.apple."),
                      let identity = applicationDirectoryIdentity(item),
                      seen.insert(identity).inserted else { continue }
                let bytes = self.directorySize(item)
                apps.append(UninstallApp(
                    name: metadata.name,
                    bundleID: metadata.bundleID,
                    source: source,
                    path: item.path,
                    size: ByteFormat.format(bytes)))
            }
        }
        return apps.sorted {
            let lhs = ByteFormat.parse($0.size)
            let rhs = ByteFormat.parse($1.size)
            if lhs != rhs { return lhs > rhs }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Installer images commonly contain Applications -> /Applications.
    /// Resolve every ancestor before enumeration and keep the first source label.
    private func uniqueApplicationRoots(_ roots: [(URL, String)]) -> [(URL, String)] {
        var seen = Set<String>()
        return roots.compactMap { root, source in
            let resolved = root.resolvingSymlinksInPath().standardizedFileURL
            guard let identity = applicationDirectoryIdentity(resolved),
                  seen.insert(identity).inserted else { return nil }
            return (resolved, source)
        }
    }

    private func applicationDirectoryIdentity(_ url: URL) -> String? {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else { return nil }
        return "\(metadata.st_dev):\(metadata.st_ino)"
    }

    /// Enumerate application locations without relying on the Mole inventory
    /// script.  External volumes are included only when macOS reports them as
    /// mounted; hidden volumes and the current app bundle are never traversed.
    private func applicationRoots(home: URL) -> [(URL, String)] {
        var roots: [(URL, String)] = [
            (URL(fileURLWithPath: "/Applications", isDirectory: true), "Applications"),
            (URL(fileURLWithPath: "/System/Applications", isDirectory: true), "System Applications"),
            (home.appendingPathComponent("Applications", isDirectory: true), "User Applications"),
            (home.appendingPathComponent("Library/Application Support/Setapp/Applications",
                                         isDirectory: true), "Setapp"),
            (home.appendingPathComponent("Library/Application Support/Steam/steamapps/common",
                                         isDirectory: true), "Steam")
        ]
        // Package-installed app bundles are occasionally placed outside the
        // normal Applications folders. Include these roots when present; the
        // bundle and Info.plist identities are still required before display
        // or removal.
        for (path, label) in [("/usr/local", "Package install"), ("/opt", "Package install")] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                roots.append((url, label))
            }
        }
        var seen = Set(roots.map { $0.0.standardizedFileURL.path })
        if let volumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                        options: [.skipHiddenVolumes]) {
            for volume in volumes {
                let applications = volume.appendingPathComponent("Applications", isDirectory: true)
                let path = applications.standardizedFileURL.path
                guard seen.insert(path).inserted,
                      fileManager.fileExists(atPath: path) else { continue }
                roots.append((applications, "External Applications"))
            }
        }
        return uniqueApplicationRoots(roots)
    }

    func uninstallPlan(for app: UninstallApp,
                       homeDirectory: String = NSHomeDirectory()) async -> UninstallPlan? {
        await Task.detached(priority: .utility) { [self] in
            let appURL = URL(fileURLWithPath: app.path).standardizedFileURL
            guard self.applicationMetadata(at: appURL)?.bundleID == app.bundleID,
                  DeletionPlan.identity(at: app.path) == app.appIdentity,
                  DeletionPlan.identity(at: app.path + "/Contents/Info.plist") == app.infoIdentity else {
                return nil
            }
            let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
            var files = [UninstallFile(
                bytes: self.directorySize(appURL), label: "app", path: appURL.path)]
            // Bundle-ID caches are shared by sibling installs. Keep them when
            // another bundle with the same ID is still present.
            let siblingRoots = self.applicationRoots(home: home).map(\.0)
                + [appURL.deletingLastPathComponent()]
            let appDirectoryIdentity = self.applicationDirectoryIdentity(appURL)
            let otherApps = siblingRoots.flatMap { self.directChildren(of: $0) }.filter { candidate in
                candidate.path != appURL.path && candidate.pathExtension.lowercased() == "app"
                    && self.applicationDirectoryIdentity(candidate) != appDirectoryIdentity
                    && !self.isSymlink(candidate)
            }
            let hasSibling = otherApps.contains {
                self.applicationMetadata(at: $0)?.bundleID == app.bundleID
            }
            files.append(contentsOf: self.relatedUninstallCandidates(
                app: app, home: home, hasSibling: hasSibling, otherApps: otherApps))
            let caskToken = self.nativeBrewCaskToken(for: app)
            return UninstallPlan(files: files, needsAdmin: false,
                                 isBrewCask: caskToken != nil,
                                 caskToken: caskToken ?? "-", includesProtectedAppData: true,
                                 scannedAt: Date())
        }.value
    }

    /// Resolve a Homebrew cask without depending on Mole's uninstall bridge.
    /// `brew list --cask <token>` reports the installed artifact paths, which
    /// gives us a stronger match than comparing display names alone.
    private func nativeBrewCaskToken(for app: UninstallApp) -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .filter { fileManager.isExecutableFile(atPath: $0) }
        guard let brew = candidates.first,
              let tokenList = runCommandOutput(brew, ["list", "--cask", "--full-name"]) else {
            return nil
        }
        let appName = URL(fileURLWithPath: app.path).lastPathComponent.lowercased()
        guard appName.hasSuffix(".app") else { return nil }
        let tokens = tokenList.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.range(of: "^[A-Za-z0-9@._+/-]+$", options: .regularExpression) != nil }
        // Avoid a potentially expensive `brew list` call for every cask by
        // checking only tokens whose spelling overlaps the app name.
        let appStem = appName.dropLast(4).filter { $0.isLetter || $0.isNumber }
            .lowercased()
        guard !appStem.isEmpty else { return nil }
        for token in tokens {
            let tokenStem = token.filter { $0.isLetter || $0.isNumber }.lowercased()
            guard tokenStem.contains(appStem) || appStem.contains(tokenStem) else { continue }
            guard let listing = runCommandOutput(brew, ["list", "--cask", token]) else { continue }
            if listing.split(whereSeparator: \.isNewline).contains(where: {
                URL(fileURLWithPath: String($0)).lastPathComponent.lowercased() == appName
            }) {
                return token
            }
        }
        return nil
    }

    /// Mixed app data stays review-only. Named app-support locations contribute
    /// only known disposable leaves, never their parent or a vendor-wide root.
    private func relatedUninstallCandidates(app: UninstallApp, home: URL,
                                            hasSibling: Bool, otherApps: [URL]) -> [UninstallFile] {
        var candidates: [UninstallFile] = []
        var seen = Set<String>()
        func append(_ url: URL, label: String) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted,
                  fileManager.fileExists(atPath: path), !isSymlink(url) else { return }
            if label == "related" {
                guard cleanupPathIsPhysical(url, home: home),
                      !CleanupRiskPolicy.isProtectedContent(path, homeDirectory: home.path) else { return }
            }
            let bytes = directorySize(url)
            candidates.append(UninstallFile(bytes: bytes, label: label, path: path))
        }

        if CleanupRiskPolicy.isValidReverseDNSOwner(app.bundleID) {
            let cacheLabel = hasSibling ? "review" : "related"
            append(home.appendingPathComponent("Library/Caches/\(app.bundleID)", isDirectory: true),
                   label: cacheLabel)
            append(home.appendingPathComponent("Library/Logs/\(app.bundleID)", isDirectory: true),
                   label: cacheLabel)
            for relative in [
                "Library/Caches/\(app.bundleID).ShipIt",
                "Library/Caches/com.apple.nsurlsessiond/Downloads/\(app.bundleID)",
                "Library/Containers/\(app.bundleID)/Data/Library/Caches",
                "Library/Containers/\(app.bundleID)/Data/Library/Logs",
                "Library/Containers/\(app.bundleID)/Data/tmp",
                "Library/WebKit/\(app.bundleID)/WebsiteData/NetworkCache"
            ] {
                append(home.appendingPathComponent(relative, isDirectory: true), label: cacheLabel)
            }

            let appURL = URL(fileURLWithPath: app.path)
            let supportNames = uninstallSupportNames(at: appURL, bundleID: app.bundleID)
            let sharedNames = Set(otherApps.flatMap { other -> [String] in
                guard let metadata = applicationMetadata(at: other) else { return [] }
                return uninstallSupportNames(at: other, bundleID: metadata.bundleID)
                    .map { $0.lowercased() }
            })
            let leaves = ["Cache", "Caches", "Code Cache", "GPUCache", "DawnCache",
                          "ShaderCache", "GrShaderCache", "CachedData", "CachedExtensionVSIXs",
                          "logs", "Crashpad/completed", "Service Worker/CacheStorage",
                          "Service Worker/ScriptCache"]
            for name in supportNames.sorted() {
                let root = home.appendingPathComponent("Library/Application Support/" + name)
                append(root, label: "review")
                let namedCache = home.appendingPathComponent("Library/Caches/" + name)
                let shared = hasSibling || sharedNames.contains(name.lowercased())
                if CleanupRiskPolicy.core(section: "Uninstall cache", path: namedCache.path,
                                          homeDirectory: home.path).risk == .safe {
                    append(namedCache, label: shared ? "review" : "related")
                }
                guard !shared else { continue }
                // Chromium/Electron profiles are bounded to known direct children.
                // Do not recursively search arbitrary user data for cache-like names.
                var profileRoots = [root]
                if cleanupPathIsPhysical(root, home: home) {
                    profileRoots += directChildren(of: root).filter {
                        $0.lastPathComponent == "Default"
                            || $0.lastPathComponent.range(of: "^Profile [0-9]+$", options: .regularExpression) != nil
                    }
                }
                for profile in profileRoots {
                    for leaf in leaves {
                        let url = profile.appendingPathComponent(leaf)
                        guard CleanupRiskPolicy.core(section: "Uninstall cache", path: url.path,
                                                     homeDirectory: home.path).risk == .safe else { continue }
                        append(url, label: "related")
                    }
                }
            }
        }

        let reviewRoots = [
            ("Library/Application Support/\(app.bundleID)", true),
            ("Library/Preferences/\(app.bundleID).plist", false),
            ("Library/Containers/\(app.bundleID)", true),
            ("Library/Group Containers/\(app.bundleID)", true),
            ("Library/Saved Application State/\(app.bundleID).savedState", true),
            ("Library/WebKit/\(app.bundleID)", true),
            ("Library/HTTPStorages/\(app.bundleID)", true),
            ("Library/Caches/com.apple.nsurlsessiond/Downloads/\(app.bundleID)", true)
        ]
        for (relative, isDirectory) in reviewRoots {
            append(home.appendingPathComponent(relative, isDirectory: isDirectory), label: "review")
        }

        // LaunchAgent/Daemon plists and privileged helpers are surfaced with
        // exact bundle evidence. They are intentionally informational until a
        // native administrator route is available; an unrelated system item
        // must never be removed as a side effect of uninstalling an app.
        let identityTokens = [app.bundleID, app.name, app.path,
                              URL(fileURLWithPath: app.path).deletingPathExtension().path]
            .map { $0.lowercased() }
        func matchesApp(_ url: URL) -> Bool {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            let lower = text.lowercased()
            return identityTokens.contains { !$0.isEmpty && lower.contains($0) }
        }
        let plistRoots = [
            home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        ]
        for root in plistRoots {
            for plist in directChildren(of: root)
                where plist.pathExtension.lowercased() == "plist" && matchesApp(plist) {
                append(plist, label: "manual")
            }
        }

        let helperRoot = URL(fileURLWithPath: "/Library/PrivilegedHelperTools", isDirectory: true)
        for helper in directChildren(of: helperRoot) {
            let lower = helper.lastPathComponent.lowercased()
            if identityTokens.contains(where: { !$0.isEmpty && lower.contains($0) }) {
                append(helper, label: "manual")
            }
        }

        let diagnosticRoots = [
            home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
        ]
        for root in diagnosticRoots {
            for report in directChildren(of: root) {
                let lower = report.lastPathComponent.lowercased()
                if identityTokens.contains(where: { !$0.isEmpty && lower.contains($0) }) {
                    append(report, label: "manual")
                }
            }
        }
        return candidates
    }

    private func uninstallSupportNames(at appURL: URL, bundleID: String) -> Set<String> {
        let bundle = Bundle(url: appURL)
        let metadataNames = [bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                             bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                             appURL.deletingPathExtension().lastPathComponent]
            .compactMap { $0 }.filter {
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/")
                    && !$0.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f })
                    && !["app", "electron", "google", "microsoft", "adobe", "shared"].contains($0.lowercased())
            }
        let knownNames: [String: String] = [
            "com.google.Chrome": "Google/Chrome",
            "com.google.Chrome.beta": "Google/Chrome Beta",
            "com.microsoft.VSCode": "Code",
            "com.microsoft.VSCodeInsiders": "Code - Insiders",
            "com.brave.Browser": "BraveSoftware/Brave-Browser",
            "company.thebrowser.Browser": "Arc/User Data"
        ]
        var names = Set(metadataNames)
        if CleanupRiskPolicy.isValidReverseDNSOwner(bundleID) { names.insert(bundleID) }
        if let name = knownNames[bundleID] { names.insert(name) }
        return names
    }

    func applyUninstall(_ app: UninstallApp, plan: UninstallPlan,
                        homeDirectory: String = NSHomeDirectory()) -> ApplySummary {
        guard DeletionPlan.identity(at: app.path) == app.appIdentity,
              DeletionPlan.identity(at: app.path + "/Contents/Info.plist") == app.infoIdentity else {
            return ApplySummary(removed: 0, skipped: 0, failed: 1,
                                messages: ["Application changed since it was scanned."])
        }
        guard !isOwnedByRunningApplication(path: app.path) else {
            return ApplySummary(removed: 0, skipped: 1, failed: 1,
                                messages: ["The application is still running."])
        }
        var appRemovedByBrew = false
        if plan.isBrewCask {
            guard plan.caskToken.range(of: "^[A-Za-z0-9@._+/-]+$", options: .regularExpression) != nil,
                  let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
                      .first(where: { fileManager.isExecutableFile(atPath: $0) }),
                  runCommand(brew, ["uninstall", "--cask", "--force", plan.caskToken]) else {
                return ApplySummary(removed: 0, skipped: 0, failed: 1,
                                    messages: ["Homebrew cask uninstall failed."])
            }
            let appURL = URL(fileURLWithPath: app.path)
            appRemovedByBrew = !fileManager.fileExists(atPath: app.path) && !isSymlink(appURL)
        }
        let cleanableFiles = plan.files.filter {
            !$0.informational && !(appRemovedByBrew && $0.path == app.path)
        }
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
        let items = cleanableFiles.compactMap { file -> DeletionPlan.Item? in
            guard let identity = plan.fileIdentities[file.path], !identity.isEmpty else { return nil }
            guard file.path == app.path || cleanupPathIsPhysical(URL(fileURLWithPath: file.path), home: home)
            else { return nil }
            return DeletionPlan.Item(record: file.path, identity: identity)
        }
        let missing = cleanableFiles.count - items.count
        var result = applyCleanup(items: items, permanent: false, homeDirectory: homeDirectory,
                                  allowedRoots: [app.path], allowApplicationBundle: true)
        if appRemovedByBrew {
            result = ApplySummary(removed: result.removed + 1, skipped: result.skipped,
                                  failed: result.failed, messages: result.messages)
        }
        if missing > 0 {
            result = ApplySummary(removed: result.removed, skipped: result.skipped + missing,
                                  failed: result.failed,
                                  messages: result.messages + ["Some uninstall paths had no confirmed identity or physical path."])
        }
        let appURL = URL(fileURLWithPath: app.path)
        if fileManager.fileExists(atPath: app.path) || isSymlink(appURL) {
            result = ApplySummary(removed: result.removed, skipped: result.skipped,
                                  failed: result.failed + 1,
                                  messages: result.messages + ["The application bundle was not removed."])
        }
        return verifyUninstallResult(result, files: plan.files)
    }

    /// Read-only verification is separate so missing and retained files have
    /// the same meaning for native and Homebrew removal.
    func verifyUninstallResult(_ result: ApplySummary, files: [UninstallFile]) -> ApplySummary {
        // A skipped cache is a partial uninstall even if the .app disappeared.
        // Keep intentionally retained data distinct from failed automatic cleanup.
        let remaining = files.filter { !$0.informational }.map(\.path).filter {
            DeletionPlan.identity(at: $0) != nil
        }
        let retained = files.filter(\.informational).map(\.path).filter {
            DeletionPlan.identity(at: $0) != nil
        }
        return ApplySummary(removed: result.removed, skipped: result.skipped,
                            failed: max(result.failed, max(result.skipped, remaining.count)),
                            messages: result.messages
                                + remaining.map { "Uninstall residue remains: \($0)" }
                                + retained.map { "Retained app data or shared/system item: \($0)" },
                            removedPaths: result.removedPaths,
                            remainingPaths: remaining, retainedPaths: retained)
    }

    // MARK: Optimize

    // MARK: Optimize helpers

    struct PreferenceRepairResult {
        var repaired = 0
        var failed = 0
        var partial = false
        var corrupt: [String] = []
    }

    /// Native port of Mole's `repair_broken_preferences`: lint third-party
    /// plists in `~/Library/Preferences` (and recursively in `ByHost`) and move
    /// the ones plutil rejects to Trash. Apple domains, `.GlobalPreferences`
    /// and `loginwindow.plist` are never candidates, whitelisted paths are
    /// skipped, and the pass stops after 15 seconds so a huge preference
    /// folder cannot stall the optimizer.
    func repairBrokenPreferences(homeDirectory: String, dryRun: Bool = false) -> PreferenceRepairResult {
        var result = PreferenceRepairResult()
        let preferences = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        guard isDirectory(preferences), fileManager.isExecutableFile(atPath: "/usr/bin/plutil") else {
            return result
        }
        let whitelist = loadWhitelist(homeDirectory: homeDirectory)
        let deadline = Date().addingTimeInterval(15)

        func isCandidate(_ url: URL, protectLoginWindow: Bool) -> Bool {
            guard url.pathExtension == "plist", !isSymlink(url) else { return false }
            let name = url.lastPathComponent
            if name.hasPrefix("com.apple.") || name.hasPrefix(".GlobalPreferences") { return false }
            if protectLoginWindow, name == "loginwindow.plist" { return false }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return false
            }
            return !matchesWhitelist(url.path, entries: whitelist)
        }

        var candidates = directChildren(of: preferences).filter { isCandidate($0, protectLoginWindow: true) }
        let byHost = preferences.appendingPathComponent("ByHost", isDirectory: true)
        if isDirectory(byHost),
           let enumerator = fileManager.enumerator(at: byHost,
                                                   includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                   options: [.skipsPackageDescendants]) {
            for case let url as URL in enumerator where isCandidate(url, protectLoginWindow: false) {
                candidates.append(url)
            }
        }

        let batchSize = 256
        var start = 0
        while start < candidates.count {
            guard Date() < deadline else { result.partial = true; break }
            let end = min(start + batchSize, candidates.count)
            let batch = Array(candidates[start..<end])
            start = end
            // One lint per batch; only a failing batch is re-checked file by file.
            if runCommand("/usr/bin/plutil", ["-lint", "-s"] + batch.map(\.path)) { continue }
            for url in batch {
                guard Date() < deadline else { result.partial = true; break }
                guard fileManager.isReadableFile(atPath: url.path),
                      !runCommand("/usr/bin/plutil", ["-lint", "-s", url.path]) else { continue }
                result.corrupt.append(url.path)
                if dryRun { continue }
                do {
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                    result.repaired += 1
                } catch {
                    result.failed += 1
                }
            }
        }
        return result
    }

    struct BrokenLaunchAgent: Sendable {
        let plist: String
        let program: String
    }

    /// Mole's `opt_launch_agents_cleanup` contract: a user launch agent is
    /// broken when its `Program` / `ProgramArguments[0]` is an absolute path
    /// missing from a mounted volume. The optimizer only reports them; the
    /// plist may belong to an updater that restores its helper later.
    func brokenLaunchAgents(homeDirectory: String) -> (scanned: Int, broken: [BrokenLaunchAgent]) {
        let agents = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        guard isDirectory(agents) else { return (0, []) }
        var scanned = 0
        var broken: [BrokenLaunchAgent] = []
        for plist in directChildren(of: agents).sorted(by: { $0.path < $1.path }) {
            guard plist.pathExtension == "plist", !isSymlink(plist),
                  (try? plist.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            scanned += 1
            guard let program = launchAgentProgram(plist), program.hasPrefix("/"),
                  !fileManager.fileExists(atPath: program),
                  launchAgentVolumeIsMounted(program) else { continue }
            broken.append(.init(plist: plist.path, program: program))
        }
        return (scanned, broken)
    }

    /// Trash sink for optimizer-owned file targets (old saved states, corrupt
    /// shared file lists). Each target must still sit directly under its
    /// expected parent, be a physical entry, and keep its planned identity.
    func trashOptimizeTargets(_ targets: [(path: String, identity: String)],
                              parent: String) -> (removed: Int, failed: Int) {
        var removed = 0
        var failed = 0
        let parentPath = URL(fileURLWithPath: parent).standardizedFileURL.path
        for target in targets {
            let url = URL(fileURLWithPath: target.path).standardizedFileURL
            guard url.path.hasPrefix(parentPath + "/"), !isSymlink(url),
                  DeletionPlan.identity(at: url.path) == target.identity else {
                failed += 1
                continue
            }
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                removed += 1
            } catch {
                failed += 1
            }
        }
        return (removed, failed)
    }

    func launchAgentProgram(_ plist: URL) -> String? {
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else { return nil }
        if let arguments = dictionary["ProgramArguments"] as? [String],
           let first = arguments.first, !first.isEmpty {
            return first
        }
        if let program = dictionary["Program"] as? String, !program.isEmpty { return program }
        return nil
    }

    /// An agent whose program lives on an unmounted external volume is not
    /// broken, only offline; skip it like Mole does.
    func launchAgentVolumeIsMounted(_ path: String) -> Bool {
        guard path.hasPrefix("/Volumes/") else { return true }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return true }
        return fileManager.fileExists(atPath: "/Volumes/" + components[1])
    }

    /// Native port of Mole's `clear_quarantine_events`: empty the
    /// `LSQuarantineEvent` table so LaunchServices stops tracking every
    /// download ever opened. Files and their quarantine xattrs are untouched,
    /// so Gatekeeper behaviour does not change.
    func clearQuarantineEvents(homeDirectory: String) -> (state: OptimizeTask.State, message: String) {
        let database = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")
        guard fileManager.fileExists(atPath: database.path) else {
            return (.unchanged, "No quarantine database found.")
        }
        guard !matchesWhitelist(database.path, entries: loadWhitelist(homeDirectory: homeDirectory)) else {
            return (.unchanged, "Skipped by whitelist.")
        }
        let sqlite = "/usr/bin/sqlite3"
        guard fileManager.isExecutableFile(atPath: sqlite) else {
            return (.unavailable, "sqlite3 is unavailable on this macOS version.")
        }
        guard let raw = runCommandOutput(sqlite, [database.path, "SELECT COUNT(*) FROM LSQuarantineEvent;"]),
              let count = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return (.failed, "Could not read the quarantine database.")
        }
        guard count > 0 else { return (.unchanged, "Quarantine history is already empty.") }
        guard runCommand(sqlite, [database.path, "DELETE FROM LSQuarantineEvent; VACUUM;"]) else {
            return (.failed, "Could not clear the quarantine database.")
        }
        return (.applied, "Cleared \(count) quarantine event record(s).")
    }

    // MARK: Filesystem helpers

    func directChildren(of directory: URL) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.map { directory.appendingPathComponent($0) }
    }

    func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func directorySize(_ url: URL) -> UInt64 {
        measureTree(url).bytes
    }

    func fileSize(_ url: URL) -> UInt64 {
        guard let values = try? url.resourceValues(forKeys: sizeKeys) else { return 0 }
        return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isAllowedCleanupPath(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(home.path + "/"), path != home.path else { return false }
        return !isProtectedCleanupItem(url)
    }

    private func isProtectedCleanupItem(_ url: URL,
                                        allowApplicationBundle: Bool = false) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if isProtectedCleanupName(name) { return true }
        let extensionName = url.pathExtension.lowercased()
        if extensionName == "app" && allowApplicationBundle { return false }
        return ["app", "db", "sqlite", "sqlite3", "realm"].contains(extensionName)
    }

    private func isProtectedCleanupName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["credentials", "credential", "sessions", "session", "databases", "database",
                "models", "model", "auth.json", "history.jsonl"].contains(lower)
    }

    /// Read `~/.config/mole/whitelist` with the same grammar Mole's
    /// `load_mole_whitelist` accepts: `~`, `$HOME` and `${HOME}` prefixes,
    /// shell globs (`*`, `?`, `[...]`), comments, and no `..` traversal. A file
    /// written by `mo clean --whitelist` therefore protects the native route
    /// exactly like it protects the CLI and the bridge scripts.
    func loadWhitelist(homeDirectory: String) -> [String] {
        let home = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        let url = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".config/mole/whitelist")
        var entries: [String] = []
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            // An existing file replaces the convenience defaults, even when it
            // is empty; that is Mole's replacement semantics since 1.7.5.
            for raw in content.split(whereSeparator: { $0.isNewline }) {
                var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !value.hasPrefix("#") else { continue }
                if value.hasPrefix("~") { value = home + value.dropFirst() }
                value = value.replacingOccurrences(of: "${HOME}", with: home)
                    .replacingOccurrences(of: "$HOME", with: home)
                guard value.hasPrefix("/"), !value.contains(".."),
                      value.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
                while value.contains("//") { value = value.replacingOccurrences(of: "//", with: "/") }
                if value.count > 1, value.hasSuffix("/") { value.removeLast() }
                if !entries.contains(value) { entries.append(value) }
            }
        } else {
            entries = Self.defaultWhitelistPatterns(home: home)
        }
        // Hard safety entries merge unconditionally, exactly like Mole's
        // ensure_safety_whitelist_patterns.
        for safety in Self.safetyWhitelistPatterns(home: home) where !entries.contains(safety) {
            entries.append(safety)
        }
        return entries
    }

    /// Mole's DEFAULT_WHITELIST_PATTERNS (lib/core/base.sh): convenience
    /// protections that apply only while the user has no whitelist file.
    /// Playwright browsers and JetBrains indexes are slow to rebuild, Ollama
    /// models and iCloud Drive are user data, Surge holds licences.
    static func defaultWhitelistPatterns(home: String) -> [String] {
        [
            home + "/Library/Caches/ms-playwright*",
            home + "/.gradle/caches/*",
            home + "/.gradle/daemon/*",
            home + "/.ollama/models/*",
            home + "/Library/Caches/com.nssurge.surge-mac/*",
            home + "/Library/Application Support/com.nssurge.surge-mac/*",
            home + "/Library/Caches/org.R-project.R/R/renv/*",
            home + "/Library/Caches/JetBrains*",
            home + "/Library/Caches/com.jetbrains.toolbox*",
            home + "/Library/Caches/tealdeer/tldr-pages",
            home + "/Library/Application Support/JetBrains*",
            home + "/Library/Caches/com.apple.finder",
            home + "/Library/Mobile Documents*"
        ]
    }

    /// Mole's SAFETY_WHITELIST_PATTERNS: removing these breaks macOS search,
    /// font rendering or iCloud sync rather than costing a rebuild, and
    /// pypoetry/virtualenvs holds live interpreters, not downloads.
    static func safetyWhitelistPatterns(home: String) -> [String] {
        [
            home + "/Library/Caches/com.apple.FontRegistry*",
            home + "/Library/Caches/com.apple.spotlight*",
            home + "/Library/Caches/com.apple.Spotlight*",
            home + "/Library/Caches/CloudKit*",
            home + "/Library/Caches/pypoetry/virtualenvs*"
        ]
    }

    private static func whitelistEntryHasGlob(_ entry: String) -> Bool {
        entry.contains { $0 == "*" || $0 == "?" || $0 == "[" }
    }

    /// Mirror of Mole's `is_path_whitelisted`: exact or glob match, a target
    /// that is an ancestor of a whitelisted path (so the protected child is
    /// never removed with its parent), and descendants of a literal entry.
    func matchesWhitelist(_ path: String, entries: [String]) -> Bool {
        var target = path
        while target.contains("//") { target = target.replacingOccurrences(of: "//", with: "/") }
        if target.count > 1, target.hasSuffix("/") { target.removeLast() }
        for entry in entries {
            if target == entry { return true }
            let hasGlob = Self.whitelistEntryHasGlob(entry)
            // Bash `[[ $path == $pattern ]]` lets `*` span `/`, so fnmatch runs
            // without FNM_PATHNAME to keep the two implementations aligned.
            if hasGlob, fnmatch(entry, target, 0) == 0 { return true }
            if entry.hasPrefix(target + "/") { return true }
            if !hasGlob, target.hasPrefix(entry + "/") { return true }
        }
        return false
    }

    private func isOwnedByRunningApplication(path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleURL = application.bundleURL?.standardizedFileURL.path,
                  let identifier = application.bundleIdentifier,
                  !identifier.isEmpty else { continue }
            let cachePath = NSHomeDirectory() + "/Library/Caches/" + identifier
            let logPath = NSHomeDirectory() + "/Library/Logs/" + identifier
            if normalized == bundleURL || normalized.hasPrefix(bundleURL + "/") ||
                normalized == cachePath || normalized.hasPrefix(cachePath + "/") ||
                normalized == logPath || normalized.hasPrefix(logPath + "/") { return true }
        }
        return false
    }

    /// Capture one user-scoped open-file snapshot for the whole deletion plan.
    /// A missing/failed probe is treated as unknown and causes the caller to
    /// skip the item rather than guessing that no process owns it.
    private func openFileSnapshot() -> Set<String>? {
        let executable = "/usr/sbin/lsof"
        guard fileManager.isExecutableFile(atPath: executable) else { return nil }
        guard let text = SystemMetrics.commandOutput(executable,
            arguments: ["-O", "-nP", "-F", "n", "-a", "-u", NSUserName()]) else { return nil }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.first == "n" else { return nil }
            let path = String(line.dropFirst())
            return path.isEmpty ? nil : URL(fileURLWithPath: path).standardizedFileURL.path
        })
    }

    private func applicationMetadata(at url: URL) -> (name: String, bundleID: String)? {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (name, bundleID)
    }

    // MARK: Native analysis implementation

    /// Measure a tree once with hard-link de-duplication and a bounded budget.
    /// This mirrors the useful part of Mole's scanner without invoking `du`,
    /// `mdfind`, or a shell process.  A timeout returns the partial result and
    /// marks it as truncated; callers still get a stable report instead of a
    /// zero-sized failure.
    private func measureTree(_ root: URL,
                             excludingDirectNames: Set<String> = []) -> TreeMeasure {
        guard fileManager.fileExists(atPath: root.path), !isSymlink(root) else { return TreeMeasure() }
        if !isDirectory(root) {
            let bytes = fileSize(root)
            return TreeMeasure(bytes: bytes, files: bytes > 0 ? 1 : 0,
                               largeFiles: bytes >= largeFileThreshold
                                   ? [.init(name: root.lastPathComponent, path: root.path, size: bytes)] : [],
                               truncated: false)
        }
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: Array(sizeKeys), options: []) else {
            return TreeMeasure()
        }
        var result = TreeMeasure()
        var visited = 0
        let deadline = Date().addingTimeInterval(maxTraversalSeconds)
        var seen = Set<FileIdentity>()
        let rootDepth = root.pathComponents.count
        for case let child as URL in enumerator {
            visited += 1
            if visited > maxTraversalEntries || Date() >= deadline {
                result.truncated = true
                break
            }
            if isSymlink(child) {
                enumerator.skipDescendants()
                continue
            }
            let depth = child.pathComponents.count - rootDepth
            if depth == 1 && excludingDirectNames.contains(child.lastPathComponent) {
                if isDirectory(child) { enumerator.skipDescendants() }
                continue
            }
            if isDirectory(child) { continue }
            guard let identity = fileIdentity(child), seen.insert(identity).inserted else { continue }
            let bytes = fileSize(child)
            result.bytes &+= bytes
            if bytes > 0 { result.files += 1 }
            if bytes >= largeFileThreshold {
                result.largeFiles.append(.init(name: child.lastPathComponent,
                                               path: child.path, size: bytes))
            }
        }
        result.largeFiles.sort {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        if result.largeFiles.count > 100 { result.largeFiles.removeLast(result.largeFiles.count - 100) }
        return result
    }

    private func fileIdentity(_ url: URL) -> FileIdentity? {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else { return nil }
        return FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    func runCommand(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func runCommandOutput(_ executable: String, _ arguments: [String]) -> String? {
        guard fileManager.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain stdout before waiting: a child that fills the 64 KB pipe
        // buffer (e.g. `brew list` with many casks) would otherwise block
        // forever while we block on waitUntilExit.
        let data = try? pipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    func isOptimizeWhitelisted(_ task: OptimizeTask, homeDirectory: String) -> Bool {
        let url = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".config/mole/whitelist")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let candidates = [task.id, task.title, task.detail].map { $0.lowercased() }
        return content.split(whereSeparator: { $0.isNewline }).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return false }
            let value = line.lowercased()
            return candidates.contains { $0 == value }
        }
    }
}
