import Foundation
import Darwin

private actor TransportProbe {
    let replies: [RunResult]
    let lease: UUID?
    var firstCalls = 0
    var reuseCalls = 0
    var plans: [[AdministratorCleanupPlan.Record]] = []
    init(_ replies: [RunResult], lease: UUID? = UUID()) { self.replies = replies; self.lease = lease }
    func execute(_ manifest: URL, reuse: UUID?) -> PrivilegedSessionClient.Execution {
        if let reuse { precondition(reuse == lease); reuseCalls += 1 }
        else { firstCalls += 1 }
        let request = try! JSONDecoder().decode(AdministratorCleanupPlan.Request.self, from: Data(contentsOf: manifest))
        plans.append(request.records)
        return .init(result: replies[min(plans.count - 1, replies.count - 1)], sessionID: lease)
    }
    func snapshot() -> (Int, Int, [[AdministratorCleanupPlan.Record]]) { (firstCalls, reuseCalls, plans) }
    nonisolated var transport: AdministratorCleanupService.Transport {
        .init(first: { await self.execute($0, reuse: nil) }, reuse: { manifest, lease in
            await self.execute(manifest, reuse: lease).result
        })
    }
}

@main
struct AdministratorCleanupRetryTests {
    static func item(_ suffix: String) -> DeletionPlan.Item {
        var info = stat()
        info.st_dev = 1; info.st_ino = 2; info.st_uid = getuid(); info.st_gid = getgid()
        info.st_mode = mode_t(S_IFREG | 0o600)
        return .init(record: "/fixture/admin-retry/" + suffix, identity: "original-" + suffix, metadata: .init(info))
    }
    static func report(removed: [String] = [], skipped: Int = 0, failed: Int = 0,
                       bytes: UInt64 = 0, retained: [DeletionPlan.RetainedTarget]? = nil,
                       code: Int32 = 0, stderr: String = "", timeout: Bool = false,
                       truncated: Bool = false) -> RunResult {
        let report = AdministratorCleanupPlan.Report(removed: removed.count, skipped: skipped, failed: failed,
            messages: [], removedPaths: removed, reclaimedBytes: bytes, retainedTargets: retained)
        let json = String(decoding: try! JSONEncoder().encode(report), as: UTF8.self)
        return .init(output: AdministratorCleanupPlan.reportPrefix + json, errorOutput: stderr,
                     exitCode: code, timedOut: timeout, outputTruncated: truncated)
    }
    private static func run(_ items: [DeletionPlan.Item], _ probe: TransportProbe,
                    budget: CleanupRetryPolicy.Budget? = nil) async -> CleanupExecutionResult {
        await AdministratorCleanupService.apply(items: items, retryBudget: budget,
            requestID: UUID(), transport: probe.transport)
    }

