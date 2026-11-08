import Foundation

/// Pure immutable-plan operations. Call these from an explicit background
/// boundary; none of them reads or refreshes filesystem identity or metadata.
enum CleanupRetryPolicy {
    static let maximumAttempts = 3

    final class Budget: @unchecked Sendable {
        private struct State { let identity: String; var attempts = 0 }
        private struct Candidate {
            let identity: String
            let firstIndex: Int
            let metadata: DeletionPlan.Metadata?
        }
        private let lock = NSLock()
        private var states: [String: State] = [:]

        private func claim(_ candidates: [String: Candidate], conflicted: Bool) -> Set<String> {
            lock.lock(); defer { lock.unlock() }
            // Even a conflicting batch cannot later rebind its first valid
            // identity. No attempt is consumed when the whole batch refuses.
            for (path, candidate) in candidates where states[path] == nil {
                states[path] = State(identity: candidate.identity)
            }
            guard !conflicted, !candidates.contains(where: { states[$0.key]?.identity != $0.value.identity }) else { return [] }
            var accepted = Set<String>()
            for path in candidates.keys {
                guard var state = states[path], state.attempts < CleanupRetryPolicy.maximumAttempts else { continue }
                state.attempts += 1
                states[path] = state
                accepted.insert(path)
            }
            return accepted
        }

        func claim(categories: [CleanupCategory]) -> [CleanupCategory] {
            var candidates: [String: Candidate] = [:]
            var invalidIdentities = Set<String>()
            var conflicted = false
            for (index, category) in categories.enumerated() where category.canSelect {
                for path in category.paths where category.isPathSelected(path) && CleanupRetryPolicy.validPath(path) {
                    guard let identity = category.pathIdentities[path], CleanupRetryPolicy.validIdentity(identity) else {
                        invalidIdentities.insert(path); continue
                    }
                    if let first = candidates[path] { conflicted = conflicted || first.identity != identity }
                    else { candidates[path] = Candidate(identity: identity, firstIndex: index, metadata: nil) }
                }
            }
            conflicted = conflicted || invalidIdentities.contains(where: { candidates[$0] != nil })
            let accepted = claim(candidates, conflicted: conflicted)
            guard !accepted.isEmpty else { return [] }
            return categories.enumerated().compactMap { index, category in
                var seen = Set<String>()
                let paths = category.paths.filter {
                    accepted.contains($0) && candidates[$0]?.firstIndex == index && seen.insert($0).inserted
                }
                return CleanupRetryPolicy.subset(category, keeping: paths)
            }
        }

        func claim(items: [DeletionPlan.Item]) -> [DeletionPlan.Item] {
            var candidates: [String: Candidate] = [:]
            var invalidIdentities = Set<String>()
            var conflicted = false
            for (index, item) in items.enumerated() where CleanupRetryPolicy.validPath(item.record) {
                guard CleanupRetryPolicy.validIdentity(item.identity) else { invalidIdentities.insert(item.record); continue }
                if let first = candidates[item.record] {
                    conflicted = conflicted || first.identity != item.identity || first.metadata != item.metadata
                } else {
                    candidates[item.record] = Candidate(identity: item.identity, firstIndex: index, metadata: item.metadata)
                }
            }
            conflicted = conflicted || invalidIdentities.contains(where: { candidates[$0] != nil })
            let accepted = claim(candidates, conflicted: conflicted)
            return items.enumerated().compactMap { index, item in
                accepted.contains(item.record) && candidates[item.record]?.firstIndex == index ? item : nil
            }
        }
    }

