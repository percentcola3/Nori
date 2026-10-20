import Foundation

/// Successful desktop removals can finish as a batch. Review their exclusive
/// Agent data once the existing uninstall queue and its failure notices settle.
/// This queue stores review scopes only; it grants no authority to delete data.
struct AgentRemovalReviewQueue {
    private var agentIDs: Set<String> = []

    mutating func record(agentIDs removedIDs: Set<String>, installationWasRemoved: Bool) {
        guard installationWasRemoved else { return }
        agentIDs.formUnion(removedIDs)
    }

    mutating func takeIfReady(hasUninstallWork: Bool, isBlocked: Bool) -> Set<String> {
        guard !hasUninstallWork, !isBlocked else { return [] }
        let pending = agentIDs
        agentIDs = []
        return pending
    }
}
