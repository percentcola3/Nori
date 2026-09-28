import Darwin
import Foundation

/// Refresh only the inventory already shown after cleanup. Never discover or
/// authorize new deletion targets, and never reuse a size from before deletion.
enum CleanupInventoryRefresh {
    struct Report {
        var categories: [CleanupCategory]
        var deferredPaths: [String]
    }

    static func refresh(_ categories: [CleanupCategory],
                        control: CleanupScanControl = CleanupScanControl(
                            mode: .quick, totalBudget: 30, directoryBudget: 5)) -> Report {
        let paths = Array(Set(categories.flatMap(\.paths))).sorted()
        var existing: [String] = []
        var deferred: [String] = []
        for path in paths {
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else {
                if errno != ENOENT && errno != ENOTDIR { deferred.append(path) }
                continue
            }
            guard metadata.st_mode & S_IFMT != S_IFLNK else {
                deferred.append(path)
                continue
            }
            existing.append(path)
        }
        let measurements = CleanupScanWorker.measure(existing, control: control) { _, _ in }
        var sizes: [String: UInt64] = [:]
        for (path, measurement) in zip(existing, measurements) {
            if measurement.complete { sizes[path] = measurement.bytes }
            else { deferred.append(path) }
        }
        let refreshed = categories.compactMap { category -> CleanupCategory? in
            let paths = category.paths.filter { (sizes[$0] ?? 0) > 0 }
            guard var updated = category.retainingPaths(paths) else { return nil }
            updated.pathBytes = Dictionary(uniqueKeysWithValues: paths.map { ($0, sizes[$0]!) })
            updated.bytes = paths.reduce(0) { $0 &+ sizes[$1]! }
            // A changed/recreated path needs a new user scan before another
            // delete attempt. Keep its original identity for executor checks.
            for path in paths where DeletionPlan.identity(at: path) != category.pathIdentities[path] {
                updated.setPathSelected(path, selected: false)
            }
            return updated
        }.sorted(by: CleanupCategory.sizeDescending)
        return Report(categories: refreshed, deferredPaths: deferred)
    }
}