    private static func validPath(_ path: String) -> Bool {
        path != "/" && DeletionPlan.isLexicallySafePath(path) && DeletionPlan.normalizedPathLiteral(path) == path
    }
    private static func validIdentity(_ identity: String) -> Bool {
        !identity.isEmpty && identity == identity.trimmingCharacters(in: .whitespacesAndNewlines)
            && !identity.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f })
    }
    private static func subset(_ category: CleanupCategory, keeping paths: [String]) -> CleanupCategory? {
        guard !paths.isEmpty, var result = category.selectingPaths(paths).selectedSubset else { return nil }
        // selectedSubset preserves all owner, route, identity and activity
        // fields. Remove duplicate original records without reconstructing it.
        result.paths = paths
        return result
    }
    private static func confirmedPaths(_ result: CleanupExecutionResult) -> Set<String> {
        Set(result.removedPaths.filter(validPath))
    }
    private static func quietIdentities(_ result: CleanupExecutionResult) -> [String: String] {
        result.quietRetainedTargets.reduce(into: [:]) { values, target in
            if validIdentity(target.identity) { values[target.record] = target.identity }
        }
    }

    static func remainingCategories(_ categories: [CleanupCategory], after result: CleanupExecutionResult) -> [CleanupCategory] {
        let removed = confirmedPaths(result), retained = quietIdentities(result)
        return categories.compactMap { category in
            var seen = Set<String>()
            let paths = category.paths.filter { path in
                category.isPathSelected(path) && seen.insert(path).inserted
                    && !DeletionPlan.isPathCovered(path, by: removed)
                    && (category.pathIdentities[path] == nil || retained[path] != category.pathIdentities[path])
            }
            return subset(category, keeping: paths)
        }
    }

    static func remainingItems(_ items: [DeletionPlan.Item], after result: CleanupExecutionResult) -> [DeletionPlan.Item] {
        let removed = confirmedPaths(result), retained = quietIdentities(result)
        return items.filter { !DeletionPlan.isPathCovered($0.record, by: removed) && retained[$0.record] != $0.identity }
    }

    private static func adding(_ left: Int, _ right: Int) -> Int {
        let (value, overflow) = max(0, left).addingReportingOverflow(max(0, right))
        return overflow ? Int.max : value
    }
    private static func messageTail(_ prior: [String], _ current: [String]) -> [String] {
        func clipped(_ value: String) -> String {
            let bytes = Array(value.utf8.suffix(2048))
            var start = 0
            while start < bytes.count, String(bytes: bytes[start...], encoding: .utf8) == nil { start += 1 }
            return String(decoding: bytes.dropFirst(start), as: UTF8.self)
        }
        let recent = Array(current.suffix(400))
        return prior.suffix(400 - recent.count).map(clipped) + recent.map(clipped)
    }

    /// `current` is a new executor pass over all remaining targets, not a
    /// cumulative result or a partial route. Counters are actual per-pass work;
    /// paths alone cannot distinguish a newly recreated leaf of a live cache.
    static func combiningAttempts(_ prior: CleanupExecutionResult, _ current: CleanupExecutionResult) -> CleanupExecutionResult {
        let removedPaths = confirmedPaths(prior).union(confirmedPaths(current))
        let oldQuiet = prior.quietRetainedTargets, newQuiet = current.quietRetainedTargets
        var receipts: [String: DeletionPlan.RetainedTarget] = [:]
        var order: [String] = []
        var conflicts = Set<String>()
        for target in oldQuiet + newQuiet where validIdentity(target.identity) {
            guard !DeletionPlan.isPathCovered(target.record, by: removedPaths) else { continue }
            if let first = receipts[target.record] {
                if first.identity != target.identity { conflicts.insert(target.record) }
                else { receipts[target.record] = target }
            } else {
                receipts[target.record] = target
                order.append(target.record)
            }
        }
        let retained = order.compactMap { conflicts.contains($0) ? nil : receipts[$0] }
        let validCurrentQuiet = newQuiet.reduce(0) { count, target in
            count + (receipts[target.record]?.identity == target.identity && !conflicts.contains(target.record) ? 1 : 0)
        }
        let (bytes, overflow) = prior.reclaimedBytes.addingReportingOverflow(current.reclaimedBytes)
        return .init(removed: adding(prior.removed, current.removed),
            skipped: adding(max(0, current.skipped - validCurrentQuiet), retained.count),
            failed: max(0, current.failed), messages: messageTail(prior.messages, current.messages),
            executionFailed: current.executionFailed, removedPaths: removedPaths,
            reclaimedBytes: overflow ? UInt64.max : bytes, retainedTargets: retained)
    }
}
