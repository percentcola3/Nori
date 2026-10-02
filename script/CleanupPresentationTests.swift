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

@main
struct CleanupPresentationTests {
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
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
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
                         "Cleanup \(phase) resized the retained window or its content area")
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
