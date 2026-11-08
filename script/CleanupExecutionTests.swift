import Foundation

@main
struct CleanupExecutionTests {
    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        if !condition() {
            throw NSError(domain: "CleanupExecutionTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func testRetainedTargets() throws {
        typealias Target = DeletionPlan.RetainedTarget
        let root = "/cache/retained"
        let target = Target(record: root, identity: "original", reason: .protectedFlags, count: 1)
        let quiet = CleanupExecutionResult(skipped: 1, retainedTargets: [target])
        try expect(quiet.quietSkipped == 1 && !quiet.completedSuccessfully && quiet.removed == 0 && quiet.reclaimedBytes == 0,
                   "Retained receipts must not manufacture deletion, bytes or complete success")
        let child = root + "/child"
        let neighbor = root + "-neighbor"
        let unicode = root + "/\u{301}entry"
        let scoped = quiet.retainedPathIdentities(in: [root: "original", child: "child-id", neighbor: "neighbor", unicode: "unicode"])
        try expect(scoped == [root: "original"], "An exact parent receipt incorrectly covered a child or nested mount")
        try expect(quiet.retainedPathIdentities(in: [root: "replacement"]).isEmpty,
                   "A different identity inherited a retained receipt")
        try expect(quiet.remainingPaths(in: [root, child]) == [root, child], "Feedback changed confirmed-removal accounting")
        var merged = quiet
        let readOnly = Target(record: "/cache/read-only", identity: "ro", reason: .readOnlyVolume, count: 1)
        merged.merge(.init(skipped: 1, retainedTargets: [readOnly]))
        try expect(merged.quietSkipped == 2 && merged.retainedTargets == [target, readOnly], "Merging dropped exact receipts")
        for bad in [Target(record: root, identity: "original", reason: .protectedFlags, count: 0),
                    Target(record: root, identity: "original", reason: .protectedFlags, count: -1),
                    Target(record: root, identity: "original", reason: .protectedFlags, count: 2),
                    Target(record: "/", identity: "root", reason: .readOnlyVolume, count: 1),
                    Target(record: "/cache/../retained", identity: "original", reason: .protectedFlags, count: 1),
                    Target(record: root, identity: "", reason: .protectedFlags, count: 1)] {
            try expect(CleanupExecutionResult(skipped: 2, retainedTargets: [bad]).quietSkipped == 0,
                       "Malformed or descendant-covering retention evidence suppressed attention")
        }
        let leaf = Target(record: child, identity: "child-id", reason: .protectedFlags, count: 1)
        try expect(CleanupExecutionResult(skipped: 2, retainedTargets: [target, target]).quietSkipped == 0,
                   "A duplicate exact receipt was counted twice")
        let nested = CleanupExecutionResult(skipped: 2, retainedTargets: [target, leaf])
        try expect(nested.quietSkipped == 2
                   && nested.retainedPathIdentities(in: [root: "original", child: "child-id"]) == [root: "original", child: "child-id"],
                   "Independently proven nested targets lost their exact receipts")
        try expect(CleanupExecutionResult(skipped: 2, retainedTargets: [target, leaf, readOnly]).quietSkipped == 0,
                   "Receipt count exceeded actual skipped targets")
        let leafOnly = CleanupExecutionResult(skipped: 1, retainedTargets: [leaf])
        try expect(leafOnly.retainedPathIdentities(in: [root: "original", child: "child-id"]) == [child: "child-id"],
                   "A retained child hid an actionable parent")
        for removed in [root, "/cache"] {
            try expect(CleanupExecutionResult(removed: 1, skipped: 1, removedPaths: [removed], retainedTargets: [target]).quietSkipped == 0,
                       "Removed self/ancestor contradicted a retained exact target")
        }
        let partial = CleanupExecutionResult(removed: 1, skipped: 1, removedPaths: [child], reclaimedBytes: 4096, retainedTargets: [target])
        try expect(partial.quietSkipped == 1 && partial.reclaimedBytes == 4096 && partial.remainingPaths(in: [root, child]) == [root],
                   "A retained root must permit independently confirmed child deletion and real reclaimed bytes")
        try expect(CleanupExecutionResult(removed: 1, skipped: 1, removedPaths: [neighbor], retainedTargets: [target]).quietSkipped == 1,
                   "A same-prefix sibling invalidated unrelated retention evidence")
    }

    private static func testFreshConsent() throws {
        let original = [DeletionPlan.Item(record: "/cache/root", identity: "original")]
        let allowed = CleanupExecutionResult.freshlyEligibleAdministratorItems(original,
            freshIdentities: ["/cache/root": "original", "/cache/new": "new"], administratorPaths: ["/cache/root", "/cache/new"], succeeded: true)
        try expect(allowed.count == 1 && allowed[0].record == original[0].record && allowed[0].identity == "original",
                   "Fresh consent expanded beyond an exact original target")
        for (identities, admin, succeeded) in [(["/cache/root/child": "child"], Set(["/cache/root/child"]), true),
                                              (["/cache/root": "replaced"], Set(["/cache/root"]), true),
                                              (["/cache/root": "original"], Set<String>(), true),
                                              (["/cache/root": "original"], Set(["/cache/root"]), false)] {
            try expect(CleanupExecutionResult.freshlyEligibleAdministratorItems(original,
                freshIdentities: identities, administratorPaths: admin, succeeded: succeeded).isEmpty,
                       "Split, replaced, non-administrator or failed inspection expanded consent")
        }
    }

    private static func testBoundedFeedback() throws {
        let messages = (0..<100_000).map { "diagnostic \($0)" }
        let payload = CleanupExecutionResult.boundedFeedback(messages)
        try expect(payload.details.count == 80 && payload.logTail.count == 400
                   && payload.logTail.last == messages.last && messages.count == 100_000,
                   "Diagnostic projection lost its bounds or newest raw tail")
        let lines = CleanupExecutionResult.boundedFeedback(["Open-file check complete", String(repeating: "x", count: 10_000), "last\nline"])
        try expect(lines.details.count == 2 && lines.details[0].count == 2049 && lines.logTail.suffix(2) == ["last", "line"],
                   "Diagnostic projection did not bound long messages or preserve logical log lines")
    }

    private static func testInstallerReportClassification() throws {
        func classify(_ output: String, count: Int = 2, exit: Int32 = 1,
                      timedOut: Bool = false, truncated: Bool = false) -> CleanupExecutionResult {
            CleanupExecutionResult.reconciledInstallerReport(bridgeOutput: output, expectedCount: count,
                exitCode: exit, timedOut: timedOut, outputTruncated: truncated)
        }
        let failed = "removed=0\nskipped=0\nfailed=2\n"
        let partial = "permission denied; original file retained\nremoved=1\nskipped=0\nfailed=1\n"
        let success = "removed=2\nskipped=0\nfailed=0\n"
        let known = classify(partial)
        try expect(known.removed == 1 && known.failed == 1 && !known.executionFailed,
                   "A complete exit-1 installer report incorrectly stopped safe original-identity retry")
        try expect(classify(success, exit: 0).completedSuccessfully,
                   "A complete successful installer report was rejected")
        let skipped = classify("removed=0\nskipped=2\nfailed=0\n", exit: 0)
        try expect(skipped.skipped == 2 && !skipped.executionFailed && skipped.removed == 0,
                   "Known runtime skips became deletions or an unknown report")
        let invalid = ["", "removed=1\nskipped=0\n", "removed=0\nskipped=0\nfailed=2",
                       failed + "removed=0\n", "removed=0\nremoved=nope\nskipped=0\nfailed=2\n",
                       "removed=-1\nskipped=0\nfailed=2\n", "removed=+0\nskipped=0\nfailed=2\n",
                       "removed=0.0\nskipped=0\nfailed=2\n", "removed=\nskipped=0\nfailed=2\n",
                       "removed=999999999999999999999999\nskipped=0\nfailed=2\n",
                       "removed=3\nskipped=0\nfailed=0\n", "removed=0\nskipped=0\nfailed=1\n",
                       " removed=0\nskipped=0\nfailed=2\n", "removed=0=0\nskipped=0\nfailed=2\n",
                       "error: missing identity for installer path: fixture\n" + failed]
        for output in invalid {
            let unknown = classify(output)
            try expect(unknown.executionFailed && unknown.removed == 0 && unknown.removedPaths.isEmpty && unknown.failed == 2,
                       "Incomplete/malformed installer output authorized replay or invented confirmed deletions")
        }
        for (output, code, timeout, truncated) in [(failed, Int32(0), false, false), (success, Int32(1), false, false),
                                                   (failed, Int32(78), false, false), (failed, Int32(130), false, false),
                                                   (failed, Int32(1), true, false), (failed, Int32(1), false, true)] {
            try expect(classify(output, exit: code, timedOut: timeout, truncated: truncated).executionFailed,
                       "Exit mismatch, structural failure, timeout or truncation permitted installer replay")
        }
        // Only synthetic reports execute here. Each pass keeps the same original
        // immutable plan; no file, bridge, authorization or application runs.
        let original = [DeletionPlan.Item(record: "/fixture/original.pkg", identity: "1:2:3"),
                        DeletionPlan.Item(record: "/fixture/second.pkg", identity: "1:4:5")]
        func attempts(_ reports: [(String, Int32)]) -> Int {
            var calls = 0
            for report in reports.prefix(3) {
                let frozen = original
                precondition(frozen[0].identity == "1:2:3")
                calls += 1
                let result = classify(report.0, exit: report.1)
                if result.executionFailed || result.failed == 0 { break }
            }
            return calls
        }
        try expect(attempts([(failed, 1), (failed, 1), (success, 0)]) == 3,
                   "Known installer failures did not reach a later successful retry")
        try expect(attempts([(failed, 1), (failed, 1), (failed, 1), (success, 0)]) == 3,
                   "Synthetic installer attempts escaped the three-pass cap")
        try expect(attempts([("removed=1\n", 0), (success, 0)]) == 1,
                   "An exit-0 missing report was blindly replayed")
        var confirmed = CleanupExecutionResult(removed: 1, removedPaths: ["/fixture/confirmed.pkg"])
        confirmed.merge(classify("removed=1\n", exit: 0))
        try expect(confirmed.removed == 1 && confirmed.removedPaths == ["/fixture/confirmed.pkg"] && confirmed.executionFailed,
                   "Unknown output fabricated new removals or erased prior confirmed path evidence")
    }

    static func main() throws {
        try testRetainedTargets()
        try testFreshConsent()
        try testBoundedFeedback()
        try testInstallerReportClassification()
        let complete = CleanupExecutionResult.reconciled(
            bridgeOutput: "removed=3\nskipped=2\nfailed=1\n", expectedCount: 6)
        try expect(complete == CleanupExecutionResult(removed: 3, skipped: 2, failed: 1),
                   "bridge counters were not preserved")

        var interrupted = CleanupExecutionResult(removed: 2, executionFailed: true)
        try expect(!interrupted.completedSuccessfully,
                   "reported deletions must not hide an interrupted bridge")
        interrupted.merge(CleanupExecutionResult(removed: 1))
        try expect(interrupted.executionFailed && !interrupted.completedSuccessfully,
                   "a later successful route must not erase an earlier execution failure")

        let unreported = CleanupExecutionResult.reconciled(
            bridgeOutput: "removed=1\nskipped=1\n", expectedCount: 4)
        try expect(unreported == CleanupExecutionResult(removed: 1, skipped: 1, failed: 2),
                   "unreported submitted items must fail closed")

        let invalid = CleanupExecutionResult.reconciled(
            bridgeOutput: "removed=-1\nskipped=nope\nfailed=0\n", expectedCount: 2)
        try expect(invalid == CleanupExecutionResult(removed: 0, skipped: 0, failed: 2),
                   "invalid bridge counters must not claim success")

        var aggregate = CleanupExecutionResult(skipped: 4)
        aggregate.merge(complete)
        try expect(aggregate == CleanupExecutionResult(removed: 3, skipped: 6, failed: 1),
                   "runtime skips and route results were not aggregated separately")

        var partial = CleanupExecutionResult(removed: 1, skipped: 1, failed: 1,
                                             removedPaths: ["/cache/deleted"])
        let scanned = ["/cache/deleted", "/cache/deleted/child", "/cache/deleted-sibling",
                       "/cache/in-use", "/cache/failed"]
        try expect(partial.remainingPaths(in: scanned) ==
                    ["/cache/deleted-sibling", "/cache/in-use", "/cache/failed"],
                   "partial cleanup must retain skipped/failed paths and remove coalesced descendants")
        partial.merge(CleanupExecutionResult(removed: 1, removedPaths: ["/cache/failed"]))
        try expect(partial.remainingPaths(in: scanned) == ["/cache/deleted-sibling", "/cache/in-use"],
                   "successful retry must remove only its confirmed paths")
        let skipped = CleanupExecutionResult(skipped: 3)
        try expect(skipped.remainingPaths(in: scanned) == scanned,
                   "a failed open-file probe must preserve all paths for retry")
        try expect(!skipped.completedSuccessfully && !complete.completedSuccessfully
                   && CleanupExecutionResult(removed: 1).completedSuccessfully,
                   "execution completeness must preserve partial work independently of its presentation")
        var bytes = CleanupExecutionResult(removed: 1, reclaimedBytes: 4096)
        bytes.merge(CleanupExecutionResult(removed: 1, failed: 1, reclaimedBytes: 8192))
        try expect(bytes.reclaimedBytes == 12288 && !bytes.completedSuccessfully,
                   "confirmed space must aggregate even when another target fails")
        var explained = CleanupExecutionResult(skipped: 1, messages: ["cache is open"])
        explained.merge(CleanupExecutionResult(failed: 1, messages: ["permission denied"]))
        try expect(explained.messages == ["cache is open", "permission denied"],
                   "route diagnostics were lost while aggregating cleanup results")

        // Large successful batches are reconciled on the presentation actor.
        // Preserve exact/prefix semantics while keeping retry selection cheap.
        let removed = Set((0..<10_000).map { "/cache/generated/\($0)" })
        let batch = CleanupExecutionResult(removed: removed.count, removedPaths: removed)
        let remaining = "/cache/generated-sibling/keep"
        let started = ProcessInfo.processInfo.systemUptime
        try expect(batch.remainingPaths(in: Array(removed) + [remaining]) == [remaining],
                   "large cleanup batches lost remaining sibling paths")
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try expect(elapsed < 0.5, "large retry reconciliation stalled the presentation actor")
        let unicode = CleanupExecutionResult(removed: 1, removedPaths: ["/cache"])
        try expect(unicode.remainingPaths(in: ["/cache/\u{301}entry"]) == ["/cache/\u{301}entry"],
                   "retry reconciliation changed literal Unicode prefix semantics")
        print(String(format: "Cleanup retry reconciliation: 10000 confirmed paths in %.2fms", elapsed * 1000))
    }
}
