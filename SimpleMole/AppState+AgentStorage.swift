import Foundation

struct AgentInstallationSize: Sendable {
    let bytes: UInt64
    let complete: Bool
}

/// Both software surfaces project one measured Agent data snapshot. Installation
/// bytes keep their own scope; no session directory is measured from a view body.
@MainActor
extension AppState {
    nonisolated static func measureAgentCLIBodies(_ installations: [AgentCLIInstallation],
                                                 control: CleanupScanControl) -> [String: AgentInstallationSize] {
        Dictionary(installations.map { installation in
            let measured = DeletionPlan.nonOverlappingPaths(installation.managedPaths).map {
                CleanupScanWorker.measure($0, control: control)
            }
            return (installation.id, AgentInstallationSize(bytes: measured.reduce(0) { $0 &+ $1.bytes },
                complete: !measured.isEmpty && measured.allSatisfy(\.complete)))
        }, uniquingKeysWith: { first, _ in first })
    }
    func ensureAgentStorageFootprints(for ids: Set<String>) {
        let missing = ids.subtracting(agentStorageFootprints.keys).subtracting(agentStorageCheckingIDs)
        guard !missing.isEmpty else { return }
        agentStorageCheckingIDs.formUnion(missing)
        let generation = agentStorageGeneration
        let home = NSHomeDirectory()
        Task {
            let values = await Task.detached(priority: .utility) {
                let report = AgentInventory.scan(home: home,
                    localize: { L10n.shared.t($0) }, includingAgentIDs: missing,
                    excludingGlobalCleanupCaches: true, onlyAgentIDs: missing)
                let cli = AgentCatalog.definitions.filter { missing.contains($0.id) }
                    .flatMap { AgentCLIService.installations(for: $0, home: home) }
                var values = AgentStorageFootprint.build(report: report, cli: cli)
                for id in missing where values[id] == nil {
                    values[id] = .init(agentID: id, identifiedDataBytes: 0, reclaimableBytes: 0,
                        preservedBytes: 0, measurementComplete: report.complete, entries: [])
                }
                return values
            }.value
            guard agentStorageGeneration == generation else { return }
            agentStorageCheckingIDs.subtract(missing)
            agentStorageFootprints.merge(values, uniquingKeysWith: { _, fresh in fresh })
        }
    }

    func invalidateAgentStorageFootprints() {
        agentStorageGeneration = UUID()
        agentStorageCheckingIDs = []
        agentStorageFootprints = [:]
    }

    func agentDataFootprints(for app: UninstallApp) -> [AgentStorageFootprint] {
        AgentSoftwareInventory.agentIDs(for: app).sorted().compactMap { agentStorageFootprints[$0] }
    }
}
