import Foundation

/// 原生采集的系统指标快照。
///
/// 基础指标用于主窗口和灵动岛；其余字段给状态面板和后续 JSON 导出
/// 使用。所有字段都有安全的零值，采集失败不会阻塞主界面。
struct MetricsSnapshot: Equatable, Sendable {
    var collectedAt: Date = Date()
    var cpuPercent: Double = 0
    var loadAverage: [Double] = []
    var logicalCPUCount: Int = 0
    var physicalCPUCount: Int = 0
    var memoryPercent: Double = 0
    var memoryUsedBytes: UInt64 = 0
    var memoryTotalBytes: UInt64 = 0
    var memoryAvailableBytes: UInt64 = 0
    var memoryPressure: String = "unknown"
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var diskFreeBytes: UInt64 = 0
    var diskUsedPercent: Double = 0
    var diskReadMBps: Double = 0
    var diskWriteMBps: Double = 0
    var batteryPercent: Double = 0
    var batteryHealthPercent: Double = 0
    var batteryCycleCount: Int = 0
    var batteryCharging: Bool = false
    var networkRxMBps: Double = 0
    var networkTxMBps: Double = 0
    var uptimeSeconds: UInt64 = 0
    var healthScore: Int = 0

    /// 1 分钟负载；采集失败时按 0。
    var loadOneMinute: Double { loadAverage.first ?? 0 }

    /// 有电量、充电、循环或健康度任一信号才认为这台机器有电池。
    var batteryPresent: Bool {
        batteryPercent > 0 || batteryCharging || batteryCycleCount > 0 || batteryHealthPercent > 0
    }
}

/// 清理扫描的实时状态。进度按原生目录遍历的已完成条目计算，currentPath
/// 只保留当前正在处理的目录，避免将每个文件写入日志而拖慢扫描。
struct CleanupScanProgress: Equatable, Sendable {
    var phase: String = ""
    var completed: Int = 0
    var total: Int = 0
    var currentPath: String = ""
    var isComplete: Bool = false
    /// Detailed count reported by the native directory walker.
    var detailCompleted: Int = 0
    var detailTotal: Int = 0

    var fraction: Double? {
        guard total > 0 else { return nil }
        let raw = min(1, max(0, Double(completed) / Double(total)))
        return raw
    }
}

enum CleanupSource: String, Codable, CaseIterable, Hashable, Sendable {
    case core
    case appLeftover
    case installer
    case developerCache
    case tool
    case aiSession
    case aiCache
    case aiModel
    case xcodeCache
    case xcodeArchive
    case unknown
}

enum CleanupRisk: String, Codable, CaseIterable, Hashable, Sendable {
    case safe
    case warning
    case protected
}

/// 候选内容的处置动作。命名与执行器的实际行为一致：清理页的删除路由执行
/// 永久删除（`NativeCore.applyCleanup(permanent: true)`）；移入废纸篓只发生
/// 在卸载等显式传入 non-permanent 的流程。旧快照里的 "trash" 解码为
/// permanentDelete，行为不变。
enum CleanupDisposal: String, Codable, CaseIterable, Hashable, Sendable {
    case permanentDelete
    case command
    case none

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "permanentDelete", "trash": self = .permanentDelete
        case "command": self = .command
        default: self = .none
        }
    }
}

enum CleanupApplyRoute: String, Codable, CaseIterable, Hashable, Sendable {
    case genericTrash
    case installerTrash
    case developerCacheTrash
    case aiTrash
    case xcodeTrash
    case toolCommand
    case none
}

/// 扫描时和最终执行前都要重新判断的运行态保护。
enum CleanupActivityGuard: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    /// 路径没有稳定的 Bundle ID，但执行边界仍会用一次批量打开文件快照复核。
    case openFile
    case reverseDNSCache
    case browser
    case xcode
    case simulator
    case packageManager
    case ide
    /// IM/国民应用（Telegram、飞书、微信等）的缓存：应用退出前一律保护。
    case messenger
    /// Agent 专清目录项：归属进程/应用记录在 `activityOwners`，归属者运行
    /// 或进程表不可读时一律不执行；用户可选（Warning）项也只在这一守卫下可执行。
    case aiAgent
    case unsupported
}

/// 清理页的五个展示分桶。分组头渲染与长尾合并共用这一映射，避免两处
/// 各自维护一套 source → 分组规则。
enum CleanupGroupBucket: String, Hashable, CaseIterable {
    case cache, leftovers, trash, developer, ai

    init(category: CleanupCategory, homeDirectory: String = NSHomeDirectory()) {
        if Self.isTrash(category, homeDirectory: homeDirectory) {
            self = .trash
            return
        }
        switch category.source {
        case .developerCache, .xcodeCache, .xcodeArchive, .tool:
            self = .developer
        case .aiSession, .aiCache, .aiModel:
            self = .ai
        case .appLeftover:
            self = .leftovers
        case .core:
            self = .cache
        default:
            // Installer and legacy/unknown records are not safe cleanup
            // candidates today, but keeping them in the cache bucket
            // preserves a single, predictable top-level taxonomy if an
            // older cache contains one.
            self = .cache
        }
    }

