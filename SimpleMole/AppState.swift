import Foundation
import SwiftUI
import AppKit
import Combine
import CryptoKit
import Darwin

/// 全局状态与业务流协调：指标采样、扫描/清理、卸载、开发环境、进程端口、
/// 图片清单、日志与确认弹窗。核心清理、分析、卸载和优化走 NativeCore；
/// 图片、Docker、Simulator 等特色能力继续使用各自桥接。文案统一经 L10n 取当前语言。
@MainActor
final class AppState: ObservableObject {
    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let onConfirm: () -> Void
    }

    // MARK: 指标

    @Published var metrics = MetricsSnapshot()
    @Published var networkHistory: [Double] = []
    /// 灵动岛展示的内存占用最高应用组（按内存排序前 5）。
    @Published var topMemoryApps: [ProcessRow] = []
    @Published var topCPUApps: [ProcessRow] = []
    @Published var islandResourceStatus: [IslandResource: String] = [:]
    @Published var islandCleaningResource: IslandResource?
    @Published var islandClosingPIDs: Set<Int32> = []
    var islandProcessRows: [ProcessRow] = []
    let islandProcessSampler = ProcessSampler()
    var islandSampling = false
    var lastIslandSample = Date.distantPast

    // MARK: 窗口与导航

    /// 功能页标识：设置中可按需隐藏。
    enum PageKey: String, CaseIterable, Identifiable {
        case cleanup, agents, analyze, uninstall, optimize, devenv, processes, ports, traffic, clipboard, settings
        var id: String { rawValue }
        var titleKey: String { self == .settings ? "settings.title" : "tab.\(rawValue)" }

        /// 剪贴板页由功能开关控制，设置页始终保留。
        static var configurableCases: [PageKey] {
            allCases.filter { $0 != .clipboard && $0 != .settings }
        }
    }

    /// 顶部刘海中常驻显示的快捷指标。
    enum IslandItem: String, CaseIterable, Identifiable {
        case cpu, memory, disk, network
        var id: String { rawValue }
    }

    /// 灵动岛贴在屏幕顶边的哪一侧。
    enum IslandEdge: String, CaseIterable, Identifiable {
        case top, left, right
        var id: String { rawValue }
        var labelKey: String { "settings.island.edge.\(rawValue)" }
    }

    @Published var selectedTab = 0
    /// 用户隐藏的页面（UserDefaults 持久化）。
    @Published var hiddenPages: Set<String> = []
    @Published var mainWindowVisible = false

    // MARK: 灵动岛 / 菜单栏入口
    // 顶部刘海：悬停展开指标与资源排行，箭头直接打开主窗口。

    @Published var islandEnabled = true
    /// 菜单栏状态图标开关。灵动岛始终保留，菜单栏图标可以单独关闭。
    @Published var menuBarIconVisible = true
    /// 至少保留一项；这里控制刘海中的常驻指标。
    @Published var islandItems: Set<IslandItem> = [.cpu, .memory, .network]
    /// 灵动岛贴在屏幕顶边的位置：居中、靠左或靠右。
    @Published var islandEdge: IslandEdge = .top

    func setIslandEnabled(_ enabled: Bool) {
        if !enabled && !menuBarIconVisible { setMenuBarIconVisible(true) }
        islandEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "SMIslandEnabled")
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        if !visible && !islandEnabled { setIslandEnabled(true) }
        menuBarIconVisible = visible
        UserDefaults.standard.set(visible, forKey: "SMMenuBarIconVisible")
    }

    func setIslandEdge(_ edge: IslandEdge) {
        islandEdge = edge
        UserDefaults.standard.set(edge.rawValue, forKey: "SMIslandEdge")
    }

    func setIslandItem(_ item: IslandItem, enabled: Bool) {
        if enabled {
            islandItems.insert(item)
        } else if islandItems.count > 1 {
            islandItems.remove(item)
        }
        UserDefaults.standard.set(islandItems.map(\.rawValue), forKey: "SMIslandItems")
    }

    var visiblePages: [PageKey] {
        var pages = PageKey.configurableCases.filter { !hiddenPages.contains($0.rawValue) }
        if clipboardHistoryEnabled { pages.append(.clipboard) }
        pages.append(.settings)
        return pages
    }

    /// 跳转到指定功能页（考虑页面被隐藏的情况）。
    func jump(to key: PageKey) {
        if let index = visiblePages.firstIndex(of: key) {
            selectedTab = index
        }
    }

    func setPageVisible(_ key: PageKey, _ visible: Bool) {
        guard PageKey.configurableCases.contains(key) else { return }
        let previousPages = visiblePages
        let selectedPage = previousPages.indices.contains(selectedTab) ? previousPages[selectedTab] : nil
        if visible {
            hiddenPages.remove(key.rawValue)
        } else {
            // 至少保留一个可见页
            guard PageKey.configurableCases.filter({ !hiddenPages.contains($0.rawValue) }).count > 1 else { return }
            hiddenPages.insert(key.rawValue)
        }
        UserDefaults.standard.set(Array(hiddenPages), forKey: "SMHiddenPages")
        if let selectedPage, let newIndex = visiblePages.firstIndex(of: selectedPage) {
            selectedTab = newIndex
        } else {
            selectedTab = min(selectedTab, max(0, visiblePages.count - 1))
        }
    }

    // MARK: Agent 专清
    // 独立于磁盘清理的清单：不写入 `categories`，也不进入快速清理与自动化。

    @Published var agentCategories: [CleanupCategory] = []
    @Published var agentGroups: [AgentGroupSummary] = []
    @Published var agentSkills: [AgentSkill] = []
    @Published var agentServers: [AgentMCPServer] = []
    @Published var agentSelectedSkills: Set<String> = []
    @Published var agentScanning = false
    @Published var agentApplying = false
    @Published var agentScanComplete = false
    @Published var agentHasScanned = false
    @Published var agentStatus = ""
    @Published var agentOutcomeMood: NoriMood?

    // MARK: 清理

    @Published var categories: [CleanupCategory] = []
    @Published var family: CleanupFamily = .clean
    @Published var isScanning = false
    @Published var cleanupOutcomeMood: NoriMood?
    @Published var cleanupFeedbackID = 0
    /// Bumps once per finished user task so the title-bar mascot can celebrate or warn.
    @Published var headerReactionID = 0
    @Published var headerReactionMood: NoriMood = .success

    func noteHeaderReaction(_ mood: NoriMood?) {
        guard let mood, mood == .success || mood == .attention else { return }
        headerReactionID += 1
        headerReactionMood = mood
    }
    @Published var isApplying = false
    @Published var cleanupScanComplete = true
    @Published var statusText: String
    /// 用户手动扫描的目录进度；页面激活不触发扫描。
    @Published var cleanupProgress = CleanupScanProgress()
    @Published var cleanupScanMode: CleanupScanMode = .quick
    @Published var cleanupDeferredPaths: [String] = []
    private var cleanupScanControl: CleanupScanControl?
    private var cleanupProgressGeneration = 0
    var isCleanupScanning: Bool { isScanning }

    // MARK: 系统数据

    /// 系统数据页的独立清单：root 拥有的日志、报告与缓存。
    /// 与通用清理页的 categories/family 完全解耦，避免互相覆盖状态。
    @Published var installerCandidates: CleanupCategory?
    @Published var processActionStatus = ""
    enum ProcessQuitFeedback {
        case waiting, refused, stillRunning, stale
    }
    /// Bind feedback to the launch identity, so a reused PID never inherits an action.
    @Published var processQuitFeedback: [String: ProcessQuitFeedback] = [:]
    @Published var cleanupQueued = false
    private var pendingCleanup: (() -> Void)?

    // MARK: 系统优化

    @Published var optimizeTasks: [NativeCore.OptimizeTask] = NativeCore.shared.initialOptimizeTasks()
    @Published var isOptimizing = false
    @Published var optimizeStatus = ""

    // MARK: 日志

    @Published var logLines: [String] = []

    // MARK: 进程与端口

    @Published var processRows: [ProcessRow] = []
    @Published var processStatus: String
    @Published var advancedProcesses = false {
        didSet {
            guard oldValue != advancedProcesses else { return }
            if !advancedProcesses { resetAutomaticProcessCleanup() }
            refreshProcesses()
        }
    }
    /// 应用级视图：按 .app 聚合的进程组（libproc 采样，2 秒刷新）。
    @Published var processGroups: [ProcessGroup] = []
    @Published var processSearch = ""
    @Published var processSort: ProcessSort = .memory
    @Published var processAlerts: [HighUsageTracker.Alert] = []
    private var processHistory = ProcessHistory(capacity: 30)
    private var highUsageTracker = HighUsageTracker()
    private var processSampleInFlight = false
    @Published var portRows: [PortRow] = []
    @Published var portStatus: String
    @Published var runtimeInFlight = false
    private var automaticProcessTracker = RuntimeStore.AutomaticCandidateTracker()
    private var automaticProcessCleanupAttempted = 0
    private var automaticProcessCleanupSucceeded = 0
    private var automaticProcessCleanupTokens: Set<String> = []

    // MARK: 应用卸载

    @Published var installedApps: [UninstallApp] = []
    @Published private(set) var uninstallPlans: [String: UninstallPlan] = [:]
    @Published var appListStatus: String
    @Published var isScanningApps = false
    @Published private(set) var isRestoringInstalledApps = true
    @Published var uninstallSearch = ""
    @Published private(set) var filteredApps: [UninstallApp] = []
    @Published private(set) var uninstallQueue = UninstallQueue()
    private let uninstallPresentationQueue = DispatchQueue(
        label: "com.nori.uninstall-presentation", qos: .userInitiated)
    private var isStoppingUninstallQueue = false

    // MARK: 开发环境

    @Published var devEnvEntries: [DevEnvEntry] = []
    @Published var devEnvSelection: Set<String> = []
    @Published var devEnvStatus: String
    @Published var isScanningEnv = false

    // MARK: 包管理 GC（owner 命令，无直接删除）

    @Published var gcActions: [GcAction] = []
    @Published var gcRunningId: String?
    private var gcScanned = false

    // MARK: Docker

    @Published var dockerDfRows: [DockerDfRow] = []
    let simulatorInventory = SimulatorInventoryStore()
    let dockerInventory = DockerInventoryStore()
    @Published var showSimulatorDevices = false
    @Published var showDockerDetails = false

    // MARK: 流量监控

    let trafficMonitor = TrafficMonitorStore()

    // MARK: 自动目录清理

    @Published var autoCleanupRules: [AutoCleanupRule] = AutoCleanupRuleStore.load()
    @Published var autoCleanupPreview: AutoCleanupPlan?
    @Published var autoCleanupPreviewRuleID: UUID?
    @Published var isAutoCleanupScanning = false
    @Published var autoCleanupStatus = ""
    @Published var showAutoCleanupSheet = false

    // MARK: 配置体检（Shell rc + 网络配置，只读）

    @Published var shellIssues: [ShellIssue] = []
    @Published var shellAudited = false
    @Published var netProxies: [ProxyIssue] = []
    @Published var netHosts: [String] = []
    @Published var netAudited = false
    @Published var netFixRunning = false
    private var configAuditsStarted = false

    /// Shell 与网络配置体检（只读，每次会话一次）。
    func runConfigAudits(force: Bool = false) {
        if configAuditsStarted && !force { return }
        configAuditsStarted = true
        log(l10n.t("log.shellAudit"))
        Task {
            let shell = await MoleEngine.shared.runBridge("bin/app_shell_audit.sh", timeout: 60)
            shellIssues = Parsers.shellIssues(shell.output)
            shellAudited = true
            let net = await MoleEngine.shared.runBridge("bin/app_net_audit.sh", timeout: 60)
            let parsed = Parsers.netAudit(net.output)
            netProxies = parsed.proxies
            netHosts = parsed.hosts
            netAudited = true
        }
    }

    func openInEditor(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 关闭某个网络服务上的代理（owner 命令 networksetup，需管理员授权）。
    func disableProxy(_ proxy: ProxyIssue) {
        guard !netFixRunning else { return }
        confirmation = Confirmation(
            title: l10n.tf("audit.fixProxy.title", proxy.kind, proxy.service),
            message: l10n.t("audit.fixProxy.msg"),
            confirmLabel: l10n.t("audit.fixProxy")) { [weak self] in
                guard let self else { return }
                self.netFixRunning = true
                Task {
                    let result = await MoleEngine.shared.runPrivilegedBridge(
                        "bin/app_net_fixproxy.sh",
                        arguments: [proxy.service, proxy.kind], timeout: 120)
                    self.netFixRunning = false
                    self.log(self.l10n.t("log.proxyOff"))
                    self.logFailure(result)
                    let net = await MoleEngine.shared.runBridge("bin/app_net_audit.sh", timeout: 60)
                    let parsed = Parsers.netAudit(net.output)
                    self.netProxies = parsed.proxies
                    self.netHosts = parsed.hosts
                }
            }
    }

    var devEnvManagers: [(manager: String, entries: [DevEnvEntry])] {
        var order: [String] = []
        var buckets: [String: [DevEnvEntry]] = [:]
        for entry in devEnvEntries where !entry.isManager {
            if buckets[entry.manager] == nil { order.append(entry.manager) }
            buckets[entry.manager, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var devEnvManagerEntries: [DevEnvEntry] {
        devEnvEntries.filter(\.isManager)
    }

    var devEnvSelectedBytes: UInt64 {
        devEnvEntries.filter { devEnvSelection.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    var devEnvSelectedGlobalPackageBytes: UInt64 {
        devEnvEntries.filter { devEnvSelection.contains($0.path) }
            .reduce(0) { $0 + $1.relatedBytes }
    }

    // MARK: 磁盘分析

    @Published var analyzePath: String = NSHomeDirectory()
    @Published var analyzeEntries: [AnalyzeEntry] = []
    @Published var analyzeSelection: Set<String> = []
    @Published var analyzeTotalSize: UInt64 = 0
    @Published var analyzeLargeFiles: [AnalyzeReport.LargeFile] = []
    /// 磁盘分析的视图：目录浏览，或按大文件/图片/视频聚合的可瘦身清单。
    @Published var analyzeMode: AnalyzeMode = .directories
    @Published var analyzeMedia: [MediaFile] = []
    @Published var analyzeMediaSummary = MediaSummary()
    @Published var slimSelection: Set<String> = []
    @Published var slimOptions = SlimOptions()
    @Published var showSlimSheet = false
    @Published var isSlimming = false
    @Published var slimProgress: SlimProgress?
    var slimTask: Task<Void, Never>?
    @Published var isAnalyzing = false
    @Published var analyzeIsOverview = false
    /// 当前展示的是第一层“快速分析”结果（个人目录 + 既知缓存 + 保存位置）。
    @Published var analyzeStatus: String
    @Published var analyzeCurrentPath = ""
    var analyzeCache = DiskAnalysisCache()
    private var analyzeHasScanned = false
    private var analyzeScanControl: CleanupScanControl?

    // APFS 快照（本地 Time Machine 快照与可清除空间）
    @Published var purgeableBytes: UInt64 = 0
    @Published var localSnapshots: [SnapshotInfo] = []
    @Published var snapshotsScanned = false
    @Published var isThinning = false

    // 用户指定目录的精确重复文件 / 相似图片。
    @Published var showDuplicateFiles = false
    @Published var duplicateRoots: [String] = []
    @Published var duplicateMode: DuplicateMode = .exact
    @Published var duplicateGroups: [DuplicateFileGroup] = []
    @Published var duplicateSelection: Set<String> = []
    @Published var isScanningDuplicates = false
    @Published var isDeletingDuplicates = false
    @Published var duplicateStatus = ""
    @Published var duplicateCoverage = ""
    @Published var duplicateScanFinished = false
    var duplicateScanControl: DuplicateScanControl?
    var duplicateScannedRoots: [String] = []

    var analyzeSelectedBytes: UInt64 {
        analyzeEntries.filter {
            analyzeSelection.contains($0.path) && $0.canCleanDirectly
        }.reduce(0) { $0 + $1.size }
    }

    // MARK: 白名单

    @Published var whitelistEntries: [String] = []
    @Published var showWhitelistSheet = false

    // MARK: 确认弹窗

    @Published var confirmation: Confirmation?
    private var isDispatchingConfirmation = false

    /// Keep the disk worker gated while the alert closes and its accepted
    /// action is dispatched. Otherwise it can race a cleanup confirmation.
    func runConfirmation(_ accepted: Confirmation) {
        isDispatchingConfirmation = true
        confirmation = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            accepted.onConfirm()
            self.isDispatchingConfirmation = false
            self.startNextUninstallIfPossible()
        }
    }

    // MARK: 剪贴板历史与截图（设置中可开关）

    let clipboardManager = ClipboardHistoryManager()
    @Published var clipboardHistoryEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clipboardHistoryEnabled, forKey: "SMClipboardHistory")
            clipboardHistoryEnabled ? clipboardManager.start() : clipboardManager.stop()
            let featurePageCount = visiblePages.count - 1 - (clipboardHistoryEnabled ? 1 : 0)
            let previousSettingsIndex = featurePageCount + (oldValue ? 1 : 0)
            let wasSettings = selectedTab == previousSettingsIndex
            if wasSettings { jump(to: .settings) }
            else { selectedTab = min(selectedTab, max(0, visiblePages.count - 1)) }
        }
    }
    @Published var screenshotHotKeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(screenshotHotKeyEnabled, forKey: "SMShotHotKey")
            if screenshotHotKeyEnabled {
                screenshotHotKeyRegistrationFailed = !HotKeyCenter.shared.register {
                    NotificationCenter.default.post(name: .smTakeScreenshot, object: nil)
                }
            } else {
                HotKeyCenter.shared.unregister()
                screenshotHotKeyRegistrationFailed = false
            }
        }
    }
    @Published private(set) var screenshotHotKeyRegistrationFailed = false

    // MARK: 权限中心

    let permissionCenter = PermissionCenter.shared
    let authorizationCoordinator = AuthorizationCoordinator()
    @Published var showPermissionCenter = false
    private var activeProtectedOperation: ProtectedOperation?

    /// 受保护扫描脚本必须显式收到这个能力标记；脚本默认无标记时拒绝枚举
    /// Desktop、Documents 等 TCC 目录，形成 UI 门禁之外的第二层防护。
    private var fullDiskScanEnvironment: [String: String] {
        guard permissionCenter.fullDiskAccessGranted else { return [:] }
        return ["FORGESWEEP_FULL_DISK_AUTHORIZED": "1"]
    }

    var hasPendingPermissionAction: Bool {
        authorizationCoordinator.pendingOperation != nil
    }

    /// 明确登记可持久化的扫描意图。未授权时只打开权限中心，不执行扫描。
    func requestScanAccess(_ operation: ProtectedOperation) {
        guard authorize(operation, presentingPermissionCenter: true) else { return }
        executeProtectedOperation(operation)
    }

    func recheckFullDiskAccess() {
        guard permissionCenter.refresh() else {
            permissionCenter.reportDiskAccessNotDetected()
            return
        }
        resumePendingAuthorizedOperation()
    }

    func presentPermissionCenter() {
        permissionCenter.refresh()
        permissionCenter.clearDiskAuthorizationError()
        showPermissionCenter = true
    }

    func completePermissionSetup() {
        guard permissionCenter.refresh() else {
            if hasPendingPermissionAction {
                permissionCenter.reportDiskAccessNotDetected()
            } else {
                showPermissionCenter = false
            }
            return
        }
        resumePendingAuthorizedOperation()
    }

    func cancelPermissionCenter() {
        authorizationCoordinator.clearPending()
        showPermissionCenter = false
    }

    /// 应用从系统设置返回、重新激活或重启时调用。权限确认成功后，持久化操作
    /// 会先被消费再执行，因此多个激活通知也只会恢复一次。
    func refreshAuthorizationAndResume() {
        let granted = permissionCenter.refresh()
        guard granted else {
            if hasPendingPermissionAction { showPermissionCenter = true }
            return
        }
        activateProtectedDiskServices()
        // Permission availability is not a scan request. Only resume an
        // explicit user action that was waiting for authorization.
        guard hasPendingPermissionAction else { return }
        resumePendingAuthorizedOperation()
    }

    @discardableResult
    private func authorize(_ operation: ProtectedOperation,
                           presentingPermissionCenter: Bool) -> Bool {
        if activeProtectedOperation == operation { return true }
        guard permissionCenter.refresh() else {
            if presentingPermissionCenter {
                authorizationCoordinator.storePending(operation)
                presentPermissionCenter()
            }
            return false
        }
        return true
    }

    private func resumePendingAuthorizedOperation() {
        guard permissionCenter.fullDiskAccessGranted else { return }
        activateProtectedDiskServices()
        guard authorizationCoordinator.pendingOperation != nil else {
            showPermissionCenter = false
            return
        }
        // Busy 时保留待执行任务；下一个激活/显式“完成”会继续尝试。
        guard !isBusy else { return }
        guard let operation = authorizationCoordinator.takePending() else { return }
        showPermissionCenter = false
        executeProtectedOperation(operation)
    }

    private func executeProtectedOperation(_ operation: ProtectedOperation) {
        guard permissionCenter.refresh() else {
            authorizationCoordinator.storePending(operation)
            presentPermissionCenter()
            return
        }
        guard !isBusy else { return }

        activeProtectedOperation = operation
        defer { activeProtectedOperation = nil }
        switch operation {
        case .cleanupScan(let force): scanCleanup(force: force)
        case .deepCleanupScan: scanCleanup(force: true, mode: .deep)
        case .quickOptimize: quickOptimize()
        case .optimize: runOptimize()
        case .developerToolsScan: scanDeveloperTools()
        case .aiScan: scanAgents()
        case .installedAppsScan: scanInstalledApps()
        case .uninstall(let app): previewUninstall(app)
        case .developmentEnvironmentScan: scanDevEnv()
        case .diskOverview(let force): scanDiskOverview(force: force)
        case .diskAnalyze(let path): scanAnalyze(path)
        case .duplicateScan: scanDuplicates()
        case .previewAutoCleanup(let ruleID): previewAutoCleanup(ruleID)
        case .runAutoCleanup(let ruleID): runAutoCleanupNow(ruleID)
        }
    }

    private var cancellables: Set<AnyCancellable> = []
    private var scheduledAutomationRetry: DispatchWorkItem?
    private var reportedScheduledPermissionRequirement = false
    private var uninstallInventoryRefreshWorkItem: DispatchWorkItem?
    private var uninstallInventoryWatchers: [DispatchSourceFileSystemObject] = []
    private var uninstallInventoryWatchedPaths: Set<String> = []
    private var uninstallInventoryGeneration = 0
    private let l10n = L10n.shared

    var isBusy: Bool {
        isBusyExcludingUninstall || uninstallQueue.hasWork || cleanupQueued
    }

    var isBusyExcludingUninstall: Bool {
        isScanning || isApplying || isSlimming
            || isScanningEnv
            || isAnalyzing || isThinning || isScanningDuplicates || isDeletingDuplicates
            || gcRunningId != nil || netFixRunning || isAutoCleanupScanning
            || isOptimizing
            || agentScanning || agentApplying
            || simulatorInventory.isDeleting
    }

    var selectedCount: Int {
        categories.reduce(0) { $0 + $1.selectedPathCount }
    }

    var selectedBytes: UInt64 {
        categories.reduce(0) { $0 &+ $1.selectedPathBytes }
    }

    var quickCleanCount: Int {
        categories.filter(\.quickCleanEligible).reduce(0) { $0 + $1.selectedPathCount }
    }

    var quickCleanBytes: UInt64 {
        categories.filter(\.quickCleanEligible).reduce(0) { $0 &+ $1.selectedPathBytes }
    }

    var reviewCount: Int {
        categories.filter { $0.risk == .warning }.reduce(0) { $0 + $1.paths.count }
    }

    var totalBytes: UInt64 {
        categories.reduce(0) { $0 + $1.bytes }
    }

    init() {
        let knownPages = Set(PageKey.configurableCases.map(\.rawValue))
        var sanitizedHiddenPages = Set(UserDefaults.standard.stringArray(forKey: "SMHiddenPages") ?? [])
            .intersection(knownPages)
        if sanitizedHiddenPages.count == PageKey.configurableCases.count {
            sanitizedHiddenPages.remove(PageKey.cleanup.rawValue)
        }
        hiddenPages = sanitizedHiddenPages
        UserDefaults.standard.set(Array(sanitizedHiddenPages), forKey: "SMHiddenPages")
        clipboardHistoryEnabled = UserDefaults.standard.object(forKey: "SMClipboardHistory") as? Bool ?? false
        screenshotHotKeyEnabled = UserDefaults.standard.object(forKey: "SMShotHotKey") as? Bool ?? true
        islandEnabled = true
        UserDefaults.standard.set(true, forKey: "SMIslandEnabled")
        menuBarIconVisible = UserDefaults.standard.object(forKey: "SMMenuBarIconVisible") as? Bool ?? true
        islandEdge = IslandEdge(rawValue: UserDefaults.standard.string(forKey: "SMIslandEdge") ?? "") ?? .top
        let knownItems = Set(IslandItem.allCases.map(\.rawValue))
        let savedItems = Set(UserDefaults.standard.stringArray(forKey: "SMIslandItems") ?? []).intersection(knownItems)
        islandItems = savedItems.isEmpty
            ? [.cpu, .memory, .network]
            : savedItems.compactMap(IslandItem.init(rawValue:)).reduce(into: Set()) { $0.insert($1) }

        statusText = L10n.shared.t("status.ready")
        processStatus = L10n.shared.t("proc.status.apps") // 会在首次刷新时替换为带数量文案
        portStatus = L10n.shared.t("ports.status.none")
        appListStatus = L10n.shared.t("uninstall.status.none")
        devEnvStatus = L10n.shared.t("devenv.status.empty")
        analyzeStatus = L10n.shared.t("analyze.status.empty")
        autoCleanupStatus = L10n.shared.t("auto.status.ready")
        optimizeStatus = L10n.shared.t("optimize.status.ready")
        if !islandEnabled && !menuBarIconVisible { setMenuBarIconVisible(true) }

        Publishers.CombineLatest3($installedApps, $uninstallPlans, $uninstallSearch)
            .debounce(for: .milliseconds(80), scheduler: uninstallPresentationQueue)
            .map { UninstallListProjection.apps($0.0, plans: $0.1, query: $0.2) }
            .receive(on: DispatchQueue.main)
            .assign(to: &$filteredApps)

        let restoreGeneration = uninstallInventoryGeneration
        Task { [weak self] in
            let cachedInventory = await UninstallInventoryCache.restoreInBackground()
            guard let self else { return }
            if self.uninstallInventoryGeneration == restoreGeneration,
               self.installedApps.isEmpty, !self.isScanningApps, !cachedInventory.isEmpty {
                self.uninstallPlans = Dictionary(cachedInventory.map {
                    ($0.app.id, $0.plan)
                }, uniquingKeysWith: { _, latest in latest })
                self.installedApps = cachedInventory.map(\.app)
                self.appListStatus = self.l10n.tf("uninstall.status.count", self.installedApps.count)
            }
            self.isRestoringInstalledApps = false
            self.scheduleUninstallInventoryRefresh(after: cachedInventory.isEmpty ? 0.4 : 2.0)
        }

        refreshMetrics()
        $selectedTab
            .removeDuplicates()
            .sink { [weak self] tab in
                // Let SwiftUI commit the navigation animation before a tab
                // performs synchronous inventory work (notably process rows).
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.selectedTab == tab else { return }
                    let pages = self.visiblePages
                    guard tab < pages.count else { return }
                    // A full-disk traversal must not keep every cleanup action
                    // disabled after the user leaves the analysis page.
                    if pages[tab] != .analyze { self.cancelAnalyze() }
                    switch pages[tab] {
                    case .cleanup:
                        // Keep the existing result/selection. Scanning starts
                        // only from the user's quick/deep scan actions.
                        break
                    case .agents:
                        // 首次进入时自动做一次只读扫描；之后保留结果与选择。
                        self.permissionCenter.refresh()
                        if !self.agentHasScanned, !self.isBusy,
                           self.permissionCenter.fullDiskAccessGranted {
                            self.scanAgents()
                        }
                    case .analyze:
                        self.scanSnapshots()
                        self.permissionCenter.refresh()
                        if self.permissionCenter.fullDiskAccessGranted {
                            self.scanUserSpace()
                        }
                    case .uninstall:
                        // The page's cancellable loading task starts data work
                        // only after the navigation/placeholder has appeared.
                        break
                    case .optimize:
                        break
                    case .devenv:
                        self.permissionCenter.refresh()
                        if self.devEnvEntries.isEmpty,
                           self.permissionCenter.fullDiskAccessGranted {
                            self.scanDevEnv()
                        }
                        self.scanGc()
                        self.scanDockerDf()
                        self.runConfigAudits()
                    case .processes: self.refreshProcesses()
                    case .ports: self.refreshPorts()
                    case .traffic: self.trafficMonitor.tick()
                    default: break
                    }
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAuthorizationAndResume() }
            .store(in: &cancellables)
        // 语言切换：重置易变状态文案，避免出现混合语言。
        L10n.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isBusy else { return }
                self.statusText = self.l10n.t("status.ready")
                self.processStatus = self.l10n.t("proc.status.none")
                self.portStatus = self.l10n.t("ports.status.none")
                if !self.isScanningApps {
                    self.appListStatus = self.installedApps.isEmpty
                        ? self.l10n.t("uninstall.status.none")
                        : self.l10n.tf("uninstall.status.count", self.installedApps.count)
                }
                if !self.isScanningEnv { self.devEnvStatus = self.l10n.t("devenv.status.empty") }
                if !self.isAutoCleanupScanning {
                    self.autoCleanupStatus = self.l10n.t("auto.status.ready")
                }
                if !self.isOptimizing {
                    self.optimizeStatus = self.l10n.t("optimize.status.ready")
                }
            }
            .store(in: &cancellables)
        simulatorInventory.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        trafficMonitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        authorizationCoordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        clipboardManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Published changes are delivered on the next run-loop turn, after
        // the busy flags have changed. This wakes pending work without polling
        // or coupling the worker to the lifetime of the uninstall tab.
        objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.startNextUninstallIfPossible() }
            .store(in: &cancellables)
        // 服务启动放在所有存储属性初始化完成之后。
        if clipboardHistoryEnabled { clipboardManager.start() }
        if screenshotHotKeyEnabled {
            screenshotHotKeyRegistrationFailed = !HotKeyCenter.shared.register {
                NotificationCenter.default.post(name: .smTakeScreenshot, object: nil)
            }
        }
        // /Applications is safe to watch at launch. ~/.Trash is registered
        // only after Full Disk Access has been verified for this process.
        startUninstallInventoryMonitoring(includeProtectedPaths: false)
        DispatchQueue.main.async { [weak self] in
            self?.refreshAuthorizationAndResume()
        }
    }

    func takeScreenshot() {
        permissionCenter.refresh()
        guard permissionCenter.screenRecordingGranted else {
            presentPermissionCenter()
            return
        }
        NotificationCenter.default.post(name: .smTakeScreenshot, object: nil)
    }

    func requestScreenRecordingAccess() {
        // 请求 API 负责把 Nori 注册进屏幕录制列表；系统弹窗之外
        // 直接把设置面板打开到位，省掉用户再找入口。
        let granted = permissionCenter.requestScreenRecordingAccess()
        if granted { return }
        permissionCenter.openSystemSettings(.screenRecording)
        log(l10n.t("permissions.screen.restartHint"))
    }

    /// 系统设置里开关是开的、应用却拿不到权限：记录绑定的是旧签名。
    /// 清掉旧记录后系统会重新弹窗，再把设置面板打开到位。
    func repairScreenRecordingAuthorization() {
        Task { @MainActor in
            let ok = await permissionCenter.resetScreenRecordingDecision()
            if ok { permissionCenter.openSystemSettings(.screenRecording) }
            log(l10n.t(ok ? "permissions.repair.done" : "permissions.repair.failed"))
        }
    }

    func repairFullDiskAuthorization() {
        Task { @MainActor in
            let ok = await permissionCenter.resetFullDiskDecision()
            if ok { permissionCenter.openSystemSettings(.fullDisk) }
            log(l10n.t(ok ? "permissions.repair.done" : "permissions.repair.failed"))
        }
    }

    /// 屏幕录制授权只对"重启后的进程"生效。重启必须是严格的两段式：
    /// 先等本进程完全退出，再拉起同一 bundle。三个工程要点：
    /// 1. helper 按本进程 PID 等待（kill -0），不依赖进程名匹配；
    /// 2. 退出前先收起 sheet——AppKit 在 sheet 呈现期间可能否决 terminate
    ///    （表现为 Apple Event quit 返回 -128"用户已取消"）；
    /// 3. 看门狗兜底：terminate 发出 1.5s 后仍存活则 exit(0) 强制退出。
    private var relaunchInFlight = false

    func relaunchApplication() {
        guard !relaunchInFlight else { return }
        relaunchInFlight = true
        statusText = l10n.t("status.relaunching")
        log(l10n.t("status.relaunching"))

        let pid = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundlePath
        // 日志放在用户自己的 Logs 目录（0700），不再落到所有用户可写的 /tmp。
        let logDirectory = NSHomeDirectory() + "/Library/Logs/Nori"
        try? FileManager.default.createDirectory(
            atPath: logDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let script = """
        exec >>\(shellQuoted(logDirectory + "/relaunch.log")) 2>&1
        date '+relaunch helper started %H:%M:%S'
        while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
        date '+old instance exited %H:%M:%S'
        /usr/bin/open \(shellQuoted(bundlePath))
        date '+reopen issued %H:%M:%S'
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            relaunchInFlight = false
            statusText = l10n.t("status.relaunchFailed")
            log("relaunch helper failed: \(error.localizedDescription)")
            return
        }
        // 先收起所有 sheet，避免 AppKit 在 sheet 期间否决 terminate。
        dismissAllSheetsForTermination()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // terminate 被任何机制否决时的最终兜底；进程即将退出，
            // 清理逻辑（子进程组、队列）由各自超时与 fail-closed 边界兜底。
            exit(0)
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 退出路径统一收口：任何 sheet 都不能在应用退出时存活，
    /// 否则 AppKit 可能在 sheet 呈现期间否决整个退出。
    func dismissAllSheetsForTermination() {
        showPermissionCenter = false
        showAutoCleanupSheet = false
        showWhitelistSheet = false
    }

    // MARK: - 指标

    func refreshMetrics() {
        metrics = SystemMetrics.sample()
        networkHistory.append(metrics.networkRxMBps)
        if networkHistory.count > 60 { networkHistory.removeFirst(networkHistory.count - 60) }
    }

    // MARK: - 日志

    func appendLogLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }

    func log(_ text: String) {
        for line in text.components(separatedBy: "\n") {
            appendLogLine(line)
        }
    }

    /// 结构化解析始终只读 stdout；失败诊断单独展示 stderr，避免污染 TSV/JSON。
    private func logFailure(_ result: RunResult, stdoutAlreadyLogged: Bool = false) {
        guard !result.succeeded else { return }
        let diagnostic = result.errorOutput.isEmpty
            ? (stdoutAlreadyLogged ? "" : result.output)
            : result.errorOutput
        if !diagnostic.isEmpty { log(diagnostic) }
    }

    /// 引擎输出回调发生在后台线程，这里负责跳回主线程。
    nonisolated private func streamLog(_ line: String) {
        Task { @MainActor in self.appendLogLine(line) }
    }

    // MARK: - 扫描

    private func beginCleanupProgress(mode: CleanupScanMode = .quick) {
        cleanupOutcomeMood = nil
        cleanupProgressGeneration += 1
        cleanupScanMode = mode
        cleanupDeferredPaths = []
        cleanupProgress = CleanupScanProgress(
            phase: l10n.t("cleanup.progress.scanning"),
            completed: 0,
            total: 0,
            currentPath: NSHomeDirectory())
    }

    private func cleanupProgressSink() -> CleanupScanProgressSink {
        let generation = cleanupProgressGeneration
        return CleanupScanProgressSink { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self,
                      self.cleanupProgressGeneration == generation,
                      self.isCleanupScanning else { return }
                guard !self.cleanupProgress.isComplete else { return }
                self.cleanupProgress.currentPath = event.currentPath
                guard event.phase == "native", event.total > 0 else { return }
                self.cleanupProgress.completed = max(self.cleanupProgress.completed, event.completed)
                self.cleanupProgress.total = event.total
                self.cleanupProgress.detailCompleted = self.cleanupProgress.completed
                self.cleanupProgress.detailTotal = event.total
            }
        }
    }

    func cancelCleanupScan() {
        cleanupScanControl?.cancel()
        // A read-only inventory can overlap an uninstall. Never cancel that
        // unrelated mutation through the engine's global cancellation hook.
        if uninstallQueue.activeJob == nil { MoleEngine.shared.cancelAll() }
    }

    private func finishCleanupProgress() {
        let total = max(1, cleanupProgress.total)
        cleanupProgress.completed = total
        cleanupProgress.total = total
        cleanupProgress.isComplete = true
        cleanupProgress.detailCompleted = max(cleanupProgress.detailCompleted,
                                              cleanupProgress.detailTotal)
        cleanupProgress.phase = l10n.t("cleanup.progress.done")
        cleanupProgress.currentPath = l10n.t("cleanup.progress.done")
    }

    func scanCleanup(force: Bool = false, mode: CleanupScanMode = .quick) {
        let operation: ProtectedOperation = mode == .deep ? .deepCleanupScan : .cleanupScan(force: force)
        guard authorize(operation, presentingPermissionCenter: true) else {
            return
        }
        guard !isBusyExcludingUninstall, !cleanupQueued else { return }
        family = .clean
        if mode == .quick, !force, let cached = CleanupCache.restore() {
            beginCleanupProgress()
            isScanning = true
            cleanupScanComplete = false
            statusText = l10n.t("status.scanningCleanup")
            Task {
                let snapshot = await captureRunningApplicationSnapshot()
                categories = finalizedCleanupCategories(cached.categories)
                cleanupScanComplete = snapshot.isComplete
                if !cleanupScanComplete {
                    for index in categories.indices { categories[index].selected = false }
                }
                finishCleanupProgress()
                isScanning = false
                noteHeaderReaction(cleanupScanComplete ? .success : .attention)
                let minutes = max(1, Int(cached.age / 60))
                statusText = cleanupScanComplete
                    ? l10n.tf("status.cacheRestored", minutes)
                    : l10n.t("log.scanPartial")
                log(l10n.tf("log.cacheUsed", categories.reduce(0) { $0 + $1.paths.count },
                            ByteFormat.format(totalBytes)))
            }
            return
        }
        categories = []
        beginCleanupProgress(mode: mode)
        isScanning = true
        cleanupScanComplete = false
        statusText = l10n.t("status.scanningCleanup")
        log(l10n.t("log.buildList"))

        Task {
            let scan = await unifiedCleanupScan(mode: mode)
            let combined = finalizedCleanupCategories(scan.categories)
            categories = combined
            cleanupDeferredPaths = scan.deferredPaths
            cleanupScanComplete = scan.allSucceeded
            if !cleanupScanComplete {
                for index in categories.indices { categories[index].selected = false }
            }
            finishCleanupProgress()
            isScanning = false
            noteHeaderReaction(cleanupScanComplete ? .success : .attention)

            scan.results.filter { !$0.succeeded }.forEach { logFailure($0) }
            if combined.isEmpty {
                statusText = scan.allSucceeded
                    ? l10n.t("status.scanEmpty")
                    : l10n.t("log.scanPartial")
                log(scan.allSucceeded ? l10n.t("log.scanEmpty") : l10n.t("log.scanPartial"))
            } else {
                statusText = scan.allSucceeded
                    ? l10n.tf("status.scanDone", combined.count)
                    : l10n.t("log.scanPartial")
                log(scan.allSucceeded
                    ? l10n.tf("log.scanDone", combined.reduce(0) { $0 + $1.paths.count },
                              ByteFormat.format(totalBytes))
                    : l10n.t("log.scanPartial"))
            }
            // Persist a successful empty result as well as a non-empty one.
            // A manual request may reuse a valid snapshot, including an
            // empty one. The cache stores only static scanner output; runtime
            // protection is still reapplied on every restore/use.
            if mode == .quick && scan.cacheable { CleanupCache.save(scan.categories) }
        }
    }

    func quickOptimize() {
        guard authorize(.quickOptimize, presentingPermissionCenter: true) else { return }
        guard !isBusyExcludingUninstall, !cleanupQueued else { return }
        family = .clean
        jump(to: .cleanup)
        // One-click clean only prepares the quick inventory. It never opens a
        // confirmation dialog or starts deleting in the background.
        scanCleanup(force: true, mode: .quick)
    }

    var optimizeSelectedCount: Int {
        optimizeTasks.filter { $0.selected && $0.selectable }.count
    }

    var optimizeHasPreview: Bool { optimizeTasks.contains { $0.preview != nil } }

    /// Read-only pass: every task reports whether it is needed and what it
    /// would change. Needed tasks are preselected unless they erase history.
    func runOptimize() {
        guard authorize(.optimize, presentingPermissionCenter: true) else { return }
        guard !isBusy else {
            optimizeStatus = l10n.t("optimize.status.busy")
            return
        }
        isOptimizing = true
        optimizeStatus = l10n.t("optimize.status.inspecting")
        let requested = optimizeTasks
        Task { @MainActor [weak self] in
            guard let self else { return }
            let inspected = await NativeCore.shared.inspectOptimize(tasks: requested)
            self.optimizeTasks = inspected
            self.isOptimizing = false
            self.noteHeaderReaction(.success)
            let needed = inspected.filter(\.selectable).count
            self.optimizeStatus = self.l10n.tf("optimize.status.inspected", needed, self.optimizeSelectedCount)
        }
    }

    func toggleOptimizeTask(_ id: String) {
        guard !isOptimizing, let index = optimizeTasks.firstIndex(where: { $0.id == id }),
              optimizeTasks[index].selectable else { return }
        optimizeTasks[index].selected.toggle()
    }

    func selectRecommendedOptimize() {
        guard !isOptimizing else { return }
        for index in optimizeTasks.indices {
            optimizeTasks[index].selected = optimizeTasks[index].selectable && optimizeTasks[index].defaultOn
        }
    }

    func clearOptimizeSelection() {
        guard !isOptimizing else { return }
        for index in optimizeTasks.indices { optimizeTasks[index].selected = false }
    }

    /// The user confirms once; each selected task reports its own result and
    /// failures do not prevent the remaining independent tasks from running.
    func applySelectedOptimize() {
        guard authorize(.optimize, presentingPermissionCenter: true) else { return }
        guard !isBusy, optimizeSelectedCount > 0 else { return }
        let admin = NativeCore.shared.selectedAdminTasks(optimizeTasks)
        confirmation = Confirmation(
            title: l10n.t("optimize.confirm.title"),
            message: l10n.tf(admin.isEmpty ? "optimize.confirm.selected" : "optimize.confirm.selectedAdmin",
                             optimizeSelectedCount, admin.count),
            confirmLabel: l10n.t("optimize.runSelected")) { [weak self] in
                self?.performOptimize()
            }
    }

    private func performOptimize() {
        guard !isOptimizing else { return }
        isOptimizing = true
        optimizeStatus = l10n.t("optimize.status.running")
        log(l10n.t("optimize.log.start"))
        let requested = optimizeTasks
        let admin = NativeCore.shared.selectedAdminTasks(requested)
        let testMode = ProcessInfo.processInfo.environment["MOLE_TEST_NO_AUTH"] == "1"
            || ProcessInfo.processInfo.environment["MOLE_TEST_MODE"] == "1"
        Task { @MainActor [weak self] in
            guard let self else { return }
            var tasks = await NativeCore.shared.runOptimize(tasks: requested).tasks
            if !admin.isEmpty {
                if testMode {
                    tasks = NativeCore.mergeAdminResults("", succeeded: false, requested: admin, into: tasks)
                } else {
                    let result = await MoleEngine.shared.runPrivilegedBridge(
                        "bin/app_optimize_admin.sh", arguments: [String(getuid())] + admin, timeout: 1800)
                    tasks = NativeCore.mergeAdminResults(result.output, succeeded: result.succeeded,
                                                         requested: admin, into: tasks)
                    if !result.succeeded { self.logFailure(result) }
                }
            }
            self.optimizeTasks = tasks
            self.isOptimizing = false
            let applied = tasks.filter { $0.state == .applied }.count
            let failed = tasks.filter { $0.state == .failed }.count
            self.noteHeaderReaction(failed > 0 ? .attention : (applied > 0 ? .success : nil))
            self.optimizeStatus = self.l10n.tf("optimize.status.done", applied, failed)
            self.log(self.l10n.tf("optimize.log.done", applied, failed))
            for task in tasks where task.state != .pending {
                self.log("\(task.title): \(task.message)")
            }
        }
    }

    private struct UnifiedCleanupScan {
        let categories: [CleanupCategory]
        /// Keep filesystem scanners separate from the process snapshot. A
        /// process-table failure must not discard completed cache discovery;
        /// the apply boundary still clears/reevaluates runtime-sensitive paths.
        let sourceResults: [RunResult]
        /// Only fully measured paths enter the result. Coverage gaps are
        /// reported separately and prevent persisting a complete snapshot.
        let requiredSourceResults: [RunResult]
        let runtimeResult: RunResult
        let runningSnapshot: RunningApplicationSnapshot
        var deferredPaths: [String] = []

        var results: [RunResult] { sourceResults + [runtimeResult] }

        var sourceScansSucceeded: Bool {
            requiredSourceResults.allSatisfy(\.succeeded)
        }

        var cacheable: Bool { sourceScansSucceeded && deferredPaths.isEmpty }

        /// 进程表失败只隐藏依赖运行态的路径；它不应让已经完成的 cache/log
        /// 扫描整体变成不可用。执行边界仍会 fail-closed 复核。
        var allSucceeded: Bool { sourceScansSucceeded }
    }

    private func unifiedCleanupScan(mode: CleanupScanMode = .quick) async -> UnifiedCleanupScan {
        guard permissionCenter.refresh() else {
            let denied = RunResult(
                output: "", errorOutput: "Full Disk Access is required for protected scan.",
                exitCode: 77, timedOut: false)
            return UnifiedCleanupScan(
                categories: [], sourceResults: [denied],
                requiredSourceResults: [denied],
                runtimeResult: denied, runningSnapshot: .unavailable)
        }
        let control = CleanupScanControl(mode: mode)
        cleanupScanControl = control
        defer { cleanupScanControl = nil }
        let progress = isCleanupScanning ? cleanupProgressSink() : nil
        async let core = NativeCore.shared.scanCleanup(progress: progress, mode: mode, control: control)
        async let runtimeText = Task.detached(priority: .utility) {
            SystemMetrics.processSnapshotText()
        }.value

        let (coreScan, runtimeOutput) = await (core, runtimeText)
        log(coreScan.diagnostics)
        let runtimeResult = RunResult(
            output: runtimeOutput ?? "",
            errorOutput: runtimeOutput == nil ? "Native process snapshot unavailable." : "",
            exitCode: runtimeOutput == nil ? 1 : 0,
            timedOut: false)
        let coreResult = RunResult(
            output: "", errorOutput: coreScan.error ?? "",
            exitCode: coreScan.succeeded ? 0 : 1, timedOut: false)

        let combined = CleanupCategory.safeCleanupCandidates(from: coreScan.categories)
        if mode == .deep, !control.isCancelled {
            cleanupProgress.phase = l10n.t("file.installer")
            let installers = await MoleEngine.shared.runBridge("bin/app_installer_scan.sh",
                extraEnvironment: fullDiskScanEnvironment, timeout: 45)
            installerCandidates = installers.succeeded
                ? Parsers.installerCategory(installers.output)?.clearingSelection() : nil
            if !installers.succeeded { logFailure(installers) }
        }
        if control.isCancelled {
            let cancelled = RunResult(output: "", errorOutput: "Scan cancelled.", exitCode: 1, timedOut: false)
            return UnifiedCleanupScan(categories: [], sourceResults: [cancelled],
                requiredSourceResults: [cancelled], runtimeResult: runtimeResult,
                runningSnapshot: .unavailable)
        }


        let snapshot = RuntimeStore.runningApplicationSnapshot(
            fromProcessText: runtimeResult.output, isComplete: runtimeResult.succeeded)
        return UnifiedCleanupScan(
            categories: combined,
            sourceResults: [coreResult],
            requiredSourceResults: [coreResult],
            runtimeResult: runtimeResult,
            runningSnapshot: snapshot,
            deferredPaths: coreScan.deferredPaths)
    }

    func captureRunningApplicationSnapshot() async -> RunningApplicationSnapshot {
        let output = await Task.detached(priority: .utility) {
            SystemMetrics.processSnapshotText()
        }.value
        let result = RunResult(
            output: output ?? "",
            errorOutput: output == nil ? "Native process snapshot unavailable." : "",
            exitCode: output == nil ? 1 : 0,
            timedOut: false)
        if !result.succeeded { logFailure(result) }
        return RuntimeStore.runningApplicationSnapshot(
            fromProcessText: result.output, isComplete: result.succeeded)
    }

    /// 执行侧运行态收口：自动化规则不经确认直接删除，必须先用最新进程快照
    /// 裁剪运行中应用的缓存。普通手动清理走 performApply 的重评估即可。
    private func protectRunningApplications(in source: [CleanupCategory],
                                            snapshot: RunningApplicationSnapshot)
        -> [CleanupCategory] {
        source.compactMap {
            CleanupRiskPolicy.runtimeEligibleSubset($0, running: snapshot)
        }.sorted(by: CleanupCategory.sizeDescending)
    }

    /// 扫描结果的展示收口：只保留 Safe 垃圾并默认全部勾选（safe 即选中），
    /// 长尾小项合并成「其他」。运行中应用的保护不在展示层做——执行前
    /// performApply 会用最新进程快照重新评估，运行中的路径会计入「已跳过」。
    private func finalizedCleanupCategories(_ source: [CleanupCategory]) -> [CleanupCategory] {
        CleanupCategory.mergingLongTail(
            CleanupCategory.safeCleanupCandidates(from: source)
        ).sorted(by: CleanupCategory.sizeDescending)
    }

    /// 开发工具扫描：包管理器卸载命令，Warning 项留给人工判断。
    func scanDeveloperTools() {
        guard authorize(.developerToolsScan, presentingPermissionCenter: true) else { return }
        guard !isBusy else { return }
        let scanEnvironment = fullDiskScanEnvironment
        guard scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1" else { return }
        family = .tools
        categories = []
        isScanning = true
        cleanupScanComplete = false
        statusText = l10n.t("status.scanning")
        log(l10n.t("log.scanningSafe"))
        Task {
            async let scanResult = MoleEngine.shared.runBridge(
                "bin/app_tool_scan.sh", extraEnvironment: scanEnvironment,
                timeout: 180, onLine: streamLog)
            async let runtimeText = Task.detached(priority: .utility) {
                SystemMetrics.processSnapshotText()
            }.value
            let (result, runtimeOutput) = await (scanResult, runtimeText)
            let runtime = RunResult(
                output: runtimeOutput ?? "",
                errorOutput: runtimeOutput == nil ? "Native process snapshot unavailable." : "",
                exitCode: runtimeOutput == nil ? 1 : 0,
                timedOut: false)
            isScanning = false
            cleanupScanComplete = result.succeeded && runtime.succeeded
            noteHeaderReaction(cleanupScanComplete ? .success : .attention)
            // 运行态保护交给执行前的重新评估。
            categories = Parsers.toolCategories(result.output)
                .sorted(by: CleanupCategory.sizeDescending)
            if !cleanupScanComplete {
                for index in categories.indices { categories[index].selected = false }
            }
            if categories.isEmpty {
                statusText = cleanupScanComplete
                    ? l10n.t("status.specialEmpty") : l10n.t("log.specialFail")
                log(cleanupScanComplete ? l10n.t("log.specialEmpty") : l10n.t("log.specialFail"))
                logFailure(result)
            } else {
                statusText = cleanupScanComplete
                    ? l10n.tf("status.scanSpecialDone", categories.count)
                    : l10n.t("log.specialFail")
                log(cleanupScanComplete
                    ? l10n.tf("log.specialDone", categories.reduce(0) { $0 + $1.paths.count },
                              ByteFormat.format(totalBytes))
                    : l10n.t("log.specialFail"))
                logFailure(result)
            }
            logFailure(runtime)
        }
    }

    // MARK: - 清理执行

    func applyInstallers() {
        guard !isBusy, let selection = installerCandidates?.selectedSubset else { return }
        // 安装包可能是用户唯一的副本：默认移入废纸篓（方案 §5.3）。
        confirmation = Confirmation(title: l10n.t("file.installer"),
            message: l10n.tf("cleanup.installers.confirm", selection.paths.count,
                             ByteFormat.format(selection.bytes)),
            confirmLabel: l10n.t("confirm.apply.trash.ok")) { [weak self] in
                guard let self, !self.isBusy else { return }
                self.isApplying = true
                Task {
                    let result = await self.executeCleanupRoute(.installerTrash,
                        categories: [selection], mode: .manual,
                        permanently: false)
                    self.installerCandidates = self.installerCandidates?.retainingPaths(
                        self.installerCandidates?.paths.filter { FileManager.default.fileExists(atPath: $0) } ?? [])
                    self.isApplying = false
                    self.reportCleanupResult(result, permanently: false)
                }
            }
    }

    func applyCleanup() {
        guard !isBusyExcludingUninstall, !cleanupQueued, cleanupScanComplete else {
            if !cleanupScanComplete { statusText = l10n.t("log.scanPartial") }
            return
        }
        // Task {} inherits MainActor. Snapshot the selection and move the
        // potentially large filtering/sorting pass off the UI executor.
        let source = categories
        let applyFamily = family
        let previousStatus = statusText
        isApplying = true
        statusText = l10n.tf("status.processing", selectedCount)
        Task {
            let selectedCategories = await Task.detached(priority: .utility) {
                let subsets = source.compactMap(\.selectedSubset)
                return applyFamily == .clean
                    ? CleanupCategory.safeCleanupCandidates(from: subsets) : subsets
            }.value
            isApplying = false
            statusText = previousStatus
            guard !selectedCategories.isEmpty else {
                statusText = l10n.t("cleanup.selectNone")
                return
            }
            confirmApply(categories: selectedCategories, family: applyFamily)
        }
    }

    private func confirmApply(categories selectedCategories: [CleanupCategory],
                              family applyFamily: CleanupFamily) {
        let selectedCount = selectedCategories.reduce(0) { $0 + $1.paths.count }
        let actionTitle: String
        var message: String
        switch applyFamily {
        case .clean:
            // 磁盘清理是永久删除：用独立的不可逆确认文案。
            actionTitle = l10n.t("confirm.cleanupPermanent.ok")
            message = l10n.t("confirm.cleanupPermanent.msg")
        case .tools:
            actionTitle = l10n.t("confirm.apply.tools.ok")
            message = l10n.t("confirm.apply.tools.msg")
        }
        let warningCount = selectedCategories
            .filter { $0.risk == .warning }
            .reduce(0) { $0 + $1.paths.count }
        if warningCount > 0 {
            message += "\n\n" + l10n.tf("cleanup.warningConfirmation", warningCount)
        }
        confirmation = Confirmation(
            title: Self.permanentFamilies.contains(applyFamily)
                ? l10n.tf("confirm.cleanupPermanent.title", selectedCount)
                : l10n.tf("confirm.apply.title", selectedCount),
            message: message,
            confirmLabel: actionTitle) { [weak self] in
                self?.performApply(categories: selectedCategories,
                                   family: applyFamily, mode: .manual)
        }
    }

    /// 永久删除的家族：清理页；安装包、卸载、分析选择项默认移入废纸篓。
    private static let permanentFamilies: Set<CleanupFamily> = [.clean]

    /// 执行阶段再次读取进程表，并按每个类别自己的 route 分流。扫描来源不会再
    /// 因为 UI 合并展示而退化成通用删除入口。
    private func performApply(categories requested: [CleanupCategory],
                              family applyFamily: CleanupFamily,
                              mode: CleanupExecutionMode) {
        if uninstallQueue.activeJob != nil {
            guard pendingCleanup == nil else { return }
            cleanupQueued = true
            statusText = l10n.t("cleanup.queued")
            pendingCleanup = { [weak self] in
                self?.performApply(categories: requested,
                                   family: applyFamily, mode: mode)
            }
            return
        }
        let requestedCount = requested.reduce(0) { $0 + $1.paths.count }
        isApplying = true
        statusText = l10n.tf("status.processing", requestedCount)
        Task {
            let snapshot = await captureRunningApplicationSnapshot()
            let prepared = await Task.detached(priority: .utility) {
                var eligible: [CleanupCategory] = []
                var protectedReasons: [UUID: String] = [:]
                let recheckControl = CleanupScanControl(mode: .quick)
                for category in requested {
                    // 年龄门复核：扫描后重新活跃（或时间证据失效）的条目
                    // 不再进入本次执行，计入跳过而不是放宽门槛。
                    var reviewed = category
                    if category.retention > 0 {
                        let stillStale = category.paths.filter { path in
                            category.isPathSelected(path)
                        }.filter { path in
                            let recheck = CleanupScanWorker.measure(
                                path, control: recheckControl)
                            return recheck.complete && CleanupAgePolicy.isStale(
                                recheck.activityEvidence, retention: category.retention)
                        }
                        reviewed = category.selectingPaths(stillStale)
                    }
                    guard reviewed.selected || reviewed.risk != .safe else {
                        continue
                    }
                    let assessment = CleanupRiskPolicy.reassess(reviewed, running: snapshot)
                    let subset = CleanupRiskPolicy.runtimeEligibleSubset(reviewed, running: snapshot)
                    if let subset, CleanupRiskPolicy.isEligible(subset, mode: mode, running: snapshot) {
                        eligible.append(subset)
                    } else if assessment.risk == .protected {
                        protectedReasons[category.id] = assessment.reasonKey
                    }
                }
                return (eligible, protectedReasons)
            }.value
            let eligible = prepared.0
            for index in categories.indices {
                if let reason = prepared.1[categories[index].id] {
                    categories[index].risk = .protected
                    categories[index].reasonKey = reason
                    categories[index].selected = false
                }
            }

            let eligibleCount = eligible.reduce(0) { $0 + $1.paths.count }
            var executionResult = CleanupExecutionResult(
                skipped: max(0, requestedCount - eligibleCount))
            // The immutable eligible plan, rather than the still-visible UI
            // selection, is the number this execution will actually submit.
            statusText = l10n.tf("status.processing", eligibleCount)
            guard !eligible.isEmpty else {
                await refreshCleanupInventory(after: applyFamily)
                isApplying = false
                reportCleanupResult(executionResult,
                                    permanently: Self.permanentFamilies.contains(applyFamily))
                return
            }

            let grouped = Dictionary(grouping: eligible, by: \.applyRoute)
            for route in CleanupApplyRoute.allCases {
                guard let routeCategories = grouped[route], !routeCategories.isEmpty else { continue }
                let started = Date()
                log("cleanup route=\(route.rawValue) started paths=\(routeCategories.reduce(0) { $0 + $1.paths.count })")
                let routeResult = await executeCleanupRoute(
                    route, categories: routeCategories, mode: mode,
                    permanently: Self.permanentFamilies.contains(applyFamily))
                log(String(format: "cleanup route=%@ completed %.2fs", route.rawValue, Date().timeIntervalSince(started)))
                executionResult.merge(routeResult)
            }

            await refreshCleanupInventory(after: applyFamily)
            isApplying = false
            reportCleanupResult(executionResult,
                                permanently: Self.permanentFamilies.contains(applyFamily))
            if applyFamily == .tools { scanDeveloperTools() }
        }
    }

    private func refreshCleanupInventory(after family: CleanupFamily) async {
        CleanupCache.invalidate()
        guard family == .clean else { return }
        statusText = l10n.t("cleanup.refreshing")
        let displayed = categories
        let refreshed = await Task.detached(priority: .utility) {
            CleanupInventoryRefresh.refresh(displayed)
        }.value
        categories = refreshed.categories
        cleanupDeferredPaths = Array(Set(cleanupDeferredPaths + refreshed.deferredPaths)).sorted()
    }

    private func reportCleanupResult(_ result: CleanupExecutionResult,
                                     permanently: Bool) {
        cleanupOutcomeMood = NoriCleanupFeedback.mood(removed: result.removed, skipped: result.skipped, failed: result.failed)
        noteHeaderReaction(NoriHeaderReaction.mood(removed: result.removed, skipped: result.skipped, failed: result.failed))
        cleanupFeedbackID += 1
        analyzeCache.clear()
        // 报告文案与执行器的实际动作一致：永久删除与移入废纸篓分开表述。
        let key = permanently
            ? "cleanup.execution.summary.permanent"
            : "cleanup.execution.summary"
        let summary = l10n.tf(key, result.removed, result.skipped, result.failed)
        statusText = summary
        log(summary)
    }

    private func executeCleanupRoute(_ route: CleanupApplyRoute,
                                     categories routeCategories: [CleanupCategory],
                                     mode: CleanupExecutionMode,
                                     permanently: Bool = false) async
        -> CleanupExecutionResult {
        let preparedRecords = await Task.detached(priority: .utility) {
            let raw = routeCategories.flatMap(\.paths)
            switch route {
            case .genericTrash, .installerTrash, .developerCacheTrash, .aiTrash, .xcodeTrash:
                return (raw.count, DeletionPlan.nonOverlappingPaths(raw))
            case .toolCommand, .none:
                return (raw.count, raw)
            }
        }.value
        let records = preparedRecords.1
        let coalescedCount = max(0, preparedRecords.0 - records.count)
        guard !records.isEmpty else {
            return CleanupExecutionResult(skipped: coalescedCount)
        }

        let bridgeName: String
        let stdinData: Data
        switch route {
        case .genericTrash, .developerCacheTrash, .aiTrash, .xcodeTrash:
            let applied = await Task.detached(priority: .utility) {
                let items = routeCategories.flatMap { category in
                    category.paths.compactMap { path -> DeletionPlan.Item? in
                        guard let identity = category.pathIdentities[path], !identity.isEmpty else { return nil }
                        return DeletionPlan.Item(record: path, identity: identity)
                    }
                }
                return (NativeCore.shared.applyCleanup(items: items, permanent: permanently), items.count)
            }.value
            let summary = applied.0
            if !summary.messages.isEmpty { log(summary.messages.joined(separator: "\n")) }
            let missing = records.count - applied.1
            return CleanupExecutionResult(
                removed: summary.removed,
                skipped: summary.skipped + coalescedCount + max(0, missing),
                failed: summary.failed,
                removedPaths: summary.removedPaths)
        case .installerTrash:
            bridgeName = "bin/app_installer_apply.sh"
            stdinData = await Task.detached(priority: .utility) {
                let items = routeCategories.flatMap { category in
                    category.paths.compactMap { path -> DeletionPlan.Item? in
                        guard let identity = category.pathIdentities[path] else { return nil }
                        return DeletionPlan.Item(record: path, identity: identity)
                    }
                }
                return DeletionPlan(items: items).stdinData
            }.value
        case .toolCommand:
            bridgeName = "bin/app_tool_apply.sh"
            var data = Data()
            for record in records {
                data.append(contentsOf: record.utf8)
                data.append(0)
            }
            stdinData = data
        case .none:
            return CleanupExecutionResult(skipped: coalescedCount, failed: records.count)
        }

        log(l10n.tf("log.pipeline", records.count,
                    (bridgeName as NSString).lastPathComponent))
        var environment: [String: String] = ["SIMPLEMOLE_EXECUTION_MODE": {
            switch mode {
            case .manual: return "manual"
            case .quickClean: return "quickClean"
            case .automatic: return "automatic"
            }
        }()]
        environment.merge(fullDiskScanEnvironment) { _, authorized in authorized }
        if route == .installerTrash, permanently {
            environment["SIMPLEMOLE_DELETE_MODE"] = "permanent"
        }
        let result = await MoleEngine.shared.runBridgeWithStdin(
            bridgeName, stdinData: stdinData, extraEnvironment: environment, timeout: 900)
        if !result.output.isEmpty { log(result.output) }
        logFailure(result, stdoutAlreadyLogged: true)
        var summary = CleanupExecutionResult.reconciled(
            bridgeOutput: result.output, expectedCount: records.count)
        if summary.removed == records.count {
            summary.removedPaths = Set(records)
        }
        summary.skipped += coalescedCount
        return summary
    }

    // MARK: - 进程与端口

    func refreshRuntimeIfNeeded() {
        guard mainWindowVisible, !runtimeInFlight, !isBusy else { return }
        guard visiblePages.indices.contains(selectedTab) else { return }
        if visiblePages[selectedTab] == .processes {
            if advancedProcesses { refreshProcesses() } else { refreshNativeProcesses() }
        } else if visiblePages[selectedTab] == .ports { refreshPorts() }
        // Traffic uses its own timer while the page is visible or monitoring is enabled.
    }

    func refreshProcesses(allowAutomaticCleanup: Bool = true) {
        guard advancedProcesses else {
            resetAutomaticProcessCleanup()
            refreshNativeProcesses()
            return
        }
        guard !runtimeInFlight else { return }
        let requestedAdvancedMode = advancedProcesses
        runtimeInFlight = true
        if processRows.isEmpty { processStatus = l10n.t("proc.status.reading") }
        Task {
            let result = await MoleEngine.shared.runRuntime("processes")
            guard requestedAdvancedMode == advancedProcesses else {
                runtimeInFlight = false
                refreshProcesses()
                return
            }
            guard result.succeeded else {
                if requestedAdvancedMode {
                    automaticProcessTracker.breakSequence()
                }
                runtimeInFlight = false
                processStatus = l10n.t("proc.status.readFailed")
                logFailure(result)
                return
            }
            if requestedAdvancedMode {
                let rows = RuntimeStore.rows(fromProcessText: result.output, advanced: true)
                processRows = rows
                // 验证重扫也必须更新 tracker，确保恢复正常或已消失的进程
                // 及时打断旧计数；只禁止这一拍继续执行自动动作。
                let candidates = automaticProcessTracker.candidates(in: rows)
                let selection = allowAutomaticCleanup
                    ? automaticCleanupSelection(fromCandidates: candidates)
                    : (actions: [], attemptedRows: [])
                if !selection.actions.isEmpty {
                    processStatus = l10n.tf("proc.status.autoProcessing", selection.actions.count)
                    await runAutomaticProcessCleanup(selection.actions)
                    return
                }
                runtimeInFlight = false
                updateAdvancedProcessStatus(for: rows)
            } else {
                resetAutomaticProcessCleanup()
                let native = RuntimeStore.nativeRows(fromProcessText: result.output)
                processRows = native.rows
                processStatus = l10n.tf("proc.status.apps", native.total)
                runtimeInFlight = false
            }
        }
    }

    // MARK: 应用级进程视图（libproc）

    /// 当前可见的进程组：搜索过滤 + 排序。
    var visibleProcessGroups: [ProcessGroup] {
        ProcessAggregator.sorted(ProcessAggregator.filter(processGroups, query: processSearch),
                                 by: processSort)
    }

    func processCPUHistory(_ pid: Int32) -> [Double] { processHistory.series(for: pid) }

    /// 用 libproc 采样并按应用聚合。不占用 runtimeInFlight，采样在后台线程，
    /// 只有 NSWorkspace 的应用列表在主线程读取。
    func refreshNativeProcesses() {
        guard !processSampleInFlight else { return }
        processSampleInFlight = true
        if processGroups.isEmpty { processStatus = l10n.t("proc.status.reading") }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Nori"
        let applications: [(pid: Int32, name: String, startIdentity: String)] =
            NSWorkspace.shared.runningApplications.compactMap { application in
                guard !application.isTerminated,
                      application.processIdentifier > 1,
                      application.processIdentifier != ownPID,
                      application.activationPolicy != .prohibited,
                      let identity = RuntimeStore.nativeStartIdentity(for: application) else { return nil }
                let name = application.localizedName ?? application.bundleIdentifier ?? ""
                guard !name.isEmpty, name != ownName, name != "Mole" else { return nil }
                return (application.processIdentifier, name, identity)
            }
        Task {
            let sampled: (groups: [ProcessGroup], total: Int) = await Task.detached(priority: .utility) {
                let samples = ProcessSampler.shared.sample()
                let groups = ProcessAggregator.groups(
                    samples: samples, applications: applications, ownPID: ownPID,
                    detail: { L10n.shared.tf("proc.detail.app", $0) },
                    childDetail: { L10n.shared.tf("proc.detail.pid", $0.pid) })
                return (groups, samples.count)
            }.value
            processSampleInFlight = false
            guard !advancedProcesses else { return }
            processGroups = sampled.groups
            let liveTokens = Set(sampled.groups.map { $0.app.signalToken })
            processQuitFeedback = processQuitFeedback.filter {
                liveTokens.contains($0.key) || $0.value == .waiting
            }
            processRows = sampled.groups.map(\.app)
            processHistory.record(sampled.groups)
            processAlerts = highUsageTracker.update(sampled.groups)
            processStatus = l10n.tf("proc.status.sampled", sampled.groups.count, sampled.total)
        }
    }

    private func runningApplication(for row: ProcessRow) -> NSRunningApplication? {
        guard let application = NSRunningApplication(processIdentifier: row.pid),
              !application.isTerminated,
              RuntimeStore.nativeStartIdentity(for: application) == row.startIdentity else { return nil }
        return application
    }

    /// 温和退出（等同 ⌘Q）：应用可以弹出保存提示；5 秒后仍在运行则提示可强制退出。
    func quitApplication(_ row: ProcessRow) {
        guard processQuitFeedback[row.signalToken] != .waiting else { return }
        guard let application = runningApplication(for: row) else {
            processQuitFeedback[row.signalToken] = .stale
            processActionStatus = l10n.t("proc.refusal.identity")
            refreshNativeProcesses()
            return
        }
        processQuitFeedback[row.signalToken] = .waiting
        processActionStatus = l10n.tf("proc.status.quitRequested", row.name)
        guard application.terminate() else {
            processQuitFeedback[row.signalToken] = .refused
            processActionStatus = l10n.t("status.quitRefused")
            return
        }
        Task {
            for _ in 0..<50 {
                if application.isTerminated { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            processActionStatus = application.isTerminated
                ? l10n.tf("proc.status.quitDone", row.name)
                : l10n.tf("proc.status.stillRunning", row.name)
            processQuitFeedback[row.signalToken] = application.isTerminated ? nil : .stillRunning
            refreshNativeProcesses()
        }
    }

    /// 结束整组：主进程 terminate → 5 秒 → forceTerminate；子进程 SIGTERM → 3 秒 → SIGKILL。
    /// 每个子进程结束前都重新核对启动身份、用户与路径。
    func endProcessGroup(_ group: ProcessGroup) {
        confirmation = Confirmation(
            title: l10n.tf("proc.confirm.endGroup.title", group.app.name),
            message: l10n.tf("proc.confirm.endGroup.msg", group.children.count),
            confirmLabel: l10n.t("proc.endGroup")) { [weak self] in
                guard let self else { return }
                Task { await self.performEndGroup(group) }
            }
    }

    private func performEndGroup(_ group: ProcessGroup) async {
        guard processQuitFeedback[group.app.signalToken] != .waiting else { return }
        processQuitFeedback[group.app.signalToken] = .waiting
        defer { processQuitFeedback[group.app.signalToken] = nil }
        processActionStatus = l10n.tf("proc.status.quitRequested", group.app.name)
        let application = runningApplication(for: group.app)
        var mainEnded = application == nil
        if let application {
            if !application.terminate() { _ = application.forceTerminate() }
            for _ in 0..<50 {
                if application.isTerminated { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !application.isTerminated { _ = application.forceTerminate() }
            for _ in 0..<10 where !application.isTerminated {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            mainEnded = application.isTerminated
        }
        var endedChildren = 0
        for child in group.children {
            guard let identity = Self.childIdentity(child) else { continue }
            if await ProcessTerminator.terminateThenKill(identity, grace: 3) { endedChildren += 1 }
        }
        processActionStatus = mainEnded
            ? l10n.tf("proc.status.groupEnded", group.app.name, endedChildren)
            : l10n.tf("proc.status.stillRunning", group.app.name)
        refreshNativeProcesses()
    }

    /// 结束单个子进程（非应用主进程）。
    func terminateChildProcess(_ row: ProcessRow) {
        guard let identity = Self.childIdentity(row) else { return }
        confirmation = Confirmation(
            title: l10n.tf("proc.confirm.child.title", row.name),
            message: l10n.tf("proc.confirm.kill.msg", row.pid),
            confirmLabel: l10n.t("proc.kill")) { [weak self] in
                guard let self else { return }
                Task {
                    switch ProcessTerminator.validate(identity) {
                    case .failure(let refusal):
                        self.processActionStatus = self.l10n.t(Self.refusalKey(refusal))
                        return
                    case .success:
                        break
                    }
                    let ended = await ProcessTerminator.terminateThenKill(identity, grace: 3)
                    self.processActionStatus = ended
                        ? self.l10n.t("status.signalSent") : self.l10n.t("status.signalFailed")
                    self.refreshNativeProcesses()
                }
            }
    }

    private static func childIdentity(_ row: ProcessRow) -> ProcessIdentity? {
        guard let startTime = UInt64(row.startIdentity, radix: 16) else { return nil }
        return ProcessIdentity(pid: row.pid, startTime: startTime, ppid: row.ppid, uid: row.uid)
    }

    private static func refusalKey(_ refusal: ProcessTerminator.Refusal) -> String {
        switch refusal {
        case .identityChanged: return "proc.refusal.identity"
        case .otherUser: return "proc.refusal.otherUser"
        case .protectedPath: return "proc.refusal.protected"
        case .ownProcessTree: return "proc.refusal.own"
        }
    }

    /// 连续采样达到阈值后才自动处理。每轮最多执行四个动作；多个 zombie
    /// 共用同一 UID + PPID 时只通知父进程一次，但会一起标记为已尝试。
    private func automaticCleanupSelection(fromCandidates candidates: [ProcessRow])
        -> (actions: [ProcessRow], attemptedRows: [ProcessRow]) {
        guard !candidates.isEmpty else { return ([], []) }

        var actions: [ProcessRow] = []
        var attemptedRows: [ProcessRow] = []
        var selectedZombieParents: Set<String> = []

        for row in candidates {
            if row.lifecycle == .zombie {
                let parentKey = "\(row.uid):\(row.ppid)"
                if selectedZombieParents.contains(parentKey) {
                    attemptedRows.append(row)
                    continue
                }
                guard actions.count < 4 else { continue }
                selectedZombieParents.insert(parentKey)
                actions.append(row)
                attemptedRows.append(row)
            } else {
                guard actions.count < 4 else { continue }
                actions.append(row)
                attemptedRows.append(row)
            }
        }

        automaticProcessTracker.markAttempted(attemptedRows)
        automaticProcessCleanupTokens.formUnion(attemptedRows.map(\.staleCleanupToken))
        return (actions, attemptedRows)
    }

    private func runAutomaticProcessCleanup(_ rows: [ProcessRow]) async {
        var attempted = 0
        var succeeded = 0
        for row in rows {
            guard advancedProcesses else { break }
            attempted += 1
            let result = await MoleEngine.shared.runRuntime("cleanup-stale", row.staleCleanupToken)
            if result.succeeded {
                succeeded += 1
            } else {
                logFailure(result)
            }
        }

        automaticProcessCleanupAttempted += attempted
        automaticProcessCleanupSucceeded += succeeded
        runtimeInFlight = false
        guard advancedProcesses else {
            resetAutomaticProcessCleanup()
            return
        }
        // 以重扫结果作为最终状态，避免把已变化或未回收的进程误报为成功。
        // 验证重扫不继续取下一批，单轮最多自动处理四个；其余候选交给下次定时刷新。
        refreshProcesses(allowAutomaticCleanup: false)
    }

    private func updateAdvancedProcessStatus(for rows: [ProcessRow]) {
        let abnormalRows = rows.filter { $0.lifecycle != .normal }
        let abnormalCount = abnormalRows.count
        automaticProcessCleanupTokens.formIntersection(abnormalRows.map(\.staleCleanupToken))
        if automaticProcessCleanupAttempted > 0 {
            let succeeded = automaticProcessCleanupSucceeded
            automaticProcessCleanupAttempted = 0
            automaticProcessCleanupSucceeded = 0
            if abnormalCount == 0, succeeded > 0 {
                processStatus = l10n.tf("proc.status.autoCleaned", succeeded)
            } else if abnormalCount == 0 {
                // 处理失败后目标可能自行退出；此时不把自然消失误报成清理成功。
                processStatus = rows.isEmpty
                    ? l10n.t("proc.status.none")
                    : l10n.tf("proc.status.pids", rows.count)
            } else {
                processStatus = l10n.tf("proc.status.abnormalRemaining", abnormalCount)
            }
        } else if !automaticProcessCleanupTokens.isEmpty {
            processStatus = l10n.tf("proc.status.abnormalRemaining", abnormalCount)
        } else if abnormalCount > 0 {
            processStatus = l10n.tf("proc.status.abnormalDetected", abnormalCount)
        } else {
            processStatus = rows.isEmpty
                ? l10n.t("proc.status.none")
                : l10n.tf("proc.status.pids", rows.count)
        }
    }

    private func resetAutomaticProcessCleanup() {
        automaticProcessTracker = RuntimeStore.AutomaticCandidateTracker()
        automaticProcessCleanupAttempted = 0
        automaticProcessCleanupSucceeded = 0
        automaticProcessCleanupTokens.removeAll()
    }

    func refreshPorts() {
        guard !runtimeInFlight else { return }
        runtimeInFlight = true
        portStatus = l10n.t("ports.status.reading")
        Task {
            let result = await MoleEngine.shared.runRuntime("ports")
            runtimeInFlight = false
            // 读取失败时保留上一轮列表，不把"读不到"显示成"没有端口"。
            guard result.succeeded else {
                portStatus = l10n.t("ports.status.readFailed")
                logFailure(result)
                return
            }
            portRows = RuntimeStore.portRows(fromText: result.output)
            portStatus = portRows.isEmpty
                ? l10n.t("ports.status.none")
                : l10n.tf("ports.status.count", portRows.count)
        }
    }

    func terminateProcess(_ row: ProcessRow) {
        if row.isNativeApp {
            guard processQuitFeedback[row.signalToken] != .waiting else { return }
            confirmation = Confirmation(
                title: l10n.tf("proc.confirm.quit.title", row.name),
                message: l10n.t("proc.force.message"),
                confirmLabel: l10n.t("proc.force.action")) {
                    guard self.processQuitFeedback[row.signalToken] != .waiting else { return }
                    let application = NSRunningApplication(processIdentifier: row.pid)
                    let identityMatches = application.flatMap(RuntimeStore.nativeStartIdentity(for:))
                        == row.startIdentity
                    let requested = identityMatches && !(application?.isTerminated ?? true)
                        ? (application?.forceTerminate() ?? false)
                        : false
                    self.processQuitFeedback[row.signalToken] = requested ? .waiting : .refused
                    Task { @MainActor in
                        self.processActionStatus = requested
                            ? self.l10n.t("status.quitRequested")
                            : self.l10n.t("status.quitRefused")
                        guard requested, let application else { return }
                        for _ in 0..<20 {
                            if application.isTerminated { break }
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                        self.processActionStatus = application.isTerminated
                            ? self.l10n.t("proc.force.done") : self.l10n.t("status.quitRefused")
                        self.processQuitFeedback[row.signalToken] = application.isTerminated ? nil : .refused
                        self.refreshProcesses(allowAutomaticCleanup: false)
                    }
                }
            return
        }
        if row.lifecycle != .normal {
            confirmation = Confirmation(
                title: l10n.t("proc.confirm.cleanupStale.title"),
                message: l10n.t("proc.confirm.cleanupStale.msg"),
                confirmLabel: l10n.t("proc.cleanupStale")) { [weak self] in
                    self?.cleanupStaleProcess(row)
                }
            return
        }
        let mode = advancedProcesses ? "kill-pid" : "kill-group"
        let title = advancedProcesses
            ? l10n.t("proc.confirm.killPid.title")
            : l10n.t("proc.confirm.killGroup.title")
        confirmation = Confirmation(
            title: title,
            message: l10n.tf("proc.confirm.kill.msg", row.pid),
            confirmLabel: l10n.t("proc.kill")) { [weak self] in
                guard let self else { return }
                Task {
                    while self.runtimeInFlight {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    self.runtimeInFlight = true
                    let result = await MoleEngine.shared.runRuntime(mode, row.signalToken)
                    self.processActionStatus = result.succeeded
                        ? self.l10n.t("status.signalSent")
                        : self.l10n.t("status.signalFailed")
                    self.runtimeInFlight = false
                    self.refreshProcesses(allowAutomaticCleanup: false)
                }
            }
    }

    private func cleanupStaleProcess(_ row: ProcessRow) {
        guard advancedProcesses, !runtimeInFlight, row.lifecycle != .normal else { return }
        let coveredRows: [ProcessRow]
        if row.lifecycle == .zombie {
            coveredRows = processRows.filter {
                $0.lifecycle == .zombie && $0.uid == row.uid && $0.ppid == row.ppid
            }
        } else {
            coveredRows = [row]
        }
        automaticProcessTracker.markAttempted(coveredRows)
        automaticProcessCleanupTokens.formUnion(coveredRows.map(\.staleCleanupToken))
        runtimeInFlight = true
        processStatus = l10n.tf("proc.status.autoProcessing", 1)
        Task {
            let result = await MoleEngine.shared.runRuntime("cleanup-stale", row.staleCleanupToken)
            automaticProcessCleanupAttempted += 1
            if result.succeeded {
                automaticProcessCleanupSucceeded += 1
            } else {
                logFailure(result)
            }
            runtimeInFlight = false
            guard advancedProcesses else {
                resetAutomaticProcessCleanup()
                return
            }
            refreshProcesses(allowAutomaticCleanup: false)
        }
    }

    func closePort(_ row: PortRow) {
        confirmation = Confirmation(
            title: l10n.tf("ports.confirm.title", row.pid),
            message: l10n.tf("ports.confirm.msg", row.port, row.command),
            confirmLabel: l10n.t("ports.close")) { [weak self] in
                guard let self else { return }
                Task {
                    let result = await MoleEngine.shared.runRuntime("kill-pid", row.signalToken)
                    self.portStatus = result.succeeded
                        ? self.l10n.t("status.signalSent")
                        : self.l10n.t("status.signalFailed")
                    self.refreshPorts()
                }
            }
    }

    // MARK: - 应用卸载

    func uninstallPlan(for app: UninstallApp) -> UninstallPlan? {
        uninstallPlans[app.id]
    }

    private func persistUninstallInventory() {
        let records = installedApps.compactMap { app -> UninstallInventoryRecord? in
            guard let plan = uninstallPlans[app.id] else { return nil }
            return .init(app: app, plan: plan)
        }
        UninstallInventoryCache.saveInBackground(records)
    }

    private nonisolated static func fetchUninstallPlan(for app: UninstallApp) async
        -> (String, UninstallPlan?) {
        let plan = await NativeCore.shared.uninstallPlan(
            for: app, homeDirectory: NSHomeDirectory())
        return (app.id, plan)
    }

    func scanInstalledApps(background: Bool = false) {
        guard authorize(.installedAppsScan,
                        presentingPermissionCenter: !background) else { return }
        guard !isScanningApps, !uninstallQueue.hasWork else { return }
        guard permissionCenter.refresh() else { return }
        let scanEnvironment = fullDiskScanEnvironment
        guard scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1" else { return }
        let generation = uninstallInventoryGeneration
        isScanningApps = true
        if !background || installedApps.isEmpty {
            appListStatus = l10n.t("uninstall.status.scanning")
        }
        Task {
            let apps = await NativeCore.shared.scanInstalledApps(
                homeDirectory: NSHomeDirectory())
            guard generation == uninstallInventoryGeneration else {
                isScanningApps = false
                scheduleUninstallInventoryRefresh(after: 0.5)
                return
            }
            guard generation == uninstallInventoryGeneration else {
                isScanningApps = false
                scheduleUninstallInventoryRefresh(after: 0.5)
                return
            }
            let previousApps = Dictionary(uniqueKeysWithValues: installedApps.map { ($0.id, $0) })
            let currentApps = Dictionary(apps.map { ($0.id, $0) },
                                         uniquingKeysWith: { _, latest in latest })
            uninstallPlans = uninstallPlans.filter { id, plan in
                guard let previous = previousApps[id],
                      let current = currentApps[id] else { return false }
                return previous.appIdentity == current.appIdentity
                    && previous.infoIdentity == current.infoIdentity
                    && plan.includesProtectedAppData
                    && !plan.fileIdentities.isEmpty
            }
            installedApps = apps
            appListStatus = installedApps.isEmpty
                ? l10n.t("uninstall.status.empty")
                : l10n.tf("uninstall.status.count", installedApps.count)
            persistUninstallInventory()

            let missing = apps.filter { uninstallPlans[$0.id] == nil }
            let batchSize = 4
            var superseded = false
            for start in stride(from: 0, to: missing.count, by: batchSize) {
                guard generation == uninstallInventoryGeneration else { superseded = true; break }
                let end = min(start + batchSize, missing.count)
                let batch = Array(missing[start..<end])
                let plans = await withTaskGroup(
                    of: (String, UninstallPlan?).self,
                    returning: [(String, UninstallPlan?)].self
                ) { group in
                    for app in batch {
                        group.addTask {
                            await Self.fetchUninstallPlan(
                                for: app)
                        }
                    }
                    var output: [(String, UninstallPlan?)] = []
                    for await plan in group { output.append(plan) }
                    return output
                }
                guard generation == uninstallInventoryGeneration else { superseded = true; break }
                var updatedPlans = uninstallPlans
                for (id, plan) in plans {
                    if let plan { updatedPlans[id] = plan }
                }
                uninstallPlans = updatedPlans
                persistUninstallInventory()
            }
            isScanningApps = false
            if !background && !superseded { noteHeaderReaction(.success) }
        }
    }

    func previewUninstall(_ app: UninstallApp) {
        guard !uninstallQueue.containsPendingOrActive(app) else { return }
        guard authorize(.uninstall(app: app), presentingPermissionCenter: true) else { return }
        guard !app.appIdentity.isEmpty else {
            log(l10n.tf("log.uninstallPreviewFail", app.name))
            return
        }
        // Capture a plan only if it belongs to this exact inventory identity.
        // A missing preview is prepared by the FIFO worker after confirmation.
        let cached = installedApps.first(where: { $0.id == app.id }) == app
            ? uninstallPlans[app.id] : nil
        let plan = cached.flatMap {
            $0.includesProtectedAppData && !$0.fileIdentities.isEmpty ? $0 : nil
        }
        // The row's destructive action is already explicit. Do not insert an
        // application-level confirmation between the click and queue entry;
        // the queue keeps the request's identity snapshot and NativeCore
        // performs the final identity and path checks before any side effect.
        guard uninstallQueue.enqueue(app: app, plan: plan) != nil else { return }
        startNextUninstallIfPossible()
    }

    func uninstallJob(for app: UninstallApp) -> UninstallJob? {
        uninstallQueue.jobs.last { $0.app.id == app.id }
    }

    func uninstallQueuePosition(for app: UninstallApp) -> Int? {
        uninstallQueue.jobs.filter { $0.state.isPending }
            .firstIndex { $0.app.id == app.id }.map { $0 + 1 }
    }

    func cancelQueuedUninstall(id: UUID) {
        guard uninstallQueue.cancel(id) else { return }
        startNextUninstallIfPossible()
        if !uninstallQueue.hasWork { scheduleUninstallInventoryRefresh(after: 1) }
    }

    func stopUninstallQueueForTermination() {
        isStoppingUninstallQueue = true
        pendingCleanup = nil
        cleanupQueued = false
        uninstallInventoryRefreshWorkItem?.cancel()
        for job in uninstallQueue.jobs where job.state.isPending {
            uninstallQueue.cancel(job.id)
        }
    }

    private func startNextUninstallIfPossible() {
        if !isStoppingUninstallQueue, let action = pendingCleanup, uninstallQueue.activeJob == nil,
           !isBusyExcludingUninstall, confirmation == nil, !isDispatchingConfirmation {
            pendingCleanup = nil
            cleanupQueued = false
            action()
            return
        }
        // Preserve mutual exclusion at the disk mutation edge while allowing
        // more confirmed requests to join the queue from any visible row.
        let blocked = isBusyExcludingUninstall || confirmation != nil || isDispatchingConfirmation
        // A no-op mutating access to an @Published value still publishes. Keep
        // these read-only guards outside startNext to avoid a wake-up loop.
        guard !isStoppingUninstallQueue, !blocked,
              uninstallQueue.activeJob == nil, uninstallQueue.hasPendingJobs else { return }
        guard let job = uninstallQueue.startNext(blocked: blocked) else { return }
        // Drop any in-flight read-only inventory result that predates this job.
        uninstallInventoryGeneration += 1
        Task {
            await executeUninstall(job)
            startNextUninstallIfPossible()
            if !uninstallQueue.hasWork { scheduleUninstallInventoryRefresh(after: 1) }
        }
    }

    private func executeUninstall(_ job: UninstallJob) async {
        let target = job.app
        // Queued requests may outlive an authorization change. Do not prompt
        // or retry with broader access from the background worker.
        guard permissionCenter.refresh() else {
            finishUninstall(job, succeeded: false, message: l10n.t("uninstall.queue.permissionLost"))
            return
        }
        // The cached plan is for presentation only. Apps create caches after
        // inventory scans and while requests wait in the queue; rescan the
        // same captured application identity immediately before removal.
        log(l10n.tf("log.uninstallScan", target.name))
        let (_, plan) = await Self.fetchUninstallPlan(for: target)
        guard let plan, !plan.files.isEmpty, plan.includesProtectedAppData else {
            finishUninstall(job, succeeded: false, message: l10n.tf("log.uninstallPreviewFail", target.name))
            return
        }
        uninstallQueue.markRunning(job.id)
        statusText = l10n.tf("status.uninstalling", target.name)
        log(l10n.tf("log.uninstallApply", target.name))
        let result = await Task.detached(priority: .utility) {
            NativeCore.shared.applyUninstall(target, plan: plan,
                                             homeDirectory: NSHomeDirectory())
        }.value
        if !result.messages.isEmpty { log(result.messages.joined(separator: "\n")) }
        if result.removed > 0 { CleanupCache.invalidate() }
        uninstallInventoryGeneration += 1
        if result.succeeded {
            installedApps.removeAll { $0.id == target.id && $0.appIdentity == target.appIdentity }
            uninstallPlans.removeValue(forKey: target.id)
            persistUninstallInventory()
            appListStatus = l10n.tf("uninstall.status.count", installedApps.count)
            var message = l10n.tf("status.uninstalled", target.name)
            if !result.retainedPaths.isEmpty {
                message += "\n" + l10n.tf("uninstall.retained", result.retainedPaths.count)
                    + "\n" + result.retainedPaths.joined(separator: "\n")
            }
            finishUninstall(job, succeeded: true, message: message)
        } else {
            // A partial uninstall can change the identity. A retry must pass
            // through a fresh user confirmation after inventory refresh.
            uninstallPlans.removeValue(forKey: target.id)
            persistUninstallInventory()
            var detail = l10n.tf("log.uninstallPartial", result.removed, result.failed)
            if !result.remainingPaths.isEmpty {
                detail += "\n" + l10n.tf("uninstall.remaining", result.remainingPaths.count)
                    + "\n" + result.remainingPaths.joined(separator: "\n")
            }
            finishUninstall(job, succeeded: false,
                            message: l10n.tf("status.uninstallPartial", target.name) + "\n" + detail)
        }
    }

    private func finishUninstall(_ job: UninstallJob, succeeded: Bool, message: String) {
        uninstallQueue.finish(job.id, succeeded: succeeded, message: message)
        noteHeaderReaction(succeeded ? .success : .attention)
        statusText = message
        log(message)
    }

    /// Watches the roots where app installs and uninstalls become visible.
    /// Directory events are coalesced because Finder/Homebrew may emit several
    /// writes for one operation.
    private func startUninstallInventoryMonitoring(includeProtectedPaths: Bool) {
        var paths = [
            "/Applications",
            NSHomeDirectory().appending("/Applications")
        ]
        if includeProtectedPaths {
            paths.append(NSHomeDirectory().appending("/.Trash"))
        }
        for path in paths where !uninstallInventoryWatchedPaths.contains(path)
            && FileManager.default.fileExists(atPath: path) {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib],
                queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleUninstallInventoryRefresh(after: 1.0)
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            uninstallInventoryWatchers.append(source)
            uninstallInventoryWatchedPaths.insert(path)
        }
    }

    /// Services that enumerate persisted user locations or ~/.Trash are
    /// activated only after the one-time Full Disk Access check succeeds.
    private func activateProtectedDiskServices() {
        guard permissionCenter.fullDiskAccessGranted else { return }
        startUninstallInventoryMonitoring(includeProtectedPaths: true)
    }

    private func scheduleUninstallInventoryRefresh(after delay: TimeInterval) {
        guard !isStoppingUninstallQueue else { return }
        uninstallInventoryRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if self.isScanningApps || self.uninstallQueue.hasWork {
                    self.scheduleUninstallInventoryRefresh(after: 1.0)
                } else {
                    self.scanInstalledApps(background: true)
                }
            }
        }
        uninstallInventoryRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 开发环境

    func scanDevEnv(announce: Bool = true) {
        guard authorize(.developmentEnvironmentScan,
                        presentingPermissionCenter: true) else { return }
        guard !isBusy else { return }
        let scanEnvironment = fullDiskScanEnvironment
        guard scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1" else { return }
        isScanningEnv = true
        devEnvStatus = l10n.t("devenv.status.scanning")
        Task {
            let result = await MoleEngine.shared.runBridge(
                "bin/app_env_scan.sh", extraEnvironment: scanEnvironment,
                timeout: 180)
            isScanningEnv = false
            if announce { noteHeaderReaction(result.succeeded ? .success : .attention) }
            devEnvEntries = Parsers.devEnvEntries(result.output)
            devEnvSelection.removeAll()
            let runtimeCount = devEnvEntries.filter { !$0.isManager }.count
            let managerCount = devEnvEntries.filter(\.isManager).count
            devEnvStatus = devEnvEntries.isEmpty
                ? l10n.t("devenv.status.none")
                : l10n.tf("devenv.status.summary", runtimeCount, managerCount)
            logFailure(result)
        }
    }

    func applyDevEnvCleanup() {
        guard !isBusy else { return }
        let paths = devEnvEntries.filter { devEnvSelection.contains($0.path) }.map(\.path)
        guard !paths.isEmpty else {
            devEnvStatus = l10n.t("devenv.selectFirst")
            return
        }
        let bytes = devEnvSelectedBytes
        let globalPackageBytes = devEnvSelectedGlobalPackageBytes
        let deletionPlan = DeletionPlan(paths: paths)
        confirmation = Confirmation(
            title: l10n.tf("confirm.env.title", paths.count),
            message: globalPackageBytes > 0
                ? l10n.tf("confirm.env.msg.node", paths.count, ByteFormat.format(bytes),
                           ByteFormat.format(globalPackageBytes))
                : l10n.tf("confirm.env.msg", paths.count, ByteFormat.format(bytes)),
            confirmLabel: l10n.t("confirm.apply.trash.ok")) { [weak self] in
                guard let self else { return }
                self.isApplying = true
                self.statusText = self.l10n.t("status.envCleaning")
                self.log(self.l10n.tf("log.envClean", paths.count))
                Task {
                    let result = await MoleEngine.shared.runBridgeWithStdin(
                        "bin/app_apply.sh", stdinData: deletionPlan.stdinData, timeout: 900)
                    self.isApplying = false
                    if !result.output.isEmpty { self.log(result.output) }
                    self.logFailure(result, stdoutAlreadyLogged: true)
                    let summary = Parsers.applySummary(result.output)
                    let fullySucceeded = result.succeeded && summary.failed == 0
                    self.noteHeaderReaction(fullySucceeded ? .success : .attention)
                    self.statusText = fullySucceeded
                        ? self.l10n.tf("status.envDone", summary.removed)
                        : self.l10n.tf("status.envPartial", summary.failed)
                    self.log(fullySucceeded
                        ? self.l10n.tf("log.envDone", summary.removed)
                        : self.l10n.tf("log.envPartial", summary.removed, summary.failed))
                    self.scanDevEnv(announce: false)
                    // 环境删除可能让 PATH 条目/初始化块失效：重跑体检引导用户处理。
                    self.runConfigAudits(force: true)
                    self.log(self.l10n.t("log.envRcHint"))
                }
            }
    }

    // MARK: - 包管理 GC（owner 命令）

    /// 列出本机可用的官方 GC 命令（只读扫描，每次会话最多一次）。
    func scanGc() {
        if gcScanned || gcRunningId != nil { return }
        gcScanned = true
        Task {
            let result = await MoleEngine.shared.runBridge("bin/app_gc_scan.sh", timeout: 60)
            gcActions = result.output.components(separatedBy: "\n").compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2, !parts[0].isEmpty else { return nil }
                return GcAction(id: parts[0], command: parts[1],
                                bytes: parts.count > 2 ? UInt64(parts[2]) ?? 0 : 0)
            }
        }
    }

    /// 运行一个白名单内的官方 GC 命令，输出逐行流入日志抽屉。
    func runGc(_ action: GcAction) {
        guard !isBusy else { return }
        confirmation = Confirmation(
            title: l10n.tf("gc.confirm.title", action.id),
            message: l10n.tf("gc.confirm.msg", action.command),
            confirmLabel: l10n.t("gc.run")) { [weak self] in
                guard let self else { return }
                self.gcRunningId = action.id
                self.statusText = self.l10n.tf("log.gcRun", action.command)
                self.log(self.l10n.tf("log.gcRun", action.command))
                Task {
                    let result = await MoleEngine.shared.runBridge(
                        "bin/app_gc_run.sh", arguments: [action.id],
                        timeout: 1200, onLine: self.streamLog)
                    self.gcRunningId = nil
                    self.noteHeaderReaction(result.succeeded ? .success : .attention)
                    self.statusText = result.succeeded
                        ? self.l10n.t("gc.finished")
                        : self.l10n.t("gc.failed")
                    self.log(result.succeeded
                        ? self.l10n.t("gc.finished")
                        : self.l10n.t("gc.failed"))
                    self.gcScanned = false
                    self.scanGc()
                }
            }
    }

    // MARK: - 磁盘分析

    /// Explicit root scope uses the same traversal as custom directories.
    func scanDiskOverview(force: Bool = false) {
        guard authorize(.diskOverview(force: force),
                        presentingPermissionCenter: true), !isBusy else { return }
        if !force, analyzeHasScanned { return }
        if force { analyzeCache.invalidate("/") }
        startAnalyze(displayPath: "/", overview: true)
    }

    /// 首次进入从当前用户目录开始，返回页面时保留当前浏览位置。
    func scanUserSpace() {
        guard !analyzeHasScanned else { return }
        scanAnalyze(NSHomeDirectory())
    }

    func scanAnalyze(_ path: String? = nil, force: Bool = false) {
        guard !isBusy else { return }
        let target = URL(fileURLWithPath: path ?? analyzePath, isDirectory: true).standardizedFileURL.path
        if force { analyzeCache.invalidate(target) }
        if let cached = analyzeCache.report(for: target) {
            showAnalyzeReport(cached)
            return
        }
        guard authorize(.diskAnalyze(path: target),
                        presentingPermissionCenter: true) else { return }
        startAnalyze(displayPath: target, overview: target == "/")
    }

    func cancelAnalyze() { analyzeScanControl?.cancel() }

    private func startAnalyze(displayPath: String, overview: Bool) {
        guard fullDiskScanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1" else { return }
        analyzeHasScanned = true
        analyzePath = displayPath
        analyzeIsOverview = overview
        if let cached = analyzeCache.report(for: displayPath) {
            showAnalyzeReport(cached)
            return
        }
        isAnalyzing = true
        analyzeCurrentPath = ""
        analyzeEntries = []
        analyzeTotalSize = 0
        analyzeLargeFiles = []
        analyzeMedia = []
        analyzeMediaSummary = MediaSummary()
        slimSelection.removeAll()
        analyzeSelection.removeAll()
        analyzeStatus = l10n.t("analyze.scanning")
        let control = CleanupScanControl(mode: .deep)
        analyzeScanControl = control
        Task {
            let report = await NativeCore.shared.scanAnalyze(
                path: displayPath, overview: overview, control: control,
                progress: { [weak self] report in
                    Task { @MainActor in
                        guard let self, self.analyzeScanControl === control else { return }
                        self.analyzeEntries = report.entries
                        self.analyzeTotalSize = report.totalSize
                        self.analyzeCurrentPath = report.currentPath ?? ""
                        self.analyzeStatus = "\(self.l10n.t("common.scanning")) · ≥ \(ByteFormat.format(report.totalSize))"
                    }
                })
            guard analyzeScanControl === control else { return }
            analyzeScanControl = nil
            isAnalyzing = false
            // Keep the partial result visible, but do not reuse an interrupted
            // traversal as the cached inventory for later navigation.
            if !control.isCancelled { analyzeCache.store(report) }
            showAnalyzeReport(report)
            noteHeaderReaction(NoriHeaderReaction.mood(
                succeeded: report.error == nil && report.isPartial != true,
                cancelled: control.isCancelled))
        }
    }

    private func showAnalyzeReport(_ report: AnalyzeReport) {
        analyzeCurrentPath = ""
        analyzeSelection.removeAll()
        analyzeIsOverview = report.overview
        analyzePath = report.path
        // 0 字节且统计完整的条目没有信息量：隐藏它们让列表聚焦真实占用；
        // 标注为部分统计（未知大小）的条目保留展示。
        analyzeEntries = report.entries
            .filter { $0.size > 0 || $0.isPartial == true }
            .sorted(by: AnalyzeEntry.analysisOrder)
        analyzeTotalSize = report.totalSize
        analyzeLargeFiles = report.largeFiles ?? []
        analyzeMedia = report.media ?? []
        analyzeMediaSummary = report.mediaSummary ?? MediaSummary()
        slimSelection.removeAll()
        if let error = report.error {
            analyzeStatus = error
        } else {
            analyzeStatus = l10n.tf(report.isPartial == true
                ? "analyze.directory.partial" : "analyze.status.summary",
                analyzeEntries.count, ByteFormat.format(analyzeTotalSize))
        }
    }

    // MARK: APFS 快照

    /// 读取可清除空间与本地快照列表（只读，幂等）。
    func scanSnapshots(force: Bool = false) {
        if snapshotsScanned && !force { return }
        snapshotsScanned = true
        Task {
            let result = await MoleEngine.shared.runBridge("bin/app_snapshots_scan.sh", timeout: 60)
            let info = Parsers.snapshotInfo(result.output)
            purgeableBytes = info.purgeable
            localSnapshots = info.names.map { SnapshotInfo(name: $0) }
            logFailure(result)
        }
    }

    /// 请求 Time Machine 归还本地快照空间（owner 命令，需管理员授权）。
    func thinSnapshots() {
        guard !isBusy else { return }
        confirmation = Confirmation(
            title: l10n.t("analyze.thin.confirm.title"),
            message: l10n.t("analyze.thin.confirm.msg"),
            confirmLabel: l10n.t("analyze.thin")) { [weak self] in
                guard let self else { return }
                self.isThinning = true
                self.log(self.l10n.t("log.thinSnapshots"))
                Task {
                    let result = await MoleEngine.shared.runPrivilegedBridge(
                        "bin/app_snapshots_thin.sh", arguments: [], timeout: 300)
                    self.isThinning = false
                    self.noteHeaderReaction(result.succeeded ? .success : .attention)
                    if result.succeeded {
                        let names = result.output.components(separatedBy: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        self.localSnapshots = names.map { SnapshotInfo(name: $0) }
                        self.log(self.l10n.t("gc.finished"))
                    } else {
                        self.log(self.l10n.t("gc.failed"))
                        self.logFailure(result)
                    }
                    self.scanSnapshots(force: true)
                }
            }
    }

    // MARK: Docker 摘要

    func scanDockerDf() {
        Task {
            let result = await MoleEngine.shared.runBridge("bin/app_docker_df.sh", timeout: 60)
            dockerDfRows = Parsers.dockerDfRows(result.output)
            logFailure(result)
        }
    }

    /// 授权入口只打开目录选择；用户显式开始后再扫描。
    func scanDuplicates() {
        guard !isBusy else { return }
        guard authorize(.duplicateScan, presentingPermissionCenter: true) else { return }
        showDuplicateFiles = true
    }

    /// 返回上级目录（根目录不再上跳）。
    func analyzeGoUp() {
        guard !isAnalyzing, analyzePath != "/" else { return }
        scanAnalyze(URL(fileURLWithPath: analyzePath).deletingLastPathComponent().path)
    }

    /// NSOpenPanel 选择任意目录分析。
    func chooseAnalyzeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = l10n.t("analyze.pick")
        if panel.runModal() == .OK, let url = panel.url {
            scanAnalyze(url.path)
        }
    }

    func toggleAnalyzeSelection(_ entry: AnalyzeEntry) {
        guard entry.canCleanDirectly else { return }
        if analyzeSelection.contains(entry.path) {
            analyzeSelection.remove(entry.path)
        } else {
            analyzeSelection.insert(entry.path)
        }
    }

    func revealAnalyzeEntry(_ entry: AnalyzeEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    func openAnalyzeEntry(_ entry: AnalyzeEntry) {
        if entry.isDir { scanAnalyze(entry.path) }
        else { revealAnalyzeEntry(entry) }
    }

    func applyAnalyzeCleanup() {
        guard !isBusy else { return }
        let paths = analyzeEntries.filter {
            analyzeSelection.contains($0.path) && $0.canCleanDirectly
        }.map(\.path)
        guard !paths.isEmpty else { return }
        let deletionPlan = DeletionPlan(paths: paths)
        let selectedCount = deletionPlan.items.count
        confirmation = Confirmation(
            title: l10n.tf("analyze.confirm.title", selectedCount),
            message: l10n.tf("analyze.confirm.msg", ByteFormat.format(analyzeSelectedBytes)),
            confirmLabel: l10n.t("confirm.apply.trash.ok")) { [weak self] in
                guard let self else { return }
                self.isApplying = true
                self.statusText = self.l10n.tf("status.processing", selectedCount)
                self.log(self.l10n.tf("log.pipeline", selectedCount, "app_apply.sh"))
                Task {
                    var removed = 0
                    var skipped = 0
                    var failed = 0
                    var allSucceeded = true
                    if !deletionPlan.items.isEmpty {
                        let allowedRoot = self.analyzeIsOverview ? NSHomeDirectory() : self.analyzePath
                        let summary = await Task.detached(priority: .utility) {
                            NativeCore.shared.applyCleanup(
                                items: deletionPlan.items, permanent: false,
                                allowedRoots: [allowedRoot])
                        }.value
                        if !summary.messages.isEmpty {
                            self.log(summary.messages.joined(separator: "\n"))
                        }
                        removed += summary.removed
                        skipped += summary.skipped
                        failed += summary.failed
                        allSucceeded = allSucceeded && summary.failed == 0 && summary.skipped == 0
                    }
                    self.isApplying = false
                    self.statusText = (allSucceeded && failed == 0)
                        ? self.l10n.tf("status.cleanupDone", removed)
                        : self.l10n.tf("status.cleanupPartial", removed, failed)
                    self.log((allSucceeded && failed == 0)
                        ? self.l10n.tf("log.cleanupDone", removed)
                        : self.l10n.tf("log.cleanupPartial", removed, failed)
                              + (skipped > 0 ? " (\(skipped) skipped)" : ""))
                    if self.analyzeIsOverview {
                        self.scanDiskOverview(force: true)
                    } else {
                        self.scanAnalyze(force: true)
                    }
                }
            }
    }

    // MARK: - 自动目录清理

    private static let autoCleanupLastCheckKey = "SMAutoCleanupLastCheck"
    private static let autoCleanupMinimumInterval: TimeInterval = 6 * 60 * 60

    /// 通过系统目录选择器添加规则。新规则默认关闭，要求用户预览后显式启用。
    func addAutoCleanupRule() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = l10n.t("auto.pick.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let directory = try AutoCleanupPlanner.validatedRoot(url)
            guard !autoCleanupRules.contains(where: { $0.directory == directory }) else {
                autoCleanupStatus = l10n.t("auto.status.duplicate")
                return
            }
            let rule = AutoCleanupRule(
                directory: directory,
                policy: .sizeLimit,
                sizeLimitBytes: 5_000_000_000,
                retentionDays: 30,
                isEnabled: false,
                isRegenerable: false,
                lastRunAt: nil,
                lastReclaimedBytes: 0)
            autoCleanupRules.append(rule)
            persistAutoCleanupRules()
            autoCleanupStatus = l10n.t("auto.status.added")
            previewAutoCleanup(rule.id)
        } catch {
            autoCleanupStatus = l10n.tf("auto.status.invalid", error.localizedDescription)
            log(autoCleanupStatus)
        }
    }

    /// 从清理扫描（可再生缓存）或磁盘分析（目录）入口批量创建自动清理
    /// 规则。清理页的路径已由风险策略判定为可再生缓存，创建时直接记录
    /// 安全授权；磁盘分析的目录由用户在规则面板里自行确认“仅可再生
    /// 内容”。规则一律默认关闭，创建后打开面板供审阅与启用。
    @discardableResult
    func addAutoCleanupRules(forDirectories directories: [String],
                             policy: AutoCleanupPolicy,
                             sizeLimitBytes: UInt64,
                             retentionDays: Int,
                             cacheVerifiedRegenerable: Bool) -> (added: Int, skipped: Int) {
        var added = 0
        var skipped = 0
        for directory in directories {
            do {
                let validated = try AutoCleanupPlanner.validatedRoot(
                    URL(fileURLWithPath: directory))
                guard !autoCleanupRules.contains(where: { $0.directory == validated }) else {
                    skipped += 1
                    continue
                }
                autoCleanupRules.append(AutoCleanupRule(
                    directory: validated,
                    policy: policy,
                    sizeLimitBytes: sizeLimitBytes,
                    retentionDays: retentionDays,
                    isEnabled: false,
                    isRegenerable: cacheVerifiedRegenerable,
                    lastRunAt: nil,
                    lastReclaimedBytes: 0))
                added += 1
            } catch {
                skipped += 1
                log(l10n.tf("auto.status.invalid", error.localizedDescription))
            }
        }
        if added > 0 { persistAutoCleanupRules() }
        return (added, skipped)
    }

    func updateAutoCleanupRule(_ updated: AutoCleanupRule) {
        guard !isBusy else { return }
        guard let index = autoCleanupRules.firstIndex(where: { $0.id == updated.id }) else { return }
        let previous = autoCleanupRules[index]
        var normalized = updated
        normalized.sizeLimitBytes = min(
            AutoCleanupRule.maximumSizeLimitBytes,
            max(AutoCleanupRule.minimumSizeLimitBytes, normalized.sizeLimitBytes))
        normalized.retentionDays = min(3650, max(1, normalized.retentionDays))
        if normalized.isRegenerable {
            if !previous.isRegenerable || previous.directory != normalized.directory {
                normalized.authorizedRootIdentity = AutoCleanupRule.rootIdentity(
                    at: normalized.directory)
            } else {
                normalized.authorizedRootIdentity = previous.authorizedRootIdentity
            }
            if let authorized = normalized.authorizedRootIdentity,
               AutoCleanupRule.rootIdentity(at: normalized.directory) == authorized {
                normalized.safetyVersion = AutoCleanupRule.currentSafetyVersion
            } else {
                normalized.isRegenerable = false
                normalized.isEnabled = false
                normalized.authorizedRootIdentity = nil
                autoCleanupStatus = l10n.t("auto.status.authorizationRequired")
            }
        } else {
            normalized.isEnabled = false
            normalized.authorizedRootIdentity = nil
        }
        if normalized.isEnabled && !normalized.isSafetyAuthorized {
            normalized.isEnabled = false
            autoCleanupStatus = l10n.t("auto.status.authorizationRequired")
        }
        let scheduleChanged = normalized.isEnabled && (
            !previous.isEnabled
                || previous.policy != normalized.policy
                || previous.sizeLimitBytes != normalized.sizeLimitBytes
                || previous.retentionDays != normalized.retentionDays)
        autoCleanupRules[index] = normalized
        if autoCleanupPreviewRuleID == normalized.id {
            autoCleanupPreview = nil
            autoCleanupPreviewRuleID = nil
        }
        persistAutoCleanupRules()
        if scheduleChanged {
            UserDefaults.standard.removeObject(forKey: Self.autoCleanupLastCheckKey)
        }
    }

    func removeAutoCleanupRule(_ id: UUID) {
        guard !isBusy else { return }
        autoCleanupRules.removeAll { $0.id == id }
        if autoCleanupPreviewRuleID == id {
            autoCleanupPreview = nil
            autoCleanupPreviewRuleID = nil
        }
        persistAutoCleanupRules()
    }

    func previewAutoCleanup(_ id: UUID) {
        guard authorize(.previewAutoCleanup(ruleID: id),
                        presentingPermissionCenter: true) else { return }
        guard !isBusy, let rule = autoCleanupRules.first(where: { $0.id == id }) else { return }
        isAutoCleanupScanning = true
        autoCleanupStatus = l10n.t("auto.status.scanning")
        Task {
            do {
                let plan = try await AutoCleanupPlanner.plan(
                    for: rule, protecting: protectedAutoCleanupDirectories(excluding: id))
                autoCleanupPreview = plan
                autoCleanupPreviewRuleID = id
                autoCleanupStatus = plan.candidates.isEmpty
                    ? l10n.t("auto.status.empty")
                    : l10n.tf("auto.status.preview", plan.candidates.count,
                              ByteFormat.format(plan.reclaimableBytes))
            } catch {
                autoCleanupPreview = nil
                autoCleanupPreviewRuleID = nil
                autoCleanupStatus = l10n.tf("auto.status.invalid", error.localizedDescription)
                log(autoCleanupStatus)
            }
            isAutoCleanupScanning = false
        }
    }

    /// 手动执行仍需二次确认；确认后会重新规划，避免使用过期预览。
    func runAutoCleanupNow(_ id: UUID) {
        guard authorize(.runAutoCleanup(ruleID: id),
                        presentingPermissionCenter: true) else { return }
        guard !isBusy, let rule = autoCleanupRules.first(where: { $0.id == id }) else { return }
        isAutoCleanupScanning = true
        autoCleanupStatus = l10n.t("auto.status.scanning")
        Task {
            do {
                let plan = try await AutoCleanupPlanner.plan(
                    for: rule, protecting: protectedAutoCleanupDirectories(excluding: id))
                autoCleanupPreview = plan
                autoCleanupPreviewRuleID = id
                isAutoCleanupScanning = false
                guard !plan.candidates.isEmpty else {
                    autoCleanupStatus = l10n.t("auto.status.empty")
                    return
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = l10n.t("auto.confirm.title")
                alert.informativeText = l10n.tf(
                    "auto.confirm.message", plan.candidates.count,
                    ByteFormat.format(plan.reclaimableBytes))
                alert.addButton(withTitle: l10n.t("confirm.apply.trash.ok"))
                alert.addButton(withTitle: l10n.t("common.cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                isAutoCleanupScanning = true
                let result = await applyAutoCleanup(rule: rule, plan: plan)
                isAutoCleanupScanning = false
                autoCleanupStatus = result.failed == 0
                    ? l10n.tf("auto.status.done", result.removed,
                              ByteFormat.format(result.reclaimedBytes))
                    : l10n.tf("auto.status.partial", result.removed, result.failed)
            } catch {
                isAutoCleanupScanning = false
                autoCleanupStatus = l10n.tf("auto.status.invalid", error.localizedDescription)
                log(autoCleanupStatus)
            }
        }
    }

    /// 启动后与每小时定时器都会调用；这里把实际目录扫描限频为每六小时一次。
    func runScheduledAutoCleanup(force: Bool = false) {
        let hasScheduledWork = autoCleanupRules.contains {
            $0.isEnabled && $0.isSafetyAuthorized
        }
        guard hasScheduledWork else {
            cancelAutomationRetry()
            return
        }

        // Background work must never trigger macOS Desktop/Documents/Downloads
        // consent dialogs. Automated scans require the same one-time Full Disk
        // Access grant as manual protected scans, but skip silently instead of
        // presenting the permission center when the grant is absent.
        permissionCenter.refresh()
        guard permissionCenter.fullDiskAccessGranted else {
            cancelAutomationRetry()
            autoCleanupStatus = l10n.t("auto.status.diskPermissionRequired")
            if !reportedScheduledPermissionRequirement {
                log(l10n.t("auto.log.diskPermissionRequired"))
                reportedScheduledPermissionRequirement = true
            }
            return
        }
        reportedScheduledPermissionRequirement = false

        guard !isBusy else {
            scheduleAutomationRetry()
            return
        }
        cancelAutomationRetry()
        let rules = autoCleanupRules.filter { $0.isEnabled && $0.isSafetyAuthorized }
        guard !rules.isEmpty else { return }
        let defaults = UserDefaults.standard
        let lastCheck = defaults.object(forKey: Self.autoCleanupLastCheckKey) as? Date
        if !force, let lastCheck,
           Date().timeIntervalSince(lastCheck) < Self.autoCleanupMinimumInterval {
            return
        }
        defaults.set(Date(), forKey: Self.autoCleanupLastCheckKey)

        isAutoCleanupScanning = true
        autoCleanupStatus = l10n.t("auto.status.scanning")
        Task {
            var removed = 0
            var reclaimed: UInt64 = 0
            var failures = 0
            for snapshot in rules {
                guard let current = autoCleanupRules.first(where: { $0.id == snapshot.id }),
                      current.isEnabled, current.isSafetyAuthorized else { continue }
                do {
                    let plan = try await AutoCleanupPlanner.plan(
                        for: current,
                        protecting: protectedAutoCleanupDirectories(excluding: current.id))
                    guard !plan.candidates.isEmpty else { continue }
                    let result = await applyAutoCleanup(rule: current, plan: plan)
                    removed += result.removed
                    reclaimed &+= result.reclaimedBytes
                    failures += result.failed
                } catch {
                    failures += 1
                    log(l10n.tf("auto.log.ruleFailed", current.directory, error.localizedDescription))
                }
            }
            isAutoCleanupScanning = false
            if failures > 0 {
                // 临时权限或文件竞争失败时，让下一次小时调度重试，而不是静默等待六小时。
                defaults.removeObject(forKey: Self.autoCleanupLastCheckKey)
            }
            autoCleanupStatus = failures == 0
                ? l10n.tf("auto.status.done", removed, ByteFormat.format(reclaimed))
                : l10n.tf("auto.status.partial", removed, failures)
        }
    }

    private func scheduleAutomationRetry() {
        guard scheduledAutomationRetry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduledAutomationRetry = nil
                self.runScheduledAutoCleanup()
            }
        }
        scheduledAutomationRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60, execute: work)
    }

    private func cancelAutomationRetry() {
        scheduledAutomationRetry?.cancel()
        scheduledAutomationRetry = nil
    }

    private func applyAutoCleanup(rule: AutoCleanupRule, plan: AutoCleanupPlan) async
        -> (removed: Int, failed: Int, reclaimedBytes: UInt64) {
        guard rule.isSafetyAuthorized,
              let authorizedRootIdentity = rule.authorizedRootIdentity,
              plan.candidates.allSatisfy(\.automaticEligible) else {
            return (0, max(1, plan.candidates.count), 0)
        }
        var stdinData = Data()
        var planned: [AutoCleanupCandidate] = []
        var preparationFailures = 0
        for candidate in plan.candidates {
            guard !candidate.identity.isEmpty else {
                preparationFailures += 1
                continue
            }
            let plannedLatestMtime = String(
                Int64(candidate.modifiedAt.timeIntervalSince1970.rounded(.down)))
            for field in [plan.root, authorizedRootIdentity,
                          candidate.path, candidate.identity,
                          plannedLatestMtime,
                          AutoCleanupRule.safetyToken] {
                stdinData.append(contentsOf: field.utf8)
                stdinData.append(0)
            }
            planned.append(candidate)
        }
        guard !planned.isEmpty else {
            return (0, max(1, preparationFailures), 0)
        }

        autoCleanupStatus = l10n.tf("auto.status.cleaning", planned.count)
        log(l10n.tf("auto.log.cleaning", planned.count, rule.directory))
        let result = await MoleEngine.shared.runBridgeWithStdin(
            "bin/app_auto_apply.sh", stdinData: stdinData, timeout: 900)
        if !result.output.isEmpty { log(result.output) }
        logFailure(result, stdoutAlreadyLogged: true)
        let summary = Parsers.applySummary(result.output)
        let processFailure = result.succeeded || summary.failed > 0 ? 0 : 1
        let failed = preparationFailures + summary.failed + processFailure
        let reclaimed = failed == 0 && summary.removed == planned.count
            ? planned.reduce(0) { $0 &+ $1.bytes }
            : 0
        if let index = autoCleanupRules.firstIndex(where: { $0.id == rule.id }) {
            autoCleanupRules[index].lastRunAt = Date()
            autoCleanupRules[index].lastReclaimedBytes = reclaimed
            persistAutoCleanupRules()
        }
        CleanupCache.invalidate()
        return (summary.removed, failed, reclaimed)
    }

    private func persistAutoCleanupRules() {
        AutoCleanupRuleStore.save(autoCleanupRules)
    }

    private func protectedAutoCleanupDirectories(excluding id: UUID) -> [String] {
        Array(autoCleanupRules.lazy.filter { $0.id != id }.map(\.directory))
    }

    // MARK: - 白名单

    private static var whitelistFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory().appending("/.config/mole/whitelist"))
    }

    func loadWhitelist() {
        whitelistEntries = Self.readWhitelistEntries()
    }

    private static func readWhitelistEntries() -> [String] {
        guard let content = try? String(contentsOf: whitelistFileURL, encoding: .utf8) else { return [] }
        return content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func addWhitelistEntry(_ rawPath: String) {
        let path = rawPath.trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/"), !path.contains("..") else {
            log(l10n.tf("log.wlInvalid", path))
            return
        }
        guard !whitelistEntries.contains(path) else { return }
        whitelistEntries.append(path)
        saveWhitelist()
    }

    func removeWhitelistEntry(_ path: String) {
        whitelistEntries.removeAll { $0 == path }
        saveWhitelist()
    }

    func saveWhitelist() {
        let header = """
        # Nori whitelist (shared by native clean / purge / bridge cleanup)
        # One absolute path or glob per line; built-in engine safety always applies.

        """
        let content = header + whitelistEntries.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(
            at: Self.whitelistFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? content.write(to: Self.whitelistFileURL, atomically: true, encoding: .utf8)
        CleanupCache.invalidate()
        log(l10n.tf("log.wlSaved", whitelistEntries.count))
    }
}
