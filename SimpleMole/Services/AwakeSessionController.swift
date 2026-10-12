import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt

enum AwakeMode: String, Codable, CaseIterable, Sendable {
    case systemOnly, systemAndDisplay
}

struct AwakePreferences: Codable, Equatable, Sendable {
    static let storageKey = "SMAwakePreferences.v1"

    var defaultMode: AwakeMode = .systemOnly
    var batteryFloorPercent: Int = 15
    var endAtCriticalThermal = true

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

struct AwakeSession: Equatable, Sendable {
    let startedAt: Date
    let mode: AwakeMode
}

enum AwakeEndReason: Equatable, Sendable {
    case manual, battery(Int), thermal, quit
}

struct AwakeMetrics: Equatable, Sendable {
    let batteryPercent: Int?
    let batteryCharging: Bool
    let thermalLevel: Int
}

protocol AwakeAssertionBackend {
    func create(type: CFString, name: CFString) throws -> IOPMAssertionID
    func release(_ assertion: IOPMAssertionID)
}

struct IOPMAwakeAssertionBackend: AwakeAssertionBackend {
    struct Failure: LocalizedError {
        let code: IOReturn
        var errorDescription: String? { "IOPMAssertionCreateWithName failed (\(code))" }
    }

    func create(type: CFString, name: CFString) throws -> IOPMAssertionID {
        var assertion = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &assertion)
        guard result == kIOReturnSuccess else { throw Failure(code: result) }
        return assertion
    }

    func release(_ assertion: IOPMAssertionID) {
        IOPMAssertionRelease(assertion)
    }
}

@MainActor
final class AwakeSessionController: ObservableObject {
    @Published private(set) var session: AwakeSession?
    @Published private(set) var lastEnd: (reason: AwakeEndReason, at: Date)?
    @Published private(set) var errorMessage: String?

    private static let assertionName = "Nori keep-awake session" as CFString
    private let backend: any AwakeAssertionBackend
    private var assertions: [IOPMAssertionID] = []
    private var terminationObserver: NSObjectProtocol?

    init(backend: any AwakeAssertionBackend = IOPMAwakeAssertionBackend()) {
        self.backend = backend
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.end(reason: .quit) }
            }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        for assertion in assertions { backend.release(assertion) }
    }

    @discardableResult
    func start(mode: AwakeMode) -> Bool {
        releaseAssertions()
        session = nil
        lastEnd = nil
        errorMessage = nil
        var created: [IOPMAssertionID] = []
        do {
            created.append(try backend.create(
                type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                name: Self.assertionName))
            if mode == .systemAndDisplay {
                created.append(try backend.create(
                    type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    name: Self.assertionName))
            }
        } catch {
            for assertion in created { backend.release(assertion) }
            errorMessage = error.localizedDescription
            return false
        }
        assertions = created
        session = AwakeSession(startedAt: Date(), mode: mode)
        return true
    }

    func end(reason: AwakeEndReason) {
        guard session != nil else { return }
        releaseAssertions()
        session = nil
        lastEnd = (reason, Date())
    }

    func dismissLastEnd() {
        lastEnd = nil
    }

    func evaluate(metrics: AwakeMetrics, preferences: AwakePreferences) {
        guard session != nil else { return }
        if preferences.batteryFloorPercent > 0, !metrics.batteryCharging,
           let percent = metrics.batteryPercent, percent <= preferences.batteryFloorPercent {
            end(reason: .battery(percent))
            return
        }
        if preferences.endAtCriticalThermal, metrics.thermalLevel >= 3 {
            end(reason: .thermal)
        }
    }

    private func releaseAssertions() {
        for assertion in assertions { backend.release(assertion) }
        assertions.removeAll()
    }
}