    private static func isTrash(_ category: CleanupCategory,
                                homeDirectory: String) -> Bool {
        let root = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL.path + "/"
        return !category.paths.isEmpty && category.paths.allSatisfy { path in
            URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root)
        }
    }
}

/// 清理类别：同一分组中的路径共享风险、处置方式和执行路由。
struct CleanupCategory: Identifiable, Equatable {
    let id: UUID
    var name: String
    var paths: [String]
    var bytes: UInt64
    /// Per-path sizes are preserved from scanner output so partial selection
    /// reports an accurate reclaimable total.
    var pathBytes: [String: UInt64]
    /// Identity captured when the scan produced the path. Apply must recheck
    /// this value before deleting so a replaced path cannot be removed.
    var pathIdentities: [String: String]
    private(set) var selectedPaths: Set<String>
    var expanded: Bool
    var source: CleanupSource
    var risk: CleanupRisk
    var disposal: CleanupDisposal
    var applyRoute: CleanupApplyRoute
    var activityGuard: CleanupActivityGuard
    /// 年龄门（秒）。开发者缓存/构建产物默认 7 天：条目未被证明“连续
    /// retention 未活跃”时不进入默认推荐。0 表示该类内容不按年龄过滤。
    var retention: TimeInterval
    /// 稳定原因键，由 UI 层自行本地化。
    var reasonKey: String
    /// `.aiAgent` 守卫的归属者：进程名或 Bundle ID，任一在运行即视为占用。
    var activityOwners: [String] = []

    init(id: UUID = UUID(),
         name: String,
         paths: [String],
         bytes: UInt64,
         pathBytes: [String: UInt64]? = nil,
         pathIdentities: [String: String]? = nil,
         selected: Bool? = nil,
         expanded: Bool = false,
         source: CleanupSource = .unknown,
         risk: CleanupRisk = .warning,
         disposal: CleanupDisposal = .none,
         applyRoute: CleanupApplyRoute = .none,
         activityGuard: CleanupActivityGuard = .unsupported,
         retention: TimeInterval = 0,
         reasonKey: String = "cleanup.risk.unknown") {
        self.id = id
        self.name = name
        self.paths = paths
        self.bytes = bytes
        if let pathBytes {
            self.pathBytes = pathBytes.filter { paths.contains($0.key) }
        } else if paths.count == 1, let path = paths.first {
            self.pathBytes = [path: bytes]
        } else {
            self.pathBytes = [:]
        }
        self.pathIdentities = pathIdentities ?? paths.reduce(into: [String: String]()) { result, path in
            if let identity = DeletionPlan.identity(at: path) { result[path] = identity }
        }
        let shouldSelect = risk != .protected && (selected ?? (risk == .safe))
        self.selectedPaths = shouldSelect ? Set(paths) : []
        self.expanded = expanded
        self.source = source
        self.risk = risk
        self.disposal = disposal
        self.applyRoute = applyRoute
        self.activityGuard = activityGuard
        self.retention = retention
        self.reasonKey = reasonKey
    }

    var canSelect: Bool { risk != .protected }
    var quickCleanEligible: Bool { risk == .safe && disposal == .permanentDelete }
    var selected: Bool {
        get { !selectedPaths.isEmpty }
        set { selectedPaths = newValue && canSelect ? Set(paths) : [] }
    }
    var allSelected: Bool { !paths.isEmpty && selectedPaths.count == paths.count }
    var partiallySelected: Bool { selected && !allSelected }
    var selectedPathCount: Int { selectedPaths.count }
    var selectedPathBytes: UInt64 {
        if allSelected { return bytes }
        return selectedPaths.reduce(0) { $0 &+ (pathBytes[$1] ?? 0) }
    }

    func isPathSelected(_ path: String) -> Bool {
        selectedPaths.contains(path)
    }

    /// Keep the category visible while clearing its current selection. This is
    /// used when runtime ownership is unknown or an app is still running.
    func clearingSelection() -> CleanupCategory {
        var copy = self
        copy.selectedPaths = []
        return copy
    }

    /// Keep the full category total while selecting only paths proven idle.
    func selectingPaths(_ pathsToSelect: some Sequence<String>) -> CleanupCategory {
        var copy = self
        let allowed = Set(pathsToSelect).intersection(copy.paths)
        copy.selectedPaths = copy.canSelect ? allowed : []
        return copy
    }

    mutating func setPathSelected(_ path: String, selected: Bool) {
        guard canSelect, paths.contains(path) else { return }
        if selected {
            selectedPaths.insert(path)
        } else {
            selectedPaths.remove(path)
        }
    }

    mutating func appendPath(_ path: String, bytes pathSize: UInt64) {
        guard !paths.contains(path) else { return }
        paths.append(path)
        pathBytes[path] = pathSize
        if let identity = DeletionPlan.identity(at: path) { pathIdentities[path] = identity }
        bytes &+= pathSize
        if risk == .safe { selectedPaths.insert(path) }
    }

