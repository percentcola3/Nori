import AppKit
import SwiftUI

/// This entry point is compiled only by capture_readme_screenshots.sh.
/// It never launches Nori's AppDelegate or any real scan/cleanup/monitor.
@MainActor
enum ReadmeFixture {
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NORI_README_FIXTURE_ROOT"]!)
    static let defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "com.nori.readme-fixtures")!
        defaults.removePersistentDomain(forName: "com.nori.readme-fixtures")
        return defaults
    }()
    static let sampleDate = Date(timeIntervalSince1970: 1_790_827_200)

    static func choose(_ english: String, _ chinese: String) -> String {
        L10n.shared.resolved == .en ? english : chinese
    }

    static func category(_ english: String, _ chinese: String, path: String, gb: Double,
                         source: CleanupSource = .core, risk: CleanupRisk = .safe,
                         reason: String = "cleanup.risk.rebuildableCache") -> CleanupCategory {
        CleanupCategory(name: choose(english, chinese), paths: [path], bytes: UInt64(gb * 1_000_000_000),
                        pathIdentities: [path: "readme-fixture"], selected: risk == .safe,
                        source: source, risk: risk, disposal: .permanentDelete,
                        applyRoute: source == .core ? .genericTrash : .developerCacheTrash,
                        activityGuard: .openFile, reasonKey: reason)
    }

    static func makeState() -> AppState {
        let state = AppState()
        state.mainWindowVisible = true
        state.metrics = MetricsSnapshot(cpuPercent: 14.2, logicalCPUCount: 12, physicalCPUCount: 12,
            memoryPercent: 48, memoryUsedBytes: 15_360_000_000, memoryTotalBytes: 32_000_000_000,
            memoryAvailableBytes: 16_640_000_000, memoryPressure: "normal", diskFreeBytes: 236_000_000_000,
            diskUsedPercent: 54, batteryPercent: 84, batteryHealthPercent: 99, batteryCycleCount: 62,
            networkRxMBps: 3.6, networkTxMBps: 0.8, healthScore: 96)
        state.islandItems = [.cpu, .memory, .network]
        state.topMemoryApps = [
            ("Xcode", 2.4), ("Safari", 1.3), ("Terminal", 0.6), ("Finder", 0.3)
        ].enumerated().map { index, value in
            ProcessRow(pid: Int32(100 + index), startIdentity: "readme", name: value.0,
                       detail: "", isNativeApp: true, cpu: 2, mem: value.1 / 32 * 100,
                       memBytes: UInt64(value.1 * 1_000_000_000))
        }
        state.networkHistory = [0.3, 0.8, 0.5, 1.1, 0.4, 0.7, 1.5, 1.2, 2.1, 1.7, 3.0, 2.2, 2.8, 3.6]
        state.networkUploadHistory = [0.2, 0.3, 0.1, 0.4, 0.2, 0.3, 0.6, 0.4, 0.7, 0.3, 0.6, 0.5, 0.7, 0.8]
        state.categories = [
            category("Xcode Derived Data", "Xcode 构建缓存", path: "/Users/demo/Library/Developer/Xcode/DerivedData", gb: 18.4, source: .xcodeCache),
            category("npm cache", "npm 缓存", path: "/Users/demo/.npm/_cacache", gb: 5.8, source: .developerCache),
            category("pip cache", "pip 缓存", path: "/Users/demo/Library/Caches/pip", gb: 2.3, source: .developerCache),
            category("Browser caches", "浏览器缓存", path: "/Users/demo/Library/Caches/com.apple.Safari", gb: 3.2),
            category("Application caches", "应用缓存", path: "/Users/demo/Library/Caches", gb: 2.1),
            category("Old application logs", "旧应用日志", path: "/Users/demo/Library/Logs", gb: 0.8),
            category("Removed app caches", "已卸载应用缓存", path: "/Users/demo/Library/Caches/com.example.OldApp", gb: 1.6, source: .appLeftover),
        ]
        state.devEnvEntries = [
            DevEnvEntry(bytes: 210_000_000, kind: "current", name: "nvm · v22.14.0", path: "/Users/demo/.nvm/versions/node/v22.14.0", relatedBytes: 0, relatedPath: nil),
            DevEnvEntry(bytes: 480_000_000, kind: "runtime", name: "nvm · v20.18.0", path: "/Users/demo/.nvm/versions/node/v20.18.0", relatedBytes: 160_000_000, relatedPath: "/Users/demo/.nvm/versions/node/v20.18.0/lib/node_modules"),
        ]
        state.devEnvSelection = [state.devEnvEntries[1].path]
        state.gcActions = [
            GcAction(id: "Homebrew", command: "brew cleanup --prune=all", bytes: 1_900_000_000),
            GcAction(id: "npm", command: "npm cache clean --force", bytes: 5_800_000_000),
            GcAction(id: "pip", command: "pip cache purge", bytes: 2_300_000_000),
        ]

        let codex = category("Codex logs", "Codex 日志", path: "/Users/demo/.codex/log", gb: 0.42,
                             source: .aiCache, reason: "agents.reason.rebuildable")
        let claude = category("Claude Code session history", "Claude Code 会话历史", path: "/Users/demo/.claude/projects/demo-project/session.jsonl", gb: 1.8,
                              source: .aiSession, risk: .warning, reason: "agents.reason.review")
        let cursor = category("Cursor caches", "Cursor 缓存", path: "/Users/demo/Library/Caches/com.todesktop.230313mzl4w4u92", gb: 0.86,
                              source: .aiCache, reason: "agents.reason.rebuildable")
        state.agentCategories = [codex, claude, cursor]
        state.agentGroups = [
            AgentGroupSummary(id: "codex", name: "Codex CLI", documented: true, orphaned: false, categoryIDs: [codex.id], skillIDs: [], serverIDs: [], bytes: codex.bytes),
            AgentGroupSummary(id: "claude", name: "Claude Code", documented: true, orphaned: false, categoryIDs: [claude.id], skillIDs: [], serverIDs: [], bytes: claude.bytes),
            AgentGroupSummary(id: "cursor", name: "Cursor", documented: true, orphaned: false, categoryIDs: [cursor.id], skillIDs: [], serverIDs: [], bytes: cursor.bytes),
            AgentGroupSummary(id: "shared", name: choose("Shared Skills", "共享 Skills"), documented: true, orphaned: false, categoryIDs: [], skillIDs: ["demo-skill"], serverIDs: [], bytes: 86_000),
        ]
        state.agentSkills = [AgentSkill(path: "/Users/demo/.agents/skills/swiftui-expert-skill", name: "swiftui-expert-skill",
            summary: choose("SwiftUI interface reviews and native macOS patterns.", "SwiftUI 界面审查与原生 macOS 开发。"),
            directory: "swiftui-expert-skill", usedBy: ["Codex", "Claude Code"], agentID: "shared",
            bytes: 86_000, identity: "readme", linked: false, linkTarget: nil)]
        state.agentHasScanned = true
        state.agentScanComplete = true

        state.autoCleanupRules = [
            AutoCleanupRule(directory: "/Users/demo/Library/Developer/Xcode/DerivedData", policy: .sizeLimit,
                sizeLimitBytes: 15_000_000_000, retentionDays: 14, isRegenerable: true,
                authorizedRootIdentity: "1:2:3", lastRunAt: sampleDate, lastReclaimedBytes: 6_400_000_000,
                executionCount: 8, totalReclaimedBytes: 42_700_000_000),
            AutoCleanupRule(directory: "/Users/demo/Library/Caches/pip", policy: .retentionDays,
                sizeLimitBytes: 2_000_000_000, retentionDays: 30, isRegenerable: true,
                authorizedRootIdentity: "1:2:4", lastRunAt: sampleDate, lastReclaimedBytes: 830_000_000,
                executionCount: 4, totalReclaimedBytes: 3_200_000_000),
        ]
        state.autoCleanupStatus = ""
        let manager = state.clipboardManager
        manager.record(.init(kind: .text, text: choose("Make room for your next idea.", "为下一个灵感腾出空间。"), date: sampleDate))
        manager.togglePinned(manager.entries[0].id)
        manager.record(.init(kind: .url, text: "https://github.com/tw93/Mole", date: sampleDate.addingTimeInterval(-120)))
        manager.record(.init(kind: .text, text: "swift build -c release", date: sampleDate.addingTimeInterval(-240)))
        manager.record(.init(kind: .file, filePaths: ["/Users/demo/Downloads/design-notes.pdf", "/Users/demo/Downloads/nori-icon.png"], date: sampleDate.addingTimeInterval(-360)))
        manager.record(.init(kind: .text, text: choose("Release notes\n• Native macOS experience\n• Review before cleanup\n• Keep your tools tidy", "发布说明\n• 原生 macOS 体验\n• 清理前先确认\n• 保持开发环境整洁"), date: sampleDate.addingTimeInterval(-480)))
        manager.stop()
        return state
    }
}

