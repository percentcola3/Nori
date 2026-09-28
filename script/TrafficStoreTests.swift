import Foundation

@main
@MainActor
private enum TrafficStoreTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "TrafficStoreTests", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.register(defaults: ["SMNetMonPersistent": false])
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        func accumulator(_ name: String, _ down: UInt64, _ up: UInt64) -> [String: Any] {
            ["down": down, "up": up, "rateDown": 99, "rateUp": 9, "name": name,
             "representativePID": 123, "seen": startedAt.timeIntervalSinceReferenceDate]
        }
        var history: [String: Any] = [
            "version": 2, "startedAt": startedAt.timeIntervalSinceReferenceDate,
            "appTotals": ["app:browser": accumulator("Browser", 1000, 20),
                          "app:upload": accumulator("Uploader", 30, 2000)],
            "names": ["app:browser": "Browser", "app:upload": "Uploader"],
            "tunnelDown": 100, "tunnelUp": 10, "physicalDown": 1100, "physicalUp": 2010]
        try JSONSerialization.data(withJSONObject: history).write(to: url)
        let store = TrafficMonitorStore(defaults: defaults, historyURL: url)
        try expect(!store.sampling && store.lastSample == nil && !store.historySaveFailed,
                   "restore unexpectedly sampled the OS or rejected history")
        try expect(store.sessionStartedAt == startedAt && store.rows.count == 2,
                   "session history did not restore")
        try expect(store.rows.first?.appKey == "app:upload", "total-byte ranking incorrect")
        store.sortOrder = .download
        try expect(store.rows.first?.appKey == "app:browser", "download ranking incorrect")
        store.sortOrder = .upload
        try expect(store.rows.first?.appKey == "app:upload", "upload ranking incorrect")
        try expect(store.rows.allSatisfy { $0.rateDown == 0 && $0.rateUp == 0 &&
            $0.representativePID == 0 && $0.connectionCount == 0 }, "stale live data restored")
        try expect(store.endpointsByApp.isEmpty, "stale connections restored")
        store.flushHistoryForTermination()
        let restored = TrafficMonitorStore(defaults: defaults, historyURL: url)
        try expect(restored.rows.reduce(UInt64(0)) { $0 + $1.sampledTotal } == 3050,
                   "round trip changed application totals")
        try expect(restored.physicalDown == 1100 && restored.tunnelDown == 100,
                   "interface counters should remain separate")
        let resetAt = Date()
        restored.resetSession()
        restored.flushHistoryForTermination()
        let reset = TrafficMonitorStore(defaults: defaults, historyURL: url)
        try expect(reset.rows.isEmpty && reset.physicalDown == 0 && reset.tunnelDown == 0
            && reset.sessionStartedAt >= resetAt, "reset did not persist")
        history["version"] = 1
        try JSONSerialization.data(withJSONObject: history).write(to: url)
        let legacy = TrafficMonitorStore(defaults: defaults, historyURL: url)
        try expect(legacy.rows.isEmpty, "legacy proxy history must not become system totals")
        print("Traffic store: persistence, ranking, reset and history isolation passed")
    }
}
