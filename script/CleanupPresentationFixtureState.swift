import AppKit
import SwiftUI

enum AgentCodexFeatureEditor {
    enum State: Equatable, Sendable { case enabled, disabled, unknown }
}

/// Fixture state only: the production cleanup view is compiled unchanged, but
/// button actions never start inventory watchers, scans, or deletion workers.
@MainActor
final class AppState: ObservableObject {
    enum ScanAccess { case quickOptimize, aiScan }
    @Published var categories: [CleanupCategory] = []
    @Published var installerCandidates: CleanupCategory?
    @Published var systemMaintenanceRows: [SystemMaintenanceRow] = []
    @Published var systemMaintenanceSelection: Set<String> = []
    @Published var isSystemMaintenanceRunning = false
    @Published var isApplying = false
    @Published var isCleanupScanning = false
    @Published var cleanupProgress = CleanupScanProgress()
    @Published var cleanupScanMode: CleanupScanMode = .quick
    @Published var cleanupQueued = false
    @Published var cleanupScanComplete = false
    @Published var cleanupDeferredPaths: [String] = []
    @Published var cleanupOutcomeMood: NoriMood?
    @Published var cleanupOutcomeDetails: [String] = []
    @Published var cleanupTaskProgress: CleanupTaskProgress?
    @Published var cleanupCelebrating = false
    @Published var cleanupFeedbackID = 0
    @Published var cleanupCompletedCount = 0
    @Published var cleanupReclaimedBytes: UInt64 = 0
    @Published var cleanupFailureApplications: [String] = []
    @Published var cleanupRetryAvailable = false
    @Published var statusText = ""
    @Published var agentCategories: [CleanupCategory] = []
    @Published var agentRetentionPreferences = AgentRetentionPreferences()
    @Published var awakePreferences = AwakePreferences()
    let awake = AwakeSessionController()
    @Published var agentCodexThreadStoreCompression: AgentCodexFeatureEditor.State?
    @Published var agentGroups: [AgentGroupSummary] = []
    @Published var agentSkills: [AgentSkill] = []
    @Published var agentServers: [AgentMCPServer] = []
    @Published var agentMCPInstallations: [AgentMCPInstallation] = []
    @Published var agentCLIInstallations: [AgentCLIInstallation] = []
    @Published var agentApplications: [String: [UninstallApp]] = [:]
    @Published var agentStorageFootprints: [String: AgentStorageFootprint] = [:]
    @Published var agentCLIBodySizes: [String: AgentInstallationSize] = [:]
    @Published var agentProgramBusyID: String?
    var uninstallDataReview: UUID?
    @Published var agentSelectedCLIInstallations = Set<String>()
    @Published var agentSelectedSkills = Set<String>()
    @Published var agentSelectedServers = Set<String>()
    @Published var agentSelectedSkillRegistrations = Set<String>()
    @Published var agentSelectedMCPInstallations = Set<String>()
    @Published var agentScanCurrentPath = ""
    @Published var agentScanning = false
    @Published var agentApplying = false
    @Published var agentHasScanned = false
    @Published var agentScanComplete = false
    @Published var agentCelebrating = false
    @Published var agentCleanupHasFeedback = false
    @Published var agentOutcomeMood: NoriMood?
    @Published var agentOutcomeDetails: [String] = []
    @Published var agentCleanupProgress: CleanupTaskProgress?
    @Published var agentFeedbackID = 0
    @Published var agentCompletedCount = 0
    @Published var agentReclaimedBytes: UInt64 = 0
    @Published var agentRetryAvailable = false
    @Published var agentFailureApplications: [String] = []
    @Published var agentStatus = ""
    let placeholderScene = "nori-static"
    var scanRequests = 0
    var cancelRequests = 0
    var rescanRequests = 0
    var cleanupRequests = 0
    var maintenanceRequests = 0
    var celebrationFinishes = 0
    var retryRequests = 0
    var programRemovalRequests = 0
    var associatedDataRequests = 0
    // The presentation harness links the production page/mutation predicates.
    // All unrelated domains stay idle; these values never start real services.
    final class Queue {
        var activeJob: String?
        var hasWork: Bool { activeJob != nil }
    }
    final class Simulator { var isDeleting = false }
    let uninstallQueue = Queue()
    let simulatorInventory = Simulator()
    var isScanning: Bool { isCleanupScanning }
    var isAutoCleanupScanning = false
    var isAutoCleanupMutationActive = false
    var isAnalyzing = false
    var isRestoringAnalysis = false
    var isScanningDuplicates = false
    var isSlimming = false
    var isDeletingDuplicates = false
    var isDeletingAnalysisFiles = false
    var isRefreshingAnalysisCache = false
    var isScanningApps = false
    var isScanningCommandLineTools = false
    var isCheckingSoftwareUpdates = false
    var commandLineToolBusyID: String?
    var softwareUpdatingID: String?
    var isScanningEnv = false
    var isApplyingDevEnv = false
    var isRefreshingGc = false
    var gcRunningId: String?
    var isDeveloperCommandRunning = false
    var isDeveloperConfigurationWriting = false
    var isNetworkToolRunning = false
    var hasCleanupSelection: Bool {
        categories.contains { $0.selectedSubset != nil }
            || installerCandidates?.selectedSubset != nil
            || !systemMaintenanceSelection.isEmpty
    }
    var selectedBytes: UInt64 { categories.reduce(0) { $0 + $1.selectedPathBytes } }
    var agentCLISelectedAgentIDs: Set<String> {
        Set(agentCLIInstallations.filter { agentSelectedCLIInstallations.contains($0.id) }.map(\.agentID))
    }
    var agentSelectedCount: Int { agentCategories.reduce(0) { $0 + $1.selectedPathCount } }
    var agentSelectedBytes: UInt64 { agentCategories.reduce(0) { $0 + $1.selectedPathBytes } }
    static func uniqueAgentBytes(_ values: [(String, UInt64)]) -> UInt64 { values.reduce(0) { $0 + $1.1 } }
    func agentGroupBytes(_ group: AgentGroupSummary) -> UInt64 {
        agentCategories.filter { group.categoryIDs.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }
    func agentStorageTotals(for agentID: String? = nil) -> AgentStorageFootprint.Totals? {
        let snapshots = agentID.map { id in agentStorageFootprints[id].map { [$0] } ?? [] }
            ?? agentGroups.compactMap { agentStorageFootprints[$0.id] }
        return snapshots.isEmpty ? nil : AgentStorageFootprint.totals(snapshots)
    }
    func isAgentCategorySelected(_ category: CleanupCategory, path: String) -> Bool { category.isPathSelected(path) }
    func isAgentCategoryIncludedByCLI(_ category: CleanupCategory) -> Bool { false }
    func isAgentSkillSelected(_ skill: AgentSkill) -> Bool { false }
    func isAgentServerSelected(_ server: AgentMCPServer) -> Bool { false }
    func setAgentRetention(_ rule: AgentRetentionRule, for retentionClass: AgentRetentionClass, agentID: String) {
        agentRetentionPreferences.set(rule, for: retentionClass, agentID: agentID)
    }
    func setCodexThreadStoreCompression(_ enabled: Bool) {
        agentCodexThreadStoreCompression = enabled ? .enabled : .disabled
    }
    func startAwakeSession() {
        _ = awake.start(mode: awakePreferences.defaultMode)
    }
    func endAwakeSession() { awake.end(reason: .manual) }
    func setAwakeDefaultMode(_ mode: AwakeMode) { awakePreferences.defaultMode = mode }
    func setAwakeBatteryFloor(_ percent: Int) { awakePreferences.batteryFloorPercent = percent }
    func setAwakeThermalProtection(_ enabled: Bool) { awakePreferences.endAtCriticalThermal = enabled }
    func toggleAgentCLIInstallation(_ installation: AgentCLIInstallation) {}
    func uninstallAgentCLI(_ installation: AgentCLIInstallation) { programRemovalRequests += 1 }
    func uninstallAgentApplication(_ app: UninstallApp) { programRemovalRequests += 1 }
    func offerAgentAssociatedDataCleanup(agentIDs: Set<String>, programName: String? = nil) {
        associatedDataRequests += 1
    }
    func cancelAgentScan() { cancelRequests += 1 }
    var uninstallSegment = 0
    func jump(to key: PageKey) {}
    enum PageKey { case uninstall, agents, cleanup }
    func toggleAgentMCPInstallation(_ installation: AgentMCPInstallation) {}
    func toggleAgentSkill(_ skill: AgentSkill) {}
    func toggleAgentServer(_ server: AgentMCPServer) {}
    var selectedAgentUnbindings: AgentResourceChanges { .init() }
    func isAgentSkillBindingSelected(_ binding: AgentResourceCatalog.SkillBinding) -> Bool { false }
    func toggleAgentSkillBinding(_ binding: AgentResourceCatalog.SkillBinding) {}
    func toggleAgentSkillBindings(_ bindings: [AgentResourceCatalog.SkillBinding]) {}
    func requestAgentResourceChanges(_ changes: AgentResourceChanges) { cleanupRequests += 1 }
    func presentTaskFailure(message: String = "", details: [String] = [], detailsAreLocalized: Bool = false) {}
    func scanAgents() { scanRequests += 1 }
    func applyAgentCleanup() { cleanupRequests += 1 }
    func retryFailedAgentCleanup() { retryRequests += 1 }
    func autoCleanupRuleCovering(directory: String) -> Bool? { nil }
    func requestScanAccess(_ access: ScanAccess) { scanRequests += 1 }
    func cancelCleanupScan() { cancelRequests += 1 }
    func startCleanupScan() { rescanRequests += 1 }
    func applyCleanup() { cleanupRequests += 1 }
    func retryFailedCleanup() { retryRequests += 1 }
    func finishAgentCelebration(feedbackID: Int) {
        guard feedbackID == agentFeedbackID, !agentApplying,
              agentOutcomeMood == .success, agentCelebrating else { return }
        agentCelebrating = false
    }

    func finishCleanupCelebration(feedbackID: Int) {
        guard cleanupCelebrating && cleanupFeedbackID == feedbackID else { return }
        celebrationFinishes += 1
        cleanupCelebrating = false
    }
    func scanSystemMaintenance() { maintenanceRequests += 1 }
    func toggleSystemMaintenance(_ id: String) {
        if systemMaintenanceSelection.contains(id) { systemMaintenanceSelection.remove(id) }
        else { systemMaintenanceSelection.insert(id) }
    }
}

enum ProtectedOperation {
    case cleanupScan, deepCleanupScan, quickOptimize, developerToolsScan
    case previewAutoCleanup, runAutoCleanup, aiScan, installedAppsScan, uninstall
    case developmentEnvironmentScan, diskOverview
}

// These auxiliary sections remain empty throughout the presentation fixtures.
struct SystemMaintenanceRow: Identifiable {
    struct Item { let titleKey: String }
    struct Preview { let summary: String; var bytes: UInt64 = 0 }
    let id: String
    let item: Item
    let preview: Preview
}
struct AutoCleanupIntent: Identifiable {
    let paths: [String]
    let cacheVerified: Bool
    var sourceName: String? = nil
    var id: String { paths.joined(separator: "\n") }
}
struct AutoCleanupIntentSheet: View {
    let state: AppState
    let intent: AutoCleanupIntent
    let onDone: () -> Void
    var body: some View { EmptyView() }
}


struct AgentGroupSummary: Identifiable {
    let id: String
    let name: String
    let documented: Bool
    let categoryIDs: [UUID]
    var orphaned = false
    var lastActivity: Date? = nil
    var unused = false
}
// Capacity classification is covered by AgentStorageFootprintTests. This
// presentation fixture supplies one immutable, already-projected snapshot.
struct AgentStorageFootprint {
    struct Totals {
        let identifiedDataBytes: UInt64
        let reclaimableBytes: UInt64
        let preservedBytes: UInt64
        let measurementComplete: Bool
    }
    let values: Totals
    static func totals(_ footprints: [Self]) -> Totals {
        precondition(footprints.count <= 1, "The presentation fixture renders one Agent snapshot")
        return footprints.first?.values
            ?? .init(identifiedDataBytes: 0, reclaimableBytes: 0, preservedBytes: 0, measurementComplete: false)
    }
}
struct AgentInstallationSize {
    let bytes: UInt64
    let complete: Bool
}
struct AgentCLIInstallation: Identifiable {
    enum Manager: String { case npm }
    let id: String
    let agentID: String
    let name: String
    let manager: Manager
    let identities: [String: String]
    let detail: String
    let managedPaths: [String]
    var executablePaths: [String] = []
}
struct AgentSkill: Identifiable, Sendable {
    let id: String
    let name: String
    let agentID: String
    let identity: String
    let linked: Bool
    let summary: String
    let path: String
    let linkTarget: String?
    let usedBy: [String]
    let bytes: UInt64
    var directUsers: [String] = []
    var registrations: [AgentSkillConfigEditor.Registration] = []
    var bodyDeletionSupported = true
    var isDangling = false
}
struct AgentMCPServer: Identifiable, Sendable {
    enum Issue: Hashable { case commandMissing(String), plaintextSecret(String, String), unreadableConfig }
    let id: String
    let agentID: String
    let name: String
    let agentName: String
    let issues: [Issue]
    let remote: Bool
    let disabled: Bool
    let configPath: String
    let endpoint: String
    let scope: String?
    var installationID: String? = nil
}
struct AgentMCPInstallation: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let bytes: UInt64
    let identity: String
    let serverIDs: [String]
}
enum AgentCatalog {
    struct Definition { let id: String; let name: String }
    static let definitions = [Definition(id: "codex", name: "Codex")]
    static func executableSearchPath(home: String) -> [String] { [] }
    static func isDirectory(_ path: String) -> Bool { false }
    static func isRegularFile(_ path: String) -> Bool { false }
    static func resolveExecutable(_ name: String, searchPath: [String], home: String) -> String? { nil }
    static func absolute(_ relative: String, home: String) -> String {
        URL(fileURLWithPath: home).appendingPathComponent(relative).standardizedFileURL.path
    }
}
enum AgentSkillConfigEditor {
    struct Registration: Equatable, Sendable {
        let configPath: String
        let skillPath: String
        var id: String { configPath + "|" + skillPath }
    }
}
