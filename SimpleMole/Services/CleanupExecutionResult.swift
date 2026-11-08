import Foundation

/// Item-level result returned by one or more cleanup bridges. Accounting is
/// reconciled against the immutable plan so missing bridge counters cannot be
/// presented as successful deletion.
struct CleanupExecutionResult: Equatable, Sendable {
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
    var retainedTargets: [DeletionPlan.RetainedTarget] = []

    /// Only independently proven exact-target receipts suppress attention. A
    /// malformed or contradictory set stays an ordinary actionable skip.
    var quietRetainedTargets: [DeletionPlan.RetainedTarget] {
        guard !retainedTargets.isEmpty else { return [] }
        var count = 0
        var roots = Set<String>()
        for target in retainedTargets {
            guard target.count == 1, target.count <= skipped - count,
                  target.record != "/", !target.identity.isEmpty, DeletionPlan.isLexicallySafePath(target.record),
                  DeletionPlan.normalizedPathLiteral(target.record) == target.record,
                  roots.insert(target.record).inserted else { return [] }
            count += target.count
        }
        guard !roots.contains(where: { DeletionPlan.isPathCovered($0, by: removedPaths) }) else { return [] }
        return retainedTargets
    }

    var quietSkipped: Int { quietRetainedTargets.reduce(0) { $0 + $1.count } }

    /// Bind each receipt to exactly its original submitted object. Parent and
    /// child targets require separate evidence; neither receipt covers the other.
    func retainedPathIdentities(in submitted: [String: String]) -> [String: String] {
        quietRetainedTargets.reduce(into: [:]) { result, target in
            if submitted[target.record] == target.identity { result[target.record] = target.identity }
        }
    }

    /// A successful read-only preflight can only shrink the original prompt.
    /// Split descendants and new identities never become administrator consent.
    static func freshlyEligibleAdministratorItems(_ proposed: [DeletionPlan.Item],
                                                 freshIdentities: [String: String],
                                                 administratorPaths: Set<String>,
                                                 succeeded: Bool) -> [DeletionPlan.Item] {
        guard succeeded else { return [] }
        return proposed.filter {
            !$0.identity.isEmpty && freshIdentities[$0.record] == $0.identity
                && administratorPaths.contains($0.record)
        }
    }

    /// Prepare bounded UI payloads off-main. The execution's original messages
    /// remain intact; rendering and Published log updates never replay them all.
    static func boundedFeedback(_ messages: [String]) -> (details: [String], logTail: [String]) {
        func clipped(_ text: String) -> String {
            let prefix = text.prefix(2048)
            return String(prefix) + (prefix.endIndex == text.endIndex ? "" : "…")
        }
        let details = messages.lazy.filter { !$0.hasPrefix("Open-file check ") }
            .prefix(80).map(clipped)
        var reversed: [String] = []
        outer: for message in messages.reversed() {
            for line in message.components(separatedBy: .newlines).reversed() {
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { reversed.append(clipped(value)) }
                if reversed.count >= 400 { break outer }
            }
        }
        return (Array(details), Array(reversed.reversed()))
    }

    var completedSuccessfully: Bool { removed > 0 && skipped == 0 && failed == 0 && !executionFailed }

    mutating func merge(_ other: CleanupExecutionResult) {
        removed += other.removed
        skipped += other.skipped
        failed += other.failed
        messages.append(contentsOf: other.messages)
        executionFailed = executionFailed || other.executionFailed
        removedPaths.formUnion(other.removedPaths)
        reclaimedBytes &+= other.reclaimedBytes
        retainedTargets.append(contentsOf: other.retainedTargets)
    }

    func remainingPaths(in paths: [String]) -> [String] {
        paths.filter { path in
            !DeletionPlan.isPathCovered(path, by: removedPaths)
        }
    }

    /// The installer bridge emits one complete three-counter report, then exits
    /// 0 for failed=0 or 1 for known item failures. Anything else is an unknown
    /// execution outcome and must not authorize automatic replay.
    static func reconciledInstallerReport(bridgeOutput: String, expectedCount: Int,
                                         exitCode: Int32, timedOut: Bool,
                                         outputTruncated: Bool) -> CleanupExecutionResult {
        let unknown = CleanupExecutionResult(failed: max(0, expectedCount),
            messages: ["Installer cleanup outcome is incomplete or invalid; automatic retry stopped."],
            executionFailed: true)
        guard expectedCount >= 0, !timedOut, !outputTruncated,
              exitCode == 0 || exitCode == 1 else { return unknown }
        let keys: Set<String> = ["removed", "skipped", "failed"]
        var counters: [String: Int] = [:]
        let lines = bridgeOutput.split(separator: "\n", omittingEmptySubsequences: false)
        let structuralErrors = ["error: missing identity for installer path:",
                                "error: invalid installer path:", "error: invalid identity for installer path:",
                                "error: could not install final installer runtime guard"]
        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            if structuralErrors.contains(where: line.hasPrefix) { return unknown }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawKey = parts.first.map(String.init) ?? ""
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard keys.contains(key) else { continue }
            guard parts.count == 2, rawKey == key, counters[key] == nil,
                  index < lines.count - 1 else { return unknown }
            let value = parts[1]
            guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let number = Int(value), String(number) == value else { return unknown }
            counters[key] = number
        }
        guard let removed = counters["removed"], let skipped = counters["skipped"], let failed = counters["failed"],
              removed <= expectedCount, skipped <= expectedCount - removed,
              failed == expectedCount - removed - skipped,
              (exitCode == 0 && failed == 0) || (exitCode == 1 && failed > 0) else { return unknown }
        return .init(removed: removed, skipped: skipped, failed: failed)
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
