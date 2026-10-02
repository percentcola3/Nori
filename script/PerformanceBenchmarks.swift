import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO

struct BenchmarkRecord: Codable {
    let name: String
    let units: Int
    let unitLabel: String
    let samples: [Double]
    let medianSeconds: Double
    let p95Seconds: Double
    let unitsPerSecond: Double
    let medianCPUSeconds: Double
    /// Darwin ru_maxrss is bytes; cumulative process high-water, not delta RSS.
    let processPeakRSSBytes: Int64
    let mainActorMaxDelaySeconds: Double
    var cancellationMaxSeconds: Double? = nil
}
struct BenchmarkReport: Codable {
    let schemaVersion: Int
    let createdAt: String
    let os: String
    let architecture: String
    let cpuModel: String
    let processors: Int
    let memoryBytes: UInt64
    let sdk: String
    let compiler: String
    let benchmarkSuiteSHA256: String
    let repetitions: Int
    let fixtureSeed: Int
    let cacheState: String
    let records: [BenchmarkRecord]
}
@MainActor enum PerformanceBenchmarks {
    static var records: [BenchmarkRecord] = []
    static let fm = FileManager.default
    static var repetitions = 5
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func peakRSS() -> Int64 { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Int64(usage.ru_maxrss) }
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted(); return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
    static func measure(_ name: String, units: Int, unit: String = "files", budget: Double = 60,
                        setup: () async throws -> Void = {},
                        operation: () async throws -> Void) async throws {
        func perform() async throws {
            let alarm = Task.detached {
                do { try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000)) }
                catch { return }
                FileHandle.standardError.write(Data(("FAIL: \(name) watchdog exceeded \(budget)s\n").utf8))
                exit(1)
            }
            defer { alarm.cancel() }
            try await operation()
        }
        try await setup(); try await perform() // warmup excluded
        var walls: [Double] = [], cpus: [Double] = [], delays: [Double] = []
        for _ in 0..<repetitions {
            try await setup()
            var lastPulse = uptime()
            let heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
                    let now = uptime(); delays.append(max(0, now - lastPulse - 0.01)); lastPulse = now
                }
            }
            await Task.yield()
            let start = uptime(), cpuStart = cpu()
            do { try await perform() }
            catch { heartbeat.cancel(); throw error }
            let elapsed = uptime() - start
            delays.append(max(0, uptime() - lastPulse - 0.01))
            heartbeat.cancel(); await heartbeat.value
            walls.append(elapsed); cpus.append(cpu() - cpuStart)
            try expect(elapsed < budget, "\(name) exceeded \(budget)s budget: \(elapsed)s")
        }
        let median = percentile(walls, 0.5), p95 = percentile(walls, 0.95)
        let delay = delays.max() ?? 0
        try expect(delay < 0.5, "\(name) MainActor stalled >500ms: \(delay)")
        try expect(peakRSS() < 2_147_483_648, "benchmark process exceeds 2 GiB peak RSS")
        records.append(.init(name: name, units: units, unitLabel: unit, samples: walls, medianSeconds: median,
            p95Seconds: p95, unitsPerSecond: Double(units) / median, medianCPUSeconds: percentile(cpus, 0.5),
            processPeakRSSBytes: peakRSS(), mainActorMaxDelaySeconds: delay))
        print(String(format: "BENCH %@ n=%d median=%.4fs p95=%.4fs %.0f units/s CPU=%.4fs RSS=%.1fMiB actor-delay=%.1fms",
            name, units, median, p95, Double(units) / median, percentile(cpus, 0.5), Double(peakRSS()) / 1048576, delay * 1000))
        fflush(stdout)
    }
    static func tree(_ root: URL, count: Int, grouped: Bool = true, age: Bool = false) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date().addingTimeInterval(-10 * 86400)
        for i in 0..<count {
            let path = grouped ? root.appendingPathComponent("bucket-\(i % 100)/file-\(i).cache") : root.appendingPathComponent("file-\(i).cache")
            var data = Data(repeating: 83, count: 4096)
            // Identical content in pairs, with fixed seed, forces full hashing.
            let group = UInt64(i / 2)
            for byte in 0..<8 { data[byte] = UInt8((group >> (byte * 8)) & 255) }
            try FeatureSimulationTests.write(path, data: data)
            if age { try fm.setAttributes([.modificationDate: now], ofItemAtPath: path.path) }
        }
    }
    static func run(_ fixture: URL, reportURL: URL) async throws {
        repetitions = Int(ProcessInfo.processInfo.environment["NORI_BENCH_REPETITIONS"] ?? "5") ?? 5
        try expect((3...20).contains(repetitions), "benchmark repetitions must be 3...20")
        for count in [1000, 10000, 30000] {
            let home = fixture.appendingPathComponent("bench-\(count)/home")
            let root = home.appendingPathComponent("Library/Caches/com.example.benchmark")
            try tree(root, count: count)
            let core = NativeCore(cleanupOpenFileProbe: { [] })
            let expectedBytes = CleanupScanWorker.measure(root.path, control: CleanupScanControl(mode: .deep)).bytes
            for mode in [CleanupScanMode.quick, .deep] {
                try await measure("cleanup-\(mode.rawValue)", units: count) {
                    let result = await core.scanCleanup(homeDirectory: home.path, mode: mode,
                        agentPresence: AgentPresenceContext(applicationDirs: [], searchPath: []))
                    try expect(result.succeeded && !result.categories.isEmpty, "benchmark cleanup incomplete")
                    try expect(result.categories.reduce(UInt64(0)) { $0 + $1.bytes } == expectedBytes, "cleanup benchmark lost files")
                }
            }
            try await measure("disk-analysis", units: count) {
                let result = await Task.detached {
                    DiskAnalysisWorker.scan(root.path, control: CleanupScanControl(mode: .deep), home: home.path)
                }.value
                try expect(result.isPartial != true && result.error == nil && result.totalFiles == count, "analysis benchmark incomplete")
            }
            // Duplicate discovery intentionally rejects ~/Library; move the
            // same bytes into an ordinary user-selected directory off-clock.
            let duplicateRoot = home.appendingPathComponent("Documents/pairs")
            try fm.createDirectory(at: duplicateRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: root, to: duplicateRoot)
            try await measure("exact-duplicates-pairs", units: count) {
                let result = await Task.detached {
                    DuplicateScanner.scan(roots: [duplicateRoot.path], control: DuplicateScanControl(), home: home.path)
                }.value
                try expect(!result.isPartial && !result.cancelled && result.error == nil && result.files.count == count
                    && result.groups.count == count / 2, "duplicate benchmark incomplete")
            }
            var cancellationSamples: [Double] = []
            try await measure("duplicate-cancellation", units: count) {
                let outcome = await Task.detached {
                    let token = DuplicateScanControl()
                    var cancelAt: Double?
                    let result = DuplicateScanner.scan(roots: [duplicateRoot.path], control: token, home: home.path) { event in
                        if event.phase == "hashing", cancelAt == nil {
                            cancelAt = ProcessInfo.processInfo.systemUptime; token.cancel()
                        }
                    }
                    return (result, cancelAt.map { ProcessInfo.processInfo.systemUptime - $0 })
                }.value
                try expect(outcome.0.cancelled && outcome.0.groups.isEmpty && outcome.1 != nil,
                    "duplicate cancellation returned actions or missed active hashing")
                cancellationSamples.append(outcome.1!)
                try expect(outcome.1! < 0.5, "active cancellation exceeded 500ms")
            }
            records[records.count - 1].cancellationMaxSeconds = cancellationSamples.dropFirst().max()
            print("CANCEL max cancel-to-return: \(cancellationSamples.dropFirst().max() ?? 0)s")
            let cancelled = CleanupScanControl(mode: .deep); cancelled.cancel()
            try await measure("cleanup-precancelled", units: count, budget: 2) {
                let result = await core.scanCleanup(homeDirectory: home.path, mode: .deep, control: cancelled)
                try expect(!result.succeeded && result.categories.isEmpty, "cancelled cleanup returned actions")
            }
            try fm.removeItem(at: home.deletingLastPathComponent())
        }
        for count in [1000, 10000] {
            let root = fixture.appendingPathComponent("planner-\(count)/cache")
            try tree(root, count: count, grouped: false, age: true)
            let rule = AutoCleanupRule(directory: root.path, policy: .retentionDays, sizeLimitBytes: 100_000_000,
                retentionDays: 7, isRegenerable: true)
            try await measure("auto-cleanup-plan", units: count) {
                let plan = try await AutoCleanupPlanner.plan(for: rule)
                try expect(plan.candidates.count == count && plan.remainingBytes == 0, "planner benchmark incomplete")
            }
            try fm.removeItem(at: root.deletingLastPathComponent())
            let home = fixture.appendingPathComponent("skills-\(count)/home")
            for i in 0..<count {
                try FeatureSimulationTests.write(home.appendingPathComponent(".agents/skills/skill-\(i)/SKILL.md"),
                    data: Data("---\nname: skill-\(i)\ndescription: benchmark fixture\n---\nfixture".utf8))
            }
            try await measure("agent-skills", units: count, unit: "skills") {
                let skills = await Task.detached {
                    AgentInventory.scanSkills(home: home.path, control: CleanupScanControl(mode: .deep))
                }.value
                try expect(skills.count == count && skills.allSatisfy { !$0.identity.isEmpty }, "skill benchmark incomplete")
            }
            try fm.removeItem(at: home.deletingLastPathComponent())
        }
        for count in [1000, 10000] {
            let home = fixture.appendingPathComponent("delete-\(count)/home")
            let root = home.appendingPathComponent("Library/Caches/com.example.benchmark")
            let core = NativeCore(cleanupOpenFileProbe: { [] })
            var plan: [DeletionPlan.Item] = []
            try await measure("permanent-delete", units: count, setup: {
                try tree(root, count: count)
                let result = await core.scanCleanup(homeDirectory: home.path, mode: .deep,
                    agentPresence: AgentPresenceContext(applicationDirs: [], searchPath: []))
                plan = result.categories.flatMap { c in c.paths.map { DeletionPlan.Item(record: $0, identity: c.pathIdentities[$0] ?? "") } }
                try expect(!plan.isEmpty, "deletion benchmark plan empty")
            }) {
                let accepted = plan
                let result = await Task.detached { core.applyCleanup(items: accepted, permanent: true, homeDirectory: home.path) }.value
                let remaining = CleanupScanWorker.measure(root.path, control: CleanupScanControl(mode: .deep))
                // Live cache sinks preserve the authorized directory object;
                // correctness is that all payloads are gone, not root removal.
                try expect(result.removed > 0 && result.reclaimedBytes > 0 && result.failed == 0 && result.skipped == 0
                    && remaining.files == 0 && remaining.bytes == 0,
                    "delete benchmark incomplete: removed=\(result.removed) skipped=\(result.skipped) failed=\(result.failed) remaining=\(remaining.files); \(result.messages)")
            }
            try fm.removeItem(at: home.deletingLastPathComponent())
        }
        for count in [64, 256] {
            let home = fixture.appendingPathComponent("images-\(count)/home")
            let root = home.appendingPathComponent("Documents/images")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for i in 0..<count { try image(i, to: root.appendingPathComponent("image-\(i).png")) }
            try await measure("similar-images", units: count) {
                let result = await Task.detached {
                    SimilarImageScanner.scan(roots: [root.path], control: DuplicateScanControl(), home: home.path)
                }.value
                try expect(result.scannedFiles == count && result.processedImages == count && !result.isPartial && result.error == nil, "similar-image benchmark incomplete")
            }
            try fm.removeItem(at: home.deletingLastPathComponent())
        }
        for count in [1000, 10000] {
            let payload = (0..<count).map { "images\t{\"ID\":\"image-\($0)\",\"Repository\":\"fixture\",\"Tag\":\"latest\",\"Size\":\"1MB\"}" }.joined(separator: "\n")
            try await measure("docker-inventory-decode", units: count, unit: "rows") {
                let rows = await Task.detached { DockerInventory.decodeItems(payload) }.value
                try expect(rows.count == count && Set(rows.map(\.id)).count == count, "Docker benchmark lost rows")
            }
        }
        let groupHome = fixture.appendingPathComponent("large-group/home")
        let groupRoot = groupHome.appendingPathComponent("Documents/copies")
        try fm.createDirectory(at: groupRoot, withIntermediateDirectories: true)
        for i in 0..<10000 { try FeatureSimulationTests.write(groupRoot.appendingPathComponent("copy-\(i)")) }
        try await measure("exact-duplicates-single-group", units: 10000) {
            let report = await Task.detached {
                DuplicateScanner.scan(roots: [groupRoot.path], control: DuplicateScanControl(), home: groupHome.path)
            }.value
            try expect(!report.isPartial && report.groups.count == 1 && report.groups[0].files.count == 10000, "single group benchmark lost members")
        }
        try fm.removeItem(at: groupHome.deletingLastPathComponent())
        for count in [1000, 10000] {
            let payload = (0..<count).map { i in
                "\(i + 100)\t1\t501\tMon_Aug_31_10:00:00_2026\tS\t00:10\t0.1\t0.01\t/Fixture\t/Applications/Fixture.app/Contents/MacOS/Fixture"
            }.joined(separator: "\n")
            try await measure("process-tree-aggregation", units: count, unit: "processes") {
                let result = await Task.detached {
                    RuntimeStore.usageByApplicationPID(Set((0..<count).map { Int32($0 + 100) }), fromProcessText: payload)
                }.value
                try expect(result.count == count, "process benchmark dropped identities")
            }
        }
        let sampler = ProcessSampler()
        try await measure("native-process-snapshot", units: 1, unit: "snapshots", budget: 5) {
            let rows = await Task.detached { sampler.sample() }.value
            try expect(rows.contains { $0.pid == ProcessInfo.processInfo.processIdentifier }, "native process benchmark omitted self")
        }
        for edge in [1024, 2048] {
            let home = fixture.appendingPathComponent("slim-\(edge)/home")
            let path = home.appendingPathComponent("Pictures/original.png")
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try image(83, to: path, edge: edge)
            let original = fm.contents(atPath: path.path)!
            let slimmer = MediaSlimmer(home: home.path) { _ in throw NSError(domain: "UnexpectedTrash", code: 1) }
            var options = SlimOptions(); options.imageFormat = .heic; options.replaceOriginal = false
            try await measure("image-slim-copy", units: edge * edge, unit: "pixels") {
                let outcome = await slimmer.slim(path: path.path, options: options)
                let validOutput = outcome.status == .slimmed && outcome.outputPath != nil
                    && Double(outcome.newBytes) <= Double(outcome.originalBytes) * SlimOptions.minimumSavingRatio
                let validRefusal = outcome.status == .notSmaller && outcome.outputPath == nil
                    && Double(outcome.newBytes) > Double(outcome.originalBytes) * SlimOptions.minimumSavingRatio
                try expect((validOutput || validRefusal) && outcome.originalBytes == UInt64(original.count)
                    && fm.contents(atPath: path.path) == original,
                    "image benchmark invalid outcome or touched original: \(outcome.message ?? "")")
                if let output = outcome.outputPath { try fm.removeItem(atPath: output) }
            }
            try fm.removeItem(at: home.deletingLastPathComponent())
        }
        let archiveHome = fixture.appendingPathComponent("archive/home")
        let archive = archiveHome.appendingPathComponent("Documents/original.bin")
        let original = Data(repeating: 83, count: 16 * 1048576)
        try FeatureSimulationTests.write(archive, data: original)
        var archiveOptions = SlimOptions(); archiveOptions.replaceOriginal = false
        let archiver = MediaSlimmer(home: archiveHome.path) { _ in throw NSError(domain: "UnexpectedTrash", code: 1) }
        try await measure("archive-slim-copy", units: original.count, unit: "bytes") {
            let outcome = await archiver.slim(path: archive.path, options: archiveOptions)
            try expect(outcome.status == .slimmed && outcome.newBytes < outcome.originalBytes
                && fm.contents(atPath: archive.path) == original, "archive benchmark failed")
            if let output = outcome.outputPath { try fm.removeItem(atPath: output) }
        }
        try fm.removeItem(at: archiveHome.deletingLastPathComponent())
        let report = BenchmarkReport(schemaVersion: 1, createdAt: ISO8601DateFormatter().string(from: Date()),
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: ProcessInfo.processInfo.environment["NORI_BENCH_ARCH"] ?? "unknown",
            cpuModel: ProcessInfo.processInfo.environment["NORI_BENCH_CPU"] ?? "unknown",
            processors: ProcessInfo.processInfo.processorCount, memoryBytes: ProcessInfo.processInfo.physicalMemory,
            sdk: ProcessInfo.processInfo.environment["SDKROOT"] ?? "unknown",
            compiler: ProcessInfo.processInfo.environment["NORI_BENCH_COMPILER"] ?? "unknown",
            benchmarkSuiteSHA256: ProcessInfo.processInfo.environment["NORI_BENCH_SUITE_SHA"] ?? "unknown", repetitions: repetitions,
            fixtureSeed: 83, cacheState: "one excluded warmup; warm filesystem cache; setup/compilation excluded", records: records)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        print("PASS benchmarks: \(records.count) workloads; report \(reportURL.path)")
    }
    static func image(_ seed: Int, to url: URL, edge: Int = 64) throws {
        let width = edge, height = edge
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            pixels[offset] = UInt8((x * 5 + seed) % 256)
            pixels[offset + 1] = UInt8((y * 5 + seed * 3) % 256)
            pixels[offset + 2] = UInt8((x * y + seed * 7) % 256)
        } }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "cannot encode benchmark image")
    }
}
@main struct FeatureTestMain {
    static func main() async {
        do {
            let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            guard fixture.lastPathComponent.hasPrefix(".feature-tests."), !fixture.path.hasPrefix("/private/") else {
                throw NSError(domain: "UnsafeFixture", code: 1)
            }
            DeveloperCacheLocations.override = .resolve(home: fixture.path, environment: [:], readText: { _ in nil })
            defer { DeveloperCacheLocations.override = nil }
            switch CommandLine.arguments[2] {
            case "--simulate": try await FeatureSimulationTests.run(fixture)
            case "--benchmark": try await PerformanceBenchmarks.run(fixture, reportURL: URL(fileURLWithPath: CommandLine.arguments[3]))
            default: throw NSError(domain: "InvalidMode", code: 1)
            }
        } catch {
            FileHandle.standardError.write(Data(("FAIL: \(error.localizedDescription)\n").utf8)); exit(1)
        }
    }
}
