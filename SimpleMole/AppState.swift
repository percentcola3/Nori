import Foundation
import SwiftUI
import AppKit
import Combine
import Darwin

/// 灵动岛指标的独立发布者：采样结果和网络趋势只通知观察它的视图。
@MainActor
final class MetricsStore: ObservableObject {
    @Published var metrics = MetricsSnapshot()
    @Published var networkHistory: [Double] = []
    @Published var networkUploadHistory: [Double] = []

    func record(_ sample: MetricsSnapshot) {
        metrics = sample
        networkHistory.append(sample.networkRxMBps)
        networkUploadHistory.append(sample.networkTxMBps)
        if networkHistory.count > 60 { networkHistory.removeFirst(networkHistory.count - 60) }
        if networkUploadHistory.count > 60 {
            networkUploadHistory.removeFirst(networkUploadHistory.count - 60)
        }
    }
}

/// SwiftUI presentation facade and application lifecycle. Domain extensions
/// project their results into Published state; software-check scheduling and
/// uninstall execution are supplied through focused workflow interfaces.
@MainActor
final class AppState: ObservableObject {
    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let onConfirm: () -> Void
    }

    @Published var administratorCleanupPrompt: String?
    private var administratorCleanupDecision: CheckedContinuation<Bool?, Never>?

    func resolveAdministratorCleanup(_ include: Bool?) {
        let decision = administratorCleanupDecision
        administratorCleanupDecision = nil
        administratorCleanupPrompt = nil
        decision?.resume(returning: include)
    }

    func confirmAdministratorCleanup(_ items: [DeletionPlan.Item]) async -> Bool? {
        await withCheckedContinuation { continuation in
            administratorCleanupDecision = continuation
            let paths = items.prefix(6).map(\.record).joined(separator: "\n")
            administratorCleanupPrompt = l10n.tf("cleanup.admin.message", items.count) + "\n\n" + paths
        }
    }

    // MARK: 指标

    /// 指标每 2 秒刷新一次，只有灵动岛关心；独立成对象，避免每次采样让所有页面重算。
    let metricsStore = MetricsStore()
    var metrics: MetricsSnapshot {
        get { metricsStore.metrics }
        set { metricsStore.metrics = newValue }
    }
    var networkHistory: [Double] {
        get { metricsStore.networkHistory }
        set { metricsStore.networkHistory = newValue }
    }
    var networkUploadHistory: [Double] {
        get { metricsStore.networkUploadHistory }
        set { metricsStore.networkUploadHistory = newValue }
    }
    private var metricsSampleInFlight = false
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
    private var mutationResampleTask: Task<Void, Never>?

    // MARK: 窗口与导航

    /// 功能页标识：设置中可按需隐藏。系统优化页已下架（DR-11），其有
    /// 价值的能力分流到硬盘清理（系统数据库维护）与开发环境（网络/服务修复）。
    enum PageKey: String, CaseIterable, Identifiable {
        case cleanup, agents, analyze, directory, uninstall, devenv, processes, ports, traffic, clipboard, settings
        var id: String { rawValue }
        var titleKey: String { self == .settings ? "settings.title" : "tab.\(rawValue)" }

        /// 剪贴板页由功能开关控制，设置页始终保留。
        static var configurableCases: [PageKey] {
            allCases.filter { $0 != .clipboard && $0 != .settings }
        }
    }

    /// 灵动岛展开时显示的快捷指标。
    enum IslandItem: String, CaseIterable, Identifiable {
        case cpu, memory, gpu, thermal, power, disk, network, bluetooth
        var id: String { rawValue }
    }

    /// 灵动岛停靠的屏幕边缘：顶部横排，左右侧边竖排。
    enum IslandEdge: String, CaseIterable, Identifiable {
        case top, left, right
        var id: String { rawValue }
        var labelKey: String { "settings.island.edge.\(rawValue)" }
    }

    @Published var selectedTab = 0
    /// 用户隐藏的页面（UserDefaults 持久化）。
    @Published var hiddenPages: Set<String> = []
    @Published var mainWindowVisible = false
    /// Keep directory navigation and selection when another page is displayed.
    let directoryBrowser = DirectoryBrowserModel()

    // MARK: 灵动岛 / 菜单栏入口
    // 边缘灵动岛：悬停展开指标与资源排行，箭头直接打开主窗口。

    @Published var islandEnabled = true
    /// 菜单栏状态图标开关。灵动岛始终保留，菜单栏图标可以单独关闭。
    @Published var menuBarIconVisible = true
    /// 至少保留一项；这里控制刘海中的常驻指标。
    @Published var islandItems: Set<IslandItem> = [.cpu, .memory, .network]
    /// 灵动岛停靠的位置：顶部居中、屏幕左侧或屏幕右侧。
    @Published var islandEdge: IslandEdge = .top
    /// 左右侧边分别保存纵向位置；0 为下端，1 为上端。
    @Published var islandLeftPosition: Double = 0.5
    @Published var islandRightPosition: Double = 0.5

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

    func islandPosition(for edge: IslandEdge) -> Double {
        switch edge {
        case .top: return 0.5
        case .left: return IslandPositionPreferences.normalized(islandLeftPosition)
        case .right: return IslandPositionPreferences.normalized(islandRightPosition)
        }
    }

    func setIslandPosition(_ position: Double, for edge: IslandEdge) {
        let normalized = IslandPositionPreferences.normalized(position)
        switch edge {
        case .top:
            return
        case .left:
            if islandLeftPosition != normalized { islandLeftPosition = normalized }
            UserDefaults.standard.set(normalized, forKey: IslandPositionPreferences.leftKey)
        case .right:
            if islandRightPosition != normalized { islandRightPosition = normalized }
            UserDefaults.standard.set(normalized, forKey: IslandPositionPreferences.rightKey)
        }
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
    @Published var agentMCPInstallations: [AgentMCPInstallation] = []
    @Published var agentCLIInstallations: [AgentCLIInstallation] = []
    @Published var agentApplications: [String: [UninstallApp]] = [:]
    @Published var agentStorageFootprints: [String: AgentStorageFootprint] = [:]
    @Published var agentCLIBodySizes: [String: AgentInstallationSize] = [:]
    @Published var agentStorageCheckingIDs = Set<String>()
    var agentStorageGeneration = UUID()
    @Published var agentProgramBusyID: String?
    @Published var agentSelectedSkills: Set<String> = []
    @Published var agentSelectedServers: Set<String> = []
    @Published var agentSelectedMCPInstallations: Set<String> = []
    @Published var agentSelectedCLIInstallations: Set<String> = []
    @Published var agentScanning = false
    @Published var agentScanCurrentPath = ""
    @Published var agentApplying = false
    @Published var agentScanComplete = false
    @Published var agentHasScanned = false
    @Published var agentStatus = ""
    @Published var agentOutcomeMood: NoriMood?
    @Published var agentOutcomeDetails: [String] = []
    @Published var agentCleanupProgress: CleanupTaskProgress?
    @Published var agentCelebrating = false
    @Published var agentFeedbackID = 0
    @Published var agentCompletedCount = 0
    @Published var agentReclaimedBytes: UInt64 = 0
    @Published var agentFailureApplications: [String] = []
    @Published var agentRetryAvailable = false
    @Published var agentCleanupHasFeedback = false
    var agentRetryAction: (() -> Void)?
    var agentTaskGeneration = UUID()

    // MARK: 清理

    @Published var categories: [CleanupCategory] = []
    @Published var family: CleanupFamily = .clean
    @Published var isScanning = false
    @Published var cleanupOutcomeMood: NoriMood?
    @Published var cleanupOutcomeDetails: [String] = []
    @Published var cleanupFeedbackID = 0
    @Published var cleanupTaskProgress: CleanupTaskProgress?
    @Published var cleanupCelebrating = false
    @Published var cleanupCompletedCount = 0
    @Published var cleanupReclaimedBytes: UInt64 = 0
    @Published var cleanupFailureApplications: [String] = []
    @Published var cleanupRetryAvailable = false
    let cleanupRuntime = CleanupRuntimeState()
    /// Bumps once per finished user task so the title-bar mascot can celebrate or warn.
    @Published var headerReactionID = 0
    @Published var headerReactionMood: NoriMood = .success
    /// One idle scene shared by every tab's placeholder, re-rolled each time the window opens.
    @Published private(set) var placeholderScene = NoriStatusAnimation.idleScenes.randomElement() ?? "nori-static"

    func shufflePlaceholderScene() {
        let others = NoriStatusAnimation.idleScenes.filter { $0 != placeholderScene }
        placeholderScene = others.randomElement() ?? placeholderScene
    }

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
    /// Agent scanning owns a cancellation token independent of cleanup scanning.
    var agentScanControl: CleanupScanControl?
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
    var pendingCleanup: (() -> Void)?

    // MARK: 系统维护（原系统优化页能力分流：数据库→清理页，网络/服务→开发环境）

    /// 系统数据库维护行（清理页卡片）：SQLite 压缩、通知历史、使用记录、
    /// 下载隔离历史、窗口保存状态。
    @Published var systemMaintenanceRows: [SystemMaintenanceRow] = []
    /// 统一“清理”待分发的维护项勾选（行 id）。
    @Published var systemMaintenanceSelection: Set<String> = []
    @Published var isSystemMaintenanceRunning = false
    @Published var systemMaintenanceStatus = ""
    /// 开发环境：DNS 与网络栈维护的执行状态。
    @Published var networkToolStatus = ""
    @Published var isNetworkToolRunning = false

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
    let processRuntime = ProcessRuntimeState()
    @Published var portRows: [PortRow] = []
    @Published var isDeveloperCommandRunning = false
    @Published var isDeveloperConfigurationWriting = false
    lazy var developerWorkspaceSession = DeveloperWorkspaceSession(state: self)
    @Published var portStatus: String
    @Published var runtimeInFlight = false

    // MARK: 应用卸载

    @Published var installedApps: [UninstallApp] = []
    @Published private(set) var uninstallPlans: [String: UninstallPlan] = [:]
    @Published var uninstallDataSelections: [String: Set<String>] = [:]
    @Published var uninstallSegment = 0
    @Published var commandLineTools: [CommandLineTool] = []
    @Published var isScanningCommandLineTools = false
    @Published var commandLineToolsScanned = false
    @Published var commandLineToolStatus = ""
    @Published var commandLineToolBusyID: String?
    var commandLineToolUninstallGeneration = UUID()
    @Published var softwareUpdateResults: [String: SoftwareUpdateResult] = [:]
    @Published var softwareUpdateCheckingIDs = Set<String>()
    @Published var isCheckingSoftwareUpdates = false
    @Published var softwareUpdatingID: String?
    @Published var softwareUpdateHandoffIDs = Set<String>()
    let softwareUpdateChecker: any SoftwareUpdateChecking
    private let uninstallExecutor: any UninstallExecuting
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
    @Published var isApplyingDevEnv = false
    @Published var devWorkspaceRefreshToken = 0
    @Published var isRefreshingGc = false
    @Published var devWorkspaceRefreshPending = false
    var developerWorkspaceRefreshTask: Task<Void, Never>?

    // MARK: 包管理 GC（owner 命令，无直接删除）

    @Published var gcActions: [GcAction] = []
    @Published var gcRunningId: String?
    let developmentRuntime = DevelopmentRuntimeState()

    // MARK: Docker

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
    /// 每条规则最近一次规划/执行失败的原因，成功后清除；仅存活于当前会话。
    @Published var autoCleanupRuleIssues: [UUID: String] = [:]

    // MARK: Shell 配置体检（只读）

    @Published var shellIssues: [ShellIssue] = []
    @Published var shellAudited = false

    var devEnvSelectedBytes: UInt64 {
        devEnvEntries.filter { devEnvSelection.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    var devEnvSelectedGlobalPackageBytes: UInt64 {
        devEnvEntries.filter { devEnvSelection.contains($0.path) }
            .reduce(0) { $0 + $1.relatedBytes }
    }

    // MARK: 磁盘分析

    /// Independent directory browser and user-managed file category inventories.
    @Published var analyzeLargeFiles: [AnalyzeReport.LargeFile] = []
    @Published var analyzeMedia: [MediaFile] = []
    /// Sidebar selection changes only the displayed section, never its inventory.
    @Published var analyzeMode: AnalyzeMode = .disk {
        didSet {
            analyzeStatus = analysisStatus(for: analyzeMode)
            analysisFileSelection = analysisSelection(for: analyzeMode)
            if inventoryScanMode != analyzeMode { analyzeCurrentPath = "" }
        }
    }
    @Published var slimSelection: Set<String> = []
    /// 大文件/视频删除清单的勾选（移入废纸篓路线）。
    @Published var analysisFileSelection: Set<String> = []
    @Published var analysisFileSelectionsByMode: [AnalyzeMode: Set<String>] = [:]
    @Published var isDeletingAnalysisFiles = false
    @Published var isRefreshingAnalysisCache = false
    @Published var slimOptions = SlimOptions()
    @Published var showSlimSheet = false
    @Published var isSlimming = false
    @Published var slimProgress: SlimProgress?
    var slimTask: Task<Void, Never>?
    @Published var isAnalyzing = false
    @Published var analysisScanIsFull = false
    @Published var analyzeStatus: String
    @Published var analyzeCurrentPath = ""
    var analyzeCache = DiskAnalysisCache()
    @Published var diskBrowserRootPath = AnalysisDiskScopes.overviewPath
    @Published var diskBrowserHomePath = NSHomeDirectory()
    @Published var diskBrowserNavigation = [AnalysisDiskScopes.overviewPath]
    @Published var diskBrowserEntriesByPath: [String: [AnalyzeEntry]] = [:]
    @Published var analysisReportsByMode: [AnalyzeMode: AnalyzeReport] = [:]
    @Published var analysisScanDates: [AnalyzeMode: Date] = [:]
    @Published var analysisStatuses: [AnalyzeMode: String] = [:]
    @Published var analysisDetailsByMode: [AnalyzeMode: [String]] = [:]
    let analysisRuntime = AnalysisRuntimeState()
    @Published var analysisAutoScanPreferences = AnalysisAutoScanPreferences.load()
    @Published private var inventoryScanMode: AnalyzeMode?
    var analysisInventoryScanMode: AnalyzeMode? {
        get { inventoryScanMode }
        set { inventoryScanMode = newValue }
    }
    let analysisInventoryCache = AnalysisInventoryCache()

    var analyzingMode: AnalyzeMode? {
        isScanningDuplicates ? .duplicates : inventoryScanMode
    }

    var isIncrementalAnalysisScanning: Bool {
        (isAnalyzing || isScanningDuplicates) && !analysisScanIsFull
    }

    // 全盘扫描的重复文件子分类（内容级比对）。
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
    let duplicateScanProgress = DuplicateScanProgressStore()
    var duplicateScanReclaimableBytes: UInt64 = 0
    var duplicateResultCache: [DuplicateMode: DuplicateCachedResult] = [:]
    let duplicateContentCache = DuplicateContentCache()
    let duplicateWorkspaceStore = DuplicateWorkspaceStore()
    let similarImageFeatureCache = SimilarImageFeatureCache()
    @Published var duplicateLastScanDate: Date? = nil

    // MARK: 白名单

    @Published var whitelistEntries: [String] = []
    @Published var showWhitelistSheet = false

    // MARK: 确认弹窗

    @Published var confirmation: Confirmation?
    private var isDispatchingConfirmation = false
    @Published var taskNotice: TaskFeedbackNotice?
    private var taskFeedbackQueue = TaskFeedbackQueue()

    func presentTaskNotice(_ notice: TaskFeedbackNotice) {
        taskFeedbackQueue.enqueue(notice)
        if taskNotice?.id != taskFeedbackQueue.active?.id {
            taskNotice = taskFeedbackQueue.active
        }
        if !mainWindowVisible {
            NotificationCenter.default.post(name: .smOpenMainWindow, object: nil)
        }
    }

    func presentTaskFailure(message: String = "", details: [String] = [],
                            detailsAreLocalized: Bool = false) {
        presentTaskNotice(TaskFeedbackNotice(
            message: message.isEmpty ? l10n.t("task.failure.message") : message,
            details: details.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            detailsAreLocalized: detailsAreLocalized))
    }

    func dismissTaskNotice(resumingQueuedTasks: Bool = true) {
        taskFeedbackQueue.dismiss()
        taskNotice = taskFeedbackQueue.active
        if resumingQueuedTasks, taskNotice == nil { startNextUninstallIfPossible() }
    }

    func retryTaskNotice(_ notice: TaskFeedbackNotice) {
        guard taskNotice?.id == notice.id else { return }
        isDispatchingConfirmation = true
        dismissTaskNotice(resumingQueuedTasks: false)
        notice.onRetry?()
        isDispatchingConfirmation = false
        startNextUninstallIfPossible()
    }

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
            registerScreenshotHotKey()
        }
    }
    /// 截图全局快捷键的组合（默认 ⇧⌘S，可自定义并持久化）。
    @Published var screenshotHotKey = HotKeyCombo.load() {
        didSet {
            guard oldValue != screenshotHotKey else { return }
            screenshotHotKey.store()
            registerScreenshotHotKey()
        }
    }
    @Published private(set) var screenshotHotKeyRegistrationFailed = false

    /// 按比例截取（第二热键，默认 ⇧⌘R）：固定比例选区，可拖动不可缩放。
    @Published var ratioCaptureHotKeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(ratioCaptureHotKeyEnabled, forKey: "SMShotRatioHotKey")
            registerScreenshotHotKey()
        }
    }
    @Published var ratioCaptureHotKey = HotKeyCombo.loadRatio() {
        didSet {
            guard oldValue != ratioCaptureHotKey else { return }
            ratioCaptureHotKey.storeRatio()
            registerScreenshotHotKey()
        }
    }
    @Published private(set) var ratioCaptureHotKeyRegistrationFailed = false

    /// 统一的快捷键注册收口：任一开关或组合变化都整体重注册。
    func registerScreenshotHotKey() {
        HotKeyCenter.shared.unregister()
        screenshotHotKeyRegistrationFailed = false
        ratioCaptureHotKeyRegistrationFailed = false
        guard screenshotHotKeyEnabled || ratioCaptureHotKeyEnabled else { return }
        if screenshotHotKeyEnabled {
            screenshotHotKeyRegistrationFailed = !HotKeyCenter.shared.register(
                id: "screenshot",
                keyCode: screenshotHotKey.keyCode,
                modifiers: screenshotHotKey.modifiers) {
                NotificationCenter.default.post(name: .smTakeScreenshot, object: nil)
            }
        }
        if ratioCaptureHotKeyEnabled {
            ratioCaptureHotKeyRegistrationFailed = !HotKeyCenter.shared.register(
                id: "ratio-capture",
                keyCode: ratioCaptureHotKey.keyCode,
                modifiers: ratioCaptureHotKey.modifiers) {
                NotificationCenter.default.post(name: .smTakeRatioScreenshot, object: nil)
            }
        }
    }

    // MARK: 权限中心

    let permissionCenter = PermissionCenter.shared
    let authorizationCoordinator = AuthorizationCoordinator()
    @Published var showPermissionCenter = false
    private var activeProtectedOperation: ProtectedOperation?

    /// 受保护扫描脚本必须显式收到这个能力标记；脚本默认无标记时拒绝枚举
    /// Desktop、Documents 等 TCC 目录，形成 UI 门禁之外的第二层防护。
    var fullDiskScanEnvironment: [String: String] {
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

    /// FDA 只能在系统设置里由用户授予。启动时先检查并展示引导，
    /// 不把打开权限中心当成扫描或管理员操作的授权。
    private func prepareStartupPermissions() {
        guard permissionCenter.refresh() else {
            permissionCenter.clearDiskAuthorizationError()
            showPermissionCenter = true
            permissionCenter.scheduleLiveCheck(force: true)
            return
        }
        refreshAuthorizationAndResume()
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
    func authorize(_ operation: ProtectedOperation,
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
        // Preserve this page's pending operation while its own task is active.
        guard let pending = authorizationCoordinator.pendingOperation,
              !isTaskBusy(for: pending) else { return }
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
        guard !isTaskBusy(for: operation) else { return }

        activeProtectedOperation = operation
        defer { activeProtectedOperation = nil }
        switch operation {
        case .cleanupScan(let force): scanCleanup(force: force)
        // 深度/快速两个入口已合并：无论从哪个旧入口恢复，都走统一的
        // “快速 + 自动深度补扫”流程。
        case .deepCleanupScan: startCleanupScan()
        case .quickOptimize: startCleanupScan()
        case .developerToolsScan: scanDeveloperTools()
        case .aiScan: scanAgents()
        case .installedAppsScan: scanInstalledApps()
        case .uninstall(let app): previewUninstall(app)
        case .developmentEnvironmentScan: scanDevEnv()
        case .diskOverview(let force): scanDiskOverview(force: force)
        case .previewAutoCleanup(let ruleID): previewAutoCleanup(ruleID)
        case .runAutoCleanup(let ruleID): runAutoCleanupNow(ruleID)
        }
    }

    private var cancellables: Set<AnyCancellable> = []
    let automationRuntime = AutomationRuntimeState()
    private var uninstallInventoryRefreshWorkItem: DispatchWorkItem?
    private var uninstallInventoryWatchers: [DispatchSourceFileSystemObject] = []
    private var uninstallInventoryWatchedPaths: Set<String> = []
    private var uninstallInventoryGeneration = 0
    let l10n = L10n.shared

    /// 标题栏展示的当前任务。删除类任务（清理、卸载）共用收纳动效。
    struct HeaderTask: Equatable {
        let text: String
        let tidying: Bool
    }

    var headerTask: HeaderTask? {
        if let job = uninstallQueue.activeJob {
            return HeaderTask(text: l10n.tf("header.task.uninstalling", job.app.name), tidying: true)
        }
        if isApplying || isApplyingDevEnv || agentApplying || isDeletingDuplicates || isDeletingAnalysisFiles
            || simulatorInventory.isDeleting || cleanupQueued {
            return HeaderTask(text: l10n.t("header.task.cleaning"), tidying: true)
        }
        if isScanning || isAnalyzing || isScanningDuplicates || isScanningEnv || agentScanning || isAutoCleanupScanning || isScanningApps {
            return HeaderTask(text: l10n.t("header.task.scanning"), tidying: false)
        }
        if isBusy { return HeaderTask(text: l10n.t("header.task.working"), tidying: false) }
        return nil
    }

    /// 磁盘分析与重复文件比对是只读遍历，在后台持续执行，不阻塞其他操作
    /// （各自入口有独立的重入保护：`isAnalyzing`/`isScanningDuplicates`）。

    var selectedCount: Int {
        categories.reduce(0) { $0 + $1.selectedPathCount }
    }

    /// 统一“清理”可分发的勾选：文件系统类目、安装包或系统维护任一存在即可。
    var hasCleanupSelection: Bool {
        selectedCount > 0 || installerCandidates?.selectedSubset != nil
            || systemMaintenanceRows.contains { systemMaintenanceSelection.contains($0.id) }
    }

    var selectedBytes: UInt64 {
        categories.reduce(0) { $0 &+ $1.selectedPathBytes }
    }

    var totalBytes: UInt64 {
        Self.uniqueAgentBytes(categories.filter(\.quickCleanEligible).flatMap { category in
            category.paths.map { ($0, category.pathBytes[$0] ?? 0) }
        })
    }

    init(softwareUpdateChecker: (any SoftwareUpdateChecking)? = nil,
         uninstallExecutor: (any UninstallExecuting)? = nil) {
        self.softwareUpdateChecker = softwareUpdateChecker ?? SoftwareUpdateService()
        self.uninstallExecutor = uninstallExecutor ?? UninstallWorkflow()
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
        ratioCaptureHotKeyEnabled = UserDefaults.standard.object(forKey: "SMShotRatioHotKey") as? Bool ?? true
        islandEnabled = true
        UserDefaults.standard.set(true, forKey: "SMIslandEnabled")
        menuBarIconVisible = UserDefaults.standard.object(forKey: "SMMenuBarIconVisible") as? Bool ?? true
        islandEdge = IslandEdge(rawValue: UserDefaults.standard.string(forKey: "SMIslandEdge") ?? "") ?? .top
        islandLeftPosition = IslandPositionPreferences.restored(forKey: IslandPositionPreferences.leftKey)
        islandRightPosition = IslandPositionPreferences.restored(forKey: IslandPositionPreferences.rightKey)
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
        // 未扫描时不需要任何状态文案：空态由吉祥物动图与入口按钮表达。
        analyzeStatus = ""
        Task { [weak self] in
            guard let self else { return }
            let cache = self.analysisInventoryCache
            let restored = await Task.detached(priority: .utility) { cache.restoreState() }.value
            guard restored.revision == cache.currentRevision else { return }
            for (kind, snapshot) in restored.snapshots {
                let mode = self.analysisMode(for: kind)
                guard self.analysisScanDates[mode] == nil, self.inventoryScanMode != mode else { continue }
                self.analysisReportsByMode[mode] = restored.reports[kind]
                if kind == .disk { self.publishDiskBrowser(restored.diskBrowser) }
                self.analysisScanDates[mode] = snapshot.scannedAt
                self.analysisStatuses[mode] = self.l10n.t(snapshot.issueCount > 0 ? "analyze.scan.partial" : "analyze.scan.scope")
                if snapshot.issueCount > 0, let report = restored.reports[kind] {
                    self.analysisDetailsByMode[mode] = DiskAnalysisWorker.failureDetails(for: report, using: self.l10n.t)
                }
            }
            self.publishAnalysisReports()
            self.runScheduledAnalysisScans()
        }
        autoCleanupStatus = L10n.shared.t("auto.status.ready")
        restorePersistedDuplicateResults()
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
                self.appListStatus = ""
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
                    // 全盘分析在后台持续执行，离开页面不取消；它也不再计入
                    // isBusy，避免遍历期间其他页的清理操作一直被禁用。
                    switch pages[tab] {
                    case .cleanup:
                        // Keep the existing result/selection. Scanning starts
                        // only from the user's quick/deep scan actions.
                        break
                    case .agents:
                        // 与磁盘分析一样，进入页面只刷新权限，扫描由用户点击触发。
                        self.permissionCenter.refresh()
                    case .analyze:
                        // 全盘扫描耗时：tab 激活不自动触发，等用户点击“开始分析”。
                        self.permissionCenter.refresh()
                    case .uninstall:
                        // The page's cancellable loading task starts data work
                        // only after the navigation/placeholder has appeared.
                        break
                    case .devenv:
                        self.refreshDeveloperWorkspace()
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
        NotificationCenter.default.publisher(for: .noriTaskFailure)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                let key = notification.userInfo?["messageKey"] as? String ?? "task.failure.message"
                let details = notification.userInfo?["details"] as? [String] ?? []
                let localized = notification.userInfo?["detailsAreLocalized"] as? Bool ?? false
                self.presentTaskFailure(message: self.l10n.t(key), details: details,
                                        detailsAreLocalized: localized)
            }
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
                        ? self.l10n.t("uninstall.status.none") : ""
                }
                if !self.isScanningEnv { self.devEnvStatus = self.l10n.t("devenv.status.empty") }
                if !self.isAutoCleanupScanning {
                    self.autoCleanupStatus = self.l10n.t("auto.status.ready")
                }
            }
            .store(in: &cancellables)
        simulatorInventory.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        simulatorInventory.$phase
            .dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard case .failed(let detail) = phase else { return }
                self?.presentTaskFailure(details: [detail])
            }
            .store(in: &cancellables)
        simulatorInventory.$lastDeleteSummary
            .dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] summary in
                guard let self, let summary, summary.failed > 0 || summary.skipped > 0 else { return }
                self.presentTaskFailure(message: self.l10n.tf("sim.delete.summary",
                    summary.removed, summary.skipped, summary.failed))
            }
            .store(in: &cancellables)
        dockerInventory.$phase
            .dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                switch phase {
                case .failed(let detail), .partial(let detail): self?.presentTaskFailure(details: [detail])
                default: break
                }
            }
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
        // /Applications is safe to watch at launch. ~/.Trash is registered
        // only after Full Disk Access has been verified for this process.
        startUninstallInventoryMonitoring(includeProtectedPaths: false)
        DispatchQueue.main.async { [weak self] in
            self?.prepareStartupPermissions()
        }
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
            if !ok { presentTaskFailure(message: l10n.t("permissions.repair.failed")) }
        }
    }

    func repairFullDiskAuthorization() {
        Task { @MainActor in
            let ok = await permissionCenter.resetFullDiskDecision()
            if ok { permissionCenter.openSystemSettings(.fullDisk) }
            log(l10n.t(ok ? "permissions.repair.done" : "permissions.repair.failed"))
            if !ok { presentTaskFailure(message: l10n.t("permissions.repair.failed")) }
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
            presentTaskFailure(message: statusText, details: [error.localizedDescription])
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
        guard !metricsSampleInFlight else { return }
        metricsSampleInFlight = true
        let includeBluetooth = islandItems.contains(.bluetooth)
        Task { [weak self] in
            let sample = await Task.detached(priority: .utility) {
                SystemMetrics.sample(includeBluetooth: includeBluetooth)
            }.value
            guard let self else { return }
            self.metricsSampleInFlight = false
            self.metricsStore.record(sample)
        }
    }

    /// 清理、删除、卸载或关闭进程之后，磁盘余量、内存占用和进程排行都已变化。
    /// 立即重采一次，1.5 秒后再采一次：APFS 回收空间和进程退出都会滞后一点。
    /// 不写入网络趋势，避免额外采样把固定节拍的曲线挤乱。
    func resampleAfterMutation() {
        resampleMetricsNow()
        mutationResampleTask?.cancel()
        mutationResampleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.resampleMetricsNow()
        }
    }

    private func resampleMetricsNow() {
        let includeBluetooth = islandItems.contains(.bluetooth)
        Task { [weak self] in
            let sample = await Task.detached(priority: .utility) {
                SystemMetrics.sample(includeBluetooth: includeBluetooth)
            }.value
            self?.metricsStore.metrics = sample
        }
        refreshIslandProcesses(force: true)
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
    func logFailure(_ result: RunResult, stdoutAlreadyLogged: Bool = false,
                    notifyingUser: Bool = true) {
        guard !result.succeeded else { return }
        let diagnostic = result.errorOutput.isEmpty
            ? (stdoutAlreadyLogged ? "" : result.output)
            : result.errorOutput
        if !diagnostic.isEmpty { log(diagnostic) }
        if notifyingUser {
            let detail = result.errorOutput.isEmpty ? result.output : result.errorOutput
            presentTaskFailure(details: detail.isEmpty ? [] : [detail])
        }
    }

    /// 引擎输出回调发生在后台线程，这里负责跳回主线程。
    nonisolated func streamLog(_ line: String) {
        Task { @MainActor in self.appendLogLine(line) }
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
            appListStatus = installedApps.isEmpty ? l10n.t("uninstall.status.empty") : ""
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

    private var uninstallConfirmationGeneration = UUID()

    func previewUninstall(_ app: UninstallApp) {
        guard softwareUpdatingID == nil else { return }
        guard confirmation == nil, taskNotice == nil else { return }
        guard !uninstallQueue.containsPendingOrActive(app) else { return }
        guard authorize(.uninstall(app: app), presentingPermissionCenter: true) else { return }
        guard !app.appIdentity.isEmpty else {
            log(l10n.tf("log.uninstallPreviewFail", app.name))
            presentTaskFailure(message: l10n.tf("log.uninstallPreviewFail", app.name))
            return
        }
        // Capture a plan only if it belongs to this exact inventory identity.
        // A missing preview is prepared by the FIFO worker after confirmation.
        let cached = installedApps.first(where: { $0.id == app.id }) == app
            ? uninstallPlans[app.id] : nil
        let plan = cached.flatMap {
            $0.includesProtectedAppData && !$0.fileIdentities.isEmpty ? $0 : nil
        }
        let dataPaths = uninstallDataSelections[app.id] ?? []
        let generation = UUID()
        uninstallConfirmationGeneration = generation
        Task {
            let processes = await Task.detached(priority: .utility) {
                UninstallProcessController.processes(for: app, samples: ProcessSampler.shared.sample())
            }.value
            guard uninstallConfirmationGeneration == generation, confirmation == nil,
                  taskNotice == nil, !uninstallQueue.containsPendingOrActive(app) else { return }
            var message = l10n.t("uninstall.confirm.message")
            if !processes.isEmpty {
                message += "\n\n" + l10n.tf("uninstall.confirm.running", app.name)
                message += "\n" + Set(processes.map(\.name)).sorted().joined(separator: ", ")
            } else {
                message += "\n\n" + l10n.t("uninstall.confirm.force")
            }
            confirmation = Confirmation(title: l10n.tf("uninstall.confirm.title", app.name),
                message: message, confirmLabel: l10n.t("uninstall.action")) { [weak self] in
                    guard let self else { return }
                    guard self.uninstallQueue.enqueue(app: app, plan: plan, dataPaths: dataPaths) != nil else { return }
                    self.startNextUninstallIfPossible()
                }
        }
    }

    func uninstallJob(for app: UninstallApp) -> UninstallJob? {
        uninstallQueue.jobs.last { $0.app.id == app.id }
    }

    /// Agent rows use the same audited executor without navigating to the
    /// software queue. Associated Agent data is a separate confirmed request.
    func executeAgentApplicationRemoval(_ app: UninstallApp,
                                         progress: (UninstallExecutionPhase) -> Void) async -> UninstallExecutionOutcome {
        let job = UninstallJob(id: UUID(), app: app, plan: nil, dataPaths: [], scope: .installationOnly)
        return await uninstallExecutor.execute(job, progress: progress)
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
        if !isStoppingUninstallQueue, taskNotice == nil,
           let action = pendingCleanup, uninstallQueue.activeJob == nil,
           !isUninstallMutationBlocked, confirmation == nil, !isDispatchingConfirmation {
            pendingCleanup = nil
            cleanupQueued = false
            action()
            return
        }
        // Preserve mutual exclusion at the disk mutation edge while allowing
        // more confirmed requests to join the queue from any visible row.
        let blocked = isUninstallMutationBlocked || confirmation != nil || isDispatchingConfirmation
            || taskNotice != nil
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
        let outcome = await uninstallExecutor.execute(job) { phase in
            switch phase {
            case .closing:
                appListStatus = l10n.tf("uninstall.status.closing", target.name)
            case .planning:
                log(l10n.tf("log.uninstallScan", target.name))
            case .removing:
                uninstallQueue.markRunning(job.id)
                appListStatus = l10n.tf("status.uninstalling", target.name)
                log(l10n.tf("log.uninstallApply", target.name))
            }
        }
        let result: NativeCore.ApplySummary
        switch outcome {
        case .processesCouldNotStop:
            finishUninstall(job, succeeded: false,
                message: l10n.tf("status.uninstallPartial", target.name),
                details: ["Uninstall processes could not be stopped."])
            return
        case .planUnavailable:
            finishUninstall(job, succeeded: false, message: l10n.tf("log.uninstallPreviewFail", target.name))
            return
        case .applied(let summary):
            result = summary
        }
        if result.succeeded { uninstallDataSelections[target.id] = nil }
        if !result.messages.isEmpty { log(result.messages.joined(separator: "\n")) }
        if result.removed > 0 { CleanupCache.invalidate() }
        uninstallInventoryGeneration += 1
        if result.succeeded {
            installedApps.removeAll { $0.id == target.id && $0.appIdentity == target.appIdentity }
            uninstallPlans.removeValue(forKey: target.id)
            persistUninstallInventory()
            appListStatus = ""
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
            let reasons = result.messages.filter {
                !$0.hasPrefix("Open-file check ") && !$0.hasPrefix("Retained app data or shared/system item:")
                    && !$0.hasPrefix("Uninstall residue remains:")
            }
            let localizedReasons = TaskFeedbackDiagnostic.localized(reasons)
            if let reason = localizedReasons.first { detail += "\n" + reason }
            if !result.remainingPaths.isEmpty {
                detail += "\n" + l10n.tf("uninstall.remaining", result.remainingPaths.count)
            }
            finishUninstall(job, succeeded: false,
                            message: l10n.tf("status.uninstallPartial", target.name) + "\n" + detail,
                            details: reasons + result.remainingPaths)
        }
    }

    private func finishUninstall(_ job: UninstallJob, succeeded: Bool, message: String, details: [String] = []) {
        uninstallQueue.finish(job.id, succeeded: succeeded, message: message)
        noteHeaderReaction(succeeded ? .success : .attention)
        resampleAfterMutation()
        appListStatus = message
        log(message)
        if !succeeded { presentTaskFailure(message: message, details: details) }
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

    /// Returns a visible error; only clear the editor once the entry is saved.
    func addWhitelistEntry(_ rawPath: String) -> String? {
        let path: String
        do {
            path = try WhitelistPath.validated(rawPath)
        } catch WhitelistPath.ValidationError.missing {
            return l10n.t("wl.error.missing")
        } catch {
            return l10n.t("wl.error.invalid")
        }
        guard !whitelistEntries.contains(where: {
            (try? WhitelistPath.normalized($0)) == path
        }) else { return l10n.t("wl.error.duplicate") }
        whitelistEntries.append(path)
        guard saveWhitelist() else {
            whitelistEntries.removeLast()
            return l10n.t("wl.error.save")
        }
        return nil
    }

    func removeWhitelistEntry(_ path: String) {
        whitelistEntries.removeAll { $0 == path }
        saveWhitelist()
    }

    @discardableResult
    func saveWhitelist() -> Bool {
        let header = """
        # Nori whitelist (shared by native clean / purge / bridge cleanup)
        # One absolute path or glob per line; built-in engine safety always applies.

        """
        let content = header + whitelistEntries.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(
                at: Self.whitelistFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try content.write(to: Self.whitelistFileURL, atomically: true, encoding: .utf8)
        } catch {
            log(l10n.t("wl.error.save"))
            return false
        }
        CleanupCache.invalidate()
        log(l10n.tf("log.wlSaved", whitelistEntries.count))
        return true
    }
}
