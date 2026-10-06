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
    private var lastPhase = ""
    private var lastPath = ""
    private var lastCompleted = -1
    private var reportedChild = false

    init(handler: @escaping (CleanupScanProgressEvent) -> Void) {
        self.handler = handler
    }

    func send(_ event: CleanupScanProgressEvent) {
        // Directory roots can contain thousands of children. Coalesce updates
        // here, before creating a MainActor task, while always forwarding the
        // final item so the bar can reach its terminal state. The first child
        // reported under the current unit's root is also forwarded, so a fast
        // root still shows what it was working on.
        let now = Date()
        lock.lock()
        let sameUnit = event.phase == lastPhase && event.completed == lastCompleted
        let firstChild = sameUnit && !reportedChild && !lastPath.isEmpty
            && event.currentPath.hasPrefix(lastPath + "/")
        let shouldSend = event.phase != lastPhase
            || (event.total > 0 && event.completed == event.total)
            || firstChild
            || now.timeIntervalSince(lastSentAt) >= 0.15
        if shouldSend {
            lastSentAt = now
            lastPhase = event.phase
            if sameUnit {
                reportedChild = reportedChild || firstChild
            } else {
                reportedChild = false
                lastCompleted = event.completed
            }
            if !firstChild { lastPath = event.currentPath }
        }
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

    /// Atime can change during our own header read or directory enumeration.
    /// Keep that observation only in this worker, bound to the exact object;
    /// it is never persisted or accepted from an administrator request.
    private struct CleanupInspection {
        let original: stat
        var observed: stat
        let firstObservedAt: ContinuousClock.Instant
    }
    private struct CleanupInspectionStart {
        let evidence: CleanupInspection
        let before: stat
        let startedAt: timespec
        let hadPrevious: Bool
    }
    private let cleanupInspectionLock = NSLock()
    private let cleanupInspectionClock = ContinuousClock()
    private var cleanupInspections: [String: CleanupInspection] = [:]
    private var lastCleanupInspectionSweep: ContinuousClock.Instant?
    private static let cleanupInspectionLifetime: TimeInterval = 300

    struct CleanupScan: Sendable {
        let categories: [CleanupCategory]
        let succeeded: Bool
        let error: String?
        var deferredPaths: [String] = []
        var diagnostics: String = ""
        var administratorRequiredPaths: Set<String> = []
        /// Fully checked roots can be carried into a deep continuation without
        /// traversing them again. Partial roots never enter this set.
        var completedRoots: Set<String> = []
    }

    struct ApplySummary: Sendable {
        let removed: Int
        let skipped: Int
        let failed: Int
        let messages: [String]
        var removedPaths: Set<String> = []
        var remainingPaths: [String] = []
        var retainedPaths: [String] = []
        /// Allocated bytes belonging to confirmed permanent removals only.
        var reclaimedBytes: UInt64 = 0

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

            enum SummaryArgument: Equatable, Sendable {
                case text(String)
                case integer(Int)

                fileprivate var formatValue: CVarArg {
                    switch self {
                    case .text(let value): return value
                    case .integer(let value): return value
                    }
                }
            }

            let need: Need
            private let originalSummary: String
            private let summaryKey: String?
            private let summaryArguments: [SummaryArgument]
            var summary: String {
                guard let summaryKey else { return originalSummary }
                return String(format: L10n.shared.t(summaryKey), locale: Locale.current,
                              arguments: summaryArguments.map(\.formatValue))
            }
            var items: [String] = []
            /// 执行时唯一允许作用的证据（`identity<TAB>path`、bundle ID、偏好键等）。
            var plan: [String] = []
            /// 涉及的数据库/文件当前占用；0 表示该项与空间无关。
            var bytes: UInt64 = 0

            init(need: Need, summary: String = "", summaryKey: String? = nil,
                 summaryArguments: [SummaryArgument] = [], items: [String] = [], plan: [String] = [],
                 bytes: UInt64 = 0) {
                self.need = need
                originalSummary = summary
                self.summaryKey = summaryKey
                self.summaryArguments = summaryArguments
                self.items = items
                self.plan = plan
                self.bytes = bytes
            }
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
    private let cleanupOpenFileProbe: (() -> Set<String>?)?
    private let cleanupOpenFileRecordsProbe: (() -> [OpenFileRecord]?)?

    struct OpenFileRecord {
        let pid: Int32
        let process: String
        let descriptor: String
        let access: String
        let path: String

        /// Moving a stopped app to Trash does not invalidate an observer's
        /// read-only metadata descriptor. Executables, mappings, cwd and all
        /// writable/unknown handles still block removal.
        var isReadOnlyBundleMetadata: Bool {
            guard pid > 0, !process.isEmpty, access == "r", !descriptor.isEmpty,
                  descriptor.allSatisfy(\.isNumber) else { return false }
            if path.hasSuffix(".app/Contents/Info.plist") { return true }
            return path.contains(".app/Contents/Resources/") && path.hasSuffix(".icns")
        }

        /// 系统代理（UserEventAgent、Spotlight、LaunchServices 等）常年持有 App 包目录
        /// 的只读目录句柄用于监听；把包整体移到废纸篓不会使这种句柄失效。
        static let bundleObserverProcesses: Set<String> = [
            "UserEventAgent", "mds", "mds_stores", "mdworker", "mdworker_shared", "lsd",
            "fseventsd", "Spotlight", "coreservicesd", "launchservicesd", "appstoreagent",
            "com.apple.appkit.xpc.openAndSavePanelService", "QuickLookUIService"
        ]

        func isObserverDirectoryHandle(onBundle bundle: String) -> Bool {
            pid > 0 && access == "r" && !descriptor.isEmpty && descriptor.allSatisfy(\.isNumber)
                && path == bundle && Self.bundleObserverProcesses.contains(process)
        }
    }

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

    /// The optional probe keeps fixture tests deterministic; production uses
    /// the user-scoped lsof snapshot, and an unavailable probe always refuses.
    init(cleanupOpenFileProbe: (() -> Set<String>?)? = nil,
         cleanupOpenFileRecordsProbe: (() -> [OpenFileRecord]?)? = nil) {
        self.cleanupOpenFileProbe = cleanupOpenFileProbe
        self.cleanupOpenFileRecordsProbe = cleanupOpenFileRecordsProbe
    }

    // MARK: Cleanup

    func scanCleanup(homeDirectory: String = NSHomeDirectory(),
                     progress: CleanupScanProgressSink? = nil,
                     mode: CleanupScanMode = .quick,
                     control: CleanupScanControl? = nil,
                     agentPresence: AgentPresenceContext? = nil,
                     includingAdministratorRequired: Bool = false,
                     excludingScannedRoots: Set<String> = []) async -> CleanupScan {
        let control = control ?? CleanupScanControl(mode: mode)
        return await Task.detached(priority: .utility) { [self] in
            let home = URL(fileURLWithPath: CleanupRiskPolicy.normalizedPathLiteral(homeDirectory), isDirectory: true)
            guard self.fileManager.fileExists(atPath: home.path) else {
                return CleanupScan(categories: [], succeeded: false,
                                   error: "Home directory is unavailable.")
            }

            progress?.send(.init(phase: "discovery", completed: 0, total: 0, currentPath: home.path))
            let orphanNames = self.cleanupOrphanNames(home: home, mode: mode, control: control)
            let roots = self.cleanupRoots(home: home, mode: mode, control: control,
                                          orphanNames: orphanNames)
            let whitelist = self.loadWhitelist(homeDirectory: homeDirectory)
            let broadRoots = Set(["Library/Caches", "Library/Logs", "Library/DiagnosticReports",
                                  ".cache", ".Trash"].map { home.appendingPathComponent($0).path })
            var candidates: [CleanupScanCandidate] = []
            var seen = Set<String>()
            // 自定义日志/SQLite/XDG 路径同样归 Agent 专清；普通缓存父目录
            // 不能隐式包住它们并以通用 Safe 规则删除。
            let agentDataRoots = AgentCatalog.definitions.flatMap {
                AgentCatalog.dataRoots(for: $0, home: home.path)
            }.filter { AgentCatalog.isPhysical($0, home: home.path) }
            let agentRetainedPaths = AgentCatalog.definitions.flatMap { agent in
                agent.targets.filter { $0.tier != .safe }.flatMap { AgentCatalog.targetPaths($0, home: home.path) }
            }
            func overlaps(_ path: String, _ roots: [String]) -> Bool {
                roots.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
            }
            // Uninstalled Agent data can contain history and credentials.
            // Its explicit review flow must never enter the junk inventory.
            for (root, label, _, _, retention) in roots {
                guard !control.shouldStop else { break }
                progress?.send(.init(phase: "discovery", completed: 0, total: 0, currentPath: root.path))
                guard self.cleanupPathIsPhysical(root, home: home) else { continue }
                let entries = broadRoots.contains(root.path) ? self.directChildren(of: root) : [root]
                for entry in entries {
                    let path = CleanupRiskPolicy.normalizedPathLiteral(entry.path)
                    // AI Agent 的缓存、版本与会话只在 Agent 专清页呈现。
                    guard self.isAllowedCleanupPath(entry, home: home),
                          self.cleanupPathIsPhysical(entry, home: home),
                          !CleanupRiskPolicy.isAgentOwnedPath(path, homeDirectory: home.path),
                          (CleanupRiskPolicy.auditedRebuildableRoot(containing: path, homeDirectory: home.path) != nil
                            || (CleanupRiskPolicy.isCoveredByGlobalCleanup(path, homeDirectory: home.path)
                                && !overlaps(path, agentRetainedPaths))
                            || !overlaps(path, agentDataRoots)),
                          !self.directlyMatchesWhitelist(path, entries: whitelist),
                          !Self.isCoveredByScannedRoot(path, roots: excludingScannedRoots) else { continue }
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
                                if let browser = Self.browserDisplayNames.first(where: { label.hasPrefix($0 + " ") }) {
                                    name = browser
                                } else if Self.namedSupportLabels.contains(label) {
                                    name = label
                                } else {
                                    name = String(path.dropFirst(supportPrefix.count).split(separator: "/").first ?? "")
                                }
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
            progress?.send(.init(phase: "occupancy", completed: 0, total: 0, currentPath: home.path))
            guard let openFiles = self.currentCleanupOpenFiles() else {
                return CleanupScan(categories: [], succeeded: false,
                    error: "Open-file safety state is unavailable.")
            }
            var eligibleCandidates: [CleanupScanCandidate] = []
            var measurements: [CleanupScanWorker.Measurement] = []
            var deferred: [String] = []
            var administratorPaths = Set<String>()
            var completedRoots = Set<String>()
            let discoverySeconds = control.elapsed
            // Keep I/O bounded while independent roots undergo the same secure
            // checks. Each tree retains its own quick-scan deadline.
            let queueLock = NSLock()
            var next = 0
            var completed = 0
            var checkedRoots = candidates.map { CleanupPreflightResult(deferredPaths: [$0.path]) }
            progress?.send(.init(phase: "native", completed: 0, total: candidates.count,
                                 currentPath: candidates.first?.path ?? home.path))
            DispatchQueue.concurrentPerform(iterations: min(4, candidates.count)) { _ in
                while true {
                    queueLock.lock()
                    guard next < candidates.count, !control.shouldStop else { queueLock.unlock(); break }
                    let index = next
                    next += 1
                    let before = completed
                    queueLock.unlock()
                    let candidate = candidates[index]
                    let rebuildable = CleanupRiskPolicy.core(section: "Cache", path: candidate.path,
                                                            homeDirectory: home.path)
                    let checked = self.preflightCleanupPath(candidate.path, homeDirectory: home.path,
                        openFiles: openFiles, whitelist: whitelist,
                        excludingScannedRoots: excludingScannedRoots, control: control,
                        includingAdministratorRequired: includingAdministratorRequired
                            && (rebuildable.risk == .safe && rebuildable.disposal == .permanentDelete
                                || CleanupRiskPolicy.trashEntryRoot(containing: candidate.path,
                                                                    homeDirectory: home.path) != nil),
                        onVisit: { path in
                            progress?.send(.init(phase: "native", completed: before,
                                total: candidates.count, currentPath: path))
                        })
                    queueLock.lock()
                    checkedRoots[index] = checked
                    completed += 1
                    let after = completed
                    queueLock.unlock()
                    progress?.send(.init(phase: "native", completed: after,
                        total: candidates.count, currentPath: candidate.path))
                }
            }
            for (index, candidate) in candidates.enumerated() {
                let checked = checkedRoots[index]
                if checked.deferredPaths.isEmpty, !control.isCancelled {
                    completedRoots.insert(candidate.path)
                } else if !checked.deferredPaths.isEmpty {
                    deferred.append(candidate.path)
                }
                for entry in checked.entries {
                    var split = candidate
                    split.path = entry.path
                    eligibleCandidates.append(split)
                    measurements.append(entry.measurement)
                    if entry.requiresAdministrator { administratorPaths.insert(entry.path) }
                }
            }
            candidates = eligibleCandidates
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
            var categories = groups.values.map { indices -> CleanupCategory in
                let first = candidates[indices[0]]
                let sizes = Dictionary(uniqueKeysWithValues: indices.map {
                    (candidates[$0].path, measurements[$0].bytes)
                })
                var category = CleanupCategory(name: first.name, paths: indices.map { candidates[$0].path },
                    bytes: sizes.values.reduce(0, &+), pathBytes: sizes,
                    selected: first.policy.risk == .safe
                        && !CleanupCategory.reviewOnlyReasonKeys.contains(first.policy.reasonKey),
                    source: first.policy.source, risk: first.policy.risk,
                    disposal: first.policy.disposal, applyRoute: first.policy.applyRoute,
                    activityGuard: first.policy.activityGuard, retention: first.retention,
                    reasonKey: first.policy.reasonKey)
                category.activityOwners = Array(Set(indices.flatMap { candidates[$0].activityOwners })).sorted()
                // 7 天活跃门按“可独立清理的单元”逐条生效：活跃条目保留在
                // 页面上但默认不勾选；证据缺失（时间为空/未来）同样不推荐。
                if first.retention > 0 {
                    var stalePaths = Set<String>()
                    var hasActive = false
                    for index in indices {
                        let stale = CleanupAgePolicy.isStale(
                            measurements[index].activityEvidence,
                            now: scanNow, retention: first.retention)
                        if stale {
                            stalePaths.insert(candidates[index].path)
                        } else {
                            hasActive = true
                        }
                    }
                    category = category.selectingPaths(category.selectedPaths.intersection(stalePaths))
                    if hasActive {
                        category.reasonKey = "cleanup.risk.recentlyActive"
                    }
                }
                return category
            }
            // Discovery itself may exhaust the deadline. Do not cache such a
            // snapshot as complete, even if every admitted candidate was sized.
            if discoverySeconds >= control.totalBudget { deferred.append(home.path) }
            let ageGated = candidates.filter { $0.retention > 0 }.count
            if !control.isCancelled, deferred.isEmpty {
                categories += self.appDataReviewCategories(home: home, offered: categories.flatMap(\.paths),
                                                           whitelist: whitelist)
            }
            return CleanupScan(categories: categories.sorted(by: CleanupCategory.sizeDescending),
                succeeded: !control.isCancelled,
                error: control.isCancelled ? "Scan cancelled." : nil,
                deferredPaths: deferred,
                diagnostics: String(format: "cleanup[%@] discovery=%.2fs sizing=%.2fs paths=%d deferred=%d files=%d ageGated=%d",
                    mode.rawValue, discoverySeconds, control.elapsed - discoverySeconds,
                    candidates.count, deferred.count,
                    measurements.reduce(0) { $0 + $1.files }, ageGated),
                administratorRequiredPaths: administratorPaths,
                completedRoots: completedRoots)
        }.value
    }

    struct InstalledApplications {
        let bundleIDs: Set<String>
        let names: Set<String>
        let bundleIDsByName: [String: Set<String>]

        func owns(_ token: String) -> Bool {
            let lower = token.lowercased()
            if names.contains(lower) || bundleIDs.contains(lower) { return true }
            return bundleIDs.contains { lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }
        }

        func sharesVendor(_ token: String) -> Bool {
            let parts = token.lowercased().split(separator: ".")
            guard parts.count >= 3 else { return false }
            let vendor = parts.prefix(2).joined(separator: ".") + "."
            return bundleIDs.contains { $0.hasPrefix(vendor) }
        }

        func owners(for token: String) -> [String] {
            ([token] + (bundleIDsByName[token.lowercased()] ?? [])).sorted()
        }
    }

    func installedApplications(home: URL) -> InstalledApplications {
        var ids = Set<String>(), names = Set<String>(), byName: [String: Set<String>] = [:]
        for (root, _) in applicationRoots(home: home) {
            for item in directChildren(of: root) where item.pathExtension.lowercased() == "app" && !isSymlink(item) {
                let filename = item.deletingPathExtension().lastPathComponent.lowercased()
                names.insert(filename)
                if let metadata = applicationMetadata(at: item) {
                    ids.insert(metadata.bundleID.lowercased())
                    names.insert(metadata.name.lowercased())
                    byName[filename, default: []].insert(metadata.bundleID)
                    byName[metadata.name.lowercased(), default: []].insert(metadata.bundleID)
                }
            }
        }
        return InstalledApplications(bundleIDs: ids, names: names, bundleIDsByName: byName)
    }

    static func isOrphanedAppToken(_ token: String, installed: InstalledApplications) -> Bool {
        CleanupRiskPolicy.isValidReverseDNSOwner(token) && !installed.owns(token) && !installed.sharesVendor(token)
            && NSWorkspace.shared.urlForApplication(withBundleIdentifier: token) == nil
            && !NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier?.lowercased() == token.lowercased()
            }
    }

    static func appDataOwnerToken(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent
        for suffix in [".plist", ".savedState"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        if name.hasPrefix("group.") { name = String(name.dropFirst("group.".count)) }
        if let range = name.range(of: #"^[A-Z0-9]{10}\."#, options: .regularExpression) {
            name = String(name[range.upperBound...])
        }
        return name
    }

    func appDataReviewCategories(home: URL, offered: [String], whitelist: [String]) -> [CleanupCategory] {
        let installed = installedApplications(home: home)
        let control = CleanupScanControl(mode: .deep, totalBudget: 25, directoryBudget: 10)
        let agentRoots = AgentCatalog.definitions.flatMap { AgentCatalog.dataRoots(for: $0, home: home.path) }
        func overlaps(_ path: String, _ others: [String]) -> Bool {
            others.contains { path == $0 || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }
        }
        func overlapsOffered(_ path: String) -> Bool { overlaps(path, offered) }
        func admissible(_ url: URL) -> Bool {
            let path = CleanupRiskPolicy.normalizedPathLiteral(url.path)
            return CleanupRiskPolicy.isAppDataRoot(path, homeDirectory: home.path) && !isSymlink(url)
                && cleanupPathIsPhysical(url, home: home)
                && !CleanupRiskPolicy.isAgentOwnedPath(path, homeDirectory: home.path)
                && !overlaps(path, agentRoots)
                && !directlyMatchesWhitelist(path, entries: whitelist)
        }
        let roots = ["Library/Application Support", "Library/Containers", "Library/Group Containers",
                     "Library/HTTPStorages", "Library/WebKit", "Library/Saved Application State",
                     "Library/Preferences"].map { home.appendingPathComponent($0, isDirectory: true) }
        var leftovers: [String: [(String, UInt64)]] = [:]
        var leftoverNames: [String: String] = [:]
        var large: [(path: String, bytes: UInt64, owner: String)] = []
        for root in roots {
            for child in directChildren(of: root) where admissible(child) && !control.shouldStop {
                let path = CleanupRiskPolicy.normalizedPathLiteral(child.path)
                let token = Self.appDataOwnerToken(path)
                let reverseDNS = CleanupRiskPolicy.isValidReverseDNSOwner(token)
                let orphaned = reverseDNS && Self.isOrphanedAppToken(token, installed: installed)
                if overlapsOffered(path) && !orphaned {
                    guard root.lastPathComponent == "Application Support", isDirectory(child) else { continue }
                    for nested in directChildren(of: child) where admissible(nested) && !control.shouldStop {
                        let nestedPath = CleanupRiskPolicy.normalizedPathLiteral(nested.path)
                        guard !overlapsOffered(nestedPath) else { continue }
                        let measurement = CleanupScanWorker.measure(nestedPath, control: control)
                        guard measurement.bytes >= CleanupRiskPolicy.appDataReviewThreshold else { continue }
                        large.append((nestedPath, measurement.bytes, token))
                    }
                    continue
                }
                if orphaned {
                    let measurement = CleanupScanWorker.measure(path, control: control)
                    leftovers[token.lowercased(), default: []].append((path, measurement.bytes))
                    leftoverNames[token.lowercased()] = token
                    continue
                }
                guard root.lastPathComponent == "Application Support" || root.lastPathComponent == "Containers"
                else { continue }
                let measurement = CleanupScanWorker.measure(path, control: control)
                guard measurement.bytes >= CleanupRiskPolicy.appDataReviewThreshold else { continue }
                large.append((path, measurement.bytes, token))
            }
        }
        var result: [CleanupCategory] = []
        var orphanedSettings: [(String, UInt64)] = []
        var orphanedSettingOwners: [String] = []
        for (key, entries) in leftovers {
            let bytes = entries.reduce(UInt64(0)) { $0 &+ $1.1 }
            guard bytes >= CleanupRiskPolicy.appDataLeftoverThreshold else {
                orphanedSettings += entries.filter { $0.1 > 0 }
                orphanedSettingOwners.append(leftoverNames[key] ?? key)
                continue
            }
            let descriptor = CleanupRiskPolicy.appDataReview(leftover: true)
            var category = CleanupCategory(name: (leftoverNames[key] ?? key) + " leftovers",
                paths: entries.map(\.0), bytes: bytes,
                pathBytes: Dictionary(entries.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first }),
                selected: false, source: descriptor.source, risk: descriptor.risk,
                disposal: descriptor.disposal, applyRoute: descriptor.applyRoute,
                activityGuard: descriptor.activityGuard, reasonKey: descriptor.reasonKey)
            category.activityOwners = [leftoverNames[key] ?? key]
            result.append(category)
        }
        for entry in large {
            let descriptor = CleanupRiskPolicy.appDataReview(leftover: false)
            let leaf = (entry.path as NSString).lastPathComponent
            let name = Self.appDataOwnerToken(entry.path) == entry.owner ? entry.owner : entry.owner + " · " + leaf
            var category = CleanupCategory(name: name, paths: [entry.path], bytes: entry.bytes,
                selected: false, source: descriptor.source, risk: descriptor.risk,
                disposal: descriptor.disposal, applyRoute: descriptor.applyRoute,
                activityGuard: descriptor.activityGuard, reasonKey: descriptor.reasonKey)
            category.activityOwners = installed.owners(for: entry.owner)
            result.append(category)
        }
        func reviewCategory(_ name: String, _ kind: CleanupRiskPolicy.ReviewTargetKind,
                            _ entries: [(String, UInt64)], owners: [String] = []) -> CleanupCategory {
            let descriptor = CleanupRiskPolicy.reviewDescriptor(kind)
            var category = CleanupCategory(name: name, paths: entries.map(\.0),
                bytes: entries.reduce(UInt64(0)) { $0 &+ $1.1 },
                pathBytes: Dictionary(entries.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first }),
                selected: false, source: descriptor.source, risk: descriptor.risk,
                disposal: descriptor.disposal, applyRoute: descriptor.applyRoute,
                activityGuard: descriptor.activityGuard, reasonKey: descriptor.reasonKey)
            category.activityOwners = owners
            return category
        }
        if !orphanedSettings.isEmpty {
            let descriptor = CleanupRiskPolicy.appDataReview(leftover: true)
            var category = CleanupCategory(name: "Orphaned Settings", paths: orphanedSettings.map(\.0),
                bytes: orphanedSettings.reduce(UInt64(0)) { $0 &+ $1.1 },
                pathBytes: Dictionary(orphanedSettings.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first }),
                selected: false, source: descriptor.source, risk: descriptor.risk,
                disposal: descriptor.disposal, applyRoute: descriptor.applyRoute,
                activityGuard: descriptor.activityGuard, reasonKey: descriptor.reasonKey)
            category.activityOwners = orphanedSettingOwners.sorted()
            result.append(category)
        }
        let brokenAgents = brokenLaunchAgents(homeDirectory: home.path).broken
            .map(\.plist).filter { !overlapsOffered($0) && !directlyMatchesWhitelist($0, entries: whitelist) }
        if !brokenAgents.isEmpty {
            result.append(reviewCategory("Broken Login Agents", .brokenLaunchAgent, brokenAgents.map { path in
                var metadata = stat()
                return (path, lstat(path, &metadata) == 0 ? UInt64(max(0, metadata.st_blocks)) * 512 : 0)
            }))
        }
        let mailDownloads = home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        if cleanupPathIsPhysical(mailDownloads, home: home), !overlapsOffered(mailDownloads.path) {
            let bytes = CleanupScanWorker.measure(mailDownloads.path, control: control).bytes
            if bytes >= CleanupRiskPolicy.appDataLeftoverThreshold {
                result.append(reviewCategory("Mail Downloads", .mailDownloads, [(mailDownloads.path, bytes)],
                                             owners: ["com.apple.mail", "Mail"]))
            }
        }
        let backups = home.appendingPathComponent("Library/Application Support/MobileSync/Backup")
        for backup in directChildren(of: backups) where isDirectory(backup) && !isSymlink(backup) {
            let info = NSDictionary(contentsOf: backup.appendingPathComponent("Info.plist"))
            let device = info?["Device Name"] as? String ?? backup.lastPathComponent
            let date = (info?["Last Backup Date"] as? Date).map {
                DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)
            }
            let bytes = CleanupScanWorker.measure(backup.path, control: control).bytes
            guard bytes > 0 else { continue }
            result.append(reviewCategory("iOS Backup · " + device + (date.map { " · " + $0 } ?? ""),
                                         .deviceBackup, [(backup.path, bytes)],
                                         owners: ["com.apple.AMPDevicesAgent", "AMPDeviceDiscoveryAgent"]))
        }
        var artifacts: [String: [(String, UInt64)]] = [:]
        let artifactPaths = projectArtifactPaths(home: home).filter {
            !overlapsOffered($0) && !directlyMatchesWhitelist($0, entries: whitelist)
        }
        var artifactSizes = [UInt64](repeating: 0, count: artifactPaths.count)
        let sizeLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: artifactPaths.count) { index in
            let bytes = CleanupScanWorker.measure(artifactPaths[index], control: control).bytes
            sizeLock.lock()
            artifactSizes[index] = bytes
            sizeLock.unlock()
        }
        for (path, bytes) in zip(artifactPaths, artifactSizes) where bytes >= 20 * 1024 * 1024 {
            artifacts[(path as NSString).lastPathComponent, default: []].append((path, bytes))
        }
        for (name, entries) in artifacts {
            let category = reviewCategory("Project " + name, .projectArtifact,
                                          entries.sorted { $0.1 > $1.1 })
            guard category.bytes >= 50 * 1024 * 1024 else { continue }
            result.append(category)
        }
        return result
    }

    func projectArtifactPaths(home: URL, budget: TimeInterval = 8, maximumDirectories: Int = 120_000) -> [String] {
        let started = Date()
        let skippedTop: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures", "Public"]
        var queue = directChildren(of: home).filter {
            !$0.lastPathComponent.hasPrefix(".") && !skippedTop.contains($0.lastPathComponent)
                && isDirectory($0) && !isSymlink($0)
        }.map { ($0, 1) }
        var found: [String] = []
        var visited = 0
        while visited < queue.count, visited < maximumDirectories, Date().timeIntervalSince(started) < budget {
            let (directory, depth) = queue[visited]
            visited += 1
            for child in directChildren(of: directory) where isDirectory(child) && !isSymlink(child) {
                let name = child.lastPathComponent
                if CleanupRiskPolicy.projectArtifactMarkers[name] != nil {
                    let path = CleanupRiskPolicy.normalizedPathLiteral(child.path)
                    if CleanupRiskPolicy.isProjectArtifact(path, homeDirectory: home.path) { found.append(path) }
                    continue
                }
                guard depth < 6, !name.hasPrefix("."), (name as NSString).pathExtension.isEmpty
                        || !["app", "bundle", "framework", "photoslibrary", "musiclibrary"]
                            .contains((name as NSString).pathExtension.lowercased()) else { continue }
                queue.append((child, depth + 1))
            }
        }
        return found
    }

    func applyAppDataReview(_ categories: [CleanupCategory],
                            homeDirectory: String = NSHomeDirectory(),
                            trashHandler: ((URL) throws -> Void)? = nil) -> ApplySummary {
        guard !categories.isEmpty else { return ApplySummary(removed: 0, skipped: 0, failed: 0, messages: []) }
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
        let installed = installedApplications(home: home)
        var refused: [String] = []
        var items: [DeletionPlan.Item] = []
        for category in categories where category.isAppDataReview {
            for path in category.paths where category.isPathSelected(path) {
                let normalized = CleanupRiskPolicy.normalizedPathLiteral(path)
                let token = Self.appDataOwnerToken(normalized)
                let stillOrphaned = category.reasonKey != "cleanup.risk.appDataLeftover"
                    || Self.isOrphanedAppToken(token, installed: installed)
                guard normalized == path, CleanupRiskPolicy.reviewTargetKind(normalized, homeDirectory: home.path) != nil,
                      !CleanupRiskPolicy.isAgentOwnedPath(normalized, homeDirectory: home.path),
                      stillOrphaned, let identity = category.pathIdentities[path], !identity.isEmpty else {
                    refused.append("Skipped app data that no longer matches its review: " + path)
                    continue
                }
                items.append(.init(record: path, identity: identity))
            }
        }
        let applied = items.isEmpty ? ApplySummary(removed: 0, skipped: 0, failed: 0, messages: [])
            : applyCleanup(items: items, permanent: false, homeDirectory: home.path,
                           verifiedTargets: Set(items.map(\.record)), trashHandler: trashHandler)
        return ApplySummary(removed: applied.removed, skipped: applied.skipped + refused.count,
                            failed: applied.failed, messages: refused + applied.messages,
                            removedPaths: applied.removedPaths, reclaimedBytes: applied.reclaimedBytes)
    }

    struct CleanupScanCandidate {
        var path: String
        let name: String
        let policy: CleanupPolicyDescriptor
        /// 年龄门（秒）。0 表示该候选不按活跃时间过滤。
        var retention: TimeInterval = 0
        var activityOwners: [String] = []
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

    /// Recheck inventories from every scanner and old caches before they are
    /// published. A mixed tree contributes only its independently deletable
    /// descendants; its protected or busy bytes are never offered as junk.
    func preflightCleanupCategories(_ categories: [CleanupCategory],
                                    homeDirectory: String = NSHomeDirectory(),
                                    control: CleanupScanControl? = nil,
                                    includingAdministratorRequired: Bool = false,
                                    verifiedRebuildableRoots: Set<String> = [],
                                    excludingPaths: Set<String> = []) -> CleanupScan {
        let control = control ?? CleanupScanControl(mode: .deep)
        guard let openFiles = currentCleanupOpenFiles() else {
            return CleanupScan(categories: [], succeeded: false,
                error: "Open-file safety state is unavailable.")
        }
        let whitelist = loadWhitelist(homeDirectory: homeDirectory)
            + excludingPaths.filter(DeletionPlan.isLexicallySafePath)
        var result: [CleanupCategory] = []
        var deferred: [String] = []
        var administratorPaths = Set<String>()
        for category in categories where category.isAppDataReview {
            let intact = category.paths.filter {
                CleanupRiskPolicy.reviewTargetKind($0, homeDirectory: homeDirectory) != nil
                    && DeletionPlan.identity(at: $0) == category.pathIdentities[$0]
            }
            if let kept = category.retainingPaths(intact) { result.append(kept) }
        }
        for category in categories where category.risk == .safe {
            if category.applyRoute == .toolCommand {
                result.append(category)
                continue
            }
            guard [.genericTrash, .developerCacheTrash, .aiTrash, .xcodeTrash]
                .contains(category.applyRoute) else { continue }
            var entries: [CleanupPreflightEntry] = []
            var selected = Set<String>()
            for path in category.paths {
                let descriptor = CleanupRiskPolicy.core(section: "Cache", path: path,
                                                        homeDirectory: homeDirectory)
                let catalogVerified = category.source == .aiCache && verifiedRebuildableRoots.contains(path)
                let trashItem = (path as NSString).deletingLastPathComponent
                    == CleanupRiskPolicy.normalizedPathLiteral(homeDirectory) + "/.Trash"
                guard descriptor.risk == .safe && descriptor.disposal == .permanentDelete
                    || catalogVerified || (trashItem && descriptor.risk != .protected) else { continue }
                let checked = preflightCleanupPath(path, homeDirectory: homeDirectory,
                    openFiles: openFiles, whitelist: whitelist, control: control,
                    includingAdministratorRequired: includingAdministratorRequired
                        && (descriptor.risk == .safe && descriptor.disposal == .permanentDelete || trashItem),
                    rootIsVerifiedRebuildable: catalogVerified)
                deferred.append(contentsOf: checked.deferredPaths)
                entries.append(contentsOf: checked.entries)
                if category.isPathSelected(path) { selected.formUnion(checked.entries.map(\.path)) }
            }
            guard !entries.isEmpty else { continue }
            let sizes = Dictionary(entries.map { ($0.path, $0.measurement.bytes) },
                                   uniquingKeysWith: { first, _ in first })
            var refreshed = CleanupCategory(id: category.id, name: category.name,
                paths: entries.map(\.path), bytes: sizes.values.reduce(0, &+), pathBytes: sizes,
                selected: false, expanded: category.expanded, source: category.source,
                risk: category.risk, disposal: category.disposal, applyRoute: category.applyRoute,
                activityGuard: category.activityGuard, retention: category.retention,
                reasonKey: category.reasonKey)
            refreshed.activityOwners = category.activityOwners
            refreshed = refreshed.selectingPaths(selected)
            result.append(refreshed)
            administratorPaths.formUnion(entries.filter(\.requiresAdministrator).map(\.path))
        }
        return CleanupScan(categories: result.sorted(by: CleanupCategory.sizeDescending),
            succeeded: !control.isCancelled, error: control.isCancelled ? "Scan cancelled." : nil,
            deferredPaths: deferred, administratorRequiredPaths: administratorPaths)
    }

    /// Permission-only failures can use the signed administrator route. Scan
    /// preflight still has to prove content, occupancy and full readability.
    /// Include descendants because a writable root can hold an ACL-locked leaf.
    func requiresAdministratorDeletion(_ path: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        guard DeletionPlan.isLexicallySafePath(path) else { return false }
        var pending = [path]
        while let candidate = pending.popLast() {
            var metadata = stat()
            guard lstat(candidate, &metadata) == 0,
                  metadata.st_mode & S_IFMT != S_IFLNK else { continue }
            if systemCleanupRequiresAdministrator(candidate, metadata: metadata, homeDirectory: homeDirectory)
                || cleanupDeletionAccess(candidate, metadata: metadata) == .administrator { return true }
            if metadata.st_mode & S_IFMT == S_IFDIR {
                guard let children = try? fileManager.contentsOfDirectory(atPath: candidate) else { continue }
                pending.append(contentsOf: children.map { candidate + "/" + $0 })
            }
        }
        return false
    }

    private enum CleanupDeletionAccess { case user, administrator, blocked }
    private struct CleanupPreflightEntry {
        let path: String
        let measurement: CleanupScanWorker.Measurement
        let requiresAdministrator: Bool
    }
    private struct CleanupPreflightResult {
        var entries: [CleanupPreflightEntry] = []
        var deferredPaths: [String] = []
        var wholeTreeEligible = false
        var measurement = CleanupScanWorker.Measurement()
        var requiresAdministrator = false
        var hardlinkBytes: [FileIdentity: UInt64] = [:]
    }

    private func currentCleanupOpenFiles() -> Set<String>? {
        if let cleanupOpenFileProbe { return cleanupOpenFileProbe() }
        return openFileSnapshot()
    }

    private func cleanupDeletionAccess(_ path: String, metadata: stat) -> CleanupDeletionAccess {
        let immutable = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND | SF_RESTRICTED)
        let parent = (path as NSString).deletingLastPathComponent
        var parentMetadata = stat()
        var filesystem = statfs()
        guard metadata.st_flags & immutable == 0,
              lstat(parent, &parentMetadata) == 0,
              parentMetadata.st_mode & S_IFMT == S_IFDIR,
              parentMetadata.st_flags & immutable == 0,
              statfs(path, &filesystem) == 0,
              UInt32(filesystem.f_flags) & UInt32(MNT_RDONLY) == 0 else { return .blocked }
        if geteuid() == 0 { return .user }
        guard let itemDeny = cleanupACLHasDeletionDeny(path, permission: ACL_DELETE),
              let parentDeny = cleanupACLHasDeletionDeny(parent, permission: ACL_DELETE_CHILD) else {
            return .blocked
        }
        if itemDeny || parentDeny { return .administrator }
        return fileManager.isDeletableFile(atPath: path) && access(parent, W_OK | X_OK) == 0
            ? .user : .administrator
    }

    /// NSFileManager's deletability query misses ACL deny-delete entries on
    /// macOS. Treat any applicable deny conservatively as permission-only;
    /// the root execution route rechecks the same content and identity gates.
    private func cleanupACLHasDeletionDeny(_ path: String, permission: acl_perm_t) -> Bool? {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT || errno == ENOTSUP ? false : nil
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var entryID = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, entryID, &entry) == 0, let current = entry {
            entryID = Int32(ACL_NEXT_ENTRY.rawValue)
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            var flags: acl_flagset_t?
            guard acl_get_tag_type(current, &tag) == 0,
                  acl_get_permset(current, &permissions) == 0, let permissions,
                  acl_get_flagset_np(UnsafeMutableRawPointer(current), &flags) == 0,
                  let flags else { return nil }
            if acl_get_flag_np(flags, ACL_ENTRY_ONLY_INHERIT) == 1 { continue }
            if tag == ACL_EXTENDED_DENY && acl_get_perm_np(permissions, permission) == 1 { return true }
        }
        return false
    }

    private func preflightCleanupPath(_ path: String, homeDirectory: String,
                                     openFiles: Set<String>, whitelist: [String],
                                     excludingScannedRoots: Set<String> = [],
                                     control: CleanupScanControl,
                                     includingAdministratorRequired: Bool,
                                     rootIsVerifiedRebuildable: Bool = false,
                                     onVisit: ((String) -> Void)? = nil) -> CleanupPreflightResult {
        guard DeletionPlan.isLexicallySafePath(path),
              cleanupPathIsPhysical(URL(fileURLWithPath: path),
                                    home: URL(fileURLWithPath: homeDirectory)) else { return .init() }
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return .init() }
        var parentFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { return .init() }
        for component in components.dropLast() {
            let next = openat(parentFD, component, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            close(parentFD)
            parentFD = next
            guard next >= 0 else { return .init() }
        }
        defer { close(parentFD) }
        var metadata = stat()
        guard fstatat(parentFD, components.last!, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { return .init() }
        let deadline = min(control.totalBudget, control.elapsed + control.directoryBudget)
        let catalogRoot = CleanupRiskPolicy.auditedRebuildableRoot(containing: path, homeDirectory: homeDirectory)
        let contentRoot = catalogRoot ?? verifiedBrowserCacheRoot(containing: path, homeDirectory: homeDirectory) ?? path
        let contentPolicy = CleanupRiskPolicy.core(section: "Cache", path: contentRoot,
                                                 homeDirectory: homeDirectory)
        return preflightCleanupEntry(parentFD: parentFD, name: components.last!, path: path,
            metadata: metadata, device: metadata.st_dev, cacheRoot: path,
            homeDirectory: homeDirectory, openFiles: openFiles, whitelist: whitelist,
            excludingScannedRoots: excludingScannedRoots,
            control: control, deadline: deadline,
            includingAdministratorRequired: includingAdministratorRequired,
            rootIsVerifiedRebuildable: rootIsVerifiedRebuildable || catalogRoot != nil || contentRoot != path
                || isVerifiedBrowserCacheRoot(path, homeDirectory: homeDirectory),
            contentRoot: contentRoot, contentPolicy: contentPolicy, onVisit: onVisit, depth: 0)
    }

    private func preflightCleanupEntry(parentFD: Int32, name: String, path: String,
                                       metadata: stat, device: dev_t, cacheRoot: String,
                                       homeDirectory: String, openFiles: Set<String>, whitelist: [String],
                                       excludingScannedRoots: Set<String>,
                                       control: CleanupScanControl, deadline: TimeInterval,
                                       includingAdministratorRequired: Bool,
                                       rootIsVerifiedRebuildable: Bool,
                                       contentRoot: String, contentPolicy: CleanupPolicyDescriptor,
                                       onVisit: ((String) -> Void)?, depth: Int) -> CleanupPreflightResult {
        var result = CleanupPreflightResult()
        guard !control.shouldStop, control.elapsed < deadline else {
            result.deferredPaths = [path]
            return result
        }
        onVisit?(path)
        // 废纸篓条目由用户丢弃：跳过内容类保护，硬安全检查照旧。
        let discarded = CleanupRiskPolicy.discardedEntryRoot(containing: path, homeDirectory: homeDirectory) != nil
        guard depth < 128, metadata.st_dev == device,
              CleanupRiskPolicy.systemCleanupKind(for: contentRoot, homeDirectory: homeDirectory) == nil
                || CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: homeDirectory) != nil,
              !isCleanupLockItem(path),
              discarded || !CleanupRiskPolicy.isProtectedCleanupPath(path, homeDirectory: homeDirectory,
                  rebuildableRoot: contentRoot, rootIsVerifiedRebuildable: rootIsVerifiedRebuildable,
                  rebuildableRootPolicy: contentPolicy),
              !directlyMatchesWhitelist(path, entries: whitelist),
              !Self.isCoveredByScannedRoot(path, roots: excludingScannedRoots) else { return result }
        let kind = metadata.st_mode & S_IFMT
        guard kind == S_IFDIR || kind == S_IFREG || (discarded && kind == S_IFLNK) else { return result }
        var deletionAccess = cleanupDeletionAccess(path, metadata: metadata)
        if deletionAccess == .user, systemCleanupRequiresAdministrator(path, metadata: metadata, homeDirectory: homeDirectory) {
            deletionAccess = .administrator
        }
        guard deletionAccess != .blocked else { return result }
        // 链接本身作为叶子 unlink，从不跟随到目标。
        if kind == S_IFLNK {
            result.requiresAdministrator = deletionAccess == .administrator
            result.wholeTreeEligible = includingAdministratorRequired || !result.requiresAdministrator
            result.measurement.bytes = UInt64(max(0, metadata.st_blocks)) * 512
            result.measurement.files = 1
            return result
        }
        let directory = kind == S_IFDIR
        if CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: homeDirectory) != nil {
            var account = stat()
            guard lstat(homeDirectory, &account) == 0,
                  CleanupRiskPolicy.systemCleanupAccountScopeEligible(path: path, homeDirectory: homeDirectory),
                  metadata.st_uid == account.st_uid || metadata.st_uid == 0 else { return result }
        }
        let systemEligible = systemCleanupMetadataEligible(path, metadata: metadata, homeDirectory: homeDirectory)
        if !directory && !systemEligible { return result }
        if directory { control.reportDirectory(path) }
        // powerlog 遥测库由 powerlogd 常开：形状策略已精确限定这三个文件，
        // 占用不构成拒绝理由（删除后由系统重建）。
        if !directory && openFiles.contains(path)
            && CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: homeDirectory) != .powerlogTelemetry {
            return result
        }
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { return result }
        defer { close(fd) }
        var current = stat()
        guard fstat(fd, &current) == 0, Self.sameCleanupEntry(metadata, current) else { return result }
        result.requiresAdministrator = deletionAccess == .administrator
        // 统一日志子目录是保留壳：子项合格也只提供直接子级 *.tracev3，
        // 目录自身永不成项（与用户 T/C 根目录"只认子项、不认根"一致）。
        result.wholeTreeEligible = systemEligible
            && (includingAdministratorRequired || !result.requiresAdministrator)
            && !CleanupRiskPolicy.isUnifiedLogDirectory(path)
        result.measurement.bytes = UInt64(max(0, metadata.st_blocks)) * 512
        if directory {
            guard let children = liveCacheEntries(in: fd, path: path, homeDirectory: homeDirectory, shouldStop: {
                control.shouldStop || control.elapsed >= deadline
            }, onEntry: { onVisit?(path + "/" + $0) }) else {
                return control.shouldStop || control.elapsed >= deadline
                    ? CleanupPreflightResult(deferredPaths: [path]) : .init()
            }
            for child in children {
                let checked = preflightCleanupEntry(parentFD: fd, name: child.name,
                    path: path + "/" + child.name, metadata: child.metadata, device: device,
                    cacheRoot: cacheRoot, homeDirectory: homeDirectory, openFiles: openFiles,
                    whitelist: whitelist, excludingScannedRoots: excludingScannedRoots,
                    control: control, deadline: deadline,
                    includingAdministratorRequired: includingAdministratorRequired,
                    rootIsVerifiedRebuildable: rootIsVerifiedRebuildable,
                    contentRoot: contentRoot, contentPolicy: contentPolicy,
                    onVisit: onVisit, depth: depth + 1)
                result.entries.append(contentsOf: checked.entries)
                result.deferredPaths.append(contentsOf: checked.deferredPaths)
                result.wholeTreeEligible = result.wholeTreeEligible && checked.wholeTreeEligible
                result.requiresAdministrator = result.requiresAdministrator || checked.requiresAdministrator
                result.measurement.bytes &+= checked.measurement.bytes
                result.measurement.files += checked.measurement.files
                for (identity, bytes) in checked.hardlinkBytes {
                    if result.hardlinkBytes.updateValue(bytes, forKey: identity) != nil {
                        result.measurement.bytes -= bytes
                        result.measurement.files -= 1
                    }
                }
                if let date = checked.measurement.newestModified {
                    result.measurement.newestModified = max(result.measurement.newestModified ?? .distantPast, date)
                }
                if let date = checked.measurement.newestAccessed {
                    result.measurement.newestAccessed = max(result.measurement.newestAccessed ?? .distantPast, date)
                }
            }
            // An occupied directory is a retained shell. Its unused children
            // remain independently eligible, exactly as at the deletion edge.
            result.wholeTreeEligible = result.wholeTreeEligible && !openFiles.contains(path)
            guard fstat(fd, &current) == 0, Self.sameCleanupEntry(metadata, current) else {
                result.wholeTreeEligible = false
                return result
            }
        } else {
            let activity = cleanupInspection(path, matching: metadata)?.original ?? metadata
            // These exact archives explicitly permit SQLite payloads. Reading
            // their header cannot improve classification and would change
            // atime before the separate administrator worker can inspect them.
            if !discarded && !CleanupRiskPolicy.isArchivedPowerlogPath(path)
                && !CleanupRiskPolicy.isPowerlogTelemetryPath(path) {
                guard let database = sqliteHeader(in: fd, path: path, homeDirectory: homeDirectory),
                      !database else { return .init() }
            }
            result.measurement.files = 1
            if metadata.st_nlink > 1 {
                result.hardlinkBytes[FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))]
                    = result.measurement.bytes
            }
            result.measurement.newestModified = Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec))
            result.measurement.newestAccessed = Date(timeIntervalSince1970: TimeInterval(activity.st_atimespec.tv_sec))
            guard fstat(fd, &current) == 0, Self.sameCleanupEntry(metadata, current) else { return .init() }
        }
        if result.wholeTreeEligible {
            result.entries = result.measurement.files > 0 && result.measurement.bytes > 0
                ? [CleanupPreflightEntry(path: path, measurement: result.measurement,
                                        requiresAdministrator: result.requiresAdministrator)] : []
        }
        return result
    }

    private func cleanupPathIsPhysical(_ url: URL, home: URL) -> Bool {
        let path = CleanupRiskPolicy.normalizedPathLiteral(url.path)
        guard path.hasPrefix(home.path + "/")
            || CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: home.path) != nil
            || Self.systemDiscoveryRoots.contains(path) else { return false }
        var probe = url
        while probe.path != "/" {
            if isSymlink(probe) { return false }
            probe.deleteLastPathComponent()
        }
        return fileManager.fileExists(atPath: url.path)
    }

    private static let browserDisplayNames = [
        "Chrome Canary", "Chrome Beta", "Chromium", "Chrome", "Edge", "Brave", "Arc", "Dia",
        "Vivaldi", "Opera", "Yandex Browser", "QQBrowser", "Helium", "Firefox"
    ]
    private static let namedSupportLabels: Set<String> = [
        "GoogleUpdater Cache", "EdgeUpdater Cache", "ChromeDebug Profile"
    ]

    private static let systemDiscoveryRoots: Set<String> = [
        "/Library/Caches", "/private/tmp", "/private/var/tmp", "/private/var/log",
        "/private/var/db/powerlog/Library/BatteryLife/Archives"
    ]

    private func systemCleanupMetadataEligible(_ path: String, metadata: stat, homeDirectory: String) -> Bool {
        guard CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: homeDirectory) != nil else { return true }
        let activity = cleanupInspection(path, matching: metadata)?.original ?? metadata
        return rawSystemCleanupMetadataEligible(path, metadata: activity, homeDirectory: homeDirectory)
            && systemCleanupOwnerEligible(path, metadata: metadata, homeDirectory: homeDirectory)
    }

    private func rawSystemCleanupMetadataEligible(_ path: String, metadata: stat, homeDirectory: String) -> Bool {
        var account = stat()
        guard lstat(homeDirectory, &account) == 0 else { return false }
        guard CleanupRiskPolicy.systemCleanupAccountScopeEligible(path: path, homeDirectory: homeDirectory) else { return false }
        return CleanupRiskPolicy.systemCleanupMetadataEligible(path: path,
            ownerUID: metadata.st_uid, userUID: account.st_uid,
            modified: Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)),
            accessed: Date(timeIntervalSince1970: TimeInterval(metadata.st_atimespec.tv_sec)),
            homeDirectory: homeDirectory)
    }

    private static func sameAccessTime(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_atimespec.tv_sec == rhs.st_atimespec.tv_sec
            && lhs.st_atimespec.tv_nsec == rhs.st_atimespec.tv_nsec
    }

    private static func sameInspectionSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        sameCleanupEntry(lhs, rhs, checkingChangeTime: true)
            && lhs.st_nlink == rhs.st_nlink && sameAccessTime(lhs, rhs)
    }

    private func cleanupInspection(_ path: String, matching metadata: stat) -> CleanupInspection? {
        cleanupInspectionLock.lock()
        defer { cleanupInspectionLock.unlock() }
        guard let evidence = cleanupInspections[path] else { return nil }
        let elapsed = evidence.firstObservedAt.duration(to: cleanupInspectionClock.now)
        guard elapsed >= .zero, elapsed <= .seconds(Self.cleanupInspectionLifetime),
              Self.sameInspectionSnapshot(evidence.observed, metadata) else {
            cleanupInspections.removeValue(forKey: path)
            return nil
        }
        return evidence
    }

    private func beginCleanupInspection(_ path: String, fd: Int32,
                                        homeDirectory: String) -> CleanupInspectionStart? {
        guard CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: homeDirectory) != nil else { return nil }
        var before = stat()
        guard fstat(fd, &before) == 0 else { return nil }
        let previous = cleanupInspection(path, matching: before)
        let evidence = previous ?? CleanupInspection(original: before, observed: before,
                                                     firstObservedAt: cleanupInspectionClock.now)
        guard rawSystemCleanupMetadataEligible(path, metadata: evidence.original, homeDirectory: homeDirectory),
              systemCleanupOwnerEligible(path, metadata: before, homeDirectory: homeDirectory) else { return nil }
        var startedAt = timespec()
        guard clock_gettime(CLOCK_REALTIME, &startedAt) == 0 else { return nil }
        return CleanupInspectionStart(evidence: evidence, before: before, startedAt: startedAt,
                                      hadPrevious: previous != nil)
    }

    private func finishCleanupInspection(_ start: CleanupInspectionStart?, path: String, fd: Int32,
                                         succeeded: Bool) {
        guard let start else { return }
        var finishedAt = timespec()
        var resolution = timespec()
        var after = stat()
        guard succeeded, fstat(fd, &after) == 0, clock_gettime(CLOCK_REALTIME, &finishedAt) == 0,
              clock_getres(CLOCK_REALTIME, &resolution) == 0,
              resolution.tv_sec == 0, resolution.tv_nsec > 0, resolution.tv_nsec <= 1_000_000,
              Self.sameCleanupEntry(start.before, after, checkingChangeTime: true),
              start.before.st_nlink == after.st_nlink else {
            cleanupInspectionLock.lock(); cleanupInspections.removeValue(forKey: path); cleanupInspectionLock.unlock()
            return
        }
        if !Self.sameAccessTime(start.before, after) {
            func noEarlier(_ lhs: timespec, than rhs: timespec) -> Bool {
                lhs.tv_sec > rhs.tv_sec || (lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec >= rhs.tv_nsec)
            }
            // Only an access timestamp observed inside this exact I/O window
            // can be attributed to the inspection. A later timestamp is busy.
            // Darwin's wall clock is quantized to its reported resolution
            // (one microsecond here), while filesystem atime has nanoseconds.
            // Use the end of that observed clock tick, not a grace interval.
            var observedEnd = finishedAt
            observedEnd.tv_nsec += resolution.tv_nsec
            if observedEnd.tv_nsec >= 1_000_000_000 {
                observedEnd.tv_sec += 1; observedEnd.tv_nsec -= 1_000_000_000
            }
            guard noEarlier(after.st_atimespec, than: start.startedAt),
                  noEarlier(observedEnd, than: after.st_atimespec) else {
                cleanupInspectionLock.lock(); cleanupInspections.removeValue(forKey: path); cleanupInspectionLock.unlock()
                return
            }
        }
        var evidence = start.evidence
        evidence.observed = after
        if !start.hadPrevious && start.before.st_mode & S_IFMT != S_IFDIR
            && Self.sameAccessTime(start.before, after) { return }
        cleanupInspectionLock.lock()
        defer { cleanupInspectionLock.unlock() }
        if cleanupInspections.count >= 100_000, cleanupInspections[path] == nil {
            let now = cleanupInspectionClock.now
            if lastCleanupInspectionSweep.map({ $0.duration(to: now) >= .seconds(60) }) ?? true {
                lastCleanupInspectionSweep = now
                cleanupInspections = cleanupInspections.filter {
                    let elapsed = $0.value.firstObservedAt.duration(to: now)
                    return elapsed >= .zero && elapsed <= .seconds(Self.cleanupInspectionLifetime)
                }
            }
        }
        // Repeated inspections retain the first age proof and expiry.
        guard evidence.firstObservedAt.duration(to: cleanupInspectionClock.now) <= .seconds(Self.cleanupInspectionLifetime),
              cleanupInspections[path].map({ Self.sameInspectionSnapshot($0.observed, start.before) }) ?? !start.hadPrevious,
              cleanupInspections.count < 100_000 || cleanupInspections[path] != nil else { return }
        cleanupInspections[path] = evidence
    }

    /// Advance only metadata changes caused by an unlink this worker actually
    /// completed. Atime must remain exactly the observed access timestamp.
    private func recordCleanupDirectoryMutation(_ path: String, fd: Int32, before: stat?) {
        guard let before, var evidence = cleanupInspection(path, matching: before) else { return }
        var after = stat()
        guard fstat(fd, &after) == 0,
              Self.sameCleanupEntry(before, after, allowingDirectoryContentChanges: true),
              Self.sameAccessTime(before, after) else { return }
        evidence.observed = after
        cleanupInspectionLock.lock()
        defer { cleanupInspectionLock.unlock() }
        guard let existing = cleanupInspections[path],
              Self.sameInspectionSnapshot(existing.observed, before),
              existing.firstObservedAt == evidence.firstObservedAt else { return }
        cleanupInspections[path] = evidence
    }

    private func directoryInspectionSnapshot(_ path: String, fd: Int32) -> stat? {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, cleanupInspection(path, matching: metadata) != nil else { return nil }
        return metadata
    }

    private func systemCleanupOwnerEligible(_ path: String, metadata: stat, homeDirectory: String) -> Bool {
        guard CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: homeDirectory) != nil else { return true }
        var account = stat()
        return lstat(homeDirectory, &account) == 0
            && CleanupRiskPolicy.systemCleanupAccountScopeEligible(path: path, homeDirectory: homeDirectory)
            && (metadata.st_uid == account.st_uid || metadata.st_uid == 0)
    }

    private func systemCleanupDirectoryEdgeEligible(_ path: String, original: stat,
                                                   current: stat, homeDirectory: String) -> Bool {
        guard CleanupRiskPolicy.systemCleanupRetention(for: path, homeDirectory: homeDirectory) != nil else { return true }
        // Only an exact proof advanced after our completed unlink can explain
        // changed directory metadata. An invalid/expired proof retains shell.
        let inspection = cleanupInspection(path, matching: current)
        if let inspection {
            return rawSystemCleanupMetadataEligible(path, metadata: inspection.original,
                                                     homeDirectory: homeDirectory)
                && systemCleanupOwnerEligible(path, metadata: current, homeDirectory: homeDirectory)
        }
        return Self.sameInspectionSnapshot(original, current)
            && rawSystemCleanupMetadataEligible(path, metadata: current, homeDirectory: homeDirectory)
    }

    private func systemCleanupRequiresAdministrator(_ path: String, metadata: stat, homeDirectory: String) -> Bool {
        guard geteuid() != 0,
              let kind = CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: homeDirectory) else { return false }
        var account = stat()
        guard lstat(homeDirectory, &account) == 0 else { return true }
        // 用户拥有的 T/C 与签名副本可用自身权限删除；其余系统内容或
        // 非本账户拥有的条目必须走管理员工作进程。
        return (kind != .temporary && kind != .codeSignClone) || metadata.st_uid != account.st_uid
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
            let path = CleanupRiskPolicy.normalizedPathLiteral(url.path)
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
        // Nori 自身的可再生存储：缓存清单目录走原生删除边界；DirectoryIndex
        // 的 SQLite 与 screenshot 暂存目录由 AppState 在进程内执行，不在此列。
        for path in NoriOwnedStorage.fileTreeRoots(home: home.path) {
            add(URL(fileURLWithPath: path, isDirectory: true),
                NoriOwnedStorage.displayName, .core, .openFile)
        }
        for path in NoriOwnedStorage.orphanTemporaryFiles(home: home.path) {
            add(URL(fileURLWithPath: path, isDirectory: false),
                NoriOwnedStorage.displayName, .core, .openFile)
        }
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

        // Precise Agent/Electron leaves are shared with the content policy.
        // A cache exception never authorizes the surrounding workspace state.
        for path in CleanupRiskPolicy.auditedRebuildableRoots(homeDirectory: home.path) {
            let label = path.hasPrefix(home.path + "/Library/Application Support/")
                ? String(path.dropFirst((home.path + "/Library/Application Support/").count))
                : URL(fileURLWithPath: path).lastPathComponent + " Cache"
            add(URL(fileURLWithPath: path), label, .aiCache, .openFile, retention)
        }
        let zedNode = home.appendingPathComponent("Library/Application Support/Zed/node")
        if cleanupPathIsPhysical(zedNode, home: home) {
            for version in directChildren(of: zedNode) where version.lastPathComponent.hasPrefix("node-v") {
                add(version.appendingPathComponent("cache"), "Zed npm Cache", .aiCache, .openFile, retention)
            }
        }
        // System roots are scanned only for the actual logged-in home. Fixture
        // homes and another account never trigger a machine-wide discovery.
        if home.path == CleanupRiskPolicy.normalizedPathLiteral(NSHomeDirectory()) {
            for root in Self.systemDiscoveryRoots.sorted() {
                let rootURL = URL(fileURLWithPath: root)
                guard cleanupPathIsPhysical(rootURL, home: home) else { continue }
                for child in directChildren(of: rootURL) {
                    if CleanupRiskPolicy.systemCleanupKind(for: child.path, homeDirectory: home.path) != nil {
                        add(child, root + " · " + child.lastPathComponent, .core, .openFile, retention)
                    }
                }
            }
            // confstr provides the current account's allocated T/C roots;
            // enumerating /var/folders would inspect other users' containers.
            // 用户自己的 T/C 子项 24 小时即可回收（策略层同步为 24 小时）；
            // /private/tmp、/private/var/tmp 仍是 7 天。
            let userTemporaryRetention: TimeInterval = 24 * 60 * 60
            for key in [Int32(_CS_DARWIN_USER_TEMP_DIR), Int32(_CS_DARWIN_USER_CACHE_DIR)] {
                let length = confstr(key, nil, 0)
                guard length > 1 && length < 16_384 else { continue }
                var bytes = [CChar](repeating: 0, count: length)
                guard confstr(key, &bytes, length) > 0 else { continue }
                let root = URL(fileURLWithPath: CleanupRiskPolicy.canonicalOpenFilePath(String(cString: bytes)))
                var account = stat(), metadata = stat()
                guard lstat(home.path, &account) == 0, lstat(root.path, &metadata) == 0,
                      metadata.st_uid == account.st_uid else { continue }
                for child in directChildren(of: root) {
                    add(child, "System Temporary Files", .core, .openFile, userTemporaryRetention)
                }
                guard key == _CS_DARWIN_USER_TEMP_DIR else { continue }
                // 浏览器更新在同级的 X 目录遗留 *.code_sign_clone 签名副本；
                // 仍限定当前账户目录，不枚举其他用户的 /var/folders 容器。
                let siblingX = root.deletingLastPathComponent()
                    .appendingPathComponent("X", isDirectory: true)
                var cloneRoot = stat()
                guard lstat(siblingX.path, &cloneRoot) == 0,
                      cloneRoot.st_mode & S_IFMT == S_IFDIR,
                      cloneRoot.st_uid == account.st_uid else { continue }
                for child in directChildren(of: siblingX)
                    where child.lastPathComponent.hasSuffix(".code_sign_clone") && !isSymlink(child) {
                    add(child, "Browser Signature Clone", .core, .browser)
                }
            }
            // 统一日志旧分片：只在四个已知子目录下按 *.tracev3 直接子级
            // 清理；uuidtext、timesync、logd 与嵌套内容由形状策略拒绝。
            // 每个子目录最多一个条目，不逐文件罗列。
            let diagnostics = URL(fileURLWithPath: "/private/var/db/diagnostics", isDirectory: true)
            for child in directChildren(of: diagnostics)
                where isDirectory(child)
                    && CleanupRiskPolicy.systemCleanupKind(for: child.path,
                                                           homeDirectory: home.path) == .unifiedLog {
                add(child, "Unified Log " + child.lastPathComponent, .core, .openFile)
            }
            // powerlog 遥测主库仅在异常膨胀（≥512MB）时提供；-wal/-shm
            // 与其同名成组呈现为一条。powerlogd 常开它，系统在删除后重建。
            var telemetry = stat()
            if lstat(CleanupRiskPolicy.powerlogTelemetryDatabase, &telemetry) == 0,
               telemetry.st_mode & S_IFMT == S_IFREG,
               telemetry.st_size >= 512 * 1024 * 1024 {
                for suffix in ["", "-wal", "-shm"] {
                    add(URL(fileURLWithPath: CleanupRiskPolicy.powerlogTelemetryDatabase + suffix),
                        "Powerlog Telemetry DB", .core, .openFile)
                }
            }
        }

        // Additional fixed developer cache locations. These are all
        // rebuildable package/build caches; project sources and installed
        // runtimes are intentionally not included in the quick inventory.
        let developerCaches: [(String, String)] = [
            ("Library/Caches/pnpm", "pnpm Cache"),
            ("Library/pnpm/store", "pnpm Store"),
            (".pnpm-store", "pnpm Store"),
            (".local/share/pnpm/store", "pnpm Store"),
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
                                (locations.goBuildCache, "Go Build Cache"),
                                (locations.pnpmStore, "pnpm Store")] {
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
                for cache in ["CacheStorage", "ScriptCache"] {
                    add(profile.appendingPathComponent("Service Worker/" + cache, isDirectory: true),
                        label, .core, .browser)
                }
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

        // 微信 4.x 按账号枚举可再生叶子；消息库与聊天文件由策略保护。
        let wechatFiles = home.appendingPathComponent(WeChatStorage.filesRelativeRoot, isDirectory: true)
        if cleanupPathIsPhysical(wechatFiles, home: home) {
            for account in directChildren(of: wechatFiles)
                where !isSymlink(account) && isDirectory(account)
                    && WeChatStorage.isAccountDirectory(account.lastPathComponent) {
                for leaf in WeChatStorage.leaves {
                    add(account.appendingPathComponent(leaf.relative, isDirectory: true),
                        leaf.label, .core, .openFile)
                }
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

        // 端侧 AI 模型（OptGuide / Gemini Nano）位于 user-data-dir 根部而非
        // profile 内，体积可达数 GB；浏览器按需重新下载，归属 .browser 守卫。
        // 只认审计过的 Chrome/Edge/Brave 三个 profile 根。
        let onDeviceModelLeaves = ["OptGuideOnDeviceModel", "OptGuideOnDeviceClassifierModel",
                                   "optimization_guide_model_store"]
        for (relative, label) in [("Google/Chrome", "Chrome"), ("Microsoft Edge", "Edge"),
                                  ("BraveSoftware/Brave-Browser", "Brave")] {
            let browserRoot = appSupport.appendingPathComponent(relative, isDirectory: true)
            for leaf in onDeviceModelLeaves {
                add(browserRoot.appendingPathComponent(leaf, isDirectory: true),
                    label + " On-Device Model", .core, .browser)
            }
        }
        // 更新器已下载的组件包缓存：下次检查更新时重新拉取。
        for (relative, label) in [("Google/GoogleUpdater/crx_cache", "GoogleUpdater Cache"),
                                  ("Microsoft/EdgeUpdater/crx_cache", "EdgeUpdater Cache")] {
            add(appSupport.appendingPathComponent(relative, isDirectory: true),
                label, .core, .openFile)
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
    /// `liveCleanupTargets` names fresh, catalog-verified rebuildable caches.
    /// Their directory objects remain bound by device/inode while unused
    /// descendants are cleaned individually and occupied/durable data stays.
    /// Progress counts submitted, non-overlapping roots, including retained or
    /// failed roots. It runs on the caller's worker thread, never per child.
    struct RootRemovalOutcome {
        var removed = 0, skipped = 0, failed = 0
        var messages: [String] = []
        var removedPaths = Set<String>()
        var reclaimedBytes: UInt64 = 0
    }

    func applyCleanup(items: [DeletionPlan.Item], permanent: Bool,
                      homeDirectory: String = NSHomeDirectory(),
                      allowedRoots: [String] = [],
                      allowApplicationBundle: Bool = false,
                      verifiedTargets: Set<String> = [],
                      atomicFamilies: [[String]] = [],
                      liveCleanupTargets: Set<String> = [],
                      finalValidation: ((String) -> Bool)? = nil,
                      trashHandler: ((URL) throws -> Void)? = nil,
                      onProgress: ((Int, Int, String) -> Void)? = nil,
                      onCurrentFile: ((String) -> Void)? = nil) -> ApplySummary {
        guard !items.isEmpty else {
            onProgress?(0, 0, "")
            return ApplySummary(removed: 0, skipped: 0, failed: 0, messages: [])
        }
        let nonOverlapping = DeletionPlan.nonOverlappingPaths(items.map(\.record))
        var completedRoots = 0
        onProgress?(0, nonOverlapping.count, nonOverlapping.first ?? "")
        let home = CleanupRiskPolicy.normalizedPathLiteral(homeDirectory)
        let whitelist = loadWhitelist(homeDirectory: homeDirectory)
        let normalizedRoots = allowedRoots.map { CleanupRiskPolicy.normalizedPathLiteral($0) }
        var removed = 0
        var skipped = 0
        var failed = 0
        var messages: [String] = []
        let probeStart = Date()
        var removedPaths = Set<String>()
        var reclaimedBytes: UInt64 = 0
        Self.cleanupLogger.notice("Open-file safety check started")
        let openFiles: Set<String>?
        let openRecords: [OpenFileRecord]?
        if let cleanupOpenFileProbe {
            openFiles = cleanupOpenFileProbe()
            openRecords = nil
        } else {
            openRecords = currentOpenFileRecords()
            openFiles = openRecords.map { Set($0.map(\.path)) }
        }
        let probeSeconds = Date().timeIntervalSince(probeStart)
        Self.cleanupLogger.notice("Open-file safety check finished in \(probeSeconds, privacy: .public)s; available=\(openFiles != nil, privacy: .public)")
        messages.append(String(format: "Open-file check %.2fs; available=%@", probeSeconds, openFiles == nil ? "no" : "yes"))

        let itemByRecord = Dictionary(items.map { ($0.record, $0) },
                                      uniquingKeysWith: { first, _ in first })
        // 整族预检：任一成员被打开、身份变化或探测不可用，整族保留。
        var blockedFamilyMembers = Set<String>()
        for family in atomicFamilies where family.count > 1 {
            let intact = family.allSatisfy { member in
                guard let expected = itemByRecord[member]?.identity, !expected.isEmpty,
                      let openFiles,
                      DeletionPlan.identity(at: member) == expected else { return false }
                return !openFiles.contains(CleanupRiskPolicy.canonicalOpenFilePath(member))
            }
            if !intact { blockedFamilyMembers.formUnion(family) }
        }
        // 各根目录互不重叠，预检与删除并行执行；结果按原顺序汇总，消息顺序不变。
        var outcomes = [RootRemovalOutcome?](repeating: nil, count: nonOverlapping.count)
        let outcomeLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: nonOverlapping.count) { index in
            let rawPath = nonOverlapping[index]
            var outcome = RootRemovalOutcome()
            onCurrentFile?(rawPath)
            defer {
                outcomeLock.lock()
                outcomes[index] = outcome
                completedRoots += 1
                let finished = completedRoots
                outcomeLock.unlock()
                onProgress?(finished, nonOverlapping.count, rawPath)
            }
            let coveredPaths = itemByRecord.keys.filter { record in
                if record == rawPath { return true }
                guard DeletionPlan.isLexicallySafePath(rawPath),
                      DeletionPlan.isLexicallySafePath(record) else { return false }
                let ancestor = CleanupRiskPolicy.normalizedPathLiteral(rawPath)
                let candidate = CleanupRiskPolicy.normalizedPathLiteral(record)
                return candidate == ancestor || candidate.hasPrefix(ancestor + "/")
            }
            let coveredCount = coveredPaths.count
            let expectedIdentity = itemByRecord[rawPath]?.identity ?? ""
            if blockedFamilyMembers.contains(rawPath) {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped database family that is open or changed: \(rawPath)")
                return
            }
            // 第一道：词法校验（绝对路径、无控制字符、无 "."/".." 分量）。
            guard DeletionPlan.isLexicallySafePath(rawPath) else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped unsafe path literal: \(rawPath)")
                return
            }
            let url = URL(fileURLWithPath: CleanupRiskPolicy.normalizedPathLiteral(rawPath))
            let path = url.path
            let cachePolicy = CleanupRiskPolicy.core(section: "Cache", path: path,
                                                     homeDirectory: home)
            let declaredLiveCleanup = liveCleanupTargets.contains(path)
                || (permanent && CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: home) != nil)
                || isVerifiedBrowserCacheRoot(path, homeDirectory: home)
            // 整体丢弃的根按原子单元删除，不走逐叶保留壳的活缓存路线。
            let liveCleanup = permanent && !allowApplicationBundle
                && CleanupRiskPolicy.discardedEntryRoot(containing: path, homeDirectory: home) == nil
                && !isProtectedCleanupItem(url, homeDirectory: home, rebuildableRoot: path,
                                           rootIsVerifiedRebuildable: declaredLiveCleanup)
                && (declaredLiveCleanup
                    || (!verifiedTargets.contains(path)
                        && cachePolicy.risk == .safe && cachePolicy.disposal == .permanentDelete))
            let isHomePath = path.hasPrefix(home + "/")
            let isAllowedRoot = normalizedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
            let auditedSystemPath = permanent && cachePolicy.risk == .safe
                && CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: home) != nil
            guard isHomePath || isAllowedRoot || auditedSystemPath else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped outside authorized roots: \(path)")
                return
            }
            // 统一日志子目录是保留壳：无论哪条路径到达这里都不删目录本身；
            // 合法条目只会是它的直接子级 *.tracev3。
            guard !CleanupRiskPolicy.isUnifiedLogDirectory(path) else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped retained diagnostics directory: \(path)")
                return
            }
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else {
                let error = errno
                if error == ENOENT || error == ENOTDIR {
                    outcome.skipped += coveredCount
                    outcome.messages.append("Skipped path that is already absent: \(path)")
                } else {
                    outcome.failed += coveredCount
                    outcome.messages.append("Could not access \(path): \(String(cString: strerror(error)))")
                }
                return
            }
            guard metadata.st_mode & S_IFMT != S_IFLNK else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped symbolic link: \(path)")
                return
            }
            guard !auditedSystemPath || metadata.st_mode & S_IFMT == S_IFDIR
                    || systemCleanupMetadataEligible(path, metadata: metadata, homeDirectory: home) else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped recent or foreign-owned system content: \(path)")
                return
            }
            guard !isCleanupLockItem(path) else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped lock file: \(path)")
                return
            }
            guard verifiedTargets.contains(rawPath)
                    || (permanent && CleanupRiskPolicy.discardedEntryRoot(containing: path, homeDirectory: home) != nil)
                    || !isProtectedCleanupItem(url, allowApplicationBundle: allowApplicationBundle,
                        homeDirectory: home, rebuildableRoot: liveCleanup ? path : nil,
                        rootIsVerifiedRebuildable: declaredLiveCleanup) else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped protected content: \(path)")
                return
            }
            guard !(liveCleanup
                    ? directlyMatchesWhitelist(path, entries: whitelist)
                    : matchesWhitelist(path, entries: whitelist)) else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped path protected by whitelist: \(path)")
                return
            }
            guard Self.matchesCleanupIdentity(metadata, expected: expectedIdentity,
                        allowingDirectoryContentChanges: liveCleanup),
                  itemByRecord[rawPath]?.metadata?.matches(metadata, allowingDirectoryContentChanges: liveCleanup) != false else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped changed or unavailable path: \(path)")
                return
            }
            guard liveCleanup || !isOwnedByRunningApplication(path: path, homeDirectory: home) else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped while owning application is running: \(path)")
                return
            }
            guard cleanupDeletionAccess(path, metadata: metadata) == .user,
                  !systemCleanupRequiresAdministrator(path, metadata: metadata, homeDirectory: home) else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped content that requires administrator access or cannot be deleted: \(path)")
                return
            }
            guard let openFiles else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped because open-file state was unavailable: \(path)")
                return
            }
            let liveDirectory = liveCleanup && metadata.st_mode & S_IFMT == S_IFDIR
            // Only a reversible bundle move may ignore read-only Info.plist
            // and icon observers. Residues and permanent cleanup keep the
            // complete open-file snapshot and their existing protections.
            let movingBundle = allowApplicationBundle && !permanent
                && metadata.st_mode & S_IFMT == S_IFDIR && path.hasSuffix(".app")
            let blockers = openRecords?.filter {
                ($0.path == path || $0.path.hasPrefix(path + "/"))
                    && !(movingBundle && ($0.isReadOnlyBundleMetadata || $0.isObserverDirectoryHandle(onBundle: path)))
            }
            let pathIsOpen = blockers.map { !$0.isEmpty }
                ?? openFiles.contains(where: { $0 == path || $0.hasPrefix(path + "/") })
            guard liveDirectory || CleanupRiskPolicy.isPowerlogTelemetryPath(path)
                    || !pathIsOpen else {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped while the path is open: \(path)")
                if let blocker = blockers?.first {
                    outcome.messages.append("Open by \(blocker.process) (PID \(blocker.pid)): \(blocker.path)")
                }
                return
            }

            // Content-dependent plans (duplicates / similar images) must still
            // hold after the potentially slow runtime probes, at the Trash edge.
            if let finalValidation, !finalValidation(path) {
                outcome.skipped += coveredCount
                outcome.messages.append("Skipped because final content validation failed: \(path)")
                return
            }

            if declaredLiveCleanup && !liveDirectory {
                let checked = preflightCleanupPath(path, homeDirectory: home, openFiles: openFiles,
                    whitelist: whitelist, control: .init(mode: .deep),
                    includingAdministratorRequired: false, rootIsVerifiedRebuildable: true)
                guard checked.entries.contains(where: { $0.path == path }) else {
                    outcome.skipped += coveredCount
                    outcome.messages.append("Skipped protected or occupied cache leaf: \(path)")
                    return
                }
            }

            if liveDirectory {
                let partial = cleanLiveCacheDirectory(path, expectedIdentity: expectedIdentity,
                    expectedMetadata: metadata, whitelist: whitelist, openFiles: openFiles,
                    blockedFamilyMembers: blockedFamilyMembers, homeDirectory: home,
                    onCurrentFile: onCurrentFile)
                outcome.removed += partial.removedPaths.count
                outcome.skipped += partial.skippedPaths.count
                outcome.failed += partial.failedPaths.count
                outcome.messages.append(contentsOf: partial.messages)
                outcome.removedPaths.formUnion(partial.removedPaths)
                outcome.reclaimedBytes &+= partial.reclaimedBytes
                return
            }

            if permanent {
                // 永久删除走 fd 链：从 "/" 开始逐级 openat(O_NOFOLLOW) 打开，
                // 任何一级是符号链接或最终身份与计划不一致都拒绝；递归删除
                // 在已打开的目录描述符下进行，全程不重新解析路径字符串，
                // 扫描与删除之间被替换的路径删不到别处。
                var accounting = RemovalAccounting()
                let identity = Self.parseIdentity(expectedIdentity)
                let succeeded = identity.map {
                    removeTreeSecurely(path, expectedDevice: $0.device,
                        expectedInode: $0.inode, expectedMetadata: metadata,
                        expectedIdentity: expectedIdentity, homeDirectory: home,
                        accounting: &accounting, onCurrentFile: onCurrentFile)
                } ?? false
                outcome.reclaimedBytes &+= accounting.reclaimedBytes
                guard succeeded else {
                    outcome.removed += accounting.removedPaths.count
                    outcome.removedPaths.formUnion(accounting.removedPaths)
                    outcome.failed += coveredCount
                    let error = errno
                    outcome.messages.append("Failed secure removal of \(path): \(String(cString: strerror(error)))")
                    return
                }
                outcome.removed += coveredCount
                outcome.removedPaths.formUnion(coveredPaths)
            } else {
                do {
                    var resultingURL: NSURL?
                    if let trashHandler {
                        outcomeLock.lock()
                        defer { outcomeLock.unlock() }
                        try trashHandler(url)
                    } else { try fileManager.trashItem(at: url, resultingItemURL: &resultingURL) }
                    outcome.removed += coveredCount
                    outcome.removedPaths.formUnion(coveredPaths)
                } catch {
                    outcome.failed += coveredCount
                    outcome.messages.append("Failed to remove \(path): \(error.localizedDescription)")
                }
            }
        }
        for outcome in outcomes.compactMap({ $0 }) {
            removed += outcome.removed
            skipped += outcome.skipped
            failed += outcome.failed
            messages.append(contentsOf: outcome.messages)
            removedPaths.formUnion(outcome.removedPaths)
            reclaimedBytes &+= outcome.reclaimedBytes
        }
        return ApplySummary(removed: removed, skipped: skipped,
                            failed: failed, messages: messages, removedPaths: removedPaths,
                            remainingPaths: items.map(\.record).filter { !removedPaths.contains($0) },
                            reclaimedBytes: reclaimedBytes)
    }

    /// 只解除已验证的 Skill / MCP 启动链接；从不打开或删除链接目标。
    /// 每级父目录用 O_NOFOLLOW 打开，最终 fstatat 复核链接自身的完整身份。
    func applyAgentSkillLinks(items: [DeletionPlan.Item], homeDirectory: String,
                              allowedDirectories: [String] = [],
                              onProgress: ((Int, Int, String) -> Void)? = nil) -> ApplySummary {
        let parents = Set(AgentCatalog.skillDirectories(home: homeDirectory).map(\.path)
                            + allowedDirectories)
        var removed = 0, skipped = 0, failed = 0
        var messages: [String] = []
        var removedPaths = Set<String>()
        var completedLinks = 0
        var reclaimedBytes: UInt64 = 0
        let whitelist = loadWhitelist(homeDirectory: homeDirectory)
        onProgress?(0, items.count, items.first?.record ?? "")
        for item in items {
            defer {
                completedLinks += 1
                onProgress?(completedLinks, items.count, item.record)
            }
            let path = item.record
            let parent = (path as NSString).deletingLastPathComponent
            if matchesWhitelist(path, entries: whitelist) {
                skipped += 1
                messages.append("Skipped Agent link protected by whitelist: " + path)
                continue
            }
            guard DeletionPlan.isLexicallySafePath(path), parents.contains(parent),
                  !item.identity.isEmpty, AgentCatalog.isSymlink(path),
                  DeletionPlan.identity(at: path) == item.identity else {
                skipped += 1
                messages.append("Skipped changed or unrecognized Agent link: " + path)
                continue
            }
            let components = path.split(separator: "/").map(String.init)
            var directoryFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            var opened = directoryFD >= 0
            for component in components.dropLast() where opened {
                let next = openat(directoryFD, component,
                                  O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
                close(directoryFD)
                directoryFD = next
                opened = next >= 0
            }
            guard opened, let leaf = components.last else {
                if directoryFD >= 0 { close(directoryFD) }
                skipped += 1
                continue
            }
            var metadata = stat()
            let matches = fstatat(directoryFD, leaf, &metadata, AT_SYMLINK_NOFOLLOW) == 0
                && (metadata.st_mode & S_IFMT) == S_IFLNK
                && "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_mtimespec.tv_sec)" == item.identity
            if !matches {
                skipped += 1
            } else if unlinkat(directoryFD, leaf, 0) == 0 {
                removed += 1
                removedPaths.insert(path)
                reclaimedBytes &+= Self.reclaimableLeafBytes(metadata)
            } else {
                failed += 1
                messages.append("Failed to unlink Agent resource: " + path)
            }
            close(directoryFD)
        }
        return ApplySummary(removed: removed, skipped: skipped, failed: failed,
                            messages: messages, removedPaths: removedPaths, reclaimedBytes: reclaimedBytes)
    }

    private struct LiveCacheCleanupResult {
        // Only aliases whose metadata has already been enumerated need a
        // known-ctime adjustment after our own unlink. Never waive an
        // unrelated later update to a multiply-linked inode.
        var pendingLinkSnapshots: [FileIdentity: Int] = [:]
        var knownAliasMetadata: [FileIdentity: stat] = [:]
        var removedPaths = Set<String>()
        var skippedPaths = Set<String>()
        var failedPaths = Set<String>()
        var messages: [String] = []
        var reclaimedBytes: UInt64 = 0

        mutating func skip(_ path: String, _ message: String) {
            if skippedPaths.insert(path).inserted { messages.append(message + path) }
        }

        mutating func fail(_ path: String) {
            let error = errno
            if failedPaths.insert(path).inserted {
                messages.append("Failed secure removal of \(path): \(String(cString: strerror(error)))")
            }
        }
    }

    private struct LiveCacheEntry {
        let name: String
        let metadata: stat
    }

    /// A cache directory remains the same authorized object as its contents
    /// change. Files and all non-live targets retain the full planned identity.
    static func matchesCleanupIdentity(_ metadata: stat, expected: String,
                                              allowingDirectoryContentChanges: Bool) -> Bool {
        let parts = expected.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let device = UInt64(parts[0]),
              let inode = UInt64(parts[1]), let modified = Int64(parts[2]),
              UInt64(metadata.st_dev) == device, UInt64(metadata.st_ino) == inode else { return false }
        return allowingDirectoryContentChanges && metadata.st_mode & S_IFMT == S_IFDIR
            || Int64(metadata.st_mtimespec.tv_sec) == modified
    }

    private static func sameCleanupEntry(_ lhs: stat, _ rhs: stat,
                                         allowingDirectoryContentChanges: Bool = false,
                                         checkingChangeTime: Bool = false) -> Bool {
        guard lhs.st_dev == rhs.st_dev, lhs.st_ino == rhs.st_ino,
              lhs.st_mode == rhs.st_mode, lhs.st_uid == rhs.st_uid,
              lhs.st_gid == rhs.st_gid, lhs.st_flags == rhs.st_flags else { return false }
        if allowingDirectoryContentChanges && lhs.st_mode & S_IFMT == S_IFDIR { return true }
        return lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec && lhs.st_size == rhs.st_size
            && (!checkingChangeTime || (lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
                && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec))
    }

    /// Completed roots are literal paths, even when their names contain glob
    /// characters. Ancestor lookup keeps continuation work proportional to
    /// path depth rather than the number of roots already checked.
    private static func isCoveredByScannedRoot(_ path: String, roots: Set<String>) -> Bool {
        guard !roots.isEmpty else { return false }
        var ancestor = path[...]
        while !ancestor.isEmpty {
            if roots.contains(String(ancestor)) { return true }
            guard let separator = ancestor.lastIndex(of: "/") else { return false }
            ancestor = ancestor[..<separator]
        }
        return roots.contains("/")
    }

    /// Unlike the scan's ancestor guard, a whitelist entry beneath this path
    /// protects that child during traversal, rather than freezing its siblings.
    private func directlyMatchesWhitelist(_ path: String, entries: [String]) -> Bool {
        entries.contains { entry in
            path == entry || (Self.whitelistEntryHasGlob(entry) && fnmatch(entry, path, 0) == 0)
                || (!Self.whitelistEntryHasGlob(entry) && path.hasPrefix(entry + "/"))
        }
    }

    private func cleanLiveCacheDirectory(_ path: String, expectedIdentity: String,
                                        expectedMetadata: stat, whitelist: [String], openFiles: Set<String>,
                                        blockedFamilyMembers: Set<String>,
                                        homeDirectory: String,
                                        onCurrentFile: ((String) -> Void)?) -> LiveCacheCleanupResult {
        var result = LiveCacheCleanupResult()
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2 else {
            result.skip(path, "Skipped outside authorized roots: ")
            return result
        }
        var parentFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { result.fail(path); return result }
        for component in components.dropLast() {
            let next = openat(parentFD, component, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            close(parentFD)
            parentFD = next
            if next < 0 { result.fail(path); return result }
        }
        defer { close(parentFD) }
        let targetFD = openat(parentFD, components.last!, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard targetFD >= 0 else { result.fail(path); return result }
        defer { close(targetFD) }
        var target = stat()
        guard fstat(targetFD, &target) == 0,
              Self.sameCleanupEntry(expectedMetadata, target, allowingDirectoryContentChanges: true),
              Self.matchesCleanupIdentity(target, expected: expectedIdentity,
                                          allowingDirectoryContentChanges: true),
              cleanupDeletionAccess(path, metadata: target) == .user,
              !systemCleanupRequiresAdministrator(path, metadata: target, homeDirectory: homeDirectory),
              systemCleanupOwnerEligible(path, metadata: target, homeDirectory: homeDirectory) else {
            result.skip(path, "Skipped changed or unavailable path: ")
            return result
        }
        // Retain the cache root even when empty. Running applications can
        // continue using their directory without having to recreate its path.
        _ = cleanLiveCacheContents(of: targetFD, path: path, device: target.st_dev,
            cacheRoot: path,
            whitelist: whitelist, openFiles: openFiles, blockedFamilyMembers: blockedFamilyMembers,
            homeDirectory: homeDirectory, depth: 0, result: &result, onCurrentFile: onCurrentFile)
        return result
    }

    /// Enumerate under an already verified descriptor. Metadata belongs to
    /// these exact entries, and is checked again immediately before unlinkat.
    private func liveCacheEntries(in directoryFD: Int32, path: String, homeDirectory: String,
                                  shouldStop: (() -> Bool)? = nil,
                                  onEntry: ((String) -> Void)? = nil) -> [LiveCacheEntry]? {
        let streamFD = dup(directoryFD)
        guard streamFD >= 0 else { return nil }
        // Darwin fdopendir can fill its directory buffer immediately, before
        // the first readdir. Bind that successful read separately as well.
        let openingInspection = beginCleanupInspection(path, fd: directoryFD,
                                                        homeDirectory: homeDirectory)
        let openedStream = fdopendir(streamFD)
        let openingError = errno
        finishCleanupInspection(openingInspection, path: path, fd: directoryFD,
                                succeeded: openedStream != nil)
        guard let stream = openedStream else {
            close(streamFD); errno = openingError
            return nil
        }
        defer { closedir(stream) }
        let rewindInspection = beginCleanupInspection(path, fd: directoryFD,
                                                       homeDirectory: homeDirectory)
        rewinddir(stream)
        finishCleanupInspection(rewindInspection, path: path, fd: directoryFD, succeeded: true)
        var entries: [LiveCacheEntry] = []
        while true {
            let inspection = beginCleanupInspection(path, fd: directoryFD, homeDirectory: homeDirectory)
            errno = 0
            let entry = readdir(stream)
            let readError = errno
            finishCleanupInspection(inspection, path: path, fd: directoryFD,
                                    succeeded: entry != nil || readError == 0)
            guard let entry else {
                guard readError == 0 else { errno = readError; return nil }
                break
            }
            if shouldStop?() == true { return nil }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            onEntry?(name)
            var metadata = stat()
            guard fstatat(directoryFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                // A concurrently removed entry is no longer garbage to clean.
                if errno == ENOENT { errno = 0; continue }
                return nil
            }
            entries.append(LiveCacheEntry(name: name, metadata: metadata))
        }
        return entries.sorted { $0.name < $1.name }
    }

    func isProtectedLiveCacheItem(_ path: String, cacheRoot: String,
                                         homeDirectory: String,
                                         rootIsVerifiedRebuildable: Bool = false) -> Bool {
        let browserRoot = CleanupRiskPolicy.auditedRebuildableRoot(containing: cacheRoot, homeDirectory: homeDirectory)
            ?? verifiedBrowserCacheRoot(containing: cacheRoot, homeDirectory: homeDirectory)
        return isCleanupLockItem(path)
            || (CleanupRiskPolicy.systemCleanupKind(for: cacheRoot, homeDirectory: homeDirectory) != nil
                && CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: homeDirectory) == nil)
            || CleanupRiskPolicy.isProtectedCleanupPath(path, homeDirectory: homeDirectory,
            rebuildableRoot: browserRoot ?? cacheRoot, rootIsVerifiedRebuildable: rootIsVerifiedRebuildable
                || browserRoot != nil)
    }

    /// Browser profiles are durable containers, but these precise leaf roots
    /// are regenerable caches. A Service Worker database is never one of them.
    private func isVerifiedBrowserCacheRoot(_ path: String, homeDirectory: String) -> Bool {
        verifiedBrowserCacheRoot(containing: path, homeDirectory: homeDirectory) != nil
    }

    private func verifiedBrowserCacheRoot(containing path: String, homeDirectory: String) -> String? {
        let home = CleanupRiskPolicy.normalizedPathLiteral(homeDirectory)
        let cacheLeaves: Set<String> = ["Cache", "Code Cache", "GPUCache", "DawnCache",
            "GrShaderCache", "Media Cache", "ShaderCache"]
        for browser in ["Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser", "Arc/User Data"] {
            let prefix = home + "/Library/Application Support/" + browser + "/"
            guard path.hasPrefix(prefix) else { continue }
            let components = String(path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
            guard components.count >= 2 else { continue }
            let rootCount: Int
            if cacheLeaves.contains(components[1]) { rootCount = 2 }
            else if components.count >= 3 && components[1] == "Service Worker"
                && ["CacheStorage", "ScriptCache"].contains(components[2]) { rootCount = 3 }
            else { continue }
            // Cached inventories can contain a split descendant. Keep the
            // actual browser cache boundary so durable ancestors inside that
            // cache are never discarded by rebasing the selected child.
            let cacheRoot = prefix + components.prefix(rootCount).joined(separator: "/")
            let descriptor = CleanupRiskPolicy.core(section: "Cache", path: path, homeDirectory: home)
            if descriptor.risk == .safe && descriptor.disposal == .permanentDelete { return cacheRoot }
        }
        return nil
    }

    private func isCleanupLockItem(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        if [".open", "lock", ".lock", "singletonlock", "singletoncookie", "singletonsocket"].contains(name) {
            return true
        }
        guard ["open", "lock"].contains(url.pathExtension.lowercased()) else { return false }
        var metadata = stat()
        // Reverse-DNS cache directories can legitimately end in ".open".
        // Extension-based lock protection applies to leaf files only.
        return lstat(path, &metadata) != 0 || metadata.st_mode & S_IFMT != S_IFDIR
    }

    private static func reclaimableLeafBytes(_ metadata: stat) -> UInt64 {
        let kind = metadata.st_mode & S_IFMT
        guard (kind == S_IFREG || kind == S_IFLNK), metadata.st_nlink <= 1 else { return 0 }
        return UInt64(max(0, metadata.st_blocks)) * 512
    }

    private func sqliteHeader(in fd: Int32, path: String, homeDirectory: String) -> Bool? {
        var header = [UInt8](repeating: 0, count: 16)
        let inspection = beginCleanupInspection(path, fd: fd, homeDirectory: homeDirectory)
        let count = pread(fd, &header, header.count, 0)
        let readError = errno
        finishCleanupInspection(inspection, path: path, fd: fd, succeeded: count >= 0)
        guard count >= 0 else { errno = readError; return nil }
        return count == 16 && header == Array("SQLite format 3\0".utf8)
    }

    private static func sameLiveCacheEntry(_ expected: stat, _ current: stat,
                                          knownAliases: [FileIdentity: stat]) -> Bool {
        if sameCleanupEntry(expected, current, checkingChangeTime: true) { return true }
        let identity = FileIdentity(device: UInt64(expected.st_dev), inode: UInt64(expected.st_ino))
        guard expected.st_mode & S_IFMT == S_IFREG, expected.st_nlink > 1,
              let known = knownAliases[identity], current.st_nlink == known.st_nlink,
              current.st_nlink < expected.st_nlink,
              sameCleanupEntry(expected, current),
              sameCleanupEntry(known, current, checkingChangeTime: true) else { return false }
        return true
    }

    /// Return whether all entries were removed. An open directory is kept as
    /// an empty shell while unused files beneath it can still be reclaimed.
    private func cleanLiveCacheContents(of directoryFD: Int32, path: String, device: dev_t,
                                        cacheRoot: String,
                                        whitelist: [String], openFiles: Set<String>,
                                        blockedFamilyMembers: Set<String>, homeDirectory: String, depth: Int,
                                        result: inout LiveCacheCleanupResult,
                                        onCurrentFile: ((String) -> Void)?) -> Bool {
        guard depth < 128 else {
            result.skip(path, "Skipped protected content: ")
            return false
        }
        guard let entries = liveCacheEntries(in: directoryFD, path: path,
                                            homeDirectory: homeDirectory) else { result.fail(path); return false }
        for entry in entries where entry.metadata.st_mode & S_IFMT == S_IFREG && entry.metadata.st_nlink > 1 {
            let identity = FileIdentity(device: UInt64(entry.metadata.st_dev), inode: UInt64(entry.metadata.st_ino))
            result.pendingLinkSnapshots[identity, default: 0] += 1
        }
        var allRemoved = true
        for entry in entries {
            let linkIdentity = FileIdentity(device: UInt64(entry.metadata.st_dev), inode: UInt64(entry.metadata.st_ino))
            let registeredLink = entry.metadata.st_mode & S_IFMT == S_IFREG && entry.metadata.st_nlink > 1
            defer {
                if registeredLink {
                    let remaining = (result.pendingLinkSnapshots[linkIdentity] ?? 1) - 1
                    if remaining > 0 { result.pendingLinkSnapshots[linkIdentity] = remaining }
                    else {
                        result.pendingLinkSnapshots.removeValue(forKey: linkIdentity)
                        result.knownAliasMetadata.removeValue(forKey: linkIdentity)
                    }
                }
            }
            let child = path + "/" + entry.name
            onCurrentFile?(child)
            guard DeletionPlan.isLexicallySafePath(child), entry.metadata.st_dev == device else {
                result.skip(child, "Skipped outside authorized roots: ")
                allRemoved = false
                continue
            }
            guard !isProtectedLiveCacheItem(child, cacheRoot: cacheRoot, homeDirectory: homeDirectory,
                                           rootIsVerifiedRebuildable: true),
                  !blockedFamilyMembers.contains(child) else {
                result.skip(child, "Skipped protected content: ")
                allRemoved = false
                continue
            }
            guard !directlyMatchesWhitelist(child, entries: whitelist) else {
                result.skip(child, "Skipped path protected by whitelist: ")
                allRemoved = false
                continue
            }
            let isSystemPath = CleanupRiskPolicy.systemCleanupKind(for: child, homeDirectory: homeDirectory) != nil
            let systemEligible = systemCleanupMetadataEligible(child, metadata: entry.metadata, homeDirectory: homeDirectory)
            if isSystemPath {
                var account = stat()
                guard lstat(homeDirectory, &account) == 0,
                      CleanupRiskPolicy.systemCleanupAccountScopeEligible(path: child, homeDirectory: homeDirectory),
                      entry.metadata.st_uid == account.st_uid || entry.metadata.st_uid == 0 else {
                    result.skip(child, "Skipped foreign-owned system content: ")
                    allRemoved = false
                    continue
                }
            }
            guard entry.metadata.st_mode & S_IFMT == S_IFDIR || !isSystemPath || systemEligible else {
                result.skip(child, "Skipped recent or foreign-owned system content: ")
                allRemoved = false
                continue
            }
            guard cleanupDeletionAccess(child, metadata: entry.metadata) == .user,
                  !systemCleanupRequiresAdministrator(child, metadata: entry.metadata, homeDirectory: homeDirectory) else {
                result.skip(child, "Skipped content that requires administrator access or cannot be deleted: ")
                allRemoved = false
                continue
            }
            let isDirectory = entry.metadata.st_mode & S_IFMT == S_IFDIR
            if !isDirectory && openFiles.contains(child)
                && CleanupRiskPolicy.systemCleanupKind(for: child, homeDirectory: homeDirectory) != .powerlogTelemetry {
                result.skip(child, "Skipped while the path is open: ")
                allRemoved = false
                continue
            }
            if isDirectory {
                let childFD = openat(directoryFD, entry.name,
                                     O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
                guard childFD >= 0 else { result.fail(child); allRemoved = false; continue }
                var current = stat()
                let same = fstat(childFD, &current) == 0
                    && Self.sameCleanupEntry(entry.metadata, current, allowingDirectoryContentChanges: true)
                guard same else {
                    close(childFD)
                    result.skip(child, "Skipped changed or unavailable path: ")
                    allRemoved = false
                    continue
                }
                let emptied = cleanLiveCacheContents(of: childFD, path: child, device: device,
                    cacheRoot: cacheRoot,
                    whitelist: whitelist, openFiles: openFiles, blockedFamilyMembers: blockedFamilyMembers,
                    homeDirectory: homeDirectory, depth: depth + 1, result: &result,
                    onCurrentFile: onCurrentFile)
                close(childFD)
                if !emptied || openFiles.contains(child) || (isSystemPath && !systemEligible) { allRemoved = false; continue }
                guard fstatat(directoryFD, entry.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      Self.sameCleanupEntry(entry.metadata, current, allowingDirectoryContentChanges: true),
                      !isSystemPath || systemCleanupDirectoryEdgeEligible(child, original: entry.metadata,
                          current: current, homeDirectory: homeDirectory) else {
                    result.skip(child, "Skipped changed or unavailable path: ")
                    allRemoved = false
                    continue
                }
                let parentBefore = directoryInspectionSnapshot(path, fd: directoryFD)
                if unlinkat(directoryFD, entry.name, AT_REMOVEDIR) == 0 {
                    result.removedPaths.insert(child)
                    recordCleanupDirectoryMutation(path, fd: directoryFD, before: parentBefore)
                }
                else if errno == ENOTEMPTY {
                    result.skip(child, "Skipped changed or unavailable path: ")
                    allRemoved = false
                } else { result.fail(child); allRemoved = false }
                continue
            }
            let kind = entry.metadata.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFLNK else {
                result.skip(child, "Skipped protected content: ")
                allRemoved = false
                continue
            }
            var regularFD: Int32 = -1
            defer { if regularFD >= 0 { close(regularFD) } }
            if kind == S_IFREG {
                regularFD = openat(directoryFD, entry.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard regularFD >= 0 else { result.fail(child); allRemoved = false; continue }
                var current = stat()
                let same = fstat(regularFD, &current) == 0
                    && Self.sameLiveCacheEntry(entry.metadata, current, knownAliases: result.knownAliasMetadata)
                let database = same ? sqliteHeader(in: regularFD, path: child,
                                                   homeDirectory: homeDirectory) : nil
                guard same else {
                    result.skip(child, "Skipped changed or unavailable path: ")
                    allRemoved = false
                    continue
                }
                guard let database else { result.fail(child); allRemoved = false; continue }
                if database && !CleanupRiskPolicy.isArchivedPowerlogPath(child)
                    && !CleanupRiskPolicy.isPowerlogTelemetryPath(child) {
                    result.skip(child, "Skipped protected content: ")
                    allRemoved = false
                    continue
                }
            }
            var current = stat()
            guard fstatat(directoryFD, entry.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.sameLiveCacheEntry(entry.metadata, current, knownAliases: result.knownAliasMetadata),
                  !isSystemPath || systemCleanupMetadataEligible(child, metadata: current, homeDirectory: homeDirectory) else {
                result.skip(child, "Skipped changed or unavailable path: ")
                allRemoved = false
                continue
            }
            let parentBefore = directoryInspectionSnapshot(path, fd: directoryFD)
            if unlinkat(directoryFD, entry.name, 0) == 0 {
                result.removedPaths.insert(child)
                result.reclaimedBytes &+= Self.reclaimableLeafBytes(current)
                recordCleanupDirectoryMutation(path, fd: directoryFD, before: parentBefore)
                if regularFD >= 0, current.st_nlink > 1,
                   (result.pendingLinkSnapshots[linkIdentity] ?? 0) > 1 {
                    var after = stat()
                    if fstat(regularFD, &after) == 0, after.st_nlink == current.st_nlink - 1,
                       Self.sameCleanupEntry(current, after) {
                        result.knownAliasMetadata[linkIdentity] = after
                    } else { result.knownAliasMetadata.removeValue(forKey: linkIdentity) }
                }
            }
            else { result.fail(child); allRemoved = false }
        }
        if allRemoved {
            guard let remaining = liveCacheEntries(in: directoryFD, path: path,
                                                   homeDirectory: homeDirectory) else { result.fail(path); return false }
            if !remaining.isEmpty {
                for entry in remaining {
                    result.skip(path + "/" + entry.name, "Skipped changed or unavailable path: ")
                }
                allRemoved = false
            }
        }
        return allRemoved
    }

    /// `device:inode:mtime` 身份串的前两个字段。
    private static func parseIdentity(_ identity: String) -> (device: UInt64, inode: UInt64)? {
        let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let device = UInt64(parts[0]),
              let inode = UInt64(parts[1]) else { return nil }
        return (device, inode)
    }

    private struct RemovalAccounting {
        var removedPaths = Set<String>()
        var reclaimedBytes: UInt64 = 0

        mutating func record(_ path: String, metadata: stat) {
            guard removedPaths.insert(path).inserted else { return }
            reclaimedBytes &+= NativeCore.reclaimableLeafBytes(metadata)
        }
    }

    /// 逐级 openat(O_NOFOLLOW|O_DIRECTORY) 打开到目标的父目录，再打开目标
    /// 本身并核对 (device, inode)。链上任何一级是符号链接（openat 失败）或
    /// 身份不一致都返回 false，不做任何删除。
    private func removeTreeSecurely(_ path: String,
                                    expectedDevice: UInt64,
                                    expectedInode: UInt64,
                                    expectedMetadata: stat,
                                    expectedIdentity: String,
                                    homeDirectory: String,
                                    accounting: inout RemovalAccounting,
                                    onCurrentFile: ((String) -> Void)?) -> Bool {
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
        defer { close(directoryFD) }
        guard opened else { return false }

        let leaf = components[components.count - 1]
        let targetFD = openat(directoryFD, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard targetFD >= 0 else { return false }
        defer { close(targetFD) }
        var target = stat()
        guard fstat(targetFD, &target) == 0 else { return false }
        guard UInt64(target.st_dev) == expectedDevice,
              UInt64(target.st_ino) == expectedInode,
              Self.sameCleanupEntry(expectedMetadata, target, checkingChangeTime: true),
              Self.matchesCleanupIdentity(target, expected: expectedIdentity, allowingDirectoryContentChanges: false),
              systemCleanupMetadataEligible(path, metadata: target, homeDirectory: homeDirectory) else {
            errno = ESTALE
            return false
        }

        if (target.st_mode & S_IFMT) == S_IFDIR {
            guard removeContents(of: targetFD, path: path, accounting: &accounting,
                                 onCurrentFile: onCurrentFile) else { return false }
        }
        var current = stat()
        guard fstatat(directoryFD, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameCleanupEntry(target, current, allowingDirectoryContentChanges: target.st_mode & S_IFMT == S_IFDIR,
                                    checkingChangeTime: true),
              systemCleanupMetadataEligible(path, metadata: current, homeDirectory: homeDirectory) else {
            errno = ESTALE
            return false
        }
        guard unlinkat(directoryFD, leaf, (target.st_mode & S_IFMT) == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
            return false
        }
        accounting.record(path, metadata: current)
        return true
    }

    /// 在已打开的目录描述符下清空全部内容。不跟随符号链接：链接本身作为
    /// 一个条目被 unlink，指向的外部内容不受影响。
    private func removeContents(of directoryFD: Int32, path: String,
                                accounting: inout RemovalAccounting,
                                onCurrentFile: ((String) -> Void)?) -> Bool {
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
            let childPath = path + "/" + name
            onCurrentFile?(childPath)
            guard !isCleanupLockItem(childPath) else { errno = EBUSY; return false }
            var entryStat = stat()
            guard fstatat(directoryFD, name, &entryStat, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            let isDirectory = (entryStat.st_mode & S_IFMT) == S_IFDIR
            if isDirectory {
                let childFD = openat(directoryFD, name,
                                     O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
                var opened = stat()
                guard childFD >= 0, fstat(childFD, &opened) == 0,
                      Self.sameCleanupEntry(entryStat, opened, allowingDirectoryContentChanges: true),
                      removeContents(of: childFD, path: childPath, accounting: &accounting,
                                     onCurrentFile: onCurrentFile) else {
                    if childFD >= 0 { close(childFD) }
                    return false
                }
                close(childFD)
            }
            var current = stat()
            guard fstatat(directoryFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.sameCleanupEntry(entryStat, current, allowingDirectoryContentChanges: true) else {
                errno = ESTALE
                return false
            }
            if unlinkat(directoryFD, name, isDirectory ? AT_REMOVEDIR : 0) != 0 {
                return false
            }
            accounting.record(childPath, metadata: current)
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
            return UninstallPlan(files: files, needsAdmin: self.uninstallRequiresAdministrator(app.path),
                                 isBrewCask: caskToken != nil,
                                 caskToken: caskToken ?? "-", includesProtectedAppData: true,
                                 scannedAt: Date())
        }.value
    }

    func uninstallRequiresAdministrator(_ path: String) -> Bool {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return false }
        return geteuid() != 0 && (metadata.st_uid == 0
            || cleanupDeletionAccess(path, metadata: metadata) == .administrator)
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
    /// 没有登记在 Agent 目录里的 App 也常把数据放在 `~/.name`、`~/.config/name` 等处
    /// （例如 WorkBuddy 的 `~/.workbuddy`）。按 App 名和 Bundle ID 末段关联，名字太短、
    /// 太通用或与其他已安装 App 重名的不关联；Agent 目录已登记的根交给 Agent 规则。
    static let genericDotNames: Set<String> = [
        "config", "local", "cache", "share", "state", "apps", "code", "git", "ssh", "npm",
        "node", "python", "java", "rust", "cargo", "docker", "aws", "azure", "google", "apple",
        "macos", "system", "library", "data", "tools", "home", "user", "users",
        "test", "demo", "default", "lite", "beta", "studio", "desktop", "mail",
        "music", "photos", "notes", "files", "cloud", "sync", "update", "updater", "helper"
    ]

    func dotDirectoryCandidates(for app: UninstallApp, home: URL, otherApps: [URL]) -> [URL] {
        let appURL = URL(fileURLWithPath: app.path)
        var names = Set(uninstallSupportNames(at: appURL, bundleID: app.bundleID).map { $0.lowercased() })
        names.insert(app.name.lowercased())
        names.insert(app.name.lowercased().replacingOccurrences(of: " ", with: ""))
        names.insert(app.name.lowercased().replacingOccurrences(of: " ", with: "-"))
        if let last = app.bundleID.split(separator: ".").last { names.insert(String(last).lowercased()) }
        let shared = Set(otherApps.flatMap { other -> [String] in
            guard let metadata = applicationMetadata(at: other) else { return [] }
            var tokens = uninstallSupportNames(at: other, bundleID: metadata.bundleID).map { $0.lowercased() }
            tokens.append(metadata.name.lowercased())
            if let last = metadata.bundleID.split(separator: ".").last { tokens.append(String(last).lowercased()) }
            return tokens
        })
        let agentRoots = AgentCatalog.definitions.flatMap { AgentCatalog.dataRoots(for: $0, home: home.path) }
        var result: [URL] = []
        for name in names.sorted() where name.count >= 4 && !Self.genericDotNames.contains(name)
            && !shared.contains(name) && name.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil {
            for relative in ["." + name, ".config/" + name, ".local/share/" + name, ".local/state/" + name, ".cache/" + name] {
                let url = home.appendingPathComponent(relative, isDirectory: true)
                guard cleanupPathIsPhysical(url, home: home), isDirectory(url),
                      !agentRoots.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") || $0.hasPrefix(url.path + "/") })
                else { continue }
                result.append(url)
            }
        }
        return result
    }

    private func relatedUninstallCandidates(app: UninstallApp, home: URL,
                                            hasSibling: Bool, otherApps: [URL]) -> [UninstallFile] {
        var candidates: [UninstallFile] = []
        var seen = Set<String>()
        func append(_ url: URL, label: String) {
            let path = CleanupRiskPolicy.normalizedPathLiteral(url.path)
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
        if !hasSibling {
            for root in AgentCatalog.uninstallDataRoots(appPath: app.path, appName: app.name, home: home.path) {
                append(URL(fileURLWithPath: root), label: "review")
            }
            for url in dotDirectoryCandidates(for: app, home: home, otherApps: otherApps) {
                append(url, label: "review")
            }
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

    func applyUninstall(_ app: UninstallApp, plan reviewedPlan: UninstallPlan,
                        homeDirectory: String = NSHomeDirectory(),
                        appAlreadyRemoved: Bool = false,
                        includingData: Set<String> = []) -> ApplySummary {
        let plan = reviewedPlan.includingData(includingData)
        if appAlreadyRemoved {
            guard !fileManager.fileExists(atPath: app.path), !isSymlink(URL(fileURLWithPath: app.path)) else {
                return ApplySummary(removed: 0, skipped: 0, failed: 1,
                                    messages: ["Application reappeared after administrator removal."])
            }
        } else {
            guard DeletionPlan.identity(at: app.path) == app.appIdentity,
                  DeletionPlan.identity(at: app.path + "/Contents/Info.plist") == app.infoIdentity else {
                return ApplySummary(removed: 0, skipped: 0, failed: 1,
                                    messages: ["Application changed since it was scanned."])
            }
            guard !isOwnedByRunningApplication(path: app.path, homeDirectory: homeDirectory) else {
                return ApplySummary(removed: 0, skipped: 1, failed: 1,
                                    messages: ["The application is still running."])
            }
        }
        var appRemovedByBrew = appAlreadyRemoved
        if plan.isBrewCask && !appAlreadyRemoved {
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
                                  allowedRoots: [app.path], allowApplicationBundle: true,
                                  verifiedTargets: includingData.intersection(reviewedPlan.dataPaths))
        if appRemovedByBrew {
            result = ApplySummary(removed: result.removed + 1, skipped: result.skipped,
                                  failed: result.failed, messages: result.messages,
                                  removedPaths: result.removedPaths.union([app.path]))
        }
        if missing > 0 {
            result = ApplySummary(removed: result.removed, skipped: result.skipped + missing,
                                  failed: result.failed,
                                  messages: result.messages + ["Some uninstall paths had no confirmed identity or physical path."],
                                  removedPaths: result.removedPaths)
        }
        let appURL = URL(fileURLWithPath: app.path)
        if fileManager.fileExists(atPath: app.path) || isSymlink(appURL) {
            result = ApplySummary(removed: result.removed, skipped: result.skipped,
                                  failed: max(result.failed, 1),
                                  messages: result.messages + ["The application bundle was not removed."],
                                  removedPaths: result.removedPaths)
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
            return (.unchanged, L10n.shared.t("audit.maintenance.quarantine.missing"))
        }
        guard !matchesWhitelist(database.path, entries: loadWhitelist(homeDirectory: homeDirectory)) else {
            return (.unchanged, L10n.shared.t("audit.maintenance.whitelisted"))
        }
        let sqlite = "/usr/bin/sqlite3"
        guard fileManager.isExecutableFile(atPath: sqlite) else {
            return (.unavailable, L10n.shared.t("audit.maintenance.sqlite.macosUnavailable"))
        }
        guard let raw = runCommandOutput(sqlite, [database.path, "SELECT COUNT(*) FROM LSQuarantineEvent;"]),
              let count = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return (.failed, L10n.shared.t("audit.maintenance.quarantine.unreadable"))
        }
        guard count > 0 else { return (.unchanged, L10n.shared.t("audit.maintenance.quarantine.alreadyEmpty")) }
        guard runCommand(sqlite, [database.path, "DELETE FROM LSQuarantineEvent; VACUUM;"]) else {
            return (.failed, L10n.shared.t("audit.maintenance.quarantine.failed"))
        }
        return (.applied, L10n.shared.tf("audit.maintenance.quarantine.success", count))
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
        let path = CleanupRiskPolicy.normalizedPathLiteral(url.path)
        guard path != home.path, path.hasPrefix(home.path + "/")
            || CleanupRiskPolicy.systemCleanupKind(for: path, homeDirectory: home.path) != nil else { return false }
        return CleanupRiskPolicy.discardedEntryRoot(containing: path, homeDirectory: home.path) != nil
            || !isProtectedCleanupItem(url, homeDirectory: home.path, rebuildableRoot: path)
    }

    private func isProtectedCleanupItem(_ url: URL,
                                        allowApplicationBundle: Bool = false,
                                        homeDirectory: String = NSHomeDirectory(),
                                        rebuildableRoot: String? = nil,
                                        rootIsVerifiedRebuildable: Bool = false) -> Bool {
        let browserRoot = rebuildableRoot.flatMap {
            CleanupRiskPolicy.auditedRebuildableRoot(containing: $0, homeDirectory: homeDirectory)
                ?? verifiedBrowserCacheRoot(containing: $0, homeDirectory: homeDirectory)
        }
        return CleanupRiskPolicy.isProtectedCleanupPath(url.path, homeDirectory: homeDirectory,
            rebuildableRoot: browserRoot ?? rebuildableRoot, rootIsVerifiedRebuildable: rootIsVerifiedRebuildable
                || browserRoot != nil,
            allowApplicationBundle: allowApplicationBundle)
    }

    /// Read `~/.config/mole/whitelist` with the same grammar Mole's
    /// `load_mole_whitelist` accepts: `~`, `$HOME` and `${HOME}` prefixes,
    /// shell globs (`*`, `?`, `[...]`), comments, and no `..` traversal. A file
    /// written by `mo clean --whitelist` therefore protects the native route
    /// exactly like it protects the CLI and the bridge scripts.
    func loadWhitelist(homeDirectory: String) -> [String] {
        let home = CleanupRiskPolicy.normalizedPathLiteral(homeDirectory)
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
    /// JetBrains indexes are slow to rebuild, Ollama
    /// models and iCloud Drive are user data, Surge holds licences.
    static func defaultWhitelistPatterns(home: String) -> [String] {
        [
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

    private func isOwnedByRunningApplication(path: String,
                                              homeDirectory: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleURL = application.bundleURL?.standardizedFileURL.path,
                  let identifier = application.bundleIdentifier,
                  !identifier.isEmpty else { continue }
            let cachePath = homeDirectory + "/Library/Caches/" + identifier
            let logPath = homeDirectory + "/Library/Logs/" + identifier
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
        currentOpenFileRecords().map { Set($0.map(\.path)) }
    }

    private func currentOpenFileRecords() -> [OpenFileRecord]? {
        if let cleanupOpenFileRecordsProbe { return cleanupOpenFileRecordsProbe() }
        let executable = "/usr/sbin/lsof"
        guard fileManager.isExecutableFile(atPath: executable) else { return nil }
        var arguments = ["-O", "-nP", "-F", "pcfan"]
        // An administrator worker operates on the requesting user's home,
        // so a root-only owner filter would miss every user's occupied file.
        if geteuid() != 0 { arguments.append(contentsOf: ["-a", "-u", NSUserName()]) }
        guard let text = SystemMetrics.commandOutput(executable,
            arguments: arguments) else { return nil }
        return Self.openFileRecords(from: text)
    }

    static func openFileRecords(from text: String) -> [OpenFileRecord] {
        var records: [OpenFileRecord] = []
        var pid: Int32 = 0
        var process = "", descriptor = "", access = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let value = String(line.dropFirst())
            switch line.first {
            case "p":
                pid = Int32(value) ?? 0
                process = ""; descriptor = ""; access = ""
            case "c": process = value
            case "f": descriptor = value; access = ""
            case "a": access = value
            case "n":
                guard value.hasPrefix("/") else { continue }
                records.append(.init(pid: pid, process: process, descriptor: descriptor,
                    access: access, path: CleanupRiskPolicy.canonicalOpenFilePath(value)))
            default: break
            }
        }
        return records
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
