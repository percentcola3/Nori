import Foundation
import Darwin

struct L10n {
    static let shared = L10n()
    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ values: CVarArg...) -> String { key }
}
struct DirectorySizeResult: Equatable, Sendable {
    let bytes: Int64
    let isComplete: Bool
}
enum CleanupAgePolicy {
    static func activityEvidence(modified: Date?, accessed: Date?) -> Date? {
        [modified, accessed].compactMap { $0 }.max()
    }
}
@main struct Bench {
    static func main() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func clock() -> Double { ProcessInfo.processInfo.systemUptime }
        func row(_ value: [String: Any]) {
            let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
        for fileCount in [8000, 28000] {
            let root = base.appendingPathComponent("files-\(fileCount)", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let payload = Data(repeating: 65, count: 128)
            for n in 0..<fileCount {
                let folder = root.appendingPathComponent(String(n / 200), isDirectory: true)
                if n % 200 == 0 { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
                let name = n % 1000 == 0 ? "needle-\(n).txt" : "sample-\(n).dat"
                guard fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: payload) else {
                    fatalError("Fixture creation failed")
                }
            }
            let index = try DirectorySearchIndex(databaseURL: base.appendingPathComponent("index-\(fileCount)/files.sqlite"))
            var began = clock()
            let status = try await index.rebuild(roots: [root])
            row(["test": "filename_index_build", "files": fileCount, "indexedEntries": status.indexedItemCount, "ms": (clock()-began)*1000])
            for term in ["needle", "sample", "zz", "zz-no-match"] {
                _ = try await index.search(query: term)
                var times: [Double] = []
                var count = 0
                for _ in 0..<11 {
                    began = clock()
                    count = try await index.search(query: term).count
                    times.append((clock()-began)*1000)
                }
                row(["test": "filename_query", "files": fileCount, "query": term, "returned": count, "median_ms": times.sorted()[5]])
            }
            let cache = DirectorySizeCache(cacheURL: base.appendingPathComponent("sizes-\(fileCount)/state.json"))
            await cache.retainTrees(for: [root])
            for run in 1...2 {
                began = clock()
                let result = await cache.refresh(root)
                let ms = (clock()-began)*1000
                let stats = await cache.diagnostics()
                row(["test":"directory_size", "files":fileCount, "run":run, "ms":ms, "inspected":stats.inspectedCount,
                    "enumerated":stats.enumerationCount,"bytes":result?.result.bytes ?? -1,"complete":result?.result.isComplete ?? false])
            }
            await cache.releaseTrees()
            began = clock()
            let released = await cache.refresh(root)
            let releasedMs = (clock()-began)*1000
            let stats = await cache.diagnostics()
            row(["test":"size_after_tree_release","files":fileCount,"ms":releasedMs,"inspected":stats.inspectedCount,
                 "enumerated":stats.enumerationCount,"complete":released?.result.isComplete ?? false])
            began = clock()
            let measurement = CleanupScanWorker.measure(root.path, control: CleanupScanControl(mode: .deep))
            row(["test":"cleanup_fts_size","files":fileCount,"ms":(clock()-began)*1000,"count":measurement.files,
                 "bytes":measurement.bytes,"complete":measurement.complete])
        }
    }
}

