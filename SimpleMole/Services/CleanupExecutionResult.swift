import Foundation

/// Item-level result returned by one or more cleanup bridges. Accounting is
/// reconciled against the immutable plan so missing bridge counters cannot be
/// presented as successful deletion.
struct CleanupExecutionResult: Equatable {
    var removed: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    var messages: [String] = []
    /// A bridge may confirm deletions and still time out or exit with an error.
    /// Preserve that failure for retries without inventing failed file counts;
    /// presentation can still acknowledge the space already reclaimed.
    var executionFailed = false
    /// Only paths whose deletion was confirmed by the executor. Skips and
    /// failures must remain available for retry with their original identity.
    var removedPaths: Set<String> = []
    /// Allocated bytes of files confirmed permanently deleted by the worker.
    var reclaimedBytes: UInt64 = 0

    var completedSuccessfully: Bool { removed > 0 && skipped == 0 && failed == 0 && !executionFailed }

    mutating func merge(_ other: CleanupExecutionResult) {
        removed += other.removed
        skipped += other.skipped
        failed += other.failed
        messages.append(contentsOf: other.messages)
        executionFailed = executionFailed || other.executionFailed
        removedPaths.formUnion(other.removedPaths)
        reclaimedBytes &+= other.reclaimedBytes
    }

    func remainingPaths(in paths: [String]) -> [String] {
        paths.filter { path in
            !removedPaths.contains { removed in
                path == removed || path.hasPrefix(removed + "/")
            }
        }
    }

    static func reconciled(bridgeOutput: String, expectedCount: Int) -> CleanupExecutionResult {
        var reportedRemoved = 0
        var reportedSkipped = 0
        var reportedFailed = 0
        for line in bridgeOutput.components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Int(parts[1]), value >= 0 else { continue }
            switch parts[0] {
            case "removed": reportedRemoved = value
            case "skipped": reportedSkipped = value
            case "failed": reportedFailed = value
            default: break
            }
        }

        let expected = max(0, expectedCount)
        let removed = min(reportedRemoved, expected)
        let skipped = min(reportedSkipped, expected - removed)
        let failedCapacity = expected - removed - skipped
        let reportedFailure = min(reportedFailed, failedCapacity)
        // A bridge that exits without accounting for a submitted item has not
        // proven either deletion or a deliberate skip, so fail closed.
        let unreportedFailure = failedCapacity - reportedFailure
        return CleanupExecutionResult(
            removed: removed,
            skipped: skipped,
            failed: reportedFailure + unreportedFailure)
    }
}