    var selectedSubset: CleanupCategory? {
        guard canSelect else { return nil }
        let selectedPathList = paths.filter(selectedPaths.contains)
        guard !selectedPathList.isEmpty else { return nil }
        var subset = self
        subset.paths = selectedPathList
        subset.pathBytes = pathBytes.filter { selectedPaths.contains($0.key) }
        subset.pathIdentities = pathIdentities.filter { selectedPaths.contains($0.key) }
        subset.bytes = selectedPathBytes
        subset.selectedPaths = Set(selectedPathList)
        return subset
    }

    /// 保留同一类别中的部分路径。运行态保护必须按路径裁剪，不能因为一个
    /// App 正在运行就把同组其他应用的缓存全部隐藏或跳过。
    func retainingPaths(_ keptPaths: [String]) -> CleanupCategory? {
        let kept = Set(keptPaths)
        let ordered = paths.filter(kept.contains)
        guard !ordered.isEmpty else { return nil }

        var subset = self
        subset.paths = ordered
        subset.pathBytes = pathBytes.filter { kept.contains($0.key) }
        subset.pathIdentities = pathIdentities.filter { kept.contains($0.key) }
        subset.bytes = ordered.reduce(0) { $0 &+ (subset.pathBytes[$1] ?? 0) }
        subset.selectedPaths.formIntersection(kept)
        return subset
    }

