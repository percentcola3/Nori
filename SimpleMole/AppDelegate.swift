import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var runtimeTimer: Timer?
    private var autoCleanupTimer: Timer?
    private var isCapturingScreenshot = false

    // 灵动岛：codenotch 式顶部刘海悬浮窗。
    private var islandPanel: NSPanel?
    private var islandHosting: IslandHostingView<FloatingIslandView>?
    private var islandPanelSafeTop: CGFloat?
    private var islandPanelCollapsedWidth: CGFloat?
    private var islandExpanded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        updateStatusItem()

        // 附件应用：启动只驻留菜单栏；点击图标直接打开高级主窗口。
        runtimeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.appState.refreshMetrics()
                self.appState.refreshRuntimeIfNeeded()
                if self.islandExpanded {
                    self.appState.refreshIslandProcesses()
                }
            }
        }
        runtimeTimer?.tolerance = 0.2
        setupScreenshotPipeline()
        // 自动目录规则由应用常驻进程调度；AppState 内部按六小时最小间隔限频。
        autoCleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.appState.runScheduledAutoCleanup() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.appState.runScheduledAutoCleanup()
        }
        // auto 模式下，回到前台时重新解析系统语言。
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in
                L10n.shared.refreshIfAuto()
            }
            .store(in: &observables)
        // 语言切换后重建本地化菜单。
        L10n.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setupMenu() }
            .store(in: &observables)
        setupIslandPanelObservers()
        updateIslandPanel()
    }

    /// 退出必须无条件放行。系统设置的"退出并重新打开"（屏幕录制授权后的
    /// 提示按钮）就是一条普通 quit 事件；若在 sheet 呈现期间被 AppKit 否决
    /// （表现为事件返回 -128"用户已取消"），用户看到的就是"点了没反应"。
    /// 这里先收起全部 sheet 再返回 .terminateNow，保证任何状态下都能退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        appState.dismissAllSheetsForTermination()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoCleanupTimer?.invalidate()
        runtimeTimer?.invalidate()
        HotKeyCenter.shared.unregister()
        MosaicCache.shared.clear()
        appState.trafficMonitor.flushHistoryForTermination()
        appState.stopUninstallQueueForTermination()
        MoleEngine.shared.cancelAll()
    }

    /// 关闭窗口后继续驻留；只有明确退出或系统退出才结束进程。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 从 Finder / Spotlight 再次打开时，唤起主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    /// 截图编辑器独立窗口（新建/复用）。
    private var editorWindow: NSWindow?

    private func setupScreenshotPipeline() {
        NotificationCenter.default.publisher(for: .smTakeScreenshot)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self,
                      !self.isCapturingScreenshot,
                      self.editorWindow?.isVisible != true else { return }
                self.appState.permissionCenter.refresh()
                guard self.appState.permissionCenter.screenRecordingGranted else {
                    self.showMainWindow()
                    self.appState.presentPermissionCenter()
                    return
                }
                self.isCapturingScreenshot = true
                ScreenShotService.captureInteractive { image in
                    self.isCapturingScreenshot = false
                    guard let image else { return }
                    self.openScreenshotEditor(image: image)
                }
            }
            .store(in: &observables)
    }

    private func openScreenshotEditor(image: NSImage) {
        NSApp.activate(ignoringOtherApps: true)
        if editorWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = L10n.shared.t("shot.title")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 640, height: 480)
            window.center()
            observeEditorWindow(window)
            editorWindow = window
        }
        editorWindow?.contentViewController = NSHostingController(
            rootView: ScreenshotEditorView(image: image) { [weak self] in
                self?.closeScreenshotEditor()
            })
        editorWindow?.makeKeyAndOrderFront(nil)
    }

    private func closeScreenshotEditor() {
        editorWindow?.close()
    }

    private func observeEditorWindow(_ window: NSWindow) {
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak window] _ in
                MosaicCache.shared.clear()
                // 关闭后释放原图和笔画；窗口外壳保留用于下次快速复用。
                DispatchQueue.main.async {
                    window?.contentViewController = nil
                }
            }
            .store(in: &observables)
    }

    // MARK: - 菜单

    /// 附件应用没有默认菜单；补一个最小菜单让日志等文本可复制。
    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.title = "Nori"
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.shared.t("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: L10n.shared.t("settings.title"),
                                           action: #selector(openSettings(_:)),
                                           keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.shared.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.shared.t("menu.edit"))
        editMenu.addItem(withTitle: L10n.shared.t("menu.copy"), action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.shared.t("menu.selectAll"), action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.menu = mainMenu
    }

    @objc private func openSettings(_ sender: Any?) {
        showMainWindow()
        DispatchQueue.main.async { [weak self] in
            self?.appState.jump(to: .settings)
        }
    }

    private func menuBarIcon(size: NSSize) -> NSImage? {
        let image = NSImage(size: size)
        for name in ["MenuBarIconTemplate", "MenuBarIconTemplate@2x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else { continue }
            representation.size = size
            image.addRepresentation(representation)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        return image
    }

    /// 菜单栏状态图标按设置装拆：隐藏后入口交给灵动岛。
    private func updateStatusItem() {
        if appState.menuBarIconVisible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                if let image = menuBarIcon(size: NSSize(width: 18, height: 18)) {
                    button.image = image
                }
                button.imageScaling = .scaleProportionallyDown
                button.toolTip = "Nori"
                button.setAccessibilityLabel("Nori")
                button.target = self
                button.action = #selector(openMainWindow(_:))
            }
            statusItem = item
        } else {
            guard let statusItem else { return }
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    // MARK: - 面板液态呈现

    /// AppKit 没有原生弹簧动画：用带轻微过冲的三次贝塞尔逼近 SwiftUI
    /// MoleMotion.press 的回弹手感。
    private static let liquidPresentTiming =
        CAMediaTimingFunction(controlPoints: 0.22, 0.86, 0.26, 1.12)

    private var liquidMotionAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 液态呈现：淡入 + 朝状态栏方向轻推入位（轻微过冲）。
    /// 灵动岛展示时不抢占主窗口焦点。
    private func presentLiquidPanel(_ panel: NSPanel, orderFront: () -> Void) {
        guard liquidMotionAllowed else {
            orderFront()
            return
        }
        let final = panel.frame
        let start = NSRect(x: final.origin.x, y: final.origin.y - 12,
                           width: final.width, height: final.height)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        orderFront()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = Self.liquidPresentTiming
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// 液态收起：淡出下坠后 orderOut，并把帧复位供下次呈现。
    private func dismissLiquidPanel(_ panel: NSPanel?) {
        guard let panel, panel.isVisible else { return }
        guard liquidMotionAllowed else {
            panel.orderOut(nil)
            return
        }
        let final = panel.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(
                NSRect(x: final.origin.x, y: final.origin.y - 8,
                       width: final.width, height: final.height), display: true)
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
            panel?.setFrame(final, display: false)
        })
    }

    @objc private func openMainWindow(_ sender: Any?) {
        showMainWindow()
    }

    // MARK: - 灵动岛

    /// 灵动岛显隐：设置开关驱动；主窗口置前时避让收起。
    private func setupIslandPanelObservers() {
        appState.$islandEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIslandPanel() }
            .store(in: &observables)
        appState.$menuBarIconVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &observables)
        appState.$mainWindowVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIslandPanel() }
            .store(in: &observables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIslandPanel() }
            .store(in: &observables)
    }

    private func updateIslandPanel() {
        guard appState.islandEnabled && !appState.mainWindowVisible else {
            islandExpanded = false
            dismissLiquidPanel(islandPanel)
            return
        }
        // 屏幕参数（刘海带宽/外接屏）变化时重建视图锚定参数。
        if islandPanel == nil
            || islandPanelSafeTop != islandSafeTop
            || islandPanelCollapsedWidth != islandCollapsedWidth {
            createIslandPanel()
        }
        positionIslandPanel()
        if let islandPanel, !islandPanel.isVisible {
            presentLiquidPanel(islandPanel) {
                islandPanel.orderFrontRegardless()
            }
        } else {
            islandPanel?.orderFrontRegardless()
        }
    }

    private func createIslandPanel() {
        dismissLiquidPanel(islandPanel)
        let size = islandWindowSize
        let panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 悬浮窗不画系统阴影：贴顶刘海自带描边，
        // 透明窗口的系统阴影会把整个窗口矩形投出来。
        panel.hasShadow = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = IslandHostingView(rootView: FloatingIslandView(
            state: appState,
            safeTop: islandSafeTop,
            collapsedWidth: islandCollapsedWidth,
            onOpenMain: { [weak self] in self?.openMainFromIsland() },
            onHitFrameChange: { [weak self] frame, shape in
                DispatchQueue.main.async {
                    self?.islandHosting?.islandHitFrame = frame
                    self?.islandHosting?.islandHitShape = shape
                }
            },
            onExpandedChange: { [weak self] expanded in
                self?.islandExpanded = expanded
            }))
        islandHosting = hosting
        islandPanel = panel
        panel.contentView = hosting
        islandPanelSafeTop = islandSafeTop
        islandPanelCollapsedWidth = islandCollapsedWidth
    }

    private func openMainFromIsland() {
        // End nonactivating-panel event tracking before activating a regular
        // window. Otherwise the floating panel can retain the key-window focus.
        islandPanel?.orderOut(nil)
        islandExpanded = false
        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow()
        }
    }

    private var islandSafeTop: CGFloat {
        NSScreen.main?.safeAreaInsets.top ?? 0
    }

    private var islandCollapsedWidth: CGFloat {
        guard let screen = NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return IslandLayout.handleWidth }
        return max(IslandLayout.handleWidth, right.minX - left.maxX + 8)
    }

    private var islandWindowSize: NSSize {
        NSSize(width: max(IslandLayout.panelWidth, islandCollapsedWidth) + IslandLayout.windowMargin * 2,
               height: ceil(islandSafeTop) + IslandLayout.metricsHeight
                   + IslandLayout.detailBudget + IslandLayout.windowMargin)
    }

    private func positionIslandPanel() {
        guard let islandPanel,
              let screen = NSScreen.main else { return }
        let size = islandWindowSize
        // 所有屏幕均贴物理顶边；真实刘海的遮挡由内容安全区避让。
        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.maxY - size.height)
        islandPanel.setFrameOrigin(origin)
    }

    // MARK: - 主窗口

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 620)
            // 深色玻璃基调：内容延伸进标题栏（fullSizeContentView），标题栏透明，
            // DarkGlassSurface 贯通整窗；标题/交通灯/工具栏按钮浮在玻璃上。
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            // 系统标题文字由 SwiftUI 头部替代。
            window.title = ""
            window.contentView = NSHostingView(rootView: MainWindowView(state: appState))
            window.center()
            observeMainWindow(window)
            mainWindow = window
        }
        mainWindow?.deminiaturize(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        if appState.visiblePages.indices.contains(appState.selectedTab),
           appState.visiblePages[appState.selectedTab] == .traffic {
            appState.trafficMonitor.setPageVisible(true)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func observeMainWindow(_ window: NSWindow) {
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: window)
            .sink { [weak self] _ in self?.appState.mainWindowVisible = true }
            .store(in: &observables)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: window)
            .sink { [weak self] _ in self?.appState.mainWindowVisible = false }
            .store(in: &observables)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak self] _ in
                NSApp.setActivationPolicy(.accessory)
                self?.appState.mainWindowVisible = false
                self?.appState.trafficMonitor.setPageVisible(false)
            }
            .store(in: &observables)
    }

    private var observables: Set<AnyCancellable> = []
}
