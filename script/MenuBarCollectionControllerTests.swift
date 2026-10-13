import AppKit
import SwiftUI

// Standalone controller fixture: no product state, cleanup, real preferences or
// privacy grants. --native explicitly exercises the private API on macOS 27.
final class L10n: ObservableObject {
    static let shared = L10n()
    func t(_ key: String) -> String { key }
}
@main
@MainActor
struct MenuBarCollectionControllerTests {
    static func settle(_ interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline { RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.02))) }
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        settle(1)
        let suite = "app.nori.menubar-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MenuBarCollectionController(defaults: defaults)
        defer { controller.stop() }
        precondition(!controller.enabled && !controller.collapsed)
        var settingsRequests = 0
        controller.onOpenSettings = { settingsRequests += 1 }
        controller.openSettings()
        precondition(settingsRequests == 1 && NSApp.windows.isEmpty, "Settings must route to the existing Nori panel")
        controller.setEnabled(true)
        guard controller.available else {
            precondition(!controller.enabled)
            print("PASS: unavailable system fails open"); return
        }
        precondition(controller.enabled && !controller.collapsed)
        controller.refreshCandidates()
        let own = Bundle.main.bundleIdentifier
        precondition(controller.candidates.allSatisfy { !$0.id.hasPrefix("com.apple.") && $0.id != own })
        controller.setSelected("app.nori.fixture.selected", true)
        precondition(defaults.stringArray(forKey: "SMMenuBarCollectionApps") == ["app.nori.fixture.selected"])
        controller.setSelected("app.nori.fixture.selected", false)
        if controller.backend == .nativeExperimental {
            controller.collapse()
            precondition(!controller.collapsed && !controller.busy && controller.error != nil)
        }
        controller.setEnabled(false)
        precondition(!controller.enabled && !controller.collapsed && !controller.busy)
        controller.setEnabled(true)
        if CommandLine.arguments.contains("--native"), controller.backend == .nativeExperimental {
            guard controller.candidates.contains(where: { $0.id == "app.nori.fixture.selected" }) else {
                fatalError("Start the disposable selected status-item fixture before --native")
            }
            controller.setSelected("app.nori.fixture.selected", true)
            controller.collapse()
            controller.restore() // Cancel before the asynchronous result arrives.
            settle(2)
            precondition(!controller.collapsed && !controller.busy)
            controller.collapse()
            settle(2)
            precondition(controller.collapsed && !controller.busy, controller.error ?? "Activation did not complete")
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
            precondition(!controller.collapsed && !controller.busy)
            controller.collapse()
            settle(2)
            precondition(controller.collapsed)
            controller.stop()
            precondition(!controller.enabled && !controller.collapsed && !controller.busy)
            print("PASS: native activation, pending cancellation, late completion, new-app restore, disable restore")
        }
        controller.stop()
        let reopened = MenuBarCollectionController(defaults: defaults)
        precondition(!reopened.enabled && !reopened.collapsed)
        print("PASS: defaults isolated, candidate exclusions, explicit selection, empty selection fails open, restart expanded, enable/disable recovery")
    }
}