    var pathsByDescendingSize: [String] {
        paths.sorted { lhs, rhs in
            let lhsBytes = pathBytes[lhs] ?? 0
            let rhsBytes = pathBytes[rhs] ?? 0
            if lhsBytes != rhsBytes { return lhsBytes > rhsBytes }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    /// 磁盘清理只接受已明确为可再生垃圾的非空条目。这个收口同时用于
    /// 新扫描和旧缓存恢复，避免历史 Warning / Protected 结果重新出现。
    var safeCleanupCandidate: CleanupCategory? {
        guard risk == .safe, disposal == .permanentDelete else { return nil }
        let keptPaths = paths.filter { (pathBytes[$0] ?? 0) > 0 }.sorted { lhs, rhs in
            let lhsBytes = pathBytes[lhs] ?? 0
            let rhsBytes = pathBytes[rhs] ?? 0
            if lhsBytes != rhsBytes { return lhsBytes > rhsBytes }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        guard !keptPaths.isEmpty else { return nil }

        var candidate = self
        candidate.paths = keptPaths
        let kept = Set(keptPaths)
        candidate.pathBytes = pathBytes.filter { kept.contains($0.key) }
        candidate.pathIdentities = pathIdentities.filter { kept.contains($0.key) }
        candidate.bytes = keptPaths.reduce(0) { $0 &+ (candidate.pathBytes[$1] ?? 0) }
        guard candidate.bytes > 0 else { return nil }
        candidate.selectedPaths = Set(keptPaths)
        return candidate
    }

    static func safeCleanupCandidates(from categories: [CleanupCategory]) -> [CleanupCategory] {
        categories.compactMap(\.safeCleanupCandidate).sorted(by: sizeDescending)
    }

    /// 长尾合并的字节阈值与最小项数：小于 100MB 的通用安全项凑满 3 个才合并。
    static let longTailByteThreshold: UInt64 = 100 * 1024 * 1024
    static let longTailMinimumCount = 3

    /// 把同一分桶里小于阈值的通用删除路线安全项并成一个「其他」类目，避免
    /// 长尾小项铺满列表。只合并 genericTrash 路线的项；特殊执行路线（Xcode、
    /// 工具命令、安装器等）即使很小也保持独立行。messenger（IM 缓存）和
    /// unsupported 守卫不参与合并，执行前的运行态保护必须按类别精确生效。
    /// 合并后的守卫取成员中最严格的一档，执行前评估只会更保守，不会更宽松。
    static func mergingLongTail(
        _ categories: [CleanupCategory],
        byteThreshold: UInt64 = longTailByteThreshold,
        minimumCount: Int = longTailMinimumCount,
        homeDirectory: String = NSHomeDirectory()
    ) -> [CleanupCategory] {
        var kept: [CleanupCategory] = []
        var tails: [CleanupGroupBucket: [CleanupCategory]] = [:]
        var tailOrder: [CleanupGroupBucket] = []
        for category in categories {
            let mergeable = category.bytes < byteThreshold
                && category.disposal == .permanentDelete
                && category.applyRoute == .genericTrash
                && category.activityGuard != .messenger
                && category.activityGuard != .unsupported
            guard mergeable else {
                kept.append(category)
                continue
            }
            let bucket = CleanupGroupBucket(category: category, homeDirectory: homeDirectory)
            if tails[bucket] == nil { tailOrder.append(bucket) }
            tails[bucket, default: []].append(category)
        }
        var result = kept
        for bucket in tailOrder {
            guard let items = tails[bucket] else { continue }
            if items.count >= minimumCount, let merged = mergedTailCategory(items) {
                result.append(merged)
            } else {
                result.append(contentsOf: items)
            }
        }
        return result
    }

    private static func mergedTailCategory(_ items: [CleanupCategory]) -> CleanupCategory? {
        guard let first = items.first else { return nil }
        var paths: [String] = []
        var pathBytes: [String: UInt64] = [:]
        var pathIdentities: [String: String] = [:]
        var selectedPaths: Set<String> = []
        var bytes: UInt64 = 0
        for item in items {
            for path in item.paths where pathBytes[path] == nil {
                let size = item.pathBytes[path] ?? 0
                paths.append(path)
                pathBytes[path] = size
                pathIdentities[path] = item.pathIdentities[path]
                if item.isPathSelected(path) { selectedPaths.insert(path) }
                bytes &+= size
            }
        }
        guard !paths.isEmpty, bytes > 0 else { return nil }

        // 类别级守卫只能有一个：取成员里最严格的一档，宁可整组跳过也不放宽。
        let strictness: [CleanupActivityGuard] = [.browser, .xcode, .simulator, .ide,
                                                  .messenger, .reverseDNSCache,
                                                  .openFile, .packageManager, .none]
        let guardKind = items.map(\.activityGuard).min {
            (strictness.firstIndex(of: $0) ?? strictness.count)
                < (strictness.firstIndex(of: $1) ?? strictness.count)
        } ?? .openFile
        return CleanupCategory(
            name: L10n.shared.t("cleanup.group.other"),
            paths: paths,
            bytes: bytes,
            pathBytes: pathBytes,
            pathIdentities: pathIdentities,
            expanded: false,
            source: first.source,
            risk: .safe,
            disposal: .permanentDelete,
            applyRoute: .genericTrash,
            activityGuard: guardKind,
            reasonKey: "cleanup.risk.rebuildableCache"
        ).selectingPaths(selectedPaths)
    }

    static func sizeDescending(_ lhs: CleanupCategory, _ rhs: CleanupCategory) -> Bool {
        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return (lhs.paths.first ?? "").localizedStandardCompare(rhs.paths.first ?? "")
            == .orderedAscending
    }

    static func == (lhs: CleanupCategory, rhs: CleanupCategory) -> Bool {
        lhs.id == rhs.id
    }
}

/// 当前清理结果所属的家族，决定确认文案与 apply 桥接脚本。
enum CleanupFamily: String {
    case clean, tools
}

/// 官方 GC 命令（owner 命令面板条目）。
struct GcAction: Identifiable, Equatable {
    let id: String
    let command: String
    let bytes: UInt64
}

/// macOS `ps state` 映射。只有首字符 `Z` 代表已经死亡的僵尸进程；
/// `E` 是附加退出标记，不能把 `X` / `T` / `U` 等主状态误判为退出。
enum ProcessLifecycle: String, Equatable {
    case normal
    case exiting
    case zombie

    init(processState state: String) {
        guard let primary = state.first else {
            self = .normal
            return
        }
        if primary == "Z" {
            self = .zombie
        } else if state.dropFirst().contains("E") {
            self = .exiting
        } else {
            self = .normal
        }
    }
}

/// 进程列表行（应用组模式 / 高级 PID 模式 / 原生应用模式共用）。
struct ProcessRow: Identifiable, Equatable, Sendable {
    let pid: Int32
    /// 进程启动身份；与 PID 一起使用，避免确认期间 PID 复用误杀新进程。
    let startIdentity: String
    let name: String
    let detail: String
    let isNativeApp: Bool
    let cpu: Double
    let mem: Double
    /// 内存占用换算成字节（百分比 × 物理内存）。
    let memBytes: UInt64
    let ppid: Int32
    let uid: UInt32
    /// 原始 `ps state`，保留附加标志供界面解释。
    let state: String
    /// 进程已运行秒数；旧 bridge 或原生应用行未知时为 0。
    let elapsed: TimeInterval
    var lifecycle: ProcessLifecycle { ProcessLifecycle(processState: state) }
    var id: Int32 { pid }
    var signalToken: String { "\(pid)|\(startIdentity)" }
    /// 后台异常处理还需绑定父进程和用户，避免快照变化后误处理同 PID。
    var staleCleanupToken: String { "\(pid)|\(startIdentity)|\(ppid)|\(uid)" }

    init(pid: Int32, startIdentity: String, name: String, detail: String,
         isNativeApp: Bool, cpu: Double, mem: Double, memBytes: UInt64,
         ppid: Int32 = 0, uid: UInt32 = UInt32.max, state: String = "",
         elapsed: TimeInterval = 0) {
        self.pid = pid
        self.startIdentity = startIdentity
        self.name = name
        self.detail = detail
        self.isNativeApp = isNativeApp
        self.cpu = cpu
        self.mem = mem
        self.memBytes = memBytes
        self.ppid = ppid
        self.uid = uid
        self.state = state
        self.elapsed = elapsed
    }
}

/// 监听端口行。
struct PortRow: Identifiable, Hashable {
    let port: String
    let pid: Int32
    let startIdentity: String
    let command: String
    let endpoint: String
    var id: String { "\(port)|\(pid)|\(startIdentity)|\(endpoint)" }
    var signalToken: String { "\(pid)|\(startIdentity)" }
}

/// 流量出口分类：应用流量最终从哪里离开本机。
enum TrafficExitKind: String, CaseIterable, Codable, Sendable {
    /// 应用自己的连接，路由落在物理口（en*）。
    case direct
    /// 应用自己的连接，路由落在隧道口（utun*）。
    case tunnel
    /// 本机回环目标。
    case loopback
    /// 尚无可信路由或出站信息。
    case unknown

    var titleKey: String { "netmon.exit.\(rawValue)" }
}

enum TrafficSortOrder: String, CaseIterable, Sendable {
    case appTotal, download, upload
    var titleKey: String { "netmon.sort.\(rawValue)" }

    func bytes(in row: TrafficAppRow) -> UInt64 {
        switch self {
        case .download: return row.sessionDown
        case .upload: return row.sessionUp
        case .appTotal: return row.sampledTotal
        }
    }

    func sorted(_ rows: [TrafficAppRow]) -> [TrafficAppRow] {
        rows.sorted {
            let lhs = bytes(in: $0), rhs = bytes(in: $1)
            if lhs != rhs { return lhs > rhs }
            if $0.sampledTotal != $1.sampledTotal { return $0.sampledTotal > $1.sampledTotal }
            if $0.displayName != $1.displayName {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.appKey < $1.appKey
        }
    }
}

/// 按应用聚合系统采样。
struct TrafficAppRow: Identifiable, Equatable, Sendable {
    /// 稳定键：应用使用最外层 app 的 bundleID 或路径，其余进程使用可执行文件名。
    let appKey: String
    var displayName: String
    var bundleIdentifier: String?
    var representativePID: Int32
    /// 采样累计的会话下行/上行（所有出口合计，近似值）。
    var sessionDown: UInt64
    var sessionUp: UInt64
    /// 最近一个采样窗口的速率（字节/秒）。
    var rateDown: Double
    var rateUp: Double
    var sampledTotal: UInt64 { sessionDown + sessionUp }
    var connectionCount: Int
    /// 端点分类集合，用于行内 badge。
    var exitKinds: [TrafficExitKind]
    var id: String { appKey }
}

/// lsof 快照中的远端端点。
struct TrafficEndpointRow: Identifiable, Equatable, Sendable {
    let appKey: String
    /// 展示用远端（host:port，优先域名）。
    let remote: String
    let proto: String
    var kind: TrafficExitKind
    var activeConnections: Int = 0
    var id: String { "\(appKey)|\(proto)|\(remote)|\(kind.rawValue)" }
}

/// nettop 进程汇总字节快照；作为独立的近似观测值。
struct NetmonProcessSample: Equatable, Sendable {
    let pid: Int32
    let bytesIn: UInt64
    let bytesOut: UInt64
    let command: String
}

/// lsof 连接快照行（仅已连接 socket，不含监听）。
struct NetmonFlow: Equatable, Sendable {
    let pid: Int32
    let command: String
    let proto: String
    let local: String
    let remote: String
}

/// 路由查询结果：地址 → 出接口。
struct NetmonRoute: Equatable, Sendable {
    let address: String
    let interface: String
}

enum MediaKind: String, Codable, CaseIterable {
    case image, video
}

/// 磁盘分析中可瘦身的图片/视频文件（只收用户自己管理的位置）。
struct MediaFile: Codable, Identifiable, Equatable {
    let name: String
    let path: String
    let size: UInt64
    let kind: MediaKind
    var id: String { path }
}

struct MediaSummary: Codable, Equatable {
    var imageCount = 0
    var imageBytes: UInt64 = 0
    var videoCount = 0
    var videoBytes: UInt64 = 0

    mutating func add(_ kind: MediaKind, bytes: UInt64) {
        switch kind {
        case .image: imageCount += 1; imageBytes += bytes
        case .video: videoCount += 1; videoBytes += bytes
        }
    }

    mutating func merge(_ other: MediaSummary) {
        imageCount += other.imageCount; imageBytes += other.imageBytes
        videoCount += other.videoCount; videoBytes += other.videoBytes
    }
}

/// 原生应用扫描生成的卸载清单条目。
struct UninstallApp: Identifiable, Codable, Equatable, Sendable {
    let name: String
    let bundleID: String
    let source: String
    let path: String
    let size: String
    /// 扫描应用列表时捕获的文件身份，供预览与执行阶段拒绝路径替换。
    let appIdentity: String
    let infoIdentity: String

    var id: String { "\(path)#\(bundleID)" }

    enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
        case source
        case path
        case size
        case appIdentity
        case infoIdentity
    }

    init(name: String, bundleID: String, source: String, path: String, size: String,
         appIdentity: String? = nil, infoIdentity: String? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.source = source
        self.path = path
        self.size = size
        self.appIdentity = appIdentity ?? DeletionPlan.identity(at: path) ?? ""
        self.infoIdentity = infoIdentity
            ?? DeletionPlan.identity(at: path + "/Contents/Info.plist") ?? "missing"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        bundleID = try values.decode(String.self, forKey: .bundleID)
        source = try values.decode(String.self, forKey: .source)
        path = try values.decode(String.self, forKey: .path)
        size = try values.decode(String.self, forKey: .size)
        appIdentity = try values.decodeIfPresent(String.self, forKey: .appIdentity)
            ?? DeletionPlan.identity(at: path) ?? ""
        infoIdentity = try values.decodeIfPresent(String.self, forKey: .infoIdentity)
            ?? DeletionPlan.identity(at: path + "/Contents/Info.plist") ?? "missing"
    }
}

/// 卸载预览的单个文件条目。label 是稳定的分类键（app/related/review/manual）。
struct UninstallFile: Identifiable, Codable, Equatable, Sendable {
    let bytes: UInt64
    let label: String
    let path: String

    var id: String { "\(label)\u{1F}\(path)" }
    var informational: Bool { label == "review" || label == "manual" }
    var isAppBundle: Bool { label == "app" }

    /// Only cache roots accepted by the shared risk policy, plus explicit
    /// sandbox cache folders, are shown as cleanable cache. Containers, WebKit,
    /// preferences and Application Support otherwise remain app data because
    /// they may include sessions or user state.
    var isCache: Bool {
        isCache(homeDirectory: NSHomeDirectory())
    }

    func isCache(homeDirectory: String) -> Bool {
        let normalized = standardizedPath
        guard !CleanupRiskPolicy.isProtectedContent(normalized,
                                                     homeDirectory: homeDirectory) else {
            return false
        }
        if CleanupRiskPolicy.developerCache(path: normalized,
                                            homeDirectory: homeDirectory).risk == .safe {
            return true
        }

        let home = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        return Self.matchesSandboxCache(normalized,
                                        prefix: home + "/Library/Containers/",
                                        suffixes: ["/Data/Library/Caches", "/Data/tmp"])
            || Self.matchesSandboxCache(normalized,
                                        prefix: home + "/Library/Group Containers/",
                                        suffixes: ["/Library/Caches"])
    }

    var standardizedPath: String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func matchesSandboxCache(_ path: String,
                                            prefix: String,
                                            suffixes: [String]) -> Bool {
        guard path.hasPrefix(prefix) else { return false }
        let remainder = String(path.dropFirst(prefix.count))
        guard let separator = remainder.firstIndex(of: "/"), separator != remainder.startIndex else {
            return false
        }
        let suffix = String(remainder[separator...])
        return suffixes.contains { suffix == $0 || suffix.hasPrefix($0 + "/") }
    }
}

/// One background inventory result. It is safe to show from disk cache because
/// the native apply path still revalidates the app and file identities before
/// performing any side effect.
struct UninstallPlan: Codable, Equatable, Sendable {
    let files: [UninstallFile]
    /// Identities captured with the uninstall preview for final TOCTOU checks.
    let fileIdentities: [String: String]
    let needsAdmin: Bool
    let isBrewCask: Bool
    let caskToken: String
    /// Whether the scan included macOS-protected app container roots.
    /// Apply must reuse the same coverage so its revalidation cannot silently
    /// broaden access or produce a different route.
    let includesProtectedAppData: Bool
    let scannedAt: Date

    /// Derived once at the inventory boundary, never inside a sort comparator
    /// or a SwiftUI body. Do not persist it: old cache files remain compatible
    /// and a restored plan uses the current classification rules.
    let space: UninstallSpaceBreakdown

    private enum CodingKeys: String, CodingKey {
        case files, fileIdentities, needsAdmin, isBrewCask, caskToken, includesProtectedAppData, scannedAt
    }

    init(files: [UninstallFile], fileIdentities: [String: String]? = nil,
         needsAdmin: Bool, isBrewCask: Bool,
         caskToken: String, includesProtectedAppData: Bool, scannedAt: Date) {
        self.files = files
        self.fileIdentities = fileIdentities ?? files.reduce(into: [String: String]()) { result, file in
            if let identity = DeletionPlan.identity(at: file.path) { result[file.path] = identity }
        }
        self.needsAdmin = needsAdmin
        self.isBrewCask = isBrewCask
        self.caskToken = caskToken
        self.includesProtectedAppData = includesProtectedAppData
        self.scannedAt = scannedAt
        self.space = UninstallSpaceBreakdown(files: files)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(files: try values.decode([UninstallFile].self, forKey: .files),
                  fileIdentities: try values.decodeIfPresent([String: String].self, forKey: .fileIdentities),
                  needsAdmin: try values.decode(Bool.self, forKey: .needsAdmin),
                  isBrewCask: try values.decode(Bool.self, forKey: .isBrewCask),
                  caskToken: try values.decode(String.self, forKey: .caskToken),
                  includesProtectedAppData: try values.decode(Bool.self, forKey: .includesProtectedAppData),
                  scannedAt: try values.decode(Date.self, forKey: .scannedAt))
    }
}

struct UninstallInventoryRecord: Equatable, Sendable {
    let app: UninstallApp
    let plan: UninstallPlan
}

/// 卸载详情中的互斥空间口径。父目录已覆盖子目录时只计算父目录，
/// 用于卸载列表和详情中的可回收空间估算。
struct UninstallSpaceBreakdown: Equatable, Sendable {
    let appBytes: UInt64
    let cacheBytes: UInt64
    let dataBytes: UInt64

    var totalBytes: UInt64 {
        Self.saturatedSum([appBytes, cacheBytes, dataBytes])
    }

    init(files: [UninstallFile], homeDirectory: String = NSHomeDirectory()) {
        let candidates = files
            .filter { !$0.informational }
            .sorted { lhs, rhs in
                let lhsDepth = (lhs.standardizedPath as NSString).pathComponents.count
                let rhsDepth = (rhs.standardizedPath as NSString).pathComponents.count
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                if lhs.isAppBundle != rhs.isAppBundle { return lhs.isAppBundle }
                return lhs.standardizedPath < rhs.standardizedPath
            }

        var coveredPaths: [String] = []
        var appFiles: [UninstallFile] = []
        var cacheFiles: [UninstallFile] = []
        var dataFiles: [UninstallFile] = []

        for file in candidates {
            let path = file.standardizedPath
            let isCovered = coveredPaths.contains { parent in
                path == parent || path.hasPrefix(parent + "/")
            }
            guard !isCovered else { continue }
            coveredPaths.append(path)

            if file.isAppBundle {
                appFiles.append(file)
            } else if file.isCache(homeDirectory: homeDirectory) {
                cacheFiles.append(file)
            } else {
                dataFiles.append(file)
            }
        }

        appBytes = Self.saturatedSum(appFiles.map(\.bytes))
        cacheBytes = Self.saturatedSum(cacheFiles.map(\.bytes))
        dataBytes = Self.saturatedSum(dataFiles.map(\.bytes))
    }

    private static func saturatedSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { result, value in
            let (sum, overflow) = result.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }
}

/// 开发环境条目（runtime=可清理版本，current=使用中，manager=工具本体）。
struct DevEnvEntry: Identifiable, Equatable {
    let bytes: UInt64
    let kind: String
    let name: String
    let path: String
    let relatedBytes: UInt64
    let relatedPath: String?

    var id: String { path }
    var manager: String { name.components(separatedBy: " · ").first ?? name }
    var versionLabel: String {
        name.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
    }
    var isCurrent: Bool { kind == "current" }
    var isManager: Bool { kind == "manager" }
    /// 系统内置运行时（macOS 自带，禁止清理）。
    var isBuiltin: Bool { kind == "builtin" }
    var hasVersionGlobalPackages: Bool {
        manager == "nvm" && relatedBytes > 0 && relatedPath != nil
    }
}

/// `mole analyze --json` 的目录/文件条目。
struct AnalyzeEntry: Identifiable, Codable, Equatable {
    let name: String
    let path: String
    let size: UInt64
    let isDir: Bool
    var insight: Bool?
    var cleanable: Bool?
    var lastAccess: String?
    var isPartial: Bool? = nil

    var id: String { path }

    enum Handling: Int {
        case directCleanup = 0
        case browse = 1
        case appData = 2
        case application = 3
        case systemReadOnly = 4
    }

    enum CodingKeys: String, CodingKey {
        case name, path, size
        case isDir = "is_dir"
        case insight, cleanable, isPartial
        case lastAccess = "last_access"
    }

    var handling: Handling {
        if isSystemManaged { return .systemReadOnly }
        if isApplicationBundle { return .application }
        if canCleanDirectly { return .directCleanup }
        if isManagedAppData { return .appData }
        return .browse
    }

    /// Direct cleanup is intentionally narrower than "visible in analysis":
    /// ordinary directories are drill-down containers, while files and Mole-
    /// verified regenerable directories can be selected.
    var canCleanDirectly: Bool {
        guard isPartial != true, !isSystemManaged, !isApplicationBundle, !isProtectedContainer else { return false }
        if isManagedAppData { return isDir && cleanable == true }
        return isDir ? cleanable == true : true
    }

    var isApplicationBundle: Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized != "/Applications" else { return false }
        if normalized.lowercased().hasSuffix(".app") { return true }
        guard normalized.hasPrefix("/Applications/") else { return false }
        return normalized.dropFirst("/Applications/".count)
            .split(separator: "/").first?.lowercased().hasSuffix(".app") == true
    }

    var isSystemManaged: Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let roots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/var", "/etc"]
        return roots.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
    }

    var isManagedAppData: Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let library = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library").standardizedFileURL.path
        return normalized == library || normalized.hasPrefix(library + "/")
    }