    @MainActor static func main() async {
        let a = item("a"), b = item("b")
        let partial = TransportProbe([
            report(removed: [a.record], failed: 1, bytes: 11, code: 1, stderr: "520: execution error: temporary worker failure (-2700)"),
            report(removed: [b.record], bytes: 17)
        ])
        let recovered = await run([a, b], partial)
        let partialCalls = await partial.snapshot()
        precondition(partialCalls.0 == 1 && partialCalls.1 == 1 && partialCalls.2.map { $0.map(\.path) } == [[a.record, b.record], [b.record]])
        precondition(partialCalls.2[1][0].identity == b.identity && partialCalls.2[1][0].metadata == b.metadata)
        precondition(recovered.removed == 2 && recovered.failed == 0 && recovered.skipped == 0
                     && recovered.reclaimedBytes == 28 && !recovered.executionFailed)
        precondition(CleanupTrace.snapshot().contains { $0.0 == "admin.attempt.finished" && $0.1["diagnostic_0"]?.contains("520:") == true })

        let alwaysFails = TransportProbe([report(failed: 1, code: 1)])
        let failed = await run([a], alwaysFails)
        let failedCalls = await alwaysFails.snapshot()
        precondition(failedCalls.0 == 1 && failedCalls.1 == 2 && failed.failed == 1 && failed.removed == 0)
        let spent = CleanupRetryPolicy.Budget()
        precondition(spent.claim(items: [a]).count == 1 && spent.claim(items: [a]).count == 1)
        let crossRoute = TransportProbe([report(failed: 1, code: 1)])
        _ = await run([a], crossRoute, budget: spent)
        let crossCalls = await crossRoute.snapshot()
        precondition(crossCalls.0 == 1 && crossCalls.1 == 0, "Cross-route budget exceeded three attempts")

        let partialBudget = CleanupRetryPolicy.Budget()
        precondition(partialBudget.claim(items: [a]).count == 1 && partialBudget.claim(items: [a]).count == 1)
        let uneven = TransportProbe([report(failed: 2, code: 1)])
        let unevenResult = await run([a, b], uneven, budget: partialBudget)
        let unevenCalls = await uneven.snapshot()
        precondition(unevenCalls.0 == 1 && unevenCalls.1 == 0 && unevenCalls.2.count == 1
                     && unevenResult.failed == 2 && unevenResult.removed == 0,
                     "Partial cross-route budget erased the exhausted target's last terminal failure")
        precondition(CleanupTrace.snapshot().contains { $0.0 == "admin.retry.stopped" && $0.1["reason"] == "partial_budget_exhausted" })

        let noLease = TransportProbe([report(failed: 1, code: 1)], lease: nil)
        _ = await run([a], noLease)
        let noLeaseCalls = await noLease.snapshot()
        precondition(noLeaseCalls.0 == 1 && noLeaseCalls.1 == 0)
        let ended = TransportProbe([report(failed: 1, code: 1), .init(output: "Administrator session is not available.", exitCode: 77, timedOut: false)])
        _ = await run([a], ended)
        let endedCalls = await ended.snapshot()
        precondition(endedCalls.0 == 1 && endedCalls.1 == 1, "An expired session reauthorized or replayed")

        let validFailure = report(failed: 1, code: 1)
        let fatal: [RunResult] = [
            .init(output: "Synthetic authorization denial (-128)", exitCode: 1, timedOut: false),
            .init(output: "Lost reply", exitCode: 77, timedOut: false),
            .init(output: AdministratorCleanupPlan.reportPrefix + "not-json", exitCode: 0, timedOut: false),
            .init(output: validFailure.output + "\n" + validFailure.output, exitCode: 1, timedOut: false),
            report(failed: 1, code: 78), report(failed: 1, code: 64), report(failed: 1, code: 130),
            report(failed: 1, code: 143), report(failed: 1, timeout: true), report(failed: 1, truncated: true),
            report(removed: ["/fixture/outside-original-scope"])
        ]
        for response in fatal {
            let probe = TransportProbe([response])
            let result = await run([a], probe)
            let calls = await probe.snapshot()
            precondition(calls.0 == 1 && calls.1 == 0 && result.executionFailed,
                         "An uncertain/invalid/signature/cancel outcome was replayed")
        }
        let unknown = TransportProbe([report(removed: [a.record + "/child"], bytes: 19)])
        let unknownResult = await run([a], unknown)
        let unknownCalls = await unknown.snapshot()
        precondition(unknownCalls.0 == 1 && unknownCalls.1 == 0 && unknownResult.executionFailed,
                     "Unaccounted remaining original was blindly replayed")

        let receipt = DeletionPlan.RetainedTarget(record: a.record, identity: a.identity, reason: .protectedFlags, count: 1)
        let quiet = TransportProbe([report(skipped: 1, retained: [receipt])])
        let quietResult = await run([a], quiet)
        let quietCalls = await quiet.snapshot()
        precondition(quietCalls.0 == 1 && quietCalls.1 == 0 && quietResult.quietSkipped == 1 && quietResult.removed == 0)
        let withQuiet = TransportProbe([report(skipped: 1, failed: 1, retained: [receipt], code: 1), report(removed: [b.record], bytes: 7)])
        let kept = await run([a, b], withQuiet)
        let keptCalls = await withQuiet.snapshot()
        precondition(keptCalls.2[1].map(\.path) == [b.record] && kept.quietSkipped == 1 && kept.skipped == 1
                     && kept.failed == 0 && kept.removed == 1 && kept.reclaimedBytes == 7)

        let sensitive = RunResult(output: validFailure.output,
            errorOutput: "520: execution error (-2700)\nAPI_KEY=must-not-escape\ndo shell script \"stage_root=/private/hidden; password=also-secret\" with administrator privileges\n" + String(repeating: "é", count: 600),
            exitCode: 1, timedOut: false)
        let chunks = await Task.detached { AdministratorCleanupService.diagnosticChunks(sensitive) }.value
        precondition(chunks.count <= 4 && chunks.allSatisfy { $0.utf8.count <= 128 }
                     && chunks.joined().contains("520:") && !chunks.joined().contains("must-not-escape")
                     && !chunks.joined().contains("also-secret") && !chunks.joined().contains("stage_root")
                     && !chunks.joined().contains("do shell script"))

        // The real client must fail closed with no active session, without ever
        // reaching bootstrap, authorization, a socket, or a destructive worker.
        let client = PrivilegedSessionClient()
        let owner = NSObject()
        let unavailable = await client.run(relativePath: "bin/app_cleanup_admin.sh", arguments: [],
            resources: URL(fileURLWithPath: "/fixture"), timeout: 1, owner: ObjectIdentifier(owner),
            generation: 0, sessionID: UUID())
        precondition(unavailable.exitCode == 77)
        let tracked = await client.runWithSession(relativePath: "bin/app_cleanup_admin.sh", arguments: [],
            resources: URL(fileURLWithPath: "/fixture"), timeout: 1, owner: ObjectIdentifier(owner), generation: 0)
        precondition(tracked.result.exitCode == 77 && tracked.sessionID == nil)

        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        let many = (0..<10_000).map { item("large-\($0)") }
        let largeProbe = TransportProbe([report(removed: many.map(\.record))])
        let large = await run(many, largeProbe)
        heartbeat.cancel(); _ = await heartbeat.value
        precondition(large.removed == many.count && ticks > 2, "Plan IO/report validation blocked the main actor")
        print("Administrator retries: partial recovery, 3-pass budget, same-session reuse, fatal no-replay, exact quiet receipts, 520 redaction/chunks, \(many.count) targets and main heartbeat=\(ticks) passed; no authorization or cleanup worker executed")
    }
}
