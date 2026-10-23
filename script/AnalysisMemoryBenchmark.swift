import Darwin
import Foundation

/// Memory-only A/B driver. Run each scan in a fresh process so peak counters
/// exclude fixture generation, previous scans and JSON fingerprint hashing.
@main
struct AnalysisMemoryBenchmark {
    struct Memory: Codable {
        let rssBytes: UInt64
        let footprintBytes: UInt64
        let peakRSSBytes: UInt64
        let peakFootprintBytes: Int64
        let heapInUseBytes: UInt64
        let heapReservedBytes: UInt64
    }

    final class HeldResult {
        var value: AnalysisInventoryScanResult?
    }

    struct Counts: Codable {
        let indexedFiles: Int
        let indexedDirectories: Int
        let totalSize: UInt64
        let issueCount: Int
        let canReuse: Bool
        let metadataReads: Int
        let reusedListedFileMetadata: Int
    }

    struct Row: Codable {
        let version: String
        let scope: String
        let kind: String
        let trial: Int
        let scanMilliseconds: Double
        let fingerprintStride: Int
        let optionalFingerprintStride: Int
        let counts: Counts
        let start: Memory
        let scanEnd: Memory
        let retained: Memory
        let released: Memory
    }

    static func memory() throws -> Memory {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let peakOffset = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak)!
        guard status == KERN_SUCCESS,
              Int(count) * MemoryLayout<integer_t>.size >= peakOffset + MemoryLayout<Int64>.size else {
            throw NSError(domain: "AnalysisMemoryBenchmark", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Task memory information is unavailable"])
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw POSIXError(.EIO) }
        var heap = malloc_statistics_t()
        malloc_zone_statistics(nil, &heap)
        return Memory(rssBytes: info.resident_size, footprintBytes: info.phys_footprint,
            peakRSSBytes: UInt64(max(0, usage.ru_maxrss)),
            peakFootprintBytes: info.ledger_phys_footprint_peak,
            heapInUseBytes: UInt64(heap.size_in_use), heapReservedBytes: UInt64(heap.size_allocated))
    }

    // Return scalars only; no accidental result copy survives result release.
    @inline(never)
    static func counts(_ holder: HeldResult) -> Counts {
        let result = holder.value!
        return Counts(indexedFiles: result.snapshot.files.count,
            indexedDirectories: result.snapshot.directories.count,
            totalSize: result.report.totalSize, issueCount: result.snapshot.issueCount,
            canReuse: result.canReuse, metadataReads: result.statistics.metadataReads,
            reusedListedFileMetadata: result.statistics.reusedListedFileMetadata)
    }

    static func createFixtures(_ home: URL) throws {
        let manager = FileManager.default
        let payload = Data(repeating: 65, count: 128)
        for (scope, count, width) in [("8000", 8_000, 200), ("28000", 28_000, 200), ("wide", 28_000, 28_000)] {
            let root = home.appendingPathComponent("files-" + scope)
            for index in 0..<count {
                let directory = root.appendingPathComponent("group-\(index / width)")
                if index % width == 0 {
                    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                guard manager.createFile(atPath: directory.appendingPathComponent("sample-\(index).jpg").path,
                                         contents: payload) else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        let home = URL(fileURLWithPath: arguments[2], isDirectory: true)
        if arguments[1] == "create" { try createFixtures(home); return }
        let version = arguments[1]
        let scope = arguments[3]
        let kind = AnalysisInventoryKind(rawValue: arguments[4])!
        let trial = Int(arguments[5])!
        let root = scope == "real" ? home.path : home.appendingPathComponent("files-" + scope).path
        let control = CleanupScanControl(mode: .deep)
        let holder = HeldResult()
        let start = try memory()
        let began = ProcessInfo.processInfo.systemUptime
        let scanEnd = try autoreleasepool {
            holder.value = AnalysisInventoryWorker.scan(kind, roots: [root],
                home: scope == "real" ? NSHomeDirectory() : home.path, control: control)
            return try memory()
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1_000
        let measuredCounts = counts(holder)
        usleep(200_000)
        let retained = try withExtendedLifetime(holder) { try memory() }
        holder.value = nil
        usleep(200_000)
        let released = try memory()
        let row = Row(version: version, scope: scope, kind: kind.rawValue, trial: trial,
            scanMilliseconds: elapsed,
            fingerprintStride: MemoryLayout<AnalysisFileFingerprint>.stride,
            optionalFingerprintStride: MemoryLayout<AnalysisFileFingerprint?>.stride,
            counts: measuredCounts, start: start, scanEnd: scanEnd, retained: retained, released: released)
        // Serialize only after all memory readings, keeping encoder allocations
        // and output buffering outside the measurements above.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        print(String(decoding: try encoder.encode(row), as: UTF8.self))
    }
}
