import Darwin
import Foundation

/// State/count diagnostics only. Callers must not pass file contents or private paths.
enum CleanupTrace {
    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Logs/Nori/cleanup-events.jsonl")
    }
    // Resolving the destination is deferred to the utility queue.
    private static let sink = Sink(destination: { fileURL })

    static func record(_ event: String, requestID: UUID? = nil, fields: [String: String] = [:]) {
        sink.record(event, requestID: requestID, fields: fields)
    }

    #if DEBUG || NORI_CLEANUP_TRACE_TESTING
    static func flushForTesting() { sink.flushForTesting() }
    #endif

    final class Sink: @unchecked Sendable {
        struct Statistics {
            let pending: Int
            let peakPending: Int
            let accepted: UInt64
            let dropped: UInt64
            let writeFailures: UInt64
        }
        private struct Entry {
            let timestamp: TimeInterval
            let sequence: UInt64
            let event: String
            let requestID: UUID?
            let fields: [String: String]
            let truncated: Bool
        }
        private struct Line: Encodable {
            let timestamp: String
            let pid: Int32
            let session: UUID
            let sequence: UInt64
            var event: String
            let requestID: UUID?
            var fields: [String: String]
            var truncated: Bool
        }
        private let queue = DispatchQueue(label: "com.nori.cleanup-trace", qos: .utility)
        private let queueKey = DispatchSpecificKey<Bool>()
        private let lock = NSLock()
        private let destination: () -> URL
        private let writer: ((Data) -> Bool)?
        private let limit: Int
        private let maximumBytes: Int
        private let fileCount: Int
        private let session = UUID()
        private let pid = getpid()
        private var pending: [Entry] = []
        private var inFlight = 0
        private var scheduled = false
        private var sequence: UInt64 = 0
        private var peakPending = 0
        private var accepted: UInt64 = 0
        private var dropped: UInt64 = 0
        private var unreportedDropped: UInt64 = 0
        private var writeFailures: UInt64 = 0
        // Queue-only state. No file or serialization work runs in record().
        private var store: Store?
        private lazy var encoder = JSONEncoder()
        private lazy var formatter: ISO8601DateFormatter = {
            let value = ISO8601DateFormatter()
            value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return value
        }()

        init(destination: @escaping () -> URL, pendingLimit: Int = 256,
             maximumBytes: Int = 4 * 1024 * 1024, fileCount: Int = 3,
             writer: ((Data) -> Bool)? = nil) {
            self.destination = destination
            self.limit = min(1024, max(64, pendingLimit))
            self.maximumBytes = min(4 * 1024 * 1024, max(512, maximumBytes))
            self.fileCount = min(3, max(2, fileCount))
            self.writer = writer
            queue.setSpecific(key: queueKey, value: true)
            record("trace.started", fields: ["pending_limit": String(limit)])
        }

        deinit {
            // Keep descriptor closing on the same utility queue as other I/O.
            if let store { queue.async { store.close() } }
        }

        private static func bounded(_ value: String, bytes: Int) -> (String, Bool) {
            let prefix = Array(value.utf8.prefix(bytes + 1))
            var end = min(bytes, prefix.count)
            // A cut UTF8 scalar must not turn into a replacement character
            // whose encoded bytes exceed the promised bound.
            while end > 0, String(bytes: prefix.prefix(end), encoding: .utf8) == nil { end -= 1 }
            return (String(decoding: prefix.prefix(end), as: UTF8.self), prefix.count > bytes)
        }

        func record(_ event: String, requestID: UUID? = nil, fields: [String: String] = [:]) {
            let (name, clipped) = Self.bounded(event, bytes: 96)
            var values: [String: String] = [:]
            var truncated = clipped || fields.count > 32
            for (key, value) in fields.prefix(32) {
                let (key, shortKey) = Self.bounded(key, bytes: 48)
                let (value, shortValue) = Self.bounded(value, bytes: 128)
                values[key] = value
                truncated = truncated || shortKey || shortValue
            }
            let timestamp = Date().timeIntervalSince1970
            lock.lock()
            sequence &+= 1
            guard pending.count + inFlight < limit else {
                dropped &+= 1
                unreportedDropped &+= 1
                lock.unlock()
                return
            }
            pending.append(Entry(timestamp: timestamp, sequence: sequence, event: name,
                                 requestID: requestID, fields: values, truncated: truncated))
            accepted &+= 1
            peakPending = max(peakPending, pending.count + inFlight)
            if !scheduled {
                scheduled = true
                // One drain job, not one Dispatch block for every event.
                queue.async { self.drain() }
            }
            lock.unlock()
        }

        private func drain() {
            while true {
                lock.lock()
                let batch: [Entry]
                if !pending.isEmpty {
                    batch = pending
                    pending.removeAll(keepingCapacity: true)
                } else if unreportedDropped > 0 {
                    sequence &+= 1
                    batch = [Entry(timestamp: Date().timeIntervalSince1970, sequence: sequence,
                        event: "trace.dropped", requestID: nil,
                        fields: ["count": String(unreportedDropped)], truncated: false)]
                    unreportedDropped = 0
                } else {
                    scheduled = false
                    lock.unlock()
                    return
                }
                inFlight = batch.count
                lock.unlock()
                autoreleasepool {
                    for entry in batch {
                        let written = persist(entry)
                        lock.lock()
                        inFlight -= 1
                        if !written { writeFailures &+= 1 }
                        lock.unlock()
                    }
                }
            }
        }

        private func persist(_ entry: Entry) -> Bool {
            var line = Line(timestamp: formatter.string(from: Date(timeIntervalSince1970: entry.timestamp)),
                pid: pid, session: session, sequence: entry.sequence, event: entry.event,
                requestID: entry.requestID, fields: entry.fields, truncated: entry.truncated)
            guard var data = try? encoder.encode(line) else { return false }
            let lineLimit = min(16 * 1024, maximumBytes)
            if data.count + 1 > lineLimit {
                line.fields = [:]
                line.truncated = true
                guard let reduced = try? encoder.encode(line) else { return false }
                data = reduced
            }
            guard data.count + 1 <= lineLimit else { return false }
            data.append(0x0a)
            if let writer { return writer(data) }
            if store == nil { store = Store(url: destination(), maximumBytes: maximumBytes, fileCount: fileCount) }
            return store?.append(data) == true
        }

        func statistics() -> Statistics {
            lock.lock(); defer { lock.unlock() }
            return .init(pending: pending.count + inFlight, peakPending: peakPending,
                         accepted: accepted, dropped: dropped, writeFailures: writeFailures)
        }

        #if DEBUG || NORI_CLEANUP_TRACE_TESTING
        func flushForTesting() {
            guard DispatchQueue.getSpecific(key: queueKey) != true else { return }
            queue.sync {}
        }
        #endif
    }

    /// Accessed exclusively by a Sink's utility queue.
    private final class Store: @unchecked Sendable {
        private let url: URL
        private let maximumBytes: Int
        private let fileCount: Int
        private var directory: Int32 = -1
        private var descriptor: Int32 = -1
        private var retryAfter: UInt64 = 0
        init(url: URL, maximumBytes: Int, fileCount: Int) {
            self.url = url; self.maximumBytes = maximumBytes; self.fileCount = fileCount
        }
        deinit { close() }
        func close() {
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
            if directory >= 0 { Darwin.close(directory); directory = -1 }
        }
        private func fail() -> Bool {
            close()
            retryAfter = DispatchTime.now().uptimeNanoseconds &+ 1_000_000_000
            return false
        }
        private func valid(_ metadata: stat) -> Bool {
            metadata.st_mode & S_IFMT == S_IFREG && metadata.st_uid == geteuid() && metadata.st_nlink == 1
        }
        private func prepareDirectory() -> Bool {
            guard url.isFileURL, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty,
                  !url.path.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) else { return false }
            var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard current >= 0 else { return false }
            for component in url.deletingLastPathComponent().path.split(separator: "/").map(String.init) {
                guard component != ".", component != ".." else { Darwin.close(current); return false }
                var next = openat(current, component, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK)
                if next < 0, errno == ENOENT {
                    guard mkdirat(current, component, 0o700) == 0 || errno == EEXIST else { Darwin.close(current); return false }
                    next = openat(current, component, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK)
                }
                Darwin.close(current)
                guard next >= 0 else { return false }
                current = next
            }
            var metadata = stat()
            guard fstat(current, &metadata) == 0, metadata.st_uid == geteuid(),
                  fchmod(current, 0o700) == 0 else { Darwin.close(current); return false }
            directory = current
            return true
        }
        private func prepareFile() -> Bool {
            if directory < 0, !prepareDirectory() { return false }
            if descriptor >= 0 {
                var current = stat(), opened = stat()
                if fstat(descriptor, &opened) == 0, valid(opened),
                   fstatat(directory, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == opened.st_dev, current.st_ino == opened.st_ino, valid(current),
                   fchmod(descriptor, 0o600) == 0 { return true }
                Darwin.close(descriptor); descriptor = -1
            }
            let opened = openat(directory, url.lastPathComponent,
                O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard opened >= 0 else { return false }
            var metadata = stat()
            guard fstat(opened, &metadata) == 0, valid(metadata), fchmod(opened, 0o600) == 0 else {
                Darwin.close(opened); return false
            }
            descriptor = opened
            return true
        }
        private func safeEntry(_ name: String) -> Bool {
            var metadata = stat()
            if fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT }
            return valid(metadata) && metadata.st_mode & 0o077 == 0
        }
        private func rotate() -> Bool {
            let names = (0..<fileCount).map { $0 == 0 ? url.lastPathComponent : url.lastPathComponent + ".\($0)" }
            guard names.allSatisfy(safeEntry) else { return false }
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
            // Every target is an exact validated entry relative to our pinned,
            // owned directory; rename/unlink never follow a replacement link.
            if unlinkat(directory, names[fileCount - 1], 0) != 0, errno != ENOENT { return false }
            for index in stride(from: fileCount - 2, through: 0, by: -1) {
                if renameat(directory, names[index], directory, names[index + 1]) != 0, errno != ENOENT { return false }
            }
            return prepareFile()
        }
        func append(_ data: Data) -> Bool {
            guard DispatchTime.now().uptimeNanoseconds >= retryAfter else { return false }
            guard prepareFile() else { return fail() }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, valid(metadata) else { return fail() }
            if metadata.st_size > Int64(maximumBytes - data.count), !rotate() { return fail() }
            let written = data.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return false }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            return written || fail()
        }
    }
}
