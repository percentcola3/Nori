import AppKit
import SwiftUI

/// Fixture state only: the production cleanup view is compiled unchanged, but
/// button actions never start inventory watchers, scans, or deletion workers.
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
    @Published var agentGroups: [AgentGroupSummary] = []
    @Published var agentSkills: [AgentSkill] = []
    @Published var agentServers: [AgentMCPServer] = []
    @Published var agentMCPInstallations: [AgentMCPInstallation] = []
    @Published var agentCLIInstallations: [AgentCLIInstallation] = []
    @Published var agentSelectedCLIInstallations = Set<String>()
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
    var isBusyExcludingUninstall: Bool { isApplying || isCleanupScanning || agentApplying || agentScanning }
    var isBusy: Bool { isBusyExcludingUninstall || cleanupQueued }
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
    func isAgentCategorySelected(_ category: CleanupCategory, path: String) -> Bool { category.isPathSelected(path) }
    func isAgentSkillSelected(_ skill: AgentSkill) -> Bool { false }
    func isAgentServerSelected(_ server: AgentMCPServer) -> Bool { false }
    func toggleAgentCLIInstallation(_ installation: AgentCLIInstallation) {}
    func toggleAgentMCPInstallation(_ installation: AgentMCPInstallation) {}
    func toggleAgentSkill(_ skill: AgentSkill) {}
    func toggleAgentServer(_ server: AgentMCPServer) {}
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

// These auxiliary sections remain empty throughout the presentation fixtures.
struct SystemMaintenanceRow: Identifiable {
    struct Item { let titleKey: String }
    struct Preview { let summary: String }
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
}
struct AgentSkill: Identifiable {
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
}
struct AgentMCPServer: Identifiable {
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
}
struct AgentMCPInstallation: Identifiable {
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
}
