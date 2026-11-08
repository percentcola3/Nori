import Foundation

@main
struct AdministratorRetentionReportTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
    static func receipt(_ path: String, _ identity: String = "original", _ count: Int = 1)
        -> DeletionPlan.RetainedTarget {
        .init(record: path, identity: identity, reason: .protectedFlags, count: count)
    }
    static func validate(_ targets: [DeletionPlan.RetainedTarget],
                         _ items: [DeletionPlan.Item], skipped: Int = 1,
                         removed: Set<String> = []) -> Bool {
        AdministratorCleanupService.validateRetainedTargets(targets, items: items,
            skipped: skipped, removedPaths: removed)
    }
    @MainActor static func main() async {
        let root = "/fixture/cache/root"
        let item = DeletionPlan.Item(record: root, identity: "original")
        expect(validate([], [item], skipped: 0), "Legacy empty retention report must remain valid")
        expect(!validate([], [item], skipped: -1), "Negative counts are invalid")
        expect(validate([receipt(root)], [item]), "Exact identity-bound retention should validate")
        expect(!validate([receipt(root, "changed")], [item]), "Changed identities must not suppress feedback")
        expect(!validate([receipt(root, "")], [item]), "Empty identity must fail closed")
        expect(!validate([receipt("/fixture/outside")], [item]), "Outside targets must not suppress feedback")
        expect(!validate([receipt(root, "original", 0)], [item]), "Zero receipt count is invalid")
        expect(!validate([receipt(root, "original", -1)], [item]), "Negative receipt count is invalid")
        expect(!validate([receipt(root, "original", Int.max)], [item], skipped: Int.max),
               "Huge counts must stay bounded by submitted coverage")
        expect(!validate([receipt(root)], [item], skipped: 0), "Retentions cannot exceed actual skips")
        expect(!validate([receipt(root), receipt(root)], [item], skipped: 2), "Duplicate receipts must not double count")
        expect(!validate([receipt(root)], [item], removed: [root]), "Removed and retained cannot overlap")
        expect(validate([receipt(root)], [item], removed: [root + "/file"]), "A retained root must not hide independently removed children")
        expect(!validate([receipt(root)], [item], removed: ["/fixture/cache"]), "A removed ancestor cannot contain a retained root")
        expect(validate([receipt(root)], [item], removed: [root + "-sibling"]), "Prefix siblings remain independent")
        let child = DeletionPlan.Item(record: root + "/child", identity: "child")
        expect(!validate([receipt(root, "original", 2)], [item, child], skipped: 2), "A root cannot attest that a submitted child is also unremovable")
        expect(!validate([receipt(root, "original", 3)], [item, child], skipped: 3), "A coalesced count cannot invent targets")
        expect(validate([receipt(root), receipt(child.record, "child")], [item, child], skipped: 2),
               "Nested submitted targets need independent exact identity-bound receipts")
        let sibling = DeletionPlan.Item(record: root + "-sibling", identity: "sibling")
        expect(!validate([receipt(root, "original", 2)], [item, sibling], skipped: 2), "A prefix sibling is not covered")
        expect(!validate([receipt(root)], [item, .init(record: root, identity: "different")]),
               "Conflicting request identities must fail closed")
        for unsafe in ["/", "relative/cache", "/fixture/../cache", "/fixture//cache", "/fixture/cache\nother"] {
            expect(!validate([receipt(unsafe)], [.init(record: unsafe, identity: "original")]),
                   "Unsafe receipt literal was accepted: \(unsafe)")
        }
        let unknownReason = Data("{\"record\":\"/fixture/cache\",\"identity\":\"original\",\"reason\":\"guess\",\"count\":1}".utf8)
        expect((try? JSONDecoder().decode(DeletionPlan.RetainedTarget.self, from: unknownReason)) == nil,
               "Unknown retention reasons cannot mute feedback")

        let count = 100_000
        let items = (0..<count).map { DeletionPlan.Item(record: "/fixture/cache/target-\($0)", identity: "id-\($0)") }
        let targets = items.map { receipt($0.record, $0.identity) }
        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        let valid = await Task.detached(priority: .utility) {
            validate(targets, items, skipped: count)
        }.value
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        heartbeat.cancel()
        _ = await heartbeat.value
        expect(valid && ticks > 1, "Large report validation must leave the main actor responsive")
        expect(elapsed < 15, "Report validation must avoid comparing every root to every target")
        print("Administrator retention reports: \(checks) guards passed; \(count) targets in \(String(format: "%.3f", elapsed))s, main heartbeat=\(ticks); no filesystem mutation or authorization")
    }
}
