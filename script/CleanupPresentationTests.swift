import AppKit
import SwiftUI

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
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
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
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded() }
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

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let originalLanguage = L10n.shared.language
        L10n.shared.setLanguage(.zhHans)
        defer { L10n.shared.setLanguage(originalLanguage) }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NORI_PRESENTATION_OUTPUT"]
                         ?? NSTemporaryDirectory() + "nori-cleanup-presentation-renders", isDirectory: true)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
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
            RunLoop.main.run(until: Date().addingTimeInterval(delay))
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

        state.isApplying = true
        state.statusText = "Fixture cleanup in progress"
        state.cleanupTaskProgress = CleanupTaskProgress(phase: .preparing, completed: 0, total: 8,
                                                       currentItem: "正在核对文件和使用状态")
        render("preparing")
        state.cleanupTaskProgress = CleanupTaskProgress(phase: .cleaning, completed: 3, total: 8,
                                                       currentItem: "Google · Cache/Storage")
        render("cleaning-progress")
        state.cleanupTaskProgress = CleanupTaskProgress(phase: .verifying, completed: 8, total: 8,
                                                       currentItem: "重新扫描剩余项目")
        render("verifying")

        state.isApplying = false
        state.cleanupOutcomeMood = .success
        state.cleanupCelebrating = true
        state.cleanupReclaimedBytes = 128 * 1024
        state.cleanupFeedbackID += 1
        state.cleanupRetryAvailable = true
        state.statusText = "已清理 7 项，1 项需要处理后再次清理"
        state.cleanupFailureApplications = ["Codex", "Google Chrome"]
        state.cleanupOutcomeDetails = ["Codex · sessions：应用正在使用会话文件，已保留。关闭 Codex 后，可重新检查并继续。",
            "Google Chrome · Cache/Storage：部分文件正在被使用；未占用缓存已经清理。"]
        render("partial-cleanup")

        state.cleanupCelebrating = false
        state.cleanupOutcomeMood = .attention
        state.statusText = "清理失败"
        state.cleanupOutcomeDetails = ["暂无更多详情，请重试。"]
        render("failure-short-reasons")
        state.cleanupFailureApplications = []
        state.cleanupOutcomeDetails = (1...12).map { index in
            "缓存项目 \(index)：无法清理 /Users/fixture/Library/Caches/a-long-directory-name/another-directory/cache-\(index).log。系统拒绝访问，请确认文件访问权限后重试。"
        }
        render("failure-long-reasons")

        state.categories = []
        render("failure-no-categories")

        state.cleanupOutcomeMood = .success
        state.cleanupOutcomeDetails = []
        state.cleanupFailureApplications = []
        state.cleanupCelebrating = true
        state.cleanupCompletedCount = 8
        state.cleanupReclaimedBytes = 12 * 1024 * 1024
        state.cleanupFeedbackID += 1
        render("confirmed-success")
        precondition(state.cleanupCelebrating, "The success stage must remain visible for its one-shot animation")
        RunLoop.main.run(until: Date().addingTimeInterval(NoriMotion.successFeedbackDuration + 0.5))
        precondition(!state.cleanupCelebrating && state.celebrationFinishes == 1 && state.cleanupOutcomeMood == .success,
                     "Success must return to the idle SVG after its animation finishes")
        render("dismissed-success")

        // An empty inventory falls all the way back to the idle placeholder.
        state.categories = []
        render("dismissed-success-empty")


        // A new result cancels the old stage timer: it may never dismiss a failure.
        state.cleanupCelebrating = true
        state.cleanupOutcomeMood = .success
        state.cleanupFeedbackID += 1
        render("success-before-interruption", delay: 0.1)
        state.cleanupCelebrating = false
        state.cleanupOutcomeMood = .attention
        state.cleanupFeedbackID += 1
        state.statusText = "后续任务失败，仍需处理"
        render("attention-after-interruption")
        RunLoop.main.run(until: Date().addingTimeInterval(NoriMotion.successFeedbackDuration + 0.5))
        precondition(state.cleanupOutcomeMood == .attention && state.celebrationFinishes == 1,
                     "An obsolete celebration must not replace a subsequent failure with idle")
        precondition(state.scanRequests == 0 && state.cleanupRequests == 0
                     && state.rescanRequests == 0 && state.cancelRequests == 0 && state.retryRequests == 0,
                     "Presentation fixtures must never initiate scan or deletion actions")
        print("Cleanup presentation layout: real idle/scanning/results/cleaning/partial/failure/success views retained \(Int(size.width))×\(Int(size.height)) geometry and rendered within the screen")
    }
}
