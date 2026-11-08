import Darwin
import Foundation

@main
struct CleanupTraceTests {
    static let fm = FileManager.default
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: message, code: 1) }
    }
    static func rows(_ data: Data) throws -> [[String: Any]] {
        try data.split(separator: 0x0a).map {
            guard let row = try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] else {
                throw NSError(domain: "Invalid JSONL object", code: 1)
            }
            return row
        }
    }
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Data] = []
        private var mainWrite = false
        func append(_ data: Data) {
            lock.lock(); values.append(data); mainWrite = mainWrite || Thread.isMainThread; lock.unlock()
        }
        func snapshot() -> ([Data], Bool) { lock.lock(); defer { lock.unlock() }; return (values, mainWrite) }
    }
    final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        func finish() { lock.lock(); finished = true; lock.unlock() }
        func isFinished() -> Bool { lock.lock(); defer { lock.unlock() }; return finished }
    }
    static func testPersistence(in base: URL) throws {
        let path = base.appendingPathComponent("persist/Nori/cleanup-events.jsonl")
        let resolvedOffMain = Completion()
        let sink = CleanupTrace.Sink(destination: {
            if !Thread.isMainThread { resolvedOffMain.finish() }
            return path
        })
        let request = UUID()
        for index in 0..<40 { sink.record("apply.stage", requestID: request, fields: ["index": String(index), "phase": "preflight"]) }
        sink.flushForTesting()
        let decoded = try rows(Data(contentsOf: path))
        try expect(decoded.count == 41 && decoded.first?["event"] as? String == "trace.started", "Startup/event persistence missing")
        try expect(resolvedOffMain.isFinished(), "Destination resolution happened on main thread")
        try expect(decoded.dropFirst().allSatisfy { $0["requestID"] as? String == request.uuidString }, "Request correlation was lost")
        try expect(Set(decoded.compactMap { $0["session"] as? String }).count == 1
            && decoded.allSatisfy { ($0["pid"] as? NSNumber)?.int32Value == getpid() && $0["timestamp"] is String },
            "PID/session/time metadata missing")
        let sequences = decoded.compactMap { ($0["sequence"] as? NSNumber)?.uint64Value }
        try expect(sequences == sequences.sorted() && Set(sequences).count == sequences.count, "Persisted sequences reordered or duplicated")
        var metadata = stat()
        try expect(lstat(path.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o600, "Log is not private 0600")
        try expect(lstat(path.deletingLastPathComponent().path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o700,
                   "Log directory is not private 0700")
        try expect(chmod(path.path, 0o644) == 0, "Cannot prepare owned changed-mode fixture")
        sink.record("privacy.recheck")
        sink.flushForTesting()
        try expect(lstat(path.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o600, "Cached log descriptor allowed nonprivate permissions")
    }
    static func testConcurrentAndTruncated(in base: URL) throws {
        let capture = Capture()
        let sink = CleanupTrace.Sink(destination: { base.appendingPathComponent("unused.jsonl") }, pendingLimit: 1024,
                                     writer: { capture.append($0); return true })
        let group = DispatchGroup()
        for producer in 0..<8 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for index in 0..<2000 { sink.record("parallel", fields: ["producer": String(producer), "index": String(index)]) }
                group.leave()
            }
        }
        group.wait()
        sink.flushForTesting()
        let enormous = "e" + String(repeating: "\u{301}", count: 200_000)
        let fields = Dictionary(uniqueKeysWithValues: (0..<40).map { ("key-\($0)", enormous) })
        let began = DispatchTime.now().uptimeNanoseconds
        sink.record(enormous, fields: fields)
        let callSeconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        sink.flushForTesting()
        let snapshot = capture.snapshot()
        let decoded = try snapshot.0.flatMap(rows)
        try expect(!snapshot.1 && callSeconds < 0.2, "Serialization or oversized string processing blocked main record")
        let sequences = decoded.compactMap { ($0["sequence"] as? NSNumber)?.uint64Value }
        try expect(sequences == sequences.sorted() && Set(sequences).count == sequences.count, "Concurrent entries lost sequence ordering")
        guard let truncated = decoded.last, let name = truncated["event"] as? String,
              let outputFields = truncated["fields"] as? [String: String] else { throw NSError(domain: "Missing truncated entry", code: 1) }
        try expect(truncated["truncated"] as? Bool == true && name.utf8.count <= 96 && outputFields.count <= 32
            && outputFields.allSatisfy { $0.key.utf8.count <= 48 && $0.value.utf8.count <= 128 }, "UTF8 truncation exceeded byte limits")
        try expect(snapshot.0.allSatisfy { $0.count <= 16 * 1024 }, "A record exceeded maximum line bytes")
    }
    static func testRotation(in base: URL) throws {
        let path = base.appendingPathComponent("rotate/cleanup-events.jsonl")
        let sink = CleanupTrace.Sink(destination: { path }, maximumBytes: 1024)
        for index in 0..<150 { sink.record("rotation", fields: ["index": String(index), "state": "accepted"]) }
        sink.flushForTesting()
        let names = try fm.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)
        try expect(names.count == 3, "Rotation did not retain exactly three bounded log files")
        var decoded: [[String: Any]] = []
        for suffix in [".2", ".1", ""] {
            let file = URL(fileURLWithPath: path.path + suffix)
            let data = try Data(contentsOf: file)
            var metadata = stat()
            try expect(data.count <= 1024 && lstat(file.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o600,
                       "Rotated logs exceeded size or private-mode bounds")
            decoded += try rows(data)
        }
        let sequences = decoded.compactMap { ($0["sequence"] as? NSNumber)?.uint64Value }
        try expect(sequences == sequences.sorted() && !sequences.isEmpty, "Rotation broke JSONL sequence order")
    }
    static func testUnsafeSinks(in base: URL) throws {
        let sentinel = base.appendingPathComponent("safety-sentinel")
        let original = Data("owned nonce sentinel".utf8)
        try original.write(to: sentinel)
        for kind in ["symlink", "hardlink", "fifo"] {
            let folder = base.appendingPathComponent(kind)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent("cleanup-events.jsonl")
            if kind == "symlink" { try fm.createSymbolicLink(at: path, withDestinationURL: sentinel) }
            else if kind == "hardlink" { try expect(link(sentinel.path, path.path) == 0, "Cannot prepare owned hardlink") }
            else { try expect(mkfifo(path.path, 0o600) == 0, "Cannot prepare owned FIFO") }
            let sink = CleanupTrace.Sink(destination: { path })
            sink.record("must.refuse")
            sink.flushForTesting()
            try expect(sink.statistics().writeFailures > 0, "Unsafe sink was accepted: " + kind)
            let contents = try Data(contentsOf: sentinel)
            try expect(contents == original, "Unsafe sink modified a linked nonce sentinel")
        }
        let target = base.appendingPathComponent("directory-target")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let alias = base.appendingPathComponent("directory-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: target)
        let sink = CleanupTrace.Sink(destination: { alias.appendingPathComponent("Nori/cleanup-events.jsonl") })
        sink.record("ancestor.refused")
        sink.flushForTesting()
        try expect(sink.statistics().writeFailures > 0 && !fm.fileExists(atPath: target.appendingPathComponent("Nori").path),
                   "Directory ancestor link redirected file creation")
    }
    static func testBlockedSinkAndHeartbeats(in base: URL) throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let capture = Capture(), completion = Completion()
        var first = true // Accessed only by the serial writer callback.
        let sink = CleanupTrace.Sink(destination: { base.appendingPathComponent("never-created.jsonl") }, pendingLimit: 64,
            writer: { data in
                if first { first = false; entered.signal(); _ = release.wait(timeout: .now() + 10) }
                capture.append(data)
                return true
            })
        try expect(entered.wait(timeout: .now() + 3) == .success, "Background writer did not start")
        var beats = 0
        var lastBeat = DispatchTime.now().uptimeNanoseconds
        var maximumGap: UInt64 = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        timer.setEventHandler {
            let now = DispatchTime.now().uptimeNanoseconds
            maximumGap = max(maximumGap, now - lastBeat); lastBeat = now; beats += 1
        }
        timer.resume()
        DispatchQueue.global(qos: .userInitiated).async {
            for index in 0..<100_000 { sink.record("stress", fields: ["index": String(index)]) }
            completion.finish()
        }
        let deadline = Date().addingTimeInterval(8)
        while !completion.isFinished(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        timer.cancel()
        let began = DispatchTime.now().uptimeNanoseconds
        sink.record("main.probe")
        let mainSeconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        let bounded = sink.statistics()
        release.signal()
        sink.flushForTesting()
        try expect(completion.isFinished() && beats > 2 && maximumGap < 250_000_000 && mainSeconds < 0.1,
                   "100k events or a blocked sink stalled the main heartbeat")
        try expect(bounded.pending <= 64 && bounded.peakPending <= 64 && bounded.dropped > 90_000,
                   "Blocked writer allowed unbounded pending work")
        let snapshot = capture.snapshot()
        let decoded = try snapshot.0.flatMap(rows)
        let drops = decoded.filter { $0["event"] as? String == "trace.dropped" }
            .compactMap { ($0["fields"] as? [String: String])?["count"].flatMap(UInt64.init) }.reduce(0, +)
        try expect(!snapshot.1 && drops == bounded.dropped && sink.statistics().pending == 0,
                   "Drop diagnostics or background-only writing failed")
        print("CleanupTrace 100k: heartbeat=\(beats) maxGapMs=\(Double(maximumGap) / 1e6) mainRecordMs=\(mainSeconds * 1000) peakPending=\(bounded.peakPending) dropped=\(bounded.dropped)")
    }
    static func main() throws {
        try expect(CommandLine.arguments.count == 2 && geteuid() != 0, "Require unprivileged owned fixture base")
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let fixture = base.appendingPathComponent(".cleanup-trace-fixture." + UUID().uuidString)
        try expect(fixture.path.hasPrefix(base.path + "/.cleanup-trace-fixture.") && mkdir(fixture.path, 0o700) == 0,
                   "Cannot create exclusive trace fixture")
        var owned = stat()
        try expect(lstat(fixture.path, &owned) == 0, "Cannot bind fixture identity")
        defer {
            var current = stat()
            if lstat(fixture.path, &current) == 0, current.st_dev == owned.st_dev, current.st_ino == owned.st_ino,
               fixture.path.hasPrefix(base.path + "/.cleanup-trace-fixture.") { try? fm.removeItem(at: fixture) }
        }
        try testPersistence(in: fixture)
        try testConcurrentAndTruncated(in: fixture)
        try testRotation(in: fixture)
        try testUnsafeSinks(in: fixture)
        try testBlockedSinkAndHeartbeats(in: fixture)
        print("PASS CleanupTrace: private persistence, concurrency, UTF8 limits, rotation, symlink/hardlink/FIFO refusal, bounded queue and 100k heartbeats")
    }
}
