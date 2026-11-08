import AppKit
import SwiftUI
import Darwin

private struct CleanupPresentationRoot: View {
    @ObservedObject var state: AppState
    var body: some View {
        CleanupTabView(state: state)
            .background(Color.glassOpaque)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

/// The active case compiles the real MainWindowView, AnimatedTabContent and
/// NoriMainWindow. Only unrelated pages/services are inert fixture stubs.
private struct CleanupConfirmationFixtureRoot: View {
    @ObservedObject var state: AppState
    let ancestorAlerts: Bool

    var body: some View {
        if ancestorAlerts {
            MainWindowView(state: state)
        } else {
            CleanupPresentationRoot(state: state)
                .environment(\.controlActiveState, .inactive)
                .alert(state.confirmation?.title ?? "", isPresented: Binding(
                    get: { state.confirmation != nil }, set: { visible in
                        if !visible {
                            let id = state.confirmation?.id
                            DispatchQueue.main.async {
                                if let id, state.confirmation?.id == id { state.cancelCleanupConfirmation() }
                            }
                        }
                    }), presenting: state.confirmation) { accepted in
                        Button(accepted.confirmLabel, role: .destructive) { state.runConfirmation(accepted) }
                        Button(L10n.shared.t("common.cancel"), role: .cancel) { state.cancelCleanupConfirmation() }
                    } message: { Text($0.message) }
        }
    }
}

extension UUID { var id: UUID { self } }
struct AgentsTabView: View { let state: AppState; var body: some View { EmptyView() } }
struct AnalyzeTabView: View { let state: AppState; var body: some View { EmptyView() } }
struct UninstallTabView: View { let state: AppState; var body: some View { EmptyView() } }
struct DevEnvTabView: View { let state: AppState; var body: some View { EmptyView() } }
struct ProcessesTabView: View { let state: AppState; var body: some View { EmptyView() } }
struct PortsTabView: View { let state: AppState; var body: some View { EmptyView() } }
struct TrafficTabView: View { let state: AppState; var body: some View { EmptyView() } }
struct SettingsTabView: View { let state: AppState; var body: some View { EmptyView() } }
struct PermissionCenterView: View { let state: AppState; var body: some View { EmptyView() } }
struct AutoCleanupRulesView: View { let state: AppState; var body: some View { EmptyView() } }
struct WhitelistSheet: View { let state: AppState; var body: some View { EmptyView() } }
struct UninstallDataReviewView: View { let state: AppState; let plan: UUID; var body: some View { EmptyView() } }
struct DirectoryTabView: View { init(model: Any) {} ; var body: some View { EmptyView() } }
struct ClipboardHistoryTabView: View { init(manager: Any) {} ; var body: some View { EmptyView() } }

@MainActor
private final class CleanupSelectionState: ObservableObject {
    @Published var enabled = true
    @Published var category = CleanupCategory(name: "A long cleanup category name for selection testing",
        paths: ["/fixture/cache/first.log", "/fixture/cache/second.log"], bytes: 8192,
        pathBytes: ["/fixture/cache/first.log": 6144, "/fixture/cache/second.log": 2048],
        selected: false, source: .core, risk: .safe, reasonKey: "cleanup.risk.safe")
    var scheduleRequests = 0
}

private struct CleanupSelectionRoot: View {
    @ObservedObject var state: CleanupSelectionState
    var body: some View {
        VStack {
            CategoryRowView(category: $state.category, selectionEnabled: state.enabled,
                            onAutoClean: { state.scheduleRequests += 1 })
            Spacer()
        }
        .padding(16)
        .background(Color.glassOpaque)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

@main
struct CleanupPresentationTests {
    /// NSApplication owns activation/key/sheet events in addition to run-loop
    /// sources. Pump only this fixture's queue, with bounded batches and time.
    @MainActor private static func pumpFixtureEvents(until deadline: Date) {
        repeat {
            var remaining = 64
            while remaining > 0, Date() < deadline,
                  let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
                remaining -= 1
            }
            NSApp.updateWindows()
            let next = min(deadline, Date().addingTimeInterval(0.01))
            if next > Date() { RunLoop.main.run(until: next) }
        } while Date() < deadline
    }

    /// Route real mouse events inside this disposable fixture window only.
    /// Fixed fixture coordinates cover the checkbox, title, blank space and sibling buttons.
    @MainActor private static func click(at point: CGPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
        while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp],
                                          until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        pumpFixtureEvents(until: Date().addingTimeInterval(0.15))
    }

    /// Execute only the extracted production reporter; its service/cache hooks
    /// are inert. Reuse the existing fixture event loop and window.
    @MainActor private static func settleCleanupResult(_ state: AppState, _ result: CleanupExecutionResult) {
        var reported = false
        Task {
            await state.reportCleanupResult(result, permanently: true, verified: false, waitingApplications: ["Fixture owner"])
            state.isApplying = false
            reported = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !reported && Date() < deadline { pumpFixtureEvents(until: Date().addingTimeInterval(0.02)) }
        precondition(reported, "The inert production cleanup reporter never completed")
        precondition(state.taskNotice == nil && !state.cleanupRetryAvailable && state.cleanupRuntime.retryAction == nil
            && state.cleanupOutcomeDetails.isEmpty && state.cleanupFailureApplications.isEmpty,
            "A settled cleanup result exposed a failure overlay or manual retry action")
    }

    @MainActor private static func verifySelection(output: URL) {
        let state = CleanupSelectionState()
        let host = NSHostingView(rootView: CleanupSelectionRoot(state: state))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 600, height: 280),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        func settle() { pumpFixtureEvents(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded() }
        settle()
        click(at: CGPoint(x: 300, y: 246), in: window)
        precondition(state.category.allSelected && !state.category.expanded,
                     "Clicking title/blank space must select once without expanding")
        click(at: CGPoint(x: 37, y: 246), in: window)
        precondition(!state.category.selected, "Clicking the checkbox must toggle exactly once")
        click(at: CGPoint(x: 527, y: 246), in: window)
        precondition(state.scheduleRequests == 1 && !state.category.selected && !state.category.expanded,
                     "Scheduling button must perform only its own action")
        click(at: CGPoint(x: 561, y: 246), in: window)
        precondition(state.category.expanded && !state.category.selected && state.scheduleRequests == 1,
                     "Expand button must preserve selection and scheduling")
        settle()
        click(at: CGPoint(x: 400, y: 197), in: window)
        precondition(state.category.selectedPathCount == 1 && state.category.selectedPathBytes == 6144,
                     "Child row blank-space click must select only its path and update bytes")
        precondition(!state.category.isPathSelected(state.category.paths[1]), "Other paths must remain unselected")
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(
            to: output.appendingPathComponent("selection-expanded-partial.png"))
        click(at: CGPoint(x: 300, y: 246), in: window)
        precondition(state.category.allSelected, "Partial row selection must select the full category")
        state.enabled = false
        settle()
        click(at: CGPoint(x: 300, y: 246), in: window)
        precondition(state.category.allSelected, "Disabled row clicks must not mutate selection")
        click(at: CGPoint(x: 527, y: 246), in: window)
        precondition(state.scheduleRequests == 1, "Disabled schedule button must not execute")
        click(at: CGPoint(x: 561, y: 246), in: window)
        precondition(!state.category.expanded && state.category.allSelected, "Details remain independent while busy")
        state.enabled = true
        state.category.risk = .protected
        state.category.selected = false
        settle()
        click(at: CGPoint(x: 300, y: 246), in: window)
        precondition(!state.category.selected && state.category.expanded,
                     "Protected row clicks must show details without becoming selected")
        click(at: CGPoint(x: 400, y: 197), in: window)
        precondition(!state.category.selected, "Read-only paths must not act like checkboxes")
        let readOnlyBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: readOnlyBitmap)
        try! readOnlyBitmap.representation(using: .png, properties: [:])!.write(
            to: output.appendingPathComponent("protected-readonly-expanded.png"))
        print("Cleanup selection interaction: title/blank area, checkbox, scheduling, expand, child paths, partial selection, busy and protected guards passed")
    }

    @MainActor private static func verifyWorkingFeedback(_ host: NSView, progress: CleanupTaskProgress,
                                                         expectedPhase: String, output: URL? = nil) {
        let display = NoriCleanupTaskStage.WorkingFeedback(progress: progress, statusText: "Fixture status")
        precondition(display.phaseKey == expectedPhase, "Incorrect working phase snapshot")
        precondition(display.handled == progress.completed && display.total == progress.total, "Incorrect target counts")
        precondition(display.detail == progress.currentItem, "Current file/stage detail was discarded")
        precondition(L10n.shared.t(expectedPhase) != expectedPhase, "Phase must have localized copy")
        if progress.phase != .cleaning { precondition(progress.fraction == nil, "Preparation/verification cannot claim a percentage") }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            preconditionFailure("Working stage must produce an actual view drawing")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        precondition(bitmap.bitmapData != nil && bitmap.pixelsWide >= Int(host.bounds.width)
                     && bitmap.pixelsHigh >= Int(host.bounds.height), "Working stage drawing clipped its viewport")
        if let output {
            let file = output.appendingPathComponent("working-\(progress.phase).png")
            try! bitmap.representation(using: .png, properties: [:])!.write(to: file)
            print("Working stage snapshot+draw: \(expectedPhase), \(display.handled)/\(display.total), \(file.path)")
            Darwin.fflush(nil)
        }
    }

    @MainActor private static func verifyWorkingStages(output: URL) {
        let state = AppState()
        state.isApplying = true
        let host = NSHostingView(rootView: CleanupPresentationRoot(state: state))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 760, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        let expectedFrame = window.frame
        let expectedBounds = host.bounds.size
        for (progress, key) in [(CleanupTaskProgress(phase: .preparing, completed: 0, total: 8, currentItem: "Fixture review"), "cleanup.task.preparing"),
                                (CleanupTaskProgress(phase: .cleaning, completed: 3, total: 8, currentItem: "/fixture/cache.bin"), "cleanup.task.cleaning"),
                                (CleanupTaskProgress(phase: .verifying, completed: 8, total: 8, currentItem: "Fixture verification"), "cleanup.task.verifying")] {
            state.cleanupTaskProgress = progress
            pumpFixtureEvents(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            precondition(window.frame == expectedFrame && host.bounds.size == expectedBounds, "Working phase changed viewport geometry")
            verifyWorkingFeedback(host, progress: progress, expectedPhase: key, output: output)
        }
        let fallback = NoriCleanupTaskStage.WorkingFeedback(progress: nil, statusText: "Fixture pending review")
        precondition(fallback.phaseKey == "cleanup.task.preparing" && fallback.handled == 0 && fallback.total == 0
                     && fallback.detail == "Fixture pending review", "Unknown progress must preserve phase/status without an invented total")
        let clamp = NoriCleanupTaskStage.WorkingFeedback(progress: .init(phase: .cleaning, completed: 12, total: 8), statusText: "")
        precondition(clamp.handled == 8, "Handled count must respect the submitted target total")
        print("Working feedback: three phase snapshots, counts/clamp/detail and real view draws passed")
        Darwin.fflush(nil)
    }

    @MainActor private static func verifyWarningConfirmation(output: URL, ancestorAlerts: Bool) {
        print("Starting ordinary AppData confirmation, ancestorAlerts=\(ancestorAlerts)")
        Darwin.fflush(nil)
        let home = NSHomeDirectory()
        let trashPath = home + "/.Trash/nori-presentation-default.cache"
        let residuePath = home + "/Library/Application Support/app.nori.presentation-fixture"
        let trash = CleanupCategory(name: "Fixture default Trash", paths: [trashPath], bytes: 4096,
            pathIdentities: [trashPath: "fixture-trash-identity"], selected: true,
            source: .core, risk: .safe, disposal: .permanentDelete, applyRoute: .genericTrash,
            activityGuard: .none, reasonKey: "cleanup.risk.safe")
        let residue = CleanupCategory(name: "Fixture ordinary app data", paths: [residuePath], bytes: 16384,
            pathIdentities: [residuePath: "fixture-residue-identity"], selected: true,
            source: .core, risk: .warning, disposal: .permanentDelete, applyRoute: .genericTrash,
            activityGuard: .appData, reasonKey: "cleanup.risk.protectedContent")
        precondition(residue.isAppDataReview && residue.source != .appLeftover,
                     "The native confirmation regression must cover ordinary AppData, not uninstall leftovers")
        let state = AppState()
        state.categories = [residue, trash]
        state.cleanupScanComplete = true
        state.selectedTab = ancestorAlerts ? 0 : 1
        let host = NSHostingView(rootView: CleanupConfirmationFixtureRoot(state: state, ancestorAlerts: ancestorAlerts))
        host.sizingOptions = []
        let frame = CGRect(x: 80, y: 80, width: 760, height: 620)
        let window: NSWindow = ancestorAlerts
            ? NoriMainWindow(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        if ancestorAlerts {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.makeKeyAndOrderFront(nil)
            if #available(macOS 14.0, *) { NSApp.activate() }
            else { NSApp.activate(ignoringOtherApps: true) }
        } else { window.orderBack(nil) }
        defer { window.close() }
        func settle() { pumpFixtureEvents(until: Date().addingTimeInterval(0.25)); host.layoutSubtreeIfNeeded() }
        func sheet() -> NSWindow? {
            let deadline = Date().addingTimeInterval(5)
            while window.attachedSheet?.isVisible != true && Date() < deadline { settle() }
            return window.attachedSheet
        }
        func button(in view: NSView, title: String) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap { button(in: $0, title: title) }.first
        }
        settle()
        if ancestorAlerts {
            let deadline = Date().addingTimeInterval(3)
            while (!window.isKeyWindow || !NSApp.isActive) && Date() < deadline { settle() }
            print("Actual fixture activation: key=\(window.isKeyWindow) main=\(window.isMainWindow) active=\(NSApp.isActive) runningActive=\(NSRunningApplication.current.isActive) visible=\(window.isVisible)")
            Darwin.fflush(nil)
            precondition(window.isKeyWindow && NSApp.isActive, "Actual MainWindow fixture must use a key, active window")
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            let nativeGlassAvailable: Bool
            if #available(macOS 26.0, *) { nativeGlassAvailable = !reduceTransparency }
            else { nativeGlassAvailable = false }
            print("Actual MainWindow coverage: key=true active=true nativeGlass=\(nativeGlassAvailable) fullAnimations=\(!reduceMotion) reduceTransparency=\(reduceTransparency)")
            Darwin.fflush(nil)
            state.selectedTab = 1 // Exercise production AnimatedTabContent rather than disabling transitions.
            pumpFixtureEvents(until: Date().addingTimeInterval(0.7))
            host.layoutSubtreeIfNeeded()
        }
        precondition(state.categories[0].selected && state.categories[1].selected && state.cleanupRequests == 0)
        for (name, point) in [("center", CGPoint(x: 680, y: 28)), ("pill-edge", CGPoint(x: 738, y: 28))] {
            let before = state.pageCleanupRequests
            click(at: point, in: window)
            guard let cancellationSheet = sheet(), let content = cancellationSheet.contentView,
                  let cancel = button(in: content, title: L10n.shared.t("common.cancel")),
                  let cancelledRequest = state.confirmation else {
                preconditionFailure("Warning confirmation did not present: \(name), actualMainWindow=\(ancestorAlerts)")
            }
            precondition(cancellationSheet.isVisible && cancel.isEnabled && state.pageCleanupRequests == before + 1,
                         "Mouse hit must enter the page exactly once and show a real native confirmation")
            if ancestorAlerts {
                pumpFixtureEvents(until: Date().addingTimeInterval(0.65))
                precondition(state.cleanupTraceEvents.contains { event, fields in
                    event == "ui.confirmation.sheet_probe" && fields["sheet_visible"] == "true"
                        && fields["confirmation_id"] == cancelledRequest.id.uuidString
                }, "The production attached-sheet probe did not witness the visible confirmation")
            }
            cancel.performClick(nil)
            let deadline = Date().addingTimeInterval(3)
            while window.attachedSheet != nil && Date() < deadline { settle() }
            cancelledRequest.onConfirm() // A late callback after Cancel must remain inert.
            settle()
            precondition(window.attachedSheet == nil && state.cleanupRequests == 0,
                         "Cancel or its late callback dispatched cleanup")
            print("Native \(name) click/cancel passed, actualMainWindow=\(ancestorAlerts), dispatch=0")
            Darwin.fflush(nil)
        }
        if ancestorAlerts {
            state.taskNotice = .init(message: "Fixture blocking dialog")
            settle()
            let before = state.pageCleanupRequests
            click(at: CGPoint(x: 680, y: 28), in: window)
            precondition(state.pageCleanupRequests == before && state.cleanupButtonBlockReason == "modal_active",
                         "An active MainWindow overlay allowed a footer dispatch")
            state.taskNotice = nil
            pumpFixtureEvents(until: Date().addingTimeInterval(0.7))
            host.layoutSubtreeIfNeeded()
        }
        let acceptanceTraceStart = state.cleanupTraceEvents.count
        click(at: CGPoint(x: 738, y: 28), in: window)
        guard let confirmationSheet = sheet(), let content = confirmationSheet.contentView,
              let confirm = button(in: content, title: L10n.shared.t("cleanup.appData.confirm.action")) else {
            preconditionFailure("Warning confirmation did not reopen")
        }
        precondition(confirmationSheet.isVisible && confirm.isEnabled, "Confirm must be a real visible native alert action")
        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(
            to: output.appendingPathComponent("warning-confirmation-ancestors-\(ancestorAlerts).png"))
        let extraPath = "/fixture/new-selection"
        state.categories = [CleanupCategory(name: "Later selection", paths: [extraPath], bytes: 32,
            pathIdentities: [extraPath: "new-identity"], selected: true, source: .core, risk: .safe)]
        settle()
        precondition(confirmationSheet.isVisible, "Changing the current selection destroyed the stable confirmation presenter")
        confirm.performClick(nil)
        settle()
        precondition(state.cleanupRequests == 1 && state.cleanupDispatches.count == 1, "Confirm must dispatch exactly once")
        let acceptedEvents = state.cleanupTraceEvents.dropFirst(acceptanceTraceStart).map { $0.0 }
        precondition(acceptedEvents.contains("submission.accepted")
                     && !acceptedEvents.contains("confirmation.cancelled")
                     && !acceptedEvents.contains("confirmation.stale_callback")
                     && !acceptedEvents.contains("ui.confirmation.cancelled"),
                     "Binding false raced Confirm and cancelled or invalidated its submission")
        if ancestorAlerts { precondition(acceptedEvents.contains("ui.confirmation.accepted")) }
        print("Confirm ordering actualMainWindow=\(ancestorAlerts): \(acceptedEvents.joined(separator: " -> "))")
        Darwin.fflush(nil)
        precondition(state.cleanupDispatches[0][residue.id] == [residuePath]
                     && state.cleanupDispatches[0][trash.id] == [trashPath] && state.cleanupDispatches[0].count == 2,
                     "Confirmation must preserve the clicked snapshot instead of the later selection")
        print("Ordinary AppData confirmation: cancel=0, confirm=1, mixed scope preserved, ancestorAlerts=\(ancestorAlerts)")
        Darwin.fflush(nil)
    }

    @MainActor private static func verifyLeftoversDirectDispatch() {
        let path = "/fixture/uninstalled-app/data"
        let unselected = "/fixture/uninstalled-app/other"
        let safePath = "/fixture/default-safe-cache"
        var leftover = CleanupCategory(name: "Fixture uninstall leftovers", paths: [path, unselected], bytes: 8192,
            pathBytes: [path: 4096, unselected: 4096],
            pathIdentities: [path: "leftover-original", unselected: "other-original"], selected: false,
            source: .appLeftover, risk: .warning, disposal: .permanentDelete, applyRoute: .genericTrash,
            activityGuard: .appData, reasonKey: "cleanup.risk.uninstallData")
        leftover.uninstallDataOwner = .init(kind: .application, name: "Fixture retired app",
            bundleID: "app.nori.direct-fixture", installationPath: "/fixture/Retired.app")
        leftover = leftover.selectingPaths([path])
        let safe = CleanupCategory(name: "Fixture safe cache", paths: [safePath], bytes: 4096,
            pathIdentities: [safePath: "safe-original"], selected: true, source: .core, risk: .safe)
        let state = AppState()
        state.categories = [leftover, safe]
        state.cleanupScanComplete = true
        state.onCleanupSnapshotCaptured = { [weak state] in
            guard let state else { return }
            var later = leftover.selectingPaths([unselected])
            later.pathIdentities[path] = "replacement-identity"
            state.categories = [later] // Must not redirect the already-clicked request.
        }
        let host = NSHostingView(rootView: MainWindowView(state: state))
        host.sizingOptions = []
        let window = NoriMainWindow(contentRect: CGRect(x: 80, y: 80, width: 760, height: 620),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        defer { window.close() }
        let deadline = Date().addingTimeInterval(3)
        while (!window.isKeyWindow || !NSApp.isActive) && Date() < deadline {
            pumpFixtureEvents(until: Date().addingTimeInterval(0.1))
        }
        precondition(window.isKeyWindow && NSApp.isActive, "Direct leftovers case requires the real active MainWindow")
        pumpFixtureEvents(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        click(at: CGPoint(x: 680, y: 28), in: window)
        pumpFixtureEvents(until: Date().addingTimeInterval(0.6))
        precondition(state.pageCleanupRequests == 1 && state.cleanupRequests == 1 && state.cleanupDispatches.count == 1,
                     "One real footer click must directly dispatch uninstall leftovers exactly once")
        precondition(state.confirmation == nil && window.attachedSheet == nil
                     && !state.cleanupTraceEvents.contains { $0.0 == "ui.confirmation.requested" || $0.0 == "ui.sheet.will_begin" },
                     "Uninstall leftovers unexpectedly opened a confirmation")
        precondition(state.cleanupDispatches[0] == [leftover.id: Set([path]), safe.id: Set([safePath])]
                     && state.cleanupDispatchIdentities[0] == [leftover.id: [path: "leftover-original"], safe.id: [safePath: "safe-original"]],
                     "Direct dispatch expanded selection or rebound the clicked snapshot's identities")
        for result in [CleanupExecutionResult(removed: 1, failed: 1, reclaimedBytes: 512),
                       CleanupExecutionResult(failed: 1, messages: ["Fixture exhausted all automatic attempts"])] {
            state.cleanupRetryAvailable = true
            state.cleanupRuntime.retryAction = { preconditionFailure("UI reporter must clear legacy retry actions") }
            state.cleanupTaskProgress = .init(phase: .verifying, completed: 2, total: 2)
            settleCleanupResult(state, result)
            pumpFixtureEvents(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            precondition(state.cleanupCompletedCount == result.removed && state.cleanupReclaimedBytes == result.reclaimedBytes
                && state.cleanupOutcomeMood == (result.removed > 0 ? .success : nil)
                && state.cleanupButtonBlockReason == nil && window.attachedSheet == nil,
                "Actual MainWindow result reporting blocked operation or changed actual removed/byte accounting")
        }
        print("Actual MainWindow uninstall leftovers: direct frozen dispatch; partial/exhausted report settles with no modal/retry/attention")
        Darwin.fflush(nil)
    }

    @MainActor private static func verifyFailureDialog(output: URL) {
        var notices = TaskFeedbackQueue()
        var recoveryCount = 0
        let notice = TaskFeedbackNotice(message: "Fixture 应用卸载未完成",
            details: ["/Applications/Fixture.app", "/fixture/selected-data"],
            detailsAreLocalized: true, recoveryLabel: L10n.shared.t("uninstall.recovery.action"),
            recoveryMessage: L10n.shared.t("uninstall.recovery.message"), recoveryIsDestructive: true,
            onRetry: { recoveryCount += 1 })
        notices.enqueue(notice)
        for size in [CGSize(width: 760, height: 620), CGSize(width: 560, height: 520)] {
            let view = TaskFeedbackView(notice: notice, dismiss: { notices.dismiss() }, retry: {
                notices.dismiss()
                notice.onRetry?()
            }).background(Color.glassOpaque).frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                preconditionFailure("Recovery dialog must render")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(
                to: output.appendingPathComponent("uninstall-recovery-\(Int(size.width)).png"))
            precondition(notices.active?.id == notice.id && recoveryCount == 0,
                         "Presenting or resizing a failure dialog must never start force cleanup")
        }
        print("Recovery dialog rendered at standard and constrained sizes without executing cleanup")
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let originalLanguage = L10n.shared.language
        L10n.shared.setLanguage(.zhHans)
        defer { L10n.shared.setLanguage(originalLanguage) }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NORI_PRESENTATION_OUTPUT"]
                         ?? NSTemporaryDirectory() + "nori-cleanup-presentation-renders", isDirectory: true)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["NORI_CONFIRMATION_ONLY"] == "1" {
            // Even an unexpected native modal loop must not wait for a human.
            // This terminates only this disposable fixture process.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) {
                FileHandle.standardError.write(Data("Confirmation fixture timed out; exiting disposable process.\n".utf8))
                Darwin._exit(124)
            }
            verifyWarningConfirmation(output: output, ancestorAlerts: false)
            verifyWarningConfirmation(output: output, ancestorAlerts: true)
            verifyLeftoversDirectDispatch()
            verifyWorkingStages(output: output)
            print("Cleanup confirmation-only fixture passed; no production services or deletion called")
            return
        }
        verifyFailureDialog(output: output)
        let fallback = NoriCleanupTaskStage.WorkingFeedback(progress: nil, statusText: "Fixture preparing")
        precondition(fallback.phaseKey == "cleanup.task.preparing" && fallback.total == 0
                     && fallback.detail == "Fixture preparing", "Unknown totals need real phase/status, not a fabricated count")
        verifyWarningConfirmation(output: output, ancestorAlerts: false)
        verifyWarningConfirmation(output: output, ancestorAlerts: true)
        verifyLeftoversDirectDispatch()
        let state = AppState()
        let host = NSHostingView(rootView: CleanupPresentationRoot(state: state))
        host.sizingOptions = []
        let visible = (NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)).insetBy(dx: 24, dy: 24)
        let size = CGSize(width: min(940, visible.width), height: min(720, visible.height))
        let frame = CGRect(x: (visible.midX - size.width / 2).rounded(.down),
                           y: (visible.midY - size.height / 2).rounded(.down),
                           width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.minSize = CGSize(width: min(760, size.width), height: min(620, size.height))
        window.contentView = host
        window.setFrame(frame, display: false)
        window.orderBack(nil)
        defer { window.close() }

        func render(_ phase: String, delay: TimeInterval = 0.4) {
            host.layoutSubtreeIfNeeded()
            pumpFixtureEvents(until: Date().addingTimeInterval(delay))
            host.layoutSubtreeIfNeeded()
            precondition(window.frame == frame && host.bounds.size == size,
                         "Cleanup \(phase) resized the retained window or its content area: window=\(window.frame), expected=\(frame), host=\(host.bounds), size=\(size)")
            precondition(visible.contains(window.frame),
                         "Cleanup \(phase) must remain inside its owning screen")
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                preconditionFailure("Cleanup \(phase) must produce a renderable view")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            precondition(bitmap.bitmapData != nil && bitmap.pixelsWide >= Int(size.width)
                         && bitmap.pixelsHigh >= Int(size.height),
                         "Cleanup \(phase) must render the whole content area")
            let file = output.appendingPathComponent(phase.replacingOccurrences(of: " ", with: "-") + ".png")
            try! bitmap.representation(using: .png, properties: [:])!.write(to: file)
            print("Rendered \(phase): \(file.path)")
        }

        render("idle")
        state.isCleanupScanning = true
        state.cleanupProgress = CleanupScanProgress(phase: "正在查找缓存目录…", currentPath: "/Users/fixture/Library/Caches")
        render("scanning")
        state.cleanupProgress = CleanupScanProgress(phase: "正在扫描", completed: 18, total: 64,
            currentPath: "/Users/fixture/Library/Caches/a-long-directory-name/another-directory/current-file.cache")
        render("scanning-progress")
        state.cleanupScanMode = .deep
        render("deep-scanning-progress")

        let path = "/fixture/cache/session.log"
        state.categories = [CleanupCategory(name: "Fixture cache", paths: [path], bytes: 4096,
            pathIdentities: [path: "fixture-identity"], selected: true, source: .core,
            risk: .safe, disposal: .permanentDelete, applyRoute: .genericTrash,
            activityGuard: .none, reasonKey: "cleanup.risk.safe")]
        state.isCleanupScanning = false
        state.cleanupScanComplete = true
        render("scan results")
        let groupY = window.contentLayoutRect.maxY - 22
        click(at: CGPoint(x: size.width * 0.6, y: groupY), in: window)
        precondition(!state.categories[0].selected, "Group title/blank area must toggle selection")
        click(at: CGPoint(x: size.width - 39, y: groupY), in: window)
        precondition(!state.categories[0].selected, "Group expansion must not toggle selection")
        click(at: CGPoint(x: size.width - 39, y: groupY), in: window)
        precondition(!state.categories[0].selected, "Group collapse must not toggle selection")
        click(at: CGPoint(x: size.width * 0.6, y: groupY), in: window)
        precondition(state.categories[0].allSelected, "Group selection must remain independent")
        verifySelection(output: output)

        let smallInventory = state.categories
        let trashPaths = (0..<100_000).map { NSHomeDirectory() + "/.Trash/presentation-fixture-\($0).cache" }
        let largeTrash = CleanupCategory(name: "Large Trash fixture", paths: trashPaths,
            bytes: 100_000, pathIdentities: [:], selected: true, source: .core,
            risk: .safe, disposal: .permanentDelete, activityGuard: .none)
        precondition(CleanupGroupBucket(category: largeTrash) == .trash,
                     "A large Trash inventory keeps its display bucket")
        var escapedTrash = largeTrash
        escapedTrash.paths = [NSHomeDirectory() + "/.Trash/../keep.cache"]
        precondition(CleanupGroupBucket(category: escapedTrash) != .trash,
                     "A normalized path outside Trash cannot enter the Trash group")
        let renderStarted = ProcessInfo.processInfo.systemUptime
        state.categories = [largeTrash] + smallInventory
        render("large-trash-results")
        let renderSeconds = ProcessInfo.processInfo.systemUptime - renderStarted
        precondition(renderSeconds < 15,
                     "100000-item results must render without blocking for tens of seconds: \(renderSeconds)s")
        print("100000-item Trash result render: \(renderSeconds)s")
        state.categories = smallInventory

        state.isApplying = true
        state.statusText = "Fixture cleanup in progress"
        state.cleanupTaskProgress = CleanupTaskProgress(phase: .preparing, completed: 0, total: 8,
                                                       currentItem: "正在核对文件和使用状态")
        render("preparing")
        verifyWorkingFeedback(host, progress: state.cleanupTaskProgress!, expectedPhase: "cleanup.task.preparing")
        state.cleanupTaskProgress = CleanupTaskProgress(phase: .cleaning, completed: 3, total: 8,
                                                       currentItem: "Google · Cache/Storage")
        render("cleaning-progress")
        verifyWorkingFeedback(host, progress: state.cleanupTaskProgress!, expectedPhase: "cleanup.task.cleaning")
        state.cleanupTaskProgress = CleanupTaskProgress(phase: .verifying, completed: 8, total: 8,
                                                       currentItem: "重新扫描剩余项目")
        render("verifying")
        verifyWorkingFeedback(host, progress: state.cleanupTaskProgress!, expectedPhase: "cleanup.task.verifying")

        settleCleanupResult(state, .init(removed: 7, failed: 1, reclaimedBytes: 128 * 1024))
        precondition(state.cleanupOutcomeMood == .success && state.cleanupCompletedCount == 7
            && state.cleanupReclaimedBytes == 128 * 1024)
        render("partial-cleanup-silent")

        settleCleanupResult(state, .init(failed: 3, messages: ["Fixture exhausted automatic attempts"]))
        precondition(state.cleanupOutcomeMood == nil && !state.cleanupCelebrating
            && state.cleanupCompletedCount == 0 && state.cleanupReclaimedBytes == 0)
        render("exhausted-cleanup-ready")
        state.categories = []
        render("exhausted-cleanup-empty")

        state.cleanupOutcomeMood = .success
        state.cleanupOutcomeDetails = []
        state.cleanupFailureApplications = []
        state.cleanupCelebrating = true
        state.cleanupCompletedCount = 8
        state.cleanupReclaimedBytes = 12 * 1024 * 1024
        state.cleanupFeedbackID += 1
        render("confirmed-success")
        precondition(state.cleanupCelebrating, "The success stage must remain visible for its one-shot animation")
        pumpFixtureEvents(until: Date().addingTimeInterval(NoriMotion.successFeedbackDuration + 0.5))
        precondition(!state.cleanupCelebrating && state.celebrationFinishes == 1 && state.cleanupOutcomeMood == .success,
                     "Success must return to the idle SVG after its animation finishes")
        render("dismissed-success")

        // An empty inventory falls all the way back to the idle placeholder.
        state.categories = []
        render("dismissed-success-empty")


        // A new quiet result cancels the old stage timer and stays ready.
        state.cleanupCelebrating = true
        state.cleanupOutcomeMood = .success
        state.cleanupFeedbackID += 1
        render("success-before-interruption", delay: 0.1)
        settleCleanupResult(state, .init(failed: 1))
        render("ready-after-interruption")
        pumpFixtureEvents(until: Date().addingTimeInterval(NoriMotion.successFeedbackDuration + 0.5))
        precondition(state.cleanupOutcomeMood == nil && !state.cleanupCelebrating && state.celebrationFinishes == 1,
                     "An obsolete celebration changed a later quiet ready state")
        precondition(state.scanRequests == 0 && state.cleanupRequests == 0
                     && state.rescanRequests == 0 && state.cancelRequests == 0 && state.retryRequests == 0,
                     "Presentation fixtures must never initiate scan or deletion actions")
        print("Cleanup presentation layout: real idle/scanning/results/cleaning/partial/failure/success views retained \(Int(size.width))×\(Int(size.height)) geometry and rendered within the screen")
    }
}