    private var isProtectedContainer: Bool {
        guard isDir else { return false }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let protected = ["/", "/Applications", home, home + "/Library",
                         home + "/Desktop", home + "/Documents", home + "/Downloads"]
        return protected.contains(normalized)
    }

    static func analysisOrder(_ lhs: AnalyzeEntry, _ rhs: AnalyzeEntry) -> Bool {
        if lhs.size != rhs.size { return lhs.size > rhs.size }
        // Sorting runs for every directory. Keep filesystem-backed safety
        // classification out of this hot path; canCleanDirectly still gates selection.
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.path < rhs.path
    }
}

/// `mole analyze --json` 的完整报告。
struct AnalyzeReport: Codable {
    let path: String
    let overview: Bool
    let entries: [AnalyzeEntry]
    let largeFiles: [LargeFile]?
    let totalSize: UInt64
    let totalFiles: Int?
    var isPartial: Bool? = nil
    var error: String? = nil
    /// Current traversal location for live progress; not serialized.
    var currentPath: String? = nil
    /// In-memory directory index from the same traversal; not serialized.
    var directoryReports: [String: AnalyzeReport]? = nil

    /// Same traversal's image/video index: top files per kind plus full totals.
    var media: [MediaFile]? = nil
    var mediaSummary: MediaSummary? = nil

