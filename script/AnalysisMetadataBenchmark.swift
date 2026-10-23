import CryptoKit
import Darwin
import Foundation

/// CLI-only A/B harness. Link against the same production dependencies as
/// test_analysis_inventory.sh, with either inventory-worker source snapshot.
@main
struct AnalysisMetadataBenchmark {
    static func main() throws {
        let arguments = CommandLine.arguments
        let home = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let manager = FileManager.default
        if arguments[1] == "create" {
            let payload = Data(repeating: 65, count: 128)
            for count in [8_000, 28_000] {
                let root = home.appendingPathComponent("files-\(count)")
                for index in 0..<count {
                    let directory = root.appendingPathComponent("group-\(index / 200)")
                    if index % 200 == 0 {
                        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                    }
                    let file = directory.appendingPathComponent("sample-\(index).jpg")
                    guard manager.createFile(atPath: file.path, contents: payload) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            }
            return
        }
        let version = arguments[1]
        let realDirectory = arguments[3] == "real"
        let count = realDirectory ? 0 : Int(arguments[3])!
        let kind = AnalysisInventoryKind(rawValue: arguments[4])!
        let trial = Int(arguments[5])!
        let root = realDirectory ? home.path : home.appendingPathComponent("files-\(count)").path
        var previous: AnalysisInventorySnapshot?
        for phase in ["full", "unchanged"] {
            let started = ProcessInfo.processInfo.systemUptime
            let result = AnalysisInventoryWorker.scan(kind, roots: [root],
                home: realDirectory ? NSHomeDirectory() : home.path,
                previous: previous, control: CleanupScanControl(mode: .deep))
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            previous = result.snapshot
            // Fingerprints, directory membership and report totals are checked
            // outside the measured interval; only scannedAt is excluded.
            var digest = SHA256()
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            for path in result.snapshot.files.keys.sorted() {
                digest.update(data: Data(path.utf8))
                digest.update(data: try encoder.encode(result.snapshot.files[path]!))
            }
            for path in result.snapshot.directories.keys.sorted() {
                digest.update(data: Data(path.utf8))
                digest.update(data: try encoder.encode(result.snapshot.directories[path]!))
            }
            let signature = digest.finalize().map { String(format: "%02x", $0) }.joined()
            let row: [String: Any] = [
                "version": version, "files": realDirectory ? result.snapshot.files.count : count,
                "scope": realDirectory ? "repository" : "fixture", "kind": kind.rawValue,
                "trial": trial, "phase": phase, "ms": milliseconds,
                "metadataReads": result.statistics.metadataReads,
                "reusedListedFileMetadata": result.statistics.reusedListedFileMetadata,
                "listedDirectories": result.statistics.listedDirectories,
                "indexedFiles": result.snapshot.files.count,
                "totalSize": result.report.totalSize, "totalFiles": result.report.totalFiles ?? 0,
                "issueCount": result.snapshot.issueCount, "canReuse": result.canReuse,
                "signature": signature
            ]
            let data = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
