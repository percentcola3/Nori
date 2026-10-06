import Foundation

/// Nori 自身的可再生存储并入统一清理管道。文件树条目仍走原生删除边界；
/// 进程内受管路径（文件名索引 SQLite、截图暂存目录）在这里计量与执行，
/// 删除前先把会回写的内存缓存复位，避免清完又被立刻写回。
@MainActor
extension AppState {
    /// 把受管路径计量后并入名为 "Nori" 的 .core/.genericTrash 类目；
    /// 该类目不存在时新建。已被扫描结果覆盖的路径不重复计量。
    func appendNoriManagedPaths(to categories: [CleanupCategory]) async -> [CleanupCategory] {
        let home = NSHomeDirectory()
        let offered = Set(categories.flatMap(\.paths))
        let pending = NoriOwnedStorage.managedPaths(home: home).filter { !offered.contains($0) }
        guard !pending.isEmpty else { return categories }
        let measured = await Task.detached(priority: .utility) {
            let control = CleanupScanControl(mode: .deep)
            return pending.map { (path: $0, measurement: CleanupScanWorker.measure($0, control: control)) }
        }.value
        let additions = measured.compactMap { entry -> (path: String, bytes: UInt64)? in
            entry.measurement.complete && entry.measurement.bytes > 0
                ? (entry.path, entry.measurement.bytes) : nil
        }
        guard !additions.isEmpty else { return categories }
        var result = categories
        if let index = result.firstIndex(where: {
            $0.name == NoriOwnedStorage.displayName && $0.source == .core
                && $0.applyRoute == .genericTrash
        }) {
            var category = result[index]
            let wasSelected = category.selected
            for addition in additions {
                category.appendPath(addition.path, bytes: addition.bytes)
                if !wasSelected { category.setPathSelected(addition.path, selected: false) }
            }
            result[index] = category
        } else {
            result.append(CleanupCategory(
                name: NoriOwnedStorage.displayName,
                paths: additions.map(\.path),
                bytes: additions.reduce(0) { $0 &+ $1.bytes },
                pathBytes: Dictionary(uniqueKeysWithValues: additions),
                selected: true,
                source: .core, risk: .safe, disposal: .permanentDelete,
                applyRoute: .genericTrash, activityGuard: .openFile,
                reasonKey: NoriOwnedStorage.reasonKey))
        }
        return result
    }

    /// 原生删除开始前复位进程内缓存：它们各自持有内存快照并在每次
    /// persist 时全量回写，不复位会在目录被删后立即重建旧内容。
    func prepareNoriOwnedDeletion(paths: [String]) async {
        let home = NSHomeDirectory()
        let normalized = paths.map(CleanupRiskPolicy.normalizedPathLiteral)
        let support = NoriOwnedStorage.supportDirectory(home: home)
        func touches(_ root: String) -> Bool {
            normalized.contains { $0 == root || $0.hasPrefix(root + "/") }
        }
        if touches(support + "/DirectorySizes") {
            await directoryBrowser.resetSizeCache()
        }
        if touches(support + "/Analysis") {
            analysisInventoryCache.reset()
            duplicateWorkspaceStore.discardPendingWrites()
            // 连同 AppState+Duplicates 的展示态一起清空：缓存文件已删除，
            // 内存里的结果不应再指向不存在的清单。
            duplicateResultCache = [:]
            duplicateGroups = []
            duplicateSelection = []
            duplicateScannedRoots = []
            duplicateScanFinished = false
            duplicateStatus = ""
            duplicateCoverage = ""
            duplicateScanReclaimableBytes = 0
            duplicateLastScanDate = nil
        }
    }

    /// 受管单元在进程内执行：搜索索引用 SQL 清空（连接常开，文件受原生
    /// 删除边界保护），截图暂存目录按自有命名规则删除。
    func applyNoriManagedPaths(_ paths: [String],
                               onProgress: ((String) -> Void)? = nil) async -> NativeCore.ApplySummary {
        let home = NSHomeDirectory()
        var removed = 0, skipped = 0, failed = 0
        var messages: [String] = []
        var removedPaths = Set<String>()
        var reclaimedBytes: UInt64 = 0
        for path in paths {
            guard NoriOwnedStorage.isManagedPath(path, home: home) else {
                skipped += 1
                continue
            }
            let measurement = await Task.detached(priority: .utility) {
                CleanupScanWorker.measure(path, control: CleanupScanControl(mode: .deep))
            }.value
            do {
                if NoriOwnedStorage.isSearchIndexPath(path, home: home) {
                    try await directoryBrowser.clearSearchIndex()
                } else {
                    try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                }
                removed += 1
                removedPaths.insert(path)
                reclaimedBytes &+= measurement.bytes
            } catch {
                failed += 1
                messages.append(path + ": " + error.localizedDescription)
            }
            onProgress?(path)
        }
        return NativeCore.ApplySummary(removed: removed, skipped: skipped, failed: failed,
                                       messages: messages, removedPaths: removedPaths,
                                       reclaimedBytes: reclaimedBytes)
    }
}
