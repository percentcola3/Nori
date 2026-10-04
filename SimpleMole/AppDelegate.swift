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
    private var screenshotSession = UUID()
    private var screenshotProcess: Process?

    // 灵动岛：顶部刘海或左右屏幕边缘的纵向悬浮栏。
    private var islandPanel: NSPanel?
    private var islandHosting: IslandHostingView<FloatingIslandView>?
    private var islandPanelHardwareNotch: Bool?
    private var islandPanelSafeTop: CGFloat?
    private var islandPanelCollapsedWidth: CGFloat?
    private var islandPanelEdge: AppState.IslandEdge?
    private var islandPanelFit: CGSize?
    private var islandExpanded = false
    private var islandMouseMonitors: [Any] = []
    private var islandRoutingTimer: Timer?
    private struct IslandSideDragSession {
        let panel: NSPanel
        let edge: AppState.IslandEdge
        let initialOrigin: NSPoint
        let windowHeight: CGFloat
        let visibleFrame: NSRect
    }
    private var islandSideDragSession: IslandSideDragSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        updateStatusItem()
        appState.directoryBrowser.startSizeBackgroundWork()

        AppUpdateController.shared.start { [weak self] in
            guard let self else { return false }
            return !self.appState.isBusy && self.appState.confirmation == nil
                && self.appState.taskNotice == nil
                && self.screenshotProcess?.isRunning != true
                && !RatioCaptureController.shared.isCapturing
                && self.editorWindow?.isVisible != true
                && NSApp.modalWindow == nil
                && !NSApp.windows.contains(where: { $0.attachedSheet != nil })
        }

        // 授权完整时只驻留菜单栏；缺少磁盘权限时先展示授权引导。
        // Published 的当前值也覆盖早于 didFinishLaunching 的启动检查。
        appState.$showPermissionCenter
            .removeDuplicates()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showMainWindow() }
            .store(in: &observables)

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
        appState.registerScreenshotHotKey()
        // 自动目录规则由应用常驻进程调度；AppState 内部按六小时最小间隔限频。
        autoCleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.appState.runScheduledAutoCleanup()
                self?.appState.runScheduledAnalysisScans()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.appState.runScheduledAutoCleanup()
            self?.appState.runScheduledAnalysisScans()
        }
        // auto 模式下，回到前台时重新解析系统语言。
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in
                L10n.shared.refreshIfAuto()
            }
            .store(in: &observables)
        NotificationCenter.default.publisher(for: .smOpenMainWindow)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showMainWindow() }
            .store(in: &observables)
        // 语言切换后重建本地化菜单。
        L10n.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setupMenu() }
            .store(in: &observables)
        setupIslandPanelObservers()
        updateIslandPanel()
    }

    /// Finder → Services → Reveal in Nori, accepting both modern file URLs
    /// and the legacy filename pasteboard supplied by some macOS applications.
    @objc func revealInNori(_ pasteboard: NSPasteboard, userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        if urls.isEmpty, let text = pasteboard.string(forType: .string),
           let path = DirectoryPathQuery(text), path.isAbsolute {
            urls = [URL(fileURLWithPath: path.text)]
        }
        guard let first = urls.first, first.isFileURL, FileManager.default.fileExists(atPath: first.path) else {
            error.pointee = L10n.shared.t("dir.error.folder") as NSString
            return
        }
        revealDirectoryItems(urls)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.compactMap { DirectoryRevealRequest.fileURL(from: $0) }
        if !files.isEmpty { revealDirectoryItems(files) }
    }

    private func revealDirectoryItems(_ urls: [URL]) {
        if !appState.visiblePages.contains(.directory) { appState.setPageVisible(.directory, true) }
        appState.directoryBrowser.reveal(urls)
        appState.jump(to: .directory)
        showMainWindow()
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
        cancelIslandSideDragTracking()
        appState.directoryBrowser.stopSizeBackgroundWork()
        AppUpdateController.shared.stop()
        autoCleanupTimer?.invalidate()
        runtimeTimer?.invalidate()
        HotKeyCenter.shared.unregister()
        islandMouseMonitors.forEach(NSEvent.removeMonitor)
        islandMouseMonitors.removeAll()
        islandRoutingTimer?.invalidate()
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.beginScreenshot(ratio: false) }
            .store(in: &observables)
        NotificationCenter.default.publisher(for: .smTakeRatioScreenshot)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.beginScreenshot(ratio: true) }
            .store(in: &observables)
    }

    private func beginScreenshot(ratio: Bool) {
        appState.permissionCenter.refresh()
        guard appState.permissionCenter.screenRecordingGranted else {
            showMainWindow()
            appState.presentPermissionCenter()
            return
        }
        // 每次触发都是新会话，旧进程/覆盖层/未完成编辑不能挡住新截图。
        let session = UUID()
        screenshotSession = session
        if let process = screenshotProcess, process.isRunning { process.terminate() }
        screenshotProcess = nil
        RatioCaptureController.shared.dismiss()
        closeScreenshotEditor()
        let completion: (NSImage?, PresetFrameStyle?) -> Void = { [weak self] image, frame in
            guard let self, self.screenshotSession == session else { return }
            self.screenshotProcess = nil
            guard let image else { return }
            self.openScreenshotEditor(image: image, captureFrame: frame)
        }
        if ratio {
            RatioCaptureController.shared.present { image, frame in completion(image, frame) }
        } else {
            screenshotProcess = ScreenShotService.captureInteractive { image in completion(image, nil) }
        }
    }

    private func openScreenshotEditor(image: NSImage, captureFrame: PresetFrameStyle?) {
        NSApp.activate(ignoringOtherApps: true)
        let targetScreen = editorWindow?.screen ?? cursorScreen
        var createdWindow = false
        if editorWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = L10n.shared.t("shot.title")
            window.isReleasedWhenClosed = false
            observeEditorWindow(window)
            editorWindow = window
            createdWindow = true
        }
        if let window = editorWindow {
            let content = ScreenshotEditorView(image: image, captureFrame: captureFrame) { [weak self] in
                self?.closeScreenshotEditor()
            }
            ScreenshotEditorSizing.replaceContent(content, in: window,
                                                   visibleFrame: (targetScreen ?? window.screen)?.visibleFrame,
                                                   center: createdWindow)
        }
        editorWindow?.deminiaturize(nil)
        editorWindow?.makeKeyAndOrderFront(nil)
    }

    private func closeScreenshotEditor() {
        editorWindow?.close()
    }

    private func observeEditorWindow(_ window: NSWindow) {
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak window] _ in
                MosaicCache.shared.clear()
                let closedContent = window?.contentViewController
                // 关闭后释放原图和笔画；窗口外壳保留用于下次快速复用。
                DispatchQueue.main.async {
                    // 新截图可能已复用窗口，旧关闭通知不能清空新编辑器。
                    if window?.isVisible == false,
                       window?.contentViewController === closedContent {
                        window?.contentViewController = nil
                    }
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
        let updateItem = appMenu.addItem(withTitle: L10n.shared.t("updates.check"),
                                        action: #selector(AppUpdateController.checkForUpdatesFromMenu(_:)),
                                        keyEquivalent: "")
        updateItem.target = AppUpdateController.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.shared.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.shared.t("menu.edit"))
        editMenu.addItem(withTitle: L10n.shared.t("menu.undo"), action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L10n.shared.t("menu.redo"), action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.shared.t("menu.cut"), action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.shared.t("menu.copy"), action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.shared.t("menu.paste"), action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.shared.t("menu.delete"), action: NSSelectorFromString("delete:"), keyEquivalent: "")
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
        appState.$islandEdge
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIslandPanel() }
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
        // 设置切换和屏幕重排结束当前拖动，按新屏幕与持久化位置重新布局。
        cancelIslandSideDragTracking()
        guard appState.islandEnabled && !appState.mainWindowVisible else {
            islandExpanded = false
            dismissLiquidPanel(islandPanel)
            return
        }
        // 同一次更新只读取一块屏幕，避免窗口重建与定位使用不同屏幕的指标。
        guard let screen = NSScreen.main ?? islandPanel?.screen ?? NSScreen.screens.first else { return }
        let hardwareNotch = screen.safeAreaInsets.top > 0
        let safeTop = islandSafeTop(on: screen)
        let collapsedWidth = islandCollapsedWidth(on: screen)
        let edge = appState.islandEdge
        let fit = islandFit(on: screen)
        // 屏幕参数或物理边缘变化时重建；侧边栏的窗口与内容采用纵向布局。
        if islandPanel == nil
            || islandPanelHardwareNotch != hardwareNotch
            || islandPanelSafeTop != safeTop
            || islandPanelCollapsedWidth != collapsedWidth
            || islandPanelEdge != edge
            || islandPanelFit != fit {
            createIslandPanel(hardwareNotch: hardwareNotch, safeTop: safeTop,
                              collapsedWidth: collapsedWidth, edge: edge, fit: fit)
        }
        positionIslandPanel(on: screen, edge: edge)
        if let islandPanel, !islandPanel.isVisible {
            presentLiquidPanel(islandPanel) {
                islandPanel.orderFrontRegardless()
            }
        } else {
            islandPanel?.orderFrontRegardless()
        }
    }

    private func createIslandPanel(hardwareNotch: Bool, safeTop: CGFloat,
                                   collapsedWidth: CGFloat, edge: AppState.IslandEdge, fit: CGSize) {
        cancelIslandSideDragTracking()
        dismissLiquidPanel(islandPanel)
        islandExpanded = false
        let size = islandWindowSize(hardwareNotch: hardwareNotch, safeTop: safeTop,
                                    collapsedWidth: collapsedWidth, edge: edge, fit: fit)
        let panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 悬浮窗不画系统阴影：贴边轮廓自带描边，
        // 透明窗口的系统阴影会把整个窗口矩形投出来。
        panel.hasShadow = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // 必须显式设置：未设置时窗口服务器按窗口缓冲区透明度判定点击穿透，
        // 而灵动岛内容画在独立图层上、窗口缓冲区全透明，点击会整片落到下方窗口。
        // 默认穿透，光标进入可见形状时由 updateIslandMouseRouting 接管。
        panel.ignoresMouseEvents = true
        let hosting = IslandHostingView(rootView: FloatingIslandView(
            state: appState,
            safeTop: safeTop,
            hardwareNotch: hardwareNotch,
            collapsedWidth: collapsedWidth,
            maxPanelWidth: fit.width,
            maxRailHeight: fit.height,
            edge: edge,
            onOpenMain: { [weak self] in self?.openMainFromIsland() },
            onHitFrameChange: { [weak self, weak panel] frame, shape in
                guard let self, let panel, self.islandPanel === panel else { return }
                // 同步赋值：SwiftUI 回调本就在主线程；async 跳一拍会让同一时刻的
                // 多次上报乱序，命中区域可能停在旧值。重建前面板的迟到回调也不能覆盖新面板。
                self.islandHosting?.islandHitFrame = frame
                self.islandHosting?.islandHitShape = shape
                self.updateIslandMouseRouting()
            },
            onDetailHitFrameChange: { [weak self, weak panel] frame in
                guard let self, let panel, self.islandPanel === panel else { return }
                self.islandHosting?.islandDetailHitFrame = frame
                self.updateIslandMouseRouting()
            },
            onExpandedChange: { [weak self, weak panel] expanded in
                guard let self, let panel, self.islandPanel === panel else { return }
                self.islandExpanded = expanded
            },
            onSideDrag: { [weak self, weak panel] delta, phase in
                guard let self, let panel, self.islandPanel === panel else { return }
                self.handleIslandSideDrag(delta: delta, phase: phase, panel: panel, edge: edge)
            }))
        islandHosting = hosting
        islandPanel = panel
        panel.contentView = hosting
        islandPanelHardwareNotch = hardwareNotch
        islandPanelSafeTop = safeTop
        islandPanelCollapsedWidth = collapsedWidth
        islandPanelEdge = edge
        islandPanelFit = fit
        installIslandMouseRouting()
    }

    /// 光标移动时切换灵动岛的鼠标穿透：在可见形状内接收点击与悬停，
    /// 形状外穿透给下方窗口，透明窗口边距不会吞掉点击。
    /// 本地监视器在事件分发前执行，离开形状的那一次移动仍会送达 SwiftUI 悬停。
    /// 穿透期间窗口收不到任何鼠标事件，只靠事件监视器会漏掉进入；定时器兜底。
    private func installIslandMouseRouting() {
        guard islandMouseMonitors.isEmpty else { return }
        islandRoutingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIslandMouseRouting() }
        }
        islandRoutingTimer?.tolerance = 0.02
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIslandMouseRouting() }
        }) {
            islandMouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateIslandMouseRouting() }
            return event
        }) {
            islandMouseMonitors.append(local)
        }
    }

    private func updateIslandMouseRouting() {
        guard let panel = islandPanel, let hosting = islandHosting,
              panel.isVisible || !panel.ignoresMouseEvents else { return }
        // 拖动越过手柄边界时仍由原生叶子控件跟踪，不切穿透也不触发收起。
        if islandSideDragSession?.panel === panel {
            panel.ignoresMouseEvents = false
            return
        }
        let inside = panel.isVisible && hosting.containsScreenPoint(NSEvent.mouseLocation)
        guard panel.ignoresMouseEvents == inside else { return }
        panel.ignoresMouseEvents = !inside
        if !inside {
            NotificationCenter.default.post(name: .smIslandPointerExited, object: nil)
        }
    }

    private func handleIslandSideDrag(delta: CGFloat, phase: IslandDragPhase,
                                       panel: NSPanel, edge: AppState.IslandEdge) {
        guard edge != .top, appState.islandEdge == edge else { return }
        if phase == .began {
            guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
            islandSideDragSession = IslandSideDragSession(
                panel: panel, edge: edge, initialOrigin: panel.frame.origin,
                windowHeight: panel.frame.height, visibleFrame: screen.visibleFrame)
            panel.ignoresMouseEvents = false
        }
        guard let session = islandSideDragSession, session.panel === panel, session.edge == edge else { return }
        if phase == .cancelled {
            panel.setFrameOrigin(session.initialOrigin)
            islandSideDragSession = nil
            updateIslandMouseRouting()
            return
        }
        // 原生控件报告从按下位置开始的累计屏幕 Y 差量；窗口位置不参与后续差量计算。
        panel.setFrameOrigin(IslandWindowGeometry.draggedSideOrigin(
            initialOrigin: session.initialOrigin, screenYDelta: delta,
            windowHeight: session.windowHeight, visibleFrame: session.visibleFrame))
        if phase == .ended {
            let fraction = IslandWindowGeometry.sidePositionFraction(
                originY: panel.frame.minY, windowHeight: session.windowHeight,
                visibleFrame: session.visibleFrame)
            islandSideDragSession = nil
            appState.setIslandPosition(fraction, for: edge)
            updateIslandMouseRouting()
        }
    }

    private func cancelIslandSideDragTracking() {
        guard islandSideDragSession != nil else { return }
        // 先结束原生叶子控件跟踪，让其取消回调同步释放 SwiftUI 的拖动锁；
        // 即使面板身份已变化、取消回调被拒绝，也必须清掉代理的临时会话。
        islandHosting?.cancelIslandDragTracking()
        islandSideDragSession = nil
    }

    private func openMainFromIsland() {
        cancelIslandSideDragTracking()
        // 点击发生在灵动岛所在的屏：主窗口就开在这块屏上，而不是按光标推断。
        let islandScreen = islandPanel?.screen
        // End nonactivating-panel event tracking before activating a regular
        // window. Otherwise the floating panel can retain the key-window focus.
        islandPanel?.orderOut(nil)
        islandExpanded = false
        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow(on: islandScreen)
        }
    }

    /// 刘海屏取硬件刘海高度；无刘海屏按 codenotch 的虚拟刘海取菜单栏高度，
    /// 菜单栏自动隐藏时 visibleFrame 顶部没有缺口，改用系统状态栏厚度。
    private func islandSafeTop(on screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return menuBar > 0 ? menuBar : NSStatusBar.system.thickness
    }

    private func islandCollapsedWidth(on screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return IslandLayout.virtualNotchWidth }
        return right.minX - left.maxX + 8
    }

    private func islandFit(on screen: NSScreen) -> CGSize {
        CGSize(width: floor(screen.frame.width - IslandLayout.windowMargin * 2 - 32),
               height: floor(screen.visibleFrame.height - IslandLayout.windowMargin * 2 - 16))
    }

    private func islandWindowSize(hardwareNotch: Bool, safeTop: CGFloat,
                                  collapsedWidth: CGFloat, edge: AppState.IslandEdge, fit: CGSize) -> NSSize {
        guard edge == .top else { return IslandLayout.sideWindowSize(maxRailHeight: fit.height) }
        let expandedTopInset = hardwareNotch ? safeTop : IslandLayout.nonNotchExpandedTopInset
        let content = IslandLayout.topWindowContentSize(hardwareNotch: hardwareNotch, maxWidth: fit.width)
        return NSSize(width: max(max(468, content.width), collapsedWidth) + IslandLayout.windowMargin * 2,
               height: ceil(expandedTopInset) + IslandLayout.metricsHeight + content.extraHeight
                   + IslandLayout.detailBudget + IslandLayout.windowMargin)
    }

    private func positionIslandPanel(on screen: NSScreen, edge: AppState.IslandEdge) {
        guard let islandPanel else { return }
        let attachment: IslandAttachment = switch edge {
        case .top: .top
        case .left: .left
        case .right: .right
        }
        // 顶部保持贴物理顶边；左右按各自保存的比例避开菜单栏和 Dock。
        islandPanel.setFrameOrigin(IslandWindowGeometry.origin(
            size: islandPanel.frame.size, screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame, attachment: attachment,
            positionFraction: appState.islandPosition(for: edge)))
    }

    // MARK: - 主窗口

    func showMainWindow(on targetScreen: NSScreen? = nil) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        var createdWindow = false
        if mainWindow == nil {
            let window = NoriMainWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                                  styleMask: [.borderless, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 620)
            // 系统标题窗口会在失焦时画暗色外框。主窗口由单层玻璃拥有轮廓，
            // AppKit 控制按钮、拖动区与边缘缩放保留在自定义窗口中。
            window.isOpaque = false
            window.backgroundColor = .clear
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.title = "Nori"
            let hosting = NSHostingView(rootView: MainWindowView(state: appState))
            // AppKit owns the window geometry through every page transition.
            // Dynamic empty/results content must not replace its size limits.
            hosting.sizingOptions = []
            window.contentView = hosting
            observeMainWindow(window)
            mainWindow = window
            createdWindow = true
        }
        if createdWindow || mainWindow?.isVisible != true || mainWindow?.isMiniaturized == true {
            appState.shufflePlaceholderScene()
        }
        restoreMainWindow(to: targetScreen ?? cursorScreen, force: createdWindow)
        mainWindow?.deminiaturize(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        if appState.visiblePages.indices.contains(appState.selectedTab),
           appState.visiblePages[appState.selectedTab] == .traffic {
            appState.trafficMonitor.setPageVisible(true)
        }
        raiseMainWindowAfterPolicyChange()
    }

    /// 主窗口必须出现在用户当前所在的屏幕：从灵动岛/菜单栏/程序坞唤起时，
    /// 光标在哪块屏，窗口就落在哪块屏。窗口只在首次创建时定位一次，
    /// 屏幕重排（合盖接外接屏、改排列）后可能搁浅在一块已经看不见的屏
    /// 上——直接 makeKeyAndOrderFront 的外在表现就是"点了没反应"。
    private var cursorScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSPointInRect(mouse, $0.frame) } ?? NSScreen.main
    }

    private func restoreMainWindow(to screen: NSScreen?, force: Bool = false) {
        guard let window = mainWindow, let screen else { return }
        if !force {
            let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
            let hosting = NSScreen.screens.first { NSPointInRect(center, $0.frame) }
            let visibleSomewhere = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
            if hosting == screen, visibleSomewhere { return }
        }
        let size = window.frame.size
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: visible.midY - size.height / 2))
    }

    /// 激活策略切换需要跑一轮 runloop 才生效；同一拍里的 activate 会被系统
    /// 忽略——表现是从灵动岛点"更多"后切到了空白桌面，主窗口却没有出现。
    /// 下一拍再抬一次窗口并激活，确保窗口真实可见。
    private func raiseMainWindowAfterPolicyChange() {
        DispatchQueue.main.async { [weak self] in
            self?.mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
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
