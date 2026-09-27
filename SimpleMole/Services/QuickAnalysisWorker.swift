import Darwin
import Foundation

/// 第一层磁盘分析（默认入口）：只测“用户能采取操作”的明确目标根，
/// 不递归整个 home、不遍历系统目录与应用安装目录。
///
/// - 范围：个人文件目录、已识别的开发者/应用缓存目录、用户保存的分析
///   位置、废纸篓。应用大小由卸载模块负责，这里不重复统计 /Applications。
/// - 预算独立于垃圾快扫：默认总预算 90 秒、单目录 20 秒，8 路并发。
/// - 每完成一个根就上报一次增量快照；超时/取消的目录标注 isPartial，
///   绝不显示为完整大小或零占用。
enum QuickAnalysisWorker {
    struct Root: Equatable {
        enum Kind: String, Equatable {
            case personal
            case developer
            case saved
            case trash
        }

        let path: String
        let label: String
        let kind: Kind
    }

    /// 快速分析的固定范围。纯函数，测试用它断言“不包含系统目录、应用
    /// 安装目录和应用包内部”。
    static func roots(home: String, savedLocations: [String] = []) -> [Root] {
        var result: [Root] = []
        var seen = Set<String>()
        func add(_ path: String, _ label: String, _ kind: Root.Kind) {
            let normalized = URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL.path
            guard normalized.hasPrefix("/"), seen.insert(normalized).inserted else { return }
            result.append(Root(path: normalized, label: label, kind: kind))
        }

        for (relative, label) in [("Desktop", "Desktop"), ("Downloads", "Downloads"),
                                  ("Documents", "Documents"), ("Movies", "Movies"),
                                  ("Pictures", "Pictures"), ("Music", "Music")] {
            add(home + "/" + relative, label, .personal)
        }
        add(home + "/.Trash", "Trash", .trash)
        for path in developerInventoryRoots(home: home) {
            add(path, URL(fileURLWithPath: path).lastPathComponent, .developer)
        }
        for path in savedLocations {
            add(path, URL(fileURLWithPath: path).lastPathComponent, .saved)
        }
        return deduplicatedRoots(result)
    }

    /// 去掉存在包含关系的重复根：范围更窄的根优先保留（与 DeletionPlan
    /// 的非重叠语义一致），避免同一目录被计量两次。
    static func deduplicatedRoots(_ input: [Root]) -> [Root] {
        var accepted: [Root] = []
        for candidate in input {
            if accepted.contains(where: { existing in
                let paths = [existing.path, candidate.path]
                return paths[0] == paths[1] || paths[1].hasPrefix(paths[0] + "/")
                    || paths[0].hasPrefix(paths[1] + "/")
            }) { continue }
            accepted.append(candidate)
        }
        return accepted
    }

    /// 开发者环境的既知位置：可重建缓存、依赖仓库（只读展示）、构建产物
    /// 与工具自定义位置。快速分析把它们作为“已识别缓存目录”整体计量。
    static func developerInventoryRoots(home: String) -> [String] {
        var roots = CleanupRiskPolicy.dependencyStoreRoots(home: home)
        let locations = DeveloperCacheLocations.current(home: home)
        for custom in [locations.npmCache, locations.yarnCache, locations.pipCache,
                       locations.poetryCache, locations.goModCache, locations.goBuildCache] {
            if let custom { roots.append(custom) }
        }
        roots.append(contentsOf: [
            home + "/.gradle/caches",
            home + "/Library/Developer/Xcode/DerivedData",
            home + "/Library/Developer/Xcode/SourcePackages",
            home + "/Library/Developer/Xcode/Archives",
            home + "/Library/Developer/CoreSimulator",
            home + "/Library/Developer/XCTestDevices",
            home + "/Library/Caches/Homebrew",
            home + "/.npm",
            home + "/.yarn",
            home + "/.bun/install/cache",
            home + "/.cargo",
            home + "/go/pkg/mod",
            home + "/.swiftpm",
            home + "/.cache",
            home + "/Library/Caches"
        ])
        if let custom = locations.gradleUserHome { roots.append(custom + "/caches") }
        if let cargo = locations.cargoHome { roots.append(cargo) }
        return roots
    }

    /// 并发计量各根；每完成一个根调用一次 `progress` 上报增量快照（先到
    /// 先显示，不等全部完成）。返回最终报告。
    static func scan(_ roots: [Root], control: CleanupScanControl,
                     progress: ((AnalyzeReport) -> Void)? = nil) -> AnalyzeReport {
        let lock = NSLock()
        var rows: [AnalyzeEntry] = []
        var totalSize: UInt64 = 0
        var totalFiles = 0
        var incomplete = false

        func snapshot(partial: Bool) -> AnalyzeReport {
            AnalyzeReport(path: NSHomeDirectory(), overview: false,
                          entries: rows.sorted(by: AnalyzeEntry.analysisOrder),
                          largeFiles: [], totalSize: totalSize, totalFiles: totalFiles,
                          isPartial: partial)
        }

        DispatchQueue.concurrentPerform(iterations: roots.count) { index in
            let root = roots[index]
            // 预算耗尽也要留下标注 partial 的行：范围可见、不显示为完整
            // 大小，也不凭空消失。
            let measurement = CleanupScanWorker.measure(root.path, control: control)
            var stat = stat()
            let rootBytes = lstat(root.path, &stat) == 0
                ? UInt64(max(0, stat.st_blocks)) * 512 : 0
            let bytes = rootBytes + (measurement.complete ? measurement.bytes : 0)
            lock.lock()
            totalSize &+= bytes
            totalFiles += measurement.files
            incomplete = incomplete || !measurement.complete
            rows.append(AnalyzeEntry(name: root.label, path: root.path,
                                     size: bytes, isDir: true,
                                     cleanable: false,
                                     isPartial: !measurement.complete))
            let snapshot = snapshot(partial: true)
            lock.unlock()
            progress?(snapshot)
        }
        lock.lock()
        let result = snapshot(partial: incomplete || control.isCancelled)
        lock.unlock()
        return result
    }
}
