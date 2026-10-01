import Foundation

/// Bind the user's current analysis selection to file objects before launching
/// background work. Analysis records lack a scan-time identity, so this snapshot
/// is taken at the confirmed action; arbitrary caller paths never enter the sink.
struct AnalysisFileDeletionPlan {
    let items: [DeletionPlan.Item]
    let refusedCount: Int

    init(requestedPaths: [String], inventoryPaths: Set<String>) {
        var planned: [DeletionPlan.Item] = []
        var refused = 0
        for path in Set(requestedPaths).sorted() {
            guard inventoryPaths.contains(path), Self.isPhysicalFile(path),
                  let identity = DeletionPlan.identity(at: path) else {
                refused += 1
                continue
            }
            planned.append(DeletionPlan.Item(record: path, identity: identity))
        }
        items = planned
        refusedCount = refused
    }

    func execute(homeDirectory: String = NSHomeDirectory()) -> NativeCore.ApplySummary {
        guard !items.isEmpty else {
            return NativeCore.ApplySummary(removed: 0, skipped: refusedCount, failed: 0, messages: [])
        }
        let identities = Dictionary(items.map { ($0.record, $0.identity) },
                                    uniquingKeysWith: { first, _ in first })
        let applied = NativeCore.shared.applyCleanup(
            items: items, permanent: false, homeDirectory: homeDirectory,
            finalValidation: { path in
                Self.isPhysicalFile(path) && DeletionPlan.identity(at: path) == identities[path]
            })
        return NativeCore.ApplySummary(
            removed: applied.removed, skipped: applied.skipped + refusedCount,
            failed: applied.failed, messages: applied.messages, removedPaths: applied.removedPaths)
    }

    private static func isPhysicalFile(_ path: String) -> Bool {
        guard DeletionPlan.isLexicallySafePath(path) else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path == url.path,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
