import Foundation

private final class BluetoothFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamp: TimeInterval = 100
    private var devices: [BluetoothBattery] = []
    private var reads = 0
    private var gate: DispatchSemaphore?
    let started = DispatchSemaphore(value: 0)
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return Date(timeIntervalSinceReferenceDate: timestamp)
    }
    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }
    func advance(_ seconds: TimeInterval, devices: [BluetoothBattery], gate: DispatchSemaphore? = nil) {
        lock.lock(); defer { lock.unlock() }
        timestamp += seconds
        self.devices = devices
        self.gate = gate
    }
    func read() -> [BluetoothBattery] {
        lock.lock()
        reads += 1
        let snapshot = devices
        let pendingGate = gate
        gate = nil
        lock.unlock()
        started.signal()
        if let pendingGate { precondition(pendingGate.wait(timeout: .now() + 2) == .success) }
        return snapshot
    }
}

@main
struct BluetoothBatteryTests {
    static func main() {
        let queue = DispatchQueue(label: "nori.bluetooth-test")
        let fixture = BluetoothFixture()
        let monitor = BluetoothBatteryMonitor(queue: queue, clock: { fixture.now },
            reader: { fixture.read() }, observeAudioChanges: false)
        _ = monitor.latest()
        queue.sync {}
        let headphones = [BluetoothBattery(name: "Fixture Headphones", percent: 76)]
        fixture.advance(1, devices: headphones)
        monitor.connectionDidChange()
        queue.sync {}
        guard monitor.latest() == headphones else {
            print("FAIL: headphones connected just after a battery refresh still wait for the 60-second cache")
            exit(1)
        }

        // Only the connection transition gets the short retry window.
        for _ in 0..<2 {
            fixture.advance(2, devices: headphones)
            _ = monitor.latest()
            queue.sync {}
        }
        let settledCalls = fixture.calls
        fixture.advance(30, devices: headphones)
        _ = monitor.latest()
        queue.sync {}
        precondition(fixture.calls == settledCalls, "Stable devices must keep the minute-long cache")

        fixture.advance(1, devices: [])
        monitor.connectionDidChange()
        queue.sync {}
        precondition(monitor.latest().isEmpty, "Disconnected headphones must leave the battery result")

        // macOS exposes the new audio route before it has battery fields.
        fixture.advance(1, devices: [])
        monitor.connectionDidChange()
        queue.sync {}
        fixture.advance(2, devices: headphones)
        _ = monitor.latest()
        queue.sync {}
        precondition(monitor.latest() == headphones, "Delayed battery data must not wait another minute")

        let blockedQueue = DispatchQueue(label: "nori.bluetooth-blocked-test")
        let blocked = BluetoothFixture()
        let gate = DispatchSemaphore(value: 0)
        blocked.advance(0, devices: headphones, gate: gate)
        let other = BluetoothBatteryMonitor(queue: blockedQueue, clock: { blocked.now },
            reader: { blocked.read() }, observeAudioChanges: false)
        let start = Date()
        _ = other.latest()
        precondition(Date().timeIntervalSince(start) < 0.1, "Battery queries must not block metrics")
        precondition(blocked.started.wait(timeout: .now() + 2) == .success)
        let reconnected = [BluetoothBattery(name: "Other Headphones", percent: 42)]
        blocked.advance(1, devices: reconnected)
        other.connectionDidChange()
        DispatchQueue.concurrentPerform(iterations: 20) { _ in _ = other.latest() }
        precondition(blocked.calls == 1, "A connection change must not duplicate an in-flight profiler")
        gate.signal()
        blockedQueue.sync {}
        blockedQueue.sync {}
        precondition(other.latest() == reconnected && blocked.calls == 2,
                     "A stale in-flight read must not overwrite the new connection or delay its refresh")

        let parsed = BluetoothBatteryMonitor.parseProfiler([
            ["device_connected": [["Headphones": ["device_batteryLevelLeft": "83%", "device_batteryLevelRight": "76%"]]],
             "device_not_connected": [["Old Headphones": ["device_batteryLevelMain": "95%"]]]],
        ])
        precondition(parsed == [BluetoothBattery(name: "Headphones", percent: 76)])
        print("PASS: connection refresh, delayed battery data, disconnects, bounded retries, nonblocking reads, in-flight isolation and parsing")
    }
}
