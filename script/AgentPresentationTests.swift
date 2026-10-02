import AppKit
import SwiftUI

private struct AgentPresentationRoot: View {
    @ObservedObject var state: AppState
    var body: some View {
        AgentsTabView(state: state)
            .background(Color.glassOpaque)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

@main
struct AgentPresentationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let language = L10n.shared.language
        L10n.shared.setLanguage(.zhHans)
        defer { L10n.shared.setLanguage(language) }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NORI_AGENT_PRESENTATION_OUTPUT"]
            ?? NSTemporaryDirectory() + "nori-agent-presentation-renders", isDirectory: true)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let visible = (NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800))
            .insetBy(dx: 24, dy: 24)
        for proposed in [CGSize(width: 940, height: 720), CGSize(width: 520, height: 360)] {
            let state = AppState()
            let size = CGSize(width: min(proposed.width, visible.width), height: min(proposed.height, visible.height))
            let frame = CGRect(x: (visible.midX - size.width / 2).rounded(.down),
                               y: (visible.midY - size.height / 2).rounded(.down),
                               width: size.width, height: size.height)
            let host = NSHostingView(rootView: AgentPresentationRoot(state: state))
            host.sizingOptions = []
            let window = NSWindow(contentRect: frame,
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.contentView = host
            window.setFrame(frame, display: false)
            window.orderBack(nil)
            func render(_ phase: String, delay: TimeInterval = 0.4) {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(delay))
                host.layoutSubtreeIfNeeded()
                precondition(window.frame == frame && host.bounds.size == size && visible.contains(window.frame),
                             "Agent \(phase) overflowed its retained \(size) viewport: window=\(window.frame), expected=\(frame), host=\(host.bounds), screen=\(visible)")
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    preconditionFailure("Agent view must render")
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let file = output.appendingPathComponent("\(Int(size.width))-\(Int(size.height))-\(phase).png")
                try! bitmap.representation(using: .png, properties: [:])!.write(to: file)
                print("Rendered \(phase): \(file.path)")
            }
            render("idle")
            state.agentScanning = true
            state.agentStatus = "正在扫描 Agent 数据"
            render("scanning")
            state.agentScanning = false
            state.agentHasScanned = true
            state.agentScanComplete = true
            let category = CleanupCategory(name: "可再生缓存", paths: ["/fixture/agent/cache"], bytes: 128 * 1024,
                pathIdentities: [:], selected: true, source: .aiCache, risk: .safe,
                disposal: .permanentDelete, applyRoute: .aiTrash, activityGuard: .openFile,
                reasonKey: "cleanup.risk.rebuildableCache")
            state.agentCategories = [category]
            state.agentGroups = [.init(id: "codex", name: "Codex", documented: true, categoryIDs: [category.id])]
            render("results")
            state.agentApplying = true
            state.agentCleanupProgress = .init(phase: .cleaning, completed: 3, total: 7,
                currentItem: "/fixture/agent/cache/a-long-cache-directory/actual-file")
            render("working")
            state.agentApplying = false
            state.agentCleanupHasFeedback = true
            state.agentOutcomeMood = .attention
            state.agentFeedbackID += 1
            state.agentStatus = "清理失败"
            state.agentOutcomeDetails = (1...12).map {
                "Failed to remove /fixture/agent/cache/a-very-long-cache-directory/another-directory/item-\($0).bin: Operation not permitted"
            }
            state.agentRetryAvailable = true
            render("total-failure")
            state.agentOutcomeMood = .success
            state.agentCelebrating = true
            state.agentCompletedCount = 3
            state.agentReclaimedBytes = 8 * 1024 * 1024
            state.agentOutcomeDetails = []
            state.agentFeedbackID += 1
            render("partial-success")
            let token = state.agentFeedbackID
            RunLoop.main.run(until: Date().addingTimeInterval(NoriMotion.successFeedbackDuration + 0.5))
            precondition(!state.agentCelebrating && state.agentFeedbackID == token,
                         "Agent success must return to idle after its feedback animation")
            render("dismissed-success")
            precondition(state.scanRequests == 0 && state.cleanupRequests == 0 && state.retryRequests == 0,
                         "Rendering must never start real cleanup or scan actions")
            window.close()
        }
        print("Agent presentation: actual view rendered at normal and constrained sizes; success returned to idle, failure remained inline")
    }
}
