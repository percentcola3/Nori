import Foundation

/// Real submitted-target progress. Preparing and verification have no estimated
/// percentage; a target is handled when its execution or refusal completes.
struct CleanupTaskProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case preparing, cleaning, verifying }

    var phase: Phase = .preparing
    var completed = 0
    var total = 0
    var currentItem = ""

    var fraction: Double? {
        guard phase == .cleaning, total > 0 else { return nil }
        return Double(min(total, max(0, completed))) / Double(total)
    }
}
