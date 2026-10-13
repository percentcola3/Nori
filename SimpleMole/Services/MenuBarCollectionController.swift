import AppKit
import Combine
import ApplicationServices

@MainActor
final class MenuBarCollectionController: NSObject, ObservableObject {
    struct Candidate: Identifiable {
        let id: String
        let name: String
        let pid: pid_t
        let icon: NSImage
    }
    @Published private(set) var enabled = false
    @Published private(set) var collapsed = false
    @Published private(set) var busy = false
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var icons: [CollectedMenuBarIcon] = []
    @Published private(set) var selected: Set<String>
    @Published private(set) var error: String?
    let backend = MenuBarCollectionPolicy.backend(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    private var boundary: NSStatusItem?
    private var recovery: NSStatusItem?
    private var assertion: Any?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    var onOpenSettings: () -> Void = {}
    private var activationTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = Set(defaults.stringArray(forKey: "SMMenuBarCollectionApps") ?? [])
        super.init()
        // Never restore a collapsed session at launch. Every hide is explicit.
    }

    var available: Bool {
        switch backend {
        case .separator: return NSApp.userInterfaceLayoutDirection == .leftToRight
        case .nativeExperimental: return NoriMenuBarVisibilityAvailable()
        case .unavailable: return false
        }
    }
    var hintKey: String {
        switch backend {
        case .separator: return "menubar.legacy.hint"
        case .nativeExperimental: return available ? "menubar.experimental.hint" : "menubar.unavailable"
        case .unavailable: return "menubar.unavailable"
        }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        restore()
        error = nil
        guard value && available else { stop(); return }
        enabled = true
        let item = NSStatusBar.system.statusItem(withLength: 24)
        item.autosaveName = "NoriMenuBarCollectionRecovery"
        item.button?.image = NSImage(systemSymbolName: "tray", accessibilityDescription: L10n.shared.t("menubar.title"))
        item.button?.target = self
        item.button?.action = #selector(toggleFromMenuBar)
        recovery = item
        if backend == .separator {
            let divider = NSStatusBar.system.statusItem(withLength: 20)
            divider.autosaveName = "NoriMenuBarCollectionBoundary"
            divider.button?.title = "│"
            divider.button?.target = self
            divider.button?.action = #selector(openSettings)
            boundary = divider
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restore() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.restore() } })
        refreshCandidates()
    }

    func setSelected(_ id: String, _ value: Bool) {
        restore()
        if value { selected.insert(id) } else { selected.remove(id) }
        defaults.set(Array(selected).sorted(), forKey: "SMMenuBarCollectionApps")
        refreshPreviews()
    }

    @objc func openSettings() { onOpenSettings() }

    var canControlNativeIcons: Bool { AXIsProcessTrusted() }
    var canCaptureNativeIcons: Bool { CGPreflightScreenCaptureAccess() }
    var selectedApps: [Candidate] { candidates.filter { selected.contains($0.id) } }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func refreshPreviews() {
        guard enabled, !collapsed else { return } // Hidden positions are stale.
        previewTask?.cancel()
        previewGeneration += 1
        let token = previewGeneration
        let apps = backend == .separator ? candidates : selectedApps
        previewTask = Task { [weak self] in
            let result = await MenuBarIconAccess.previews(for: apps)
            guard let self, !Task.isCancelled, self.previewGeneration == token, !self.collapsed else { return }
            self.icons = self.collectionIcons(result)
        }
    }

    private func collectionIcons(_ result: [CollectedMenuBarIcon]) -> [CollectedMenuBarIcon] {
        guard backend == .separator else { return result }
        guard let boundaryX = boundary?.button?.window?.frame.minX else { return [] }
        return result.filter { $0.frame.map { $0.maxX <= boundaryX } == true }
    }

    func activate(_ icon: CollectedMenuBarIcon, secondary: Bool = false) {
        guard canControlNativeIcons else {
            error = L10n.shared.t("menubar.access.required")
            openSettings()
            return
        }
        guard icon.frame != nil else {
            error = L10n.shared.t("menubar.icon.unavailable")
            openSettings()
            return
        }
        restore()
        let token = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, self.generation == token, self.enabled,
                  (self.backend == .separator || self.selected.contains(icon.bundleIdentifier)) else { return }
            let succeeded = await Task.detached(priority: .userInitiated) {
                MenuBarIconAccess.activate(icon, secondary: secondary)
            }.value
            guard self.generation == token else { return }
            if !succeeded {
                self.error = L10n.shared.t("menubar.icon.unavailable")
                self.openSettings()
            }
        }
    }

    @objc private func toggleFromMenuBar() {
        if collapsed || busy { restore() } else { collapse(); if error != nil { openSettings() } }
    }

    func restore() {
        activationTask?.cancel()
        activationTask = nil
        generation += 1
        if let assertion { NoriMenuBarVisibilityRelease(assertion) }
        assertion = nil
        boundary?.length = 20
        collapsed = false
        busy = false
        recovery?.button?.image = NSImage(systemSymbolName: "tray", accessibilityDescription: L10n.shared.t("menubar.title"))
    }

    func stop() {
        restore()
        previewTask?.cancel()
        previewGeneration += 1
        enabled = false
        icons.removeAll()
        if let boundary { NSStatusBar.system.removeStatusItem(boundary) }
        if let recovery { NSStatusBar.system.removeStatusItem(recovery) }
        boundary = nil
        recovery = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func collapse() {
        guard enabled, available, !busy, !collapsed else { return }
        error = nil
        if backend == .separator {
            guard let divider = boundary?.button?.window?.frame,
                  let rescue = recovery?.button?.window?.frame,
                  divider.maxX <= rescue.minX,
                  let width = MenuBarCollectionPolicy.separatorLength(screenWidths: NSScreen.screens.map { $0.frame.width }) else {
                error = L10n.shared.t("menubar.arrangement"); return
            }
            busy = true
            generation += 1
            let token = generation
            let apps = candidates
            activationTask = Task { [weak self] in
                let previews = await MenuBarIconAccess.previews(for: apps)
                guard let self, !Task.isCancelled, self.generation == token, self.enabled else { return }
                self.icons = self.collectionIcons(previews)
                self.boundary?.length = width
                self.collapsed = true
                self.busy = false
            }
            return
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let owned = Set(candidates.map(\.id))
        let own = Bundle.main.bundleIdentifier ?? "com.nori.app"
        let allowed = MenuBarCollectionPolicy.allowedApps(running: running, selected: selected, candidates: owned, own: own)
        guard allowed.count < running.union([own]).count else { error = L10n.shared.t("menubar.select"); return }
        busy = true
        generation += 1
        let token = generation
        let apps = selectedApps
        activationTask = Task { [weak self] in
            let previews = await MenuBarIconAccess.previews(for: apps)
            guard let self, !Task.isCancelled, self.generation == token, self.enabled, self.busy else { return }
            self.icons = previews
            self.activateVisibility(allowed, token: token)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == token, self.busy else { return }
            self.restore()
            self.error = L10n.shared.t("menubar.failed")
        }
    }

    private func activateVisibility(_ allowed: [String], token: Int) {
        assertion = NoriMenuBarVisibilityActivate(allowed) { [weak self] handle, message in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, self.enabled else {
                    if let handle { NoriMenuBarVisibilityRelease(handle) }
                    return
                }
                self.busy = false
                if let handle, message == nil {
                    self.assertion = handle
                    self.collapsed = true
                    self.recovery?.button?.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: L10n.shared.t("menubar.restore"))
                } else {
                    self.restore()
                    self.error = L10n.shared.t("menubar.failed") + (message.map { " · " + $0 } ?? "")
                }
            }
        }
    }

    func refreshCandidates(clearError: Bool = true) {
        restore()
        if clearError { error = nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var apps: [String: Candidate] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != ownPID, let id = app.bundleIdentifier,
                  !id.hasPrefix("com.apple."), app.bundleURL?.pathExtension == "app" else { continue }
            apps[id] = Candidate(id: id, name: app.localizedName ?? id, pid: app.processIdentifier,
                icon: app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
        }
        candidates = Array(apps.values)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        refreshPreviews()
    }
}
