import Darwin
import Foundation

@main
struct CleanupRetryPolicyTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: message, code: 1) }
    }
    static func item(_ path: String, _ identity: String? = nil, metadata: DeletionPlan.Metadata? = nil) -> DeletionPlan.Item {
        .init(record: path, identity: identity ?? "original:" + path, metadata: metadata)
    }
    static func category(_ paths: [String]) -> CleanupCategory {
        var identities: [String: String] = [:], sizes: [String: UInt64] = [:]
        for path in paths { identities[path] = "original:" + path; sizes[path] = 16 }
        var result = CleanupCategory(name: "Pure fixture", paths: paths, bytes: UInt64(Set(paths).count) * 16,
            pathBytes: sizes, pathIdentities: identities, pathActivity: identities.mapValues { _ in Date(timeIntervalSince1970: 1) },
            pathNotes: identities.mapValues { _ in "original note" }, selected: true,
            source: .core, risk: .safe, disposal: .permanentDelete, applyRoute: .genericTrash,
            retention: 123, reasonKey: "original.reason")
        result.activityOwners = ["original.owner"]
        return result
    }
    static func receipt(_ path: String, _ identity: String? = nil) -> DeletionPlan.RetainedTarget {
        .init(record: path, identity: identity ?? "original:" + path, reason: .protectedFlags, count: 1)
    }
    static func testBudget() throws {
        let path = "/fixture/cache/a", other = "/fixture/cache/b"
        let budget = CleanupRetryPolicy.Budget()
        let original = category([path, other]).selectingPaths([path])
        let first = budget.claim(categories: [original, original])
        try expect(first.count == 1 && first[0].paths == [path] && first[0].id == original.id
            && first[0].activityOwners == original.activityOwners && first[0].reasonKey == original.reasonKey
            && first[0].retention == original.retention && first[0].pathNotes[path] == "original note"
            && !first[0].paths.contains(other), "Category claim expanded selection or lost immutable context")
        var value = stat(); value.st_ino = 1; value.st_dev = 1; value.st_size = 123
        let metadata = DeletionPlan.Metadata(value)
        let frozen = item(path, metadata: metadata)
        let second = budget.claim(items: [frozen, frozen])
        try expect(second.count == 1 && second[0].metadata == metadata, "Item claim lost original metadata or duplicated a target")
        try expect(budget.claim(categories: [original]).count == 1 && budget.claim(items: [frozen]).isEmpty,
                   "Cross-route budget exceeded three claims")
        try expect(budget.claim(items: [item(other)]).count == 1, "An unselected path consumed budget")

        let conflict = CleanupRetryPolicy.Budget()
        try expect(conflict.claim(items: [item(path), item(path, "replacement"), item(other)]).isEmpty,
                   "A conflicting batch partially executed")
        try expect(conflict.claim(items: [item(path, "replacement")]).isEmpty, "Conflict rebound first original identity")
        for _ in 0..<3 { try expect(conflict.claim(items: [item(path)]).count == 1, "Rejected batch consumed an attempt") }
        try expect(conflict.claim(items: [item(path)]).isEmpty, "Fourth attempt was admitted")
        let inconsistent = CleanupRetryPolicy.Budget()
        try expect(inconsistent.claim(items: [item(path), frozen]).isEmpty, "Conflicting duplicate metadata was accepted")
        let invalid = ["", "/", "relative", "/fixture//a", "/fixture/./a", "/fixture/../a", "/fixture/a\n"]
        try expect(CleanupRetryPolicy.Budget().claim(items: invalid.map { item($0) }).isEmpty, "Noncanonical/unsafe records entered the budget")
        try expect(CleanupRetryPolicy.Budget().claim(items: [item(path, ""), item(other, "bad\0id")]).isEmpty,
                   "Invalid identity entered the budget")

        final class Count: @unchecked Sendable {
            let lock = NSLock(); var value = 0
            func add(_ number: Int) { lock.lock(); value += number; lock.unlock() }
        }
        let concurrent = CleanupRetryPolicy.Budget(), count = Count()
        DispatchQueue.concurrentPerform(iterations: 40) { _ in count.add(concurrent.claim(items: [item(path)]).count) }
        try expect(count.value == 3, "Concurrent routes escaped the shared cap")
    }
    static func testRemaining() throws {
        let parent = "/fixture/held", child = parent + "/child", gone = "/fixture/gone/item", keep = "/fixture/keep"
        let original = category([parent, child, gone, keep]).selectingPaths([parent, child, gone])
        let result = CleanupExecutionResult(removed: 1, skipped: 1, removedPaths: ["/fixture/gone"], retainedTargets: [receipt(parent)])
        let categories = CleanupRetryPolicy.remainingCategories([original], after: result)
        try expect(categories.count == 1 && categories[0].paths == [child] && categories[0].activityOwners == original.activityOwners,
                   "Remaining categories expanded selection, ignored ancestor deletion or quieted an independent child")
        let items = [item(parent), item(child), item(gone), item(parent, "new-identity")]
        let remaining = CleanupRetryPolicy.remainingItems(items, after: result)
        try expect(remaining.map(\.record) == [child, parent] && remaining.last?.identity == "new-identity",
                   "Quiet receipt covered a child or different file identity")
        let invalid = CleanupExecutionResult(skipped: 2, retainedTargets: [.init(record: parent, identity: "original:" + parent,
                                                                                  reason: .protectedFlags, count: 2)])
        try expect(CleanupRetryPolicy.remainingItems([item(parent)], after: invalid).count == 1, "Malformed quiet evidence removed a retry target")
    }
    static func testCombining() throws {
        let q = "/fixture/held", first = "/fixture/first", second = "/fixture/second"
        let prior = CleanupExecutionResult(removed: 1, skipped: 2, failed: 3, messages: ["old transient"], executionFailed: true,
                                          removedPaths: [first], reclaimedBytes: 10, retainedTargets: [receipt(q)])
        let current = CleanupExecutionResult(removed: 1, skipped: 1, failed: 0, messages: ["recovered"],
                                            removedPaths: [second], reclaimedBytes: 7, retainedTargets: [receipt(q)])
        let result = CleanupRetryPolicy.combiningAttempts(prior, current)
        try expect(result.removed == 2 && result.reclaimedBytes == 17 && result.removedPaths == [first, second]
            && result.failed == 0 && !result.executionFailed && result.skipped == 1 && result.retainedTargets == [receipt(q)],
            "Per-pass work or terminal failures/quiet-once accounting was lost")
        let noRepeat = CleanupRetryPolicy.combiningAttempts(result, .init())
        try expect(noRepeat.removed == 2 && noRepeat.reclaimedBytes == 17 && noRepeat.skipped == 1,
                   "Previously accumulated work or quiet receipt was counted again")
        let ancestor = CleanupRetryPolicy.combiningAttempts(prior, .init(removed: 1, removedPaths: ["/fixture"]))
        try expect(ancestor.retainedTargets.isEmpty && ancestor.skipped == 0, "Removed ancestor did not cancel old quiet evidence")
        let descendant = CleanupRetryPolicy.combiningAttempts(prior, .init(removed: 1, removedPaths: [q + "/child"]))
        try expect(descendant.retainedTargets == [receipt(q)] && descendant.skipped == 1, "Removed descendant canceled its independently retained parent")
        let changed = CleanupRetryPolicy.combiningAttempts(prior, .init(skipped: 1, retainedTargets: [receipt(q, "replacement")]))
        try expect(changed.retainedTargets.isEmpty && changed.skipped == 1, "Conflicting quiet identities became silent")
        let enormous = String(repeating: "e\u{301}", count: 3000) + "terminal"
        let bounded = CleanupRetryPolicy.combiningAttempts(.init(messages: Array(repeating: enormous, count: 100_000)),
                                                         .init(messages: [enormous]))
        try expect(bounded.messages.count == 400 && bounded.messages.allSatisfy { $0.utf8.count <= 2048 }
            && bounded.messages.last?.hasSuffix("terminal") == true, "Diagnostic tails grew unbounded or lost newest text")
        let overflow = CleanupRetryPolicy.combiningAttempts(.init(removed: Int.max, reclaimedBytes: UInt64.max),
                                                          .init(removed: 1, reclaimedBytes: 1))
        try expect(overflow.removed == Int.max && overflow.reclaimedBytes == UInt64.max, "Counter overflow wrapped or trapped")
    }
    final class Work: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var problem: String?
        private var seconds = 0.0
        func finish(_ problem: String?, seconds: Double) { lock.lock(); self.problem = problem; self.seconds = seconds; done = true; lock.unlock() }
        func snapshot() -> (Bool, String?, Double) { lock.lock(); defer { lock.unlock() }; return (done, problem, seconds) }
    }
    static func testScale() throws {
        let work = Work()
        var beats = 0, maximumGap: UInt64 = 0
        var last = DispatchTime.now().uptimeNanoseconds
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        timer.setEventHandler { let now = DispatchTime.now().uptimeNanoseconds; maximumGap = max(maximumGap, now - last); last = now; beats += 1 }
        timer.resume()
        DispatchQueue.global(qos: .utility).async {
            let began = DispatchTime.now().uptimeNanoseconds
            do {
                let paths = (0..<100_000).map { "/fixture/cache/\($0)/payload" }
                let original = category(paths), budget = CleanupRetryPolicy.Budget()
                for _ in 0..<3 { try expect(budget.claim(categories: [original]).first?.paths.count == paths.count, "100k claim lost scope") }
                try expect(budget.claim(categories: [original]).isEmpty, "100k fourth claim escaped")
                let removed = Set(paths.prefix(50_000))
                let quiet = paths.suffix(25_000).map { receipt($0) }
                let result = CleanupExecutionResult(removed: 50_000, skipped: quiet.count, removedPaths: removed, retainedTargets: quiet)
                let remaining = CleanupRetryPolicy.remainingCategories([original], after: result)
                try expect(remaining.first?.paths.count == 25_000, "100k remaining filtering changed exact scope")
                let combined = CleanupRetryPolicy.combiningAttempts(result, .init())
                try expect(combined.retainedTargets.count == quiet.count && combined.skipped == quiet.count,
                           "100k quiet aggregation duplicated or lost receipts")
                work.finish(nil, seconds: Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9)
            } catch { work.finish(String(describing: error), seconds: 0) }
        }
        let deadline = Date().addingTimeInterval(20)
        while !work.snapshot().0, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        timer.cancel()
        let result = work.snapshot()
        try expect(result.0 && result.1 == nil && beats > 2 && maximumGap < 500_000_000,
                   "100k background policy failed or blocked heartbeat: " + (result.1 ?? "timeout"))
        print("CleanupRetryPolicy 100k: \(result.2)s heartbeat=\(beats) maxGapMs=\(Double(maximumGap) / 1e6)")
    }
    static func main() throws {
        try testBudget(); try testRemaining(); try testCombining(); try testScale()
        print("PASS CleanupRetryPolicy: shared three-attempt budget, immutable identities/metadata, conflicts, exact remaining scope, terminal aggregation, bounded diagnostics and 100k heartbeats; no filesystem probes")
    }
}