private struct RuntimeScreenshot: View {
    let state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ReadmeFixture.choose("Developer workspace", "开发者工作台"))
                .font(.system(size: 15, weight: .semibold))
            ScrollView {
                DeveloperRuntimePanel(state: state)
            }
        }
        .padding(20)
        .background { GlassSurface().ignoresSafeArea() }
    }
}

private struct IslandScreenshot: View {
    let state: AppState
    var body: some View {
        FloatingIslandView(state: state, safeTop: 0, hardwareNotch: false,
                           onOpenMain: {}, onHitFrameChange: { _, _ in })
            .padding(.top, 18)
            .background {
                LinearGradient(colors: [Color.surface1, Color.surface3, Color.surface2],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
    }
}

@main
@MainActor
struct ReadmeScreenshots {
    static func settle(_ seconds: Double = 1.2) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func capture<V: View>(_ view: V, size: NSSize, to path: URL, borderless: Bool = false) throws -> NSImage {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: borderless ? [.borderless] : [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Nori"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isOpaque = borderless
        window.backgroundColor = borderless
            ? NSColor(srgbRed: 0.12, green: 0.15, blue: 0.18, alpha: 1) : .clear
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: L10n.shared.resolved == .en ? "en_US" : "zh_CN"))
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.center()
        // Native glass can sample beyond the window bounds. A dedicated
        // opaque backing window ensures that sample contains only a neutral
        // fixture color, never the user's desktop or other application text.
        let backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -80, dy: -80),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.isOpaque = true
        backdrop.backgroundColor = NSColor(srgbRed: 0.12, green: 0.15, blue: 0.18, alpha: 1)
        backdrop.ignoresMouseEvents = true
        backdrop.orderFront(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settle()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        // NSView.cacheDisplay does not capture SwiftUI's window compositor
        // (including native glass) reliably. Capture this exact window only.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let image = NSImage(contentsOf: path) else {
            throw NSError(domain: "ReadmeScreenshot", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Native own-window capture failed. Check screen capture access for the invoking terminal/app."])
        }
        window.orderOut(nil)
        window.close()
        backdrop.orderOut(nil)
        backdrop.close()
        settle(0.08)
        print("Rendered \(path.path)")
        return image
    }

    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        // The renderer has its own bundle identity and fixture suite. The
        // production com.nori.app defaults and clipboard are never read.
        UserDefaults.standard.removePersistentDomain(forName: "com.nori.readme-renderer")
        let folder = CommandLine.arguments[2]
        let language: AppLanguage = folder == "en" ? .en : .zhHans
        let localeIdentifier = folder == "en" ? "en_US" : "zh_CN"
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        UserDefaults.standard.set(localeIdentifier, forKey: "AppleLocale")
        try FileManager.default.createDirectory(at: ReadmeFixture.root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: ReadmeFixture.root.appendingPathComponent("clipboard.json"))
        NSApplication.shared.setActivationPolicy(.accessory)
        do {
            L10n.shared.setLanguage(language)
            let directory = output.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let state = ReadmeFixture.makeState()
            let windowSize = NSSize(width: 1100, height: 760)
            let allCategories = state.categories
            state.categories = []
            let overview = try capture(MainWindowView(state: state), size: windowSize,
                                       to: directory.appendingPathComponent("overview.png"))
            state.categories = allCategories
            _ = try capture(MainWindowView(state: state), size: windowSize,
                            to: directory.appendingPathComponent("cleanup.png"))
            _ = try capture(RuntimeScreenshot(state: state), size: NSSize(width: 940, height: 830),
                            to: directory.appendingPathComponent("developers.png"))
            state.jump(to: .agents)
            _ = try capture(MainWindowView(state: state), size: windowSize,
                            to: directory.appendingPathComponent("agents.png"))
            state.jump(to: .cleanup)
            state.showAutoCleanupSheet = true
            _ = try capture(MainWindowView(state: state), size: windowSize,
                            to: directory.appendingPathComponent("automation.png"))
            state.showAutoCleanupSheet = false
            state.jump(to: .clipboard)
            _ = try capture(MainWindowView(state: state), size: windowSize,
                            to: directory.appendingPathComponent("clipboard.png"))
            let preferences = ScreenshotPreferences(defaults: ReadmeFixture.defaults)
            _ = try capture(ScreenshotEditorView(image: overview, preferences: preferences, onClose: {})
                .background { GlassSurface().ignoresSafeArea() },
                size: NSSize(width: 1100, height: 760),
                to: directory.appendingPathComponent("screenshot.png"))
            _ = try capture(IslandScreenshot(state: state), size: NSSize(width: 500, height: 340),
                            to: directory.appendingPathComponent("island.png"), borderless: true)
        }
        UserDefaults.standard.removePersistentDomain(forName: "com.nori.readme-renderer")
        ReadmeFixture.defaults.removePersistentDomain(forName: "com.nori.readme-fixtures")
    }
}
