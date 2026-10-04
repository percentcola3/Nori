import Foundation

private final class CapacityReaderFixture: @unchecked Sendable {
    private let lock = NSLock()
    let started = DispatchSemaphore(value: 0)
    private var gate: DispatchSemaphore?
    private var count = 0
    private var nextBytes: UInt64?

    init(bytes: UInt64?, gate: DispatchSemaphore? = nil) {
        nextBytes = bytes
        self.gate = gate
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func setNext(bytes: UInt64?, gate: DispatchSemaphore? = nil) {
        lock.lock()
        nextBytes = bytes
        self.gate = gate
        lock.unlock()
    }

    func read(_ url: URL) -> UInt64? {
        lock.lock()
        count += 1
        let bytes = nextBytes
        let pendingGate = gate
        lock.unlock()
        started.signal()
        if let pendingGate { precondition(pendingGate.wait(timeout: .now() + 2) == .success) }
        return bytes
    }
}

@main
struct SystemDiskMetricsTests {
    static func main() {
        let gigabyte: UInt64 = 1_000_000_000
        let normalized = SystemMetrics.normalizedDiskUsage(totalBytes: 250 * gigabyte,
            physicalFreeBytes: 40 * gigabyte, reclaimableBytes: 14 * gigabyte)
        precondition(normalized.freeBytes == 54 * gigabyte)
        precondition(abs(normalized.usedPercent - 78.4) < 0.0001,
                     "Disk progress must use the same available capacity as its label")
        let changed = SystemMetrics.normalizedDiskUsage(totalBytes: 250 * gigabyte,
            physicalFreeBytes: 42 * gigabyte, reclaimableBytes: 14 * gigabyte)
        precondition(changed.freeBytes == 56 * gigabyte,
                     "Cleaning must appear before the next Foundation capacity query")
        let fallback = SystemMetrics.normalizedDiskUsage(totalBytes: 100,
            physicalFreeBytes: 25, reclaimableBytes: 0)
        precondition(fallback.freeBytes == 25 && fallback.usedPercent == 75)
        let bounded = SystemMetrics.normalizedDiskUsage(totalBytes: 100,
            physicalFreeBytes: 80, reclaimableBytes: 50)
        precondition(bounded.freeBytes == 100 && bounded.usedPercent == 0)
        let overflow = SystemMetrics.normalizedDiskUsage(totalBytes: 100,
            physicalFreeBytes: .max, reclaimableBytes: 1)
        precondition(overflow.freeBytes == 100 && overflow.usedPercent == 0)
        let unknown = SystemMetrics.normalizedDiskUsage(totalBytes: 0,
            physicalFreeBytes: 25, reclaimableBytes: 10)
        precondition(unknown.freeBytes == 0 && unknown.usedPercent == 0)

        let queue = DispatchQueue(label: "nori.disk-capacity-test")
        let gate = DispatchSemaphore(value: 0)
        let fixture = CapacityReaderFixture(bytes: 14 * gigabyte, gate: gate)
        let cache = DiskAvailableCapacityCache(refreshInterval: 15, queue: queue,
                                               reader: { fixture.read($0) })
        let url = URL(fileURLWithPath: "/fixture/a")
        let start = Date()
        precondition(cache.reclaimableBytes(for: url, timestamp: 100) == 0,
                     "First sample must return physical capacity while the query runs")
        precondition(Date().timeIntervalSince(start) < 0.1,
                     "Capacity queries must not block metric refresh")
        precondition(fixture.started.wait(timeout: .now() + 2) == .success)
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            precondition(cache.reclaimableBytes(for: url, timestamp: 101) == 0)
        }
        precondition(fixture.calls == 1, "Concurrent samples duplicated an in-flight query")
        gate.signal()
        queue.sync {}
        precondition(cache.reclaimableBytes(for: url, timestamp: 114) == 14 * gigabyte)
        precondition(fixture.calls == 1, "The cache did not throttle capacity queries")

        fixture.setNext(bytes: 12 * gigabyte)
        precondition(cache.reclaimableBytes(for: url, timestamp: 115) == 14 * gigabyte,
                     "Refresh must continue returning cached capacity")
        queue.sync {}
        precondition(cache.reclaimableBytes(for: url, timestamp: 116) == 12 * gigabyte)
        precondition(fixture.calls == 2)

        fixture.setNext(bytes: nil)
        _ = cache.reclaimableBytes(for: url, timestamp: 130)
        queue.sync {}
        precondition(cache.reclaimableBytes(for: url, timestamp: 131) == 0,
                     "Failed Foundation queries must fall back to physical capacity")
        precondition(fixture.calls == 3)

        let oldGate = DispatchSemaphore(value: 0)
        let newGate = DispatchSemaphore(value: 0)
        let oldStarted = DispatchSemaphore(value: 0)
        let newStarted = DispatchSemaphore(value: 0)
        let switched = DiskAvailableCapacityCache(queue: queue) { path in
            if path.path == "/fixture/a" {
                oldStarted.signal()
                precondition(oldGate.wait(timeout: .now() + 2) == .success)
                return 20 * gigabyte
            }
            newStarted.signal()
            precondition(newGate.wait(timeout: .now() + 2) == .success)
            return 5 * gigabyte
        }
        _ = switched.reclaimableBytes(for: url, timestamp: 100)
        precondition(oldStarted.wait(timeout: .now() + 2) == .success)
        let otherURL = URL(fileURLWithPath: "/fixture/b")
        precondition(switched.reclaimableBytes(for: otherURL, timestamp: 101) == 0)
        oldGate.signal()
        precondition(newStarted.wait(timeout: .now() + 2) == .success)
        precondition(switched.reclaimableBytes(for: otherURL, timestamp: 102) == 0,
                     "A stale query must not fill another volume's capacity cache")
        newGate.signal()
        queue.sync {}
        precondition(switched.reclaimableBytes(for: otherURL, timestamp: 103) == 5 * gigabyte)
        print("System disk metrics: available capacity, immediate mutations, bounds, background caching, throttling, fallback and volume isolation passed")
    }
}