    struct LargeFile: Codable {
        let name: String
        let path: String
        let size: UInt64
    }

    enum CodingKeys: String, CodingKey {
        case path, overview, entries, isPartial, error, media
        case mediaSummary = "media_summary"
        case largeFiles = "large_files"
        case totalSize = "total_size"
        case totalFiles = "total_files"
    }
}

/// APFS 本地快照条目。
struct SnapshotInfo: Identifiable, Equatable {
    let name: String
    var id: String { name }
}

/// `docker system df` 的一行摘要（原始人读字符串直接透传）。
struct DockerDfRow: Identifiable, Equatable {
    let type: String
    let count: String
    let size: String
    let reclaimable: String

    var id: String { type }
}

/// Shell 配置体检发现项。
struct ShellIssue: Identifiable, Equatable {
    let file: String
    let kind: String   // path-dup / path-dead / orphan
    let detail: String
    let line: Int

    var id: String { "\(file)#\(line)#\(kind)#\(detail)" }
    /// 展示用的短路径（~ 化）与位置。
    var shortFile: String {
        let home = NSHomeDirectory()
        return file.hasPrefix(home) ? "~" + file.dropFirst(home.count) : file
    }
    var location: String { line > 0 ? "\(shortFile):\(line)" : shortFile }
}

/// 系统代理残留条目。
struct ProxyIssue: Identifiable, Equatable {
    let service: String
    let kind: String   // http / https / socks
    let endpoint: String

