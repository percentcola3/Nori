import AppKit
import Foundation
import IOKit.pwr_mgt

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

private final class FakeAwakeBackend: AwakeAssertionBackend {
    struct Failure: Error {}
    var createdTypes: [String] = []
    var released: [IOPMAssertionID] = []
    var failAtCreation: Int?
    private var nextID = IOPMAssertionID(1)

    func create(type: CFString, name: CFString) throws -> IOPMAssertionID {
        let call = createdTypes.count + 1
        if failAtCreation == call { throw Failure() }
        createdTypes.append(type as String)
        defer { nextID += 1 }
        return nextID
    }

    func release(_ assertion: IOPMAssertionID) {
        released.append(assertion)
    }
}

@main
struct AwakeSessionTests {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--real") {
            runRealAssertionProbe()
            return
        }

        let backend = FakeAwakeBackend()
        let controller = AwakeSessionController(backend: backend)
        expect(controller.start(mode: .systemOnly), "system-only start failed")
        expect(backend.createdTypes.count == 1, "system-only mode did not create one assertion")
        expect(controller.start(mode: .systemAndDisplay), "display mode replacement failed")
        expect(backend.createdTypes.count == 3 && backend.released.count == 1,
               "replacement did not release the old assertion and create two new assertions")
        controller.end(reason: .manual)
        expect(backend.released.count == 3 && controller.session == nil,
               "manual end did not release all assertions")

        let continuousBackend = FakeAwakeBackend()
        var continuous: AwakeSessionController? = AwakeSessionController(backend: continuousBackend)
        expect(continuous!.start(mode: .systemOnly), "continuous fixture did not start")
        let initialSession = continuous!.session
        for _ in 0..<100 {
            continuous!.evaluate(metrics: .init(batteryPercent: 80, batteryCharging: false, thermalLevel: 0),
                preferences: AwakePreferences())
        }
        expect(continuous!.session == initialSession && continuousBackend.released.isEmpty,
               "continuous session ended without manual action or a safety condition")
        continuous = nil
        expect(continuousBackend.released.count == 1, "controller disposal leaked the power assertion")

        let battery = AwakeSessionController(backend: FakeAwakeBackend())
        expect(battery.start(mode: .systemOnly), "battery fixture did not start")
        battery.evaluate(metrics: .init(batteryPercent: 14, batteryCharging: false, thermalLevel: 0),
            preferences: AwakePreferences())
        expect(battery.lastEnd?.reason == .battery(14), "low unplugged battery did not end session")

        let charging = AwakeSessionController(backend: FakeAwakeBackend())
        expect(charging.start(mode: .systemOnly), "charging fixture did not start")
        charging.evaluate(metrics: .init(batteryPercent: 14, batteryCharging: true, thermalLevel: 0),
            preferences: AwakePreferences())
        expect(charging.session != nil, "charging battery incorrectly ended session")

        var noFloorPreferences = AwakePreferences()
        noFloorPreferences.batteryFloorPercent = 0
        let noFloor = AwakeSessionController(backend: FakeAwakeBackend())
        expect(noFloor.start(mode: .systemOnly), "no-floor fixture did not start")
        noFloor.evaluate(metrics: .init(batteryPercent: 1, batteryCharging: false, thermalLevel: 0),
            preferences: noFloorPreferences)
        expect(noFloor.session != nil, "disabled battery floor ended session")

        let thermal = AwakeSessionController(backend: FakeAwakeBackend())
        expect(thermal.start(mode: .systemOnly), "thermal fixture did not start")
        thermal.evaluate(metrics: .init(batteryPercent: nil, batteryCharging: false, thermalLevel: 3),
            preferences: AwakePreferences())
        expect(thermal.lastEnd?.reason == .thermal, "critical thermal level did not end session")

        var thermalOffPreferences = AwakePreferences()
        thermalOffPreferences.endAtCriticalThermal = false
        let thermalOff = AwakeSessionController(backend: FakeAwakeBackend())
        expect(thermalOff.start(mode: .systemOnly), "thermal-off fixture did not start")
        thermalOff.evaluate(metrics: .init(batteryPercent: nil, batteryCharging: false, thermalLevel: 3),
            preferences: thermalOffPreferences)
        expect(thermalOff.session != nil, "disabled thermal protection ended session")

        let quitBackend = FakeAwakeBackend()
        let quitting = AwakeSessionController(backend: quitBackend)
        expect(quitting.start(mode: .systemAndDisplay), "quit fixture did not start")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        await Task.yield()
        expect(quitting.session == nil && quitting.lastEnd?.reason == .quit && quitBackend.released.count == 2,
               "application termination did not release both assertions")
        quitting.end(reason: .manual)
        expect(quitBackend.released.count == 2, "inactive session released assertions twice")

        let suiteName = "nori-awake-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyData = Data(#"{"defaultMode":"systemAndDisplay","batteryFloorPercent":20,"endAtCriticalThermal":false,"lastDurationMinutes":120}"#.utf8)
        defaults.set(legacyData, forKey: AwakePreferences.storageKey)
        let migrated = AwakePreferences.load(from: defaults)
        expect(migrated.defaultMode == .systemAndDisplay && migrated.batteryFloorPercent == 20
               && !migrated.endAtCriticalThermal, "removing the duration reset existing safety preferences")
        migrated.save(to: defaults)
        expect(AwakePreferences.load(from: defaults) == migrated, "preferences did not round-trip after migration")

        let failingBackend = FakeAwakeBackend()
        failingBackend.failAtCreation = 1
        let failing = AwakeSessionController(backend: failingBackend)
        expect(!failing.start(mode: .systemOnly) && failing.session == nil,
               "backend creation failure still established a session")

        let partialBackend = FakeAwakeBackend()
        partialBackend.failAtCreation = 2
        let partial = AwakeSessionController(backend: partialBackend)
        expect(!partial.start(mode: .systemAndDisplay)
               && partialBackend.released.count == 1 && partial.session == nil,
               "partial display assertion failure did not release the system assertion")

        print("AwakeSessionTests: continuous assertion lifecycle, safety rules, quit and preference migration passed")
    }

    @MainActor
    private static func runRealAssertionProbe() {
        let controller = AwakeSessionController()
        guard controller.start(mode: .systemOnly) else {
            print("Awake real assertion probe: failed: \(controller.errorMessage ?? "unknown error")")
            exit(1)
        }
        func assertionLines() -> [String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "assertions"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run(); process.waitUntilExit() }
            catch { print("Awake real assertion probe: pmset failed: \(error)"); exit(1) }
            expect(process.terminationStatus == 0, "pmset assertion inspection failed")
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let ownPID = "pid \(ProcessInfo.processInfo.processIdentifier)("
            return output.components(separatedBy: .newlines).filter {
                $0.contains(ownPID) && $0.contains("Nori keep-awake session")
            }
        }
        let matches = assertionLines()
        expect(!matches.isEmpty, "pmset did not report the Nori power assertion")
        print("Awake real assertion probe:")
        matches.forEach { print($0) }
        expect(!matches.contains { $0.contains("Timeout") }, "continuous power assertion has a timeout")
        controller.end(reason: .manual)
        expect(controller.session == nil, "manual end did not stop the real assertion")
        expect(assertionLines().isEmpty, "manual end leaked the real power assertion")
        print("Real assertion has no timeout and ends manually")
    }
}
