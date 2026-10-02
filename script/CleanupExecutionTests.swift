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

    static func main() throws {
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
    }
}