    var id: String { "\(service)#\(kind)" }
}

struct RunResult {
    let output: String
    let errorOutput: String
    let exitCode: Int32
    let timedOut: Bool

    init(output: String, errorOutput: String = "", exitCode: Int32, timedOut: Bool) {
        self.output = output
        self.errorOutput = errorOutput
        self.exitCode = exitCode
        self.timedOut = timedOut
    }

    var succeeded: Bool { exitCode == 0 && !timedOut }
    /// 失败日志优先展示 stderr；没有 stderr 时回退到普通输出。
    var diagnosticOutput: String { errorOutput.isEmpty ? output : errorOutput }
}

enum ByteFormat {
    static func format(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if bytes >= 1_000_000_000 { return String(format: "%.2f GB", value / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f KB", value / 1_000) }
        return "\(bytes) B"
    }

    /// 紧凑短格式（环形图等窄空间用）：18.2G / 742M。
    static func short(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if bytes >= 1_000_000_000 { return String(format: "%.1fG", value / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.0fM", value / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0fK", value / 1_000) }
        return "\(bytes)B"
    }

    /// 内存专用短格式。macOS 的 `hw.memsize` 以字节返回，但硬件容量按
    /// 1024 进制标称；不能复用磁盘清理使用的十进制容量格式，否则 16 GiB
    /// 会被误显示为 17.2G。
    static func memoryShort(_ bytes: UInt64) -> String {
        let kib = UInt64(1_024)
        let mib = kib * 1_024
        let gib = mib * 1_024
        let value = Double(bytes)
        if bytes >= gib {
            let gibibytes = value / Double(gib)
            if abs(gibibytes.rounded() - gibibytes) < 0.05 {
                return String(format: "%.0fG", gibibytes)
            }
            return String(format: "%.1fG", gibibytes)
        }
        if bytes >= mib { return String(format: "%.0fM", value / Double(mib)) }
        if bytes >= kib { return String(format: "%.0fK", value / Double(kib)) }
        return "\(bytes)B"
    }

    /// 网络吞吐。入参是 MB/s；低于 1 MB/s 时改用 KB/s，避免把空闲显示成 0.0 MB/s。
    static func megabytesPerSecond(_ megabytesPerSecond: Double) -> String {
        let rate = max(0, megabytesPerSecond)
        if rate < 0.0005 { return "0 KB/s" }
        if rate < 1 { return String(format: "%.0f KB/s", rate * 1_000) }
        if rate < 10 { return String(format: "%.1f MB/s", rate) }
        return String(format: "%.0f MB/s", rate)
    }

    /// 解析引擎预览文件中的 "12.5 MB" / "size unknown" 标签。
    static func parse(_ label: String) -> UInt64 {
        let scanner = Scanner(string: label)
        guard let number = scanner.scanDouble() else { return 0 }
        let unit = String(label[scanner.currentIndex...]).uppercased()
        let multiplier: Double
        if unit.contains("TB") { multiplier = 1_000_000_000_000 }
        else if unit.contains("GB") { multiplier = 1_000_000_000 }
        else if unit.contains("MB") { multiplier = 1_000_000 }
        else if unit.contains("KB") { multiplier = 1_000 }
        else { multiplier = 1 }
        return UInt64(max(0, number * multiplier))
    }
}

extension Notification.Name {
    /// 截图完成（screencapture 输出文件就绪），携带图片 URL。
    static let smTakeScreenshot = Notification.Name("SMTakeScreenshot")
    /// 光标离开灵动岛可见形状、窗口恢复鼠标穿透；之后不再有悬停事件送达。
    static let smIslandPointerExited = Notification.Name("SMIslandPointerExited")
}
