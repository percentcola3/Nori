import Foundation

@main
struct CleanupInventoryRefreshTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "CleanupInventoryRefresh", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let removed = root.appendingPathComponent("removed")
        let partial = root.appendingPathComponent("partial")
        let unchanged = root.appendingPathComponent("unchanged")
        for url in [removed, partial, unchanged] {
            try Data(repeating: 8, count: 65536).write(to: url)
        }
        let paths = [removed.path, partial.path, unchanged.path]
        let category = CleanupCategory(name: "Caches", paths: paths, bytes: 196608,
            pathBytes: Dictionary(uniqueKeysWithValues: paths.map { ($0, UInt64(65536)) }),
            risk: .safe, disposal: .permanentDelete, applyRoute: .genericTrash)
        try fm.removeItem(at: removed)
        // Changing/recreating a target must never receive new delete authority.
        try Data(repeating: 1, count: 4096).write(to: partial, options: .atomic)
        let result = CleanupInventoryRefresh.refresh([category])
        try check(result.categories.count == 1 && result.deferredPaths.isEmpty, "unexpected incomplete refresh")
        let refreshed = result.categories[0]
        let measured = CleanupScanWorker.measure(partial.path, control: .init(mode: .quick)).bytes
        try check(!refreshed.paths.contains(removed.path), "confirmed absent path remained visible")
        try check(refreshed.pathBytes[partial.path] == measured && measured < 65536,
                  "remaining path retained its pre-cleanup size")
        try check(refreshed.bytes == refreshed.pathBytes.values.reduce(0, +), "group total is stale")
        try check(refreshed.selectedPathBytes == refreshed.pathBytes[unchanged.path], "selected total is stale")
        try check(!refreshed.isPathSelected(partial.path) && refreshed.isPathSelected(unchanged.path),
                  "changed target silently received permission to retry")
        try check(refreshed.pathIdentities[partial.path] == category.pathIdentities[partial.path],
                  "original deletion identity was replaced")
        let cancelled = CleanupScanControl(mode: .quick)
        cancelled.cancel()
        let incomplete = CleanupInventoryRefresh.refresh([category], control: cancelled)
        try check(incomplete.categories.isEmpty && Set(incomplete.deferredPaths) == [partial.path, unchanged.path],
                  "unmeasured paths must be deferred rather than show stale totals")
        try fm.removeItem(at: partial)
        try fm.removeItem(at: unchanged)
        try check(CleanupInventoryRefresh.refresh([category]).categories.isEmpty, "empty category remained")
        print("Cleanup refresh: partial sizes, totals, identity guards, cancellation and empty results passed")
    }
}
