import AppKit
import Combine
import Darwin
import Foundation

enum DirectorySizeState: Equatable {
    case pending, complete, partial, unavailable, updating, stale
}

/// A small file workspace: expensive I/O runs outside the main actor, while
/// navigation, search generations and clipboard ownership stay on it.
@MainActor
final class DirectoryBrowserModel: ObservableObject {
    @Published private(set) var currentDirectory: URL
    @Published private(set) var entries: [DirectoryEntry] = []
    @Published var selectedIDs: Set<String> = []
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            statusMessage = nil
            updateSearch()
        }
    }
    @Published var showHidden: Bool {
        didSet {
            guard showHidden != oldValue else { return }
            hiddenVisibility[currentDirectory.path] = showHidden
            defaults.set(hiddenVisibility, forKey: "NoriDirectoryHiddenVisibility")
            selectedIDs.removeAll()
            updateSearch()
        }
    }
    @Published private(set) var sizeStates: [String: DirectorySizeState] = [:]
    @Published private(set) var sizeUpdatedAt: [String: Date] = [:]
    @Published private(set) var sizePartialIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isCalculatingSizes = false
    @Published private var isCalibratingSizes = false
    @Published private(set) var isSearching = false
    @Published private(set) var isWorking = false
    @Published private(set) var isIndexing = false
    @Published var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var canPaste = false
    @Published private(set) var copiedPath: String?
    @Published private(set) var pathMatchScores: [String: Int] = [:]
    private var copyFeedbackTask: Task<Void, Never>?
    private var pendingRevealIDs: Set<String> = []
    @Published private(set) var history: [URL] = []
    @Published private(set) var historyPosition = 0
    @Published private var indexCount = 0
    @Published private var indexUpdated: Date?
    @Published private var indexScanned = 0
    @Published private var indexSkipped = 0

    private let defaults: UserDefaults
    private let homeDirectory: URL
    private let pasteboard: NSPasteboard
    private var hiddenVisibility: [String: Bool]
    private var folderEntries: [DirectoryEntry] = []
    private var index: DirectorySearchIndex?
    private let spotlight = DirectorySpotlightSearch()
    private var indexRoots: [URL] = []
    private var isActive = false
    private var generation = UUID()
    private var searchGeneration = UUID()
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private let sizeCache: DirectorySizeCache
    private let sizeStorageDirectory: URL
    private let sizeCalibrationInterval: TimeInterval
    private var sizeTask: Task<Void, Never>?
    private var sizeTimer: Timer?
    private var sizeWatcher: DirectorySizeWatcher?
    private var sizeBackgroundStarted = false
    private var sizeSessionID = UUID()
    private var sizeObservedURLs: [URL] = []
    private var sizeScheduleTask: Task<Void, Never>?
    private var sizeWatchTask: Task<Void, Never>?
    private var sizeChangeTask: Task<Void, Never>?
    private var pendingSizeChanges: Set<URL> = []
    private var sizeRecords: [String: DirectorySizeRecord] = [:]
    private var pendingSizeRequests: [String: (url: URL, mode: DirectorySizeRefreshMode)] = [:]
    private var sizeRequestOrder: [String] = []
    private var urgentSizeIDs: Set<String> = []
    private var lastSizeAttempt: [String: Date] = [:]
    private var unavailableSizeIDs: Set<String> = []
    private var sizeCalibrationRequested = false
    private var activeSizeRequest: (url: URL, mode: DirectorySizeRefreshMode)?
    private var indexTask: Task<Void, Never>?
    private var watcher: DispatchSourceFileSystemObject?
    private var refreshTask: Task<Void, Never>?
    private var clipboardTimer: Timer?
    private var clipboardChangeCount = -1
    private var cutURLs: [URL] = []
    private var cutChangeCount = -1
    private var selectionAnchor: String?
    private var pendingIndexChanges: Set<URL> = []
    private var indexRefreshTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         initialDirectory: URL? = nil, indexDatabaseURL: URL? = nil, pasteboard: NSPasteboard = .general,
         sizeCacheURL: URL? = nil, sizeCalibrationInterval: TimeInterval = 6 * 3600) {
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        self.pasteboard = pasteboard
        self.sizeCache = DirectorySizeCache(cacheURL: sizeCacheURL)
        self.sizeStorageDirectory = DirectorySizeCache.storageURL(cacheURL: sizeCacheURL).deletingLastPathComponent()
        self.sizeCalibrationInterval = max(1, sizeCalibrationInterval)
        let saved = defaults.string(forKey: "NoriDirectoryLastPath").map { URL(fileURLWithPath: $0) }
        let initial = initialDirectory ?? saved ?? homeDirectory
        let directory = initial.standardizedFileURL
        let visibility = defaults.dictionary(forKey: "NoriDirectoryHiddenVisibility") as? [String: Bool] ?? [:]
        currentDirectory = directory
        hiddenVisibility = visibility
        showHidden = visibility[directory.path] ?? true
        history = [directory]
        do { index = try DirectorySearchIndex(databaseURL: indexDatabaseURL) }
        catch { errorMessage = L10n.shared.tf("dir.index.failed", error.localizedDescription) }
    }

    deinit {
        clipboardTimer?.invalidate()
        sizeTimer?.invalidate()
        watcher?.cancel()
        sizeTask?.cancel()
        sizeScheduleTask?.cancel()
        sizeWatchTask?.cancel()
        sizeChangeTask?.cancel()
    }

    var hasSearchQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isPathQuery: Bool { DirectoryPathQuery(query, home: homeDirectory) != nil }
    var isBreadcrumbPathCopied: Bool { copiedPath == breadcrumbDirectory.path }

    var canGoBack: Bool { historyPosition > 0 }
    var canGoForward: Bool { historyPosition + 1 < history.count }
    var selectedEntries: [DirectoryEntry] { entries.filter { selectedIDs.contains($0.id) } }
    var breadcrumbDirectory: URL {
        if hasSearchQuery,
           let selected = selectedEntries.first {
            return selected.url.deletingLastPathComponent()
        }
        return currentDirectory
    }
    var indexStatus: String {
        if isIndexing { return L10n.shared.tf("dir.index.building", indexScanned, indexSkipped) }
        guard let indexUpdated else { return L10n.shared.t("dir.index.empty") }
        return L10n.shared.tf("dir.index.ready", indexCount,
                             indexUpdated.formatted(date: .abbreviated, time: .shortened))
    }
    var sizeBackgroundStatus: String {
        L10n.shared.t(isCalibratingSizes ? "dir.size.background.calibrating"
            : isCalculatingSizes ? "dir.size.background.working" : "dir.size.background.idle")
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        startSizeBackgroundWork()
        reloadDirectory()
        updateClipboardState()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateClipboardState() }
        }
        Task { [weak self] in await self?.readIndexStatus() }
    }

    func suspend() {
        isActive = false
        generation = UUID()
        searchGeneration = UUID()
        loadTask?.cancel()
        searchTask?.cancel()
        refreshTask?.cancel()
        spotlight.cancel()
        watcher?.cancel()
        watcher = nil
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        isLoading = false
        isSearching = false
        // The app owns the cache, scheduler and recursive watcher. Leaving the
        // tab only suspends navigation/search; queued utility I/O keeps going.
    }

    func clearError() { errorMessage = nil }
    func selectAll() { selectedIDs = Set(entries.map(\.id)) }
    func copyBreadcrumbPath() { copyPath(breadcrumbDirectory) }
    func copyPath(_ url: URL) {
        pasteboard.clearContents()
        guard pasteboard.setString(url.path, forType: .string), pasteboard.string(forType: .string) == url.path else {
            errorMessage = L10n.shared.t("dir.path.copy.failed")
            return
        }
        copiedPath = url.path
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.copiedPath = nil
        }
        updateClipboardState()
    }

    func navigate(to url: URL) {
        guard url.isFileURL else { errorMessage = L10n.shared.t("dir.error.path"); return }
        let destination = url.standardizedFileURL
        guard destination.path != currentDirectory.path else { query = ""; refresh(); return }
        history = Array(history.prefix(historyPosition + 1)) + [destination]
        if history.count > 100 { history.removeFirst(history.count - 100) }
        historyPosition = history.count - 1
        setDirectory(destination)
    }

    private func setDirectory(_ url: URL) {
        folderEntries = []
        entries = []
        sizeStates = [:]
        sizeUpdatedAt = [:]
        sizePartialIDs = []
        currentDirectory = url
        query = ""
        showHidden = hiddenVisibility[url.path] ?? true
        selectedIDs.removeAll()
        selectionAnchor = nil
        defaults.set(url.path, forKey: "NoriDirectoryLastPath")
        reloadDirectory()
    }

    func goBack() { guard canGoBack else { return }; historyPosition -= 1; setDirectory(history[historyPosition]) }
    func goForward() { guard canGoForward else { return }; historyPosition += 1; setDirectory(history[historyPosition]) }
    func goUp() { navigate(to: breadcrumbDirectory.deletingLastPathComponent()) }

    func go(to path: String) {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { errorMessage = L10n.shared.t("dir.error.path"); return }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &directory), directory.boolValue else {
            errorMessage = L10n.shared.t("dir.error.folder"); return
        }
        navigate(to: URL(fileURLWithPath: expanded, isDirectory: true))
    }

    /// A directory opens directly; files are selected in their containing folder.
    func reveal(_ urls: [URL]) {
        guard let first = urls.first, first.isFileURL else { return }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: first.path, isDirectory: &directory) else {
            errorMessage = L10n.shared.t("dir.error.folder"); return
        }
        let destination = directory.boolValue ? first : first.deletingLastPathComponent()
        pendingRevealIDs = directory.boolValue ? [] : Set(urls.filter {
            $0.isFileURL && $0.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL
        }.map { $0.standardizedFileURL.path })
        navigate(to: destination)
        if !directory.boolValue, (try? DirectoryEntry.metadata(url: first).isHidden) == true { showHidden = true }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = currentDirectory
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in self?.navigate(to: url) }
        }
    }

    func refresh() {
        reloadDirectory(calibrateSizes: true)
    }

    private func reloadDirectory(calibrateSizes: Bool = false) {
        generation = UUID()
        let ticket = generation
        let directory = currentDirectory
        loadTask?.cancel()
        watcher?.cancel()
        watcher = nil
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DirectoryFileService.list(directory: directory, showHidden: true) }
            }.value
            guard let self, !Task.isCancelled, self.generation == ticket else { return }
            self.isLoading = false
            switch result {
            case .success(let items):
                self.folderEntries = items
                self.updateSearch(calibrateSizes: calibrateSizes)
                if !self.pendingRevealIDs.isEmpty {
                    self.selectedIDs = self.pendingRevealIDs.intersection(Set(self.entries.map(\.id)))
                    self.pendingRevealIDs.removeAll()
                }
                self.watch(directory)
            case .failure(let error):
                self.folderEntries = []
                self.entries = []
                self.sizeStates = [:]
                self.sizeUpdatedAt = [:]
                self.sizePartialIDs = []
                self.errorMessage = L10n.shared.tf("dir.error.operation", error.localizedDescription)
            }
        }
    }

    private func watch(_ directory: URL) {
        guard isActive else { return }
        let descriptor = Darwin.open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshTask?.cancel()
                self.refreshTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled, let self, self.isActive, !self.isWorking else { return }
                    self.reloadDirectory()
                }
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        watcher = source
        source.resume()
    }

    private func updateSearch(calibrateSizes: Bool = false) {
        searchGeneration = UUID()
        let ticket = searchGeneration
        searchTask?.cancel()
        spotlight.cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        pathMatchScores = [:]
        if let path = DirectoryPathQuery(term, home: homeDirectory) {
            searchPaths(path, ticket: ticket)
            return
        }
        let currentMatches = folderEntries.filter { (showHidden || !$0.isHidden)
            && (term.isEmpty || $0.name.localizedStandardContains(term)) }
        // Current-folder matches appear synchronously, including when the global
        // indexes are empty or unavailable. An empty query remains folder browsing.
        entries = currentMatches
        selectedIDs.formIntersection(Set(entries.map(\.id)))
        measureDirectories(calibrate: calibrateSizes)
        guard !term.isEmpty else { isSearching = false; return }
        isSearching = true
        statusMessage = nil
        let hidden = showHidden
        let directory = currentDirectory
        let currentURLs = currentMatches.map(\.url)
        let index = index
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                guard let self, !Task.isCancelled else { return }
                // Local results arrive first; Spotlight then expands across volumes.
                var localURLs: [URL] = []
                var errors: [String] = []
                if let index {
                    do { localURLs = try await index.search(query: term, showHidden: hidden, limit: 300).map(\.url) }
                    catch { if !Task.isCancelled { errors.append(error.localizedDescription) } }
                }
                guard !Task.isCancelled, self.searchGeneration == ticket else { return }
                await self.publishSearch(currentURLs + localURLs, query: term, directory: directory, ticket: ticket)
                let systemURLs: [URL]
                do { systemURLs = try await self.spotlight.search(query: term, showHidden: hidden, limit: 300) }
                catch {
                    if Task.isCancelled { return }
                    errors.append(error.localizedDescription)
                    systemURLs = []
                }
                guard !Task.isCancelled, self.searchGeneration == ticket else { return }
                var seen = Set<String>()
                let combined = (currentURLs + localURLs + systemURLs).filter { seen.insert($0.standardizedFileURL.path).inserted }
                await self.publishSearch(combined, query: term, directory: directory, ticket: ticket)
                guard !Task.isCancelled, self.searchGeneration == ticket else { return }
                self.isSearching = false
                if !errors.isEmpty { self.errorMessage = L10n.shared.tf("dir.search.partial", errors.joined(separator: "\n")) }
                if combined.count >= 300 { self.statusMessage = L10n.shared.tf("dir.search.limit", 300) }
                self.measureDirectories(calibrate: calibrateSizes)
            } catch { /* Cancellation supersedes this search. */ }
        }
    }

    private func searchPaths(_ path: DirectoryPathQuery, ticket: UUID) {
        statusMessage = nil
        isSearching = true
        entries = []
        selectedIDs.removeAll()
        let directory = currentDirectory
        let hidden = showHidden
        let index = index
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                var urls = try await Task.detached(priority: .userInitiated) {
                    try path.localCandidates(currentDirectory: directory, showHidden: hidden)
                }.value
                try Task.checkCancellation()
                if let index { urls += (try? await index.searchPath(path, showHidden: hidden)) ?? [] }
                guard let self, self.searchGeneration == ticket, !Task.isCancelled else { return }
                await self.publishPathSearch(urls, path: path, hidden: hidden, ticket: ticket)
                if let leaf = path.components.last {
                    let system = (try? await self.spotlight.search(query: leaf, showHidden: hidden, limit: 300)) ?? []
                    urls += system.filter { path.score($0) >= 55 }
                }
                try Task.checkCancellation()
                await self.publishPathSearch(urls, path: path, hidden: hidden, ticket: ticket)
                guard self.searchGeneration == ticket, !Task.isCancelled else { return }
                self.isSearching = false
            } catch {
                guard let self, !Task.isCancelled, self.searchGeneration == ticket else { return }
                self.isSearching = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func publishPathSearch(_ urls: [URL], path: DirectoryPathQuery, hidden: Bool, ticket: UUID) async {
        let result: [(entry: DirectoryEntry, score: Int)] = await Task.detached(priority: .userInitiated) {
            var seen = Set<String>()
            var matches: [(entry: DirectoryEntry, score: Int)] = []
            for url in urls {
                guard !Task.isCancelled, seen.insert(url.resolvingSymlinksInPath().path).inserted,
                      let entry = try? DirectoryEntry.metadata(url: url), hidden || !entry.isHidden else { continue }
                matches.append((entry: entry, score: path.score(entry.url)))
            }
            matches.sort {
                if $0.score == $1.score { return $0.entry.id < $1.entry.id }
                return $0.score > $1.score
            }
            return matches
        }.value
        guard searchGeneration == ticket, !Task.isCancelled else { return }
        entries = result.prefix(100).map { $0.entry }
        pathMatchScores = Dictionary(uniqueKeysWithValues: result.prefix(100).map { ($0.entry.id, $0.score) })
        selectedIDs.formIntersection(Set(entries.map(\.id)))
        measureDirectories()
    }

    private func publishSearch(_ urls: [URL], query: String, directory: URL, ticket: UUID) async {
        let result = await Task.detached(priority: .userInitiated) {
            var seen = Set<String>()
            var items: [DirectoryEntry] = []
            for url in urls {
                // Resolve parent aliases such as /var without collapsing a file
                // symlink into its target, which is a separate actionable item.
                let identity = url.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent(url.lastPathComponent).path
                guard !Task.isCancelled, seen.insert(identity).inserted,
                      let entry = try? DirectoryEntry.metadata(url: url) else { continue }
                items.append(entry)
            }
            return DirectorySearchRanking.sorted(items, query: query, directory: directory)
        }.value
        guard searchGeneration == ticket, !Task.isCancelled else { return }
        entries = Array(result.prefix(300))
        selectedIDs.formIntersection(Set(entries.map(\.id)))
        measureDirectories()
    }

    private func measureDirectories(calibrate: Bool = false) {
        let directories = entries.filter { $0.isDirectory && !$0.isSymbolicLink }.map(\.url)
        applySizeRecords()
        guard !directories.isEmpty else { return }
        let session = sizeSessionID
        Task { [weak self, sizeCache] in
            let cached = await sizeCache.records(for: directories)
            guard let self, self.sizeSessionID == session, self.sizeBackgroundStarted else { return }
            for url in directories {
                // The actor owns eviction and freshness. In-memory values are
                // only a presentation cache, never a reason to skip observing.
                if let record = cached[url.path] { self.sizeRecords[url.path] = record }
            }
            // Visible results can outnumber the bounded persistent inventories.
            // Keep their cheap totals and subscriptions until navigation changes,
            // so filtering a large folder never churns the inventory eviction cap.
            let available = self.sizeRecords.merging(cached) { _, persisted in persisted }
            self.enqueueSizeRequests(directories, mode: calibrate ? .calibration : .incremental,
                                     cached: available)
        }
    }

    func startSizeBackgroundWork() {
        guard !sizeBackgroundStarted else { return }
        sizeBackgroundStarted = true
        sizeSessionID = UUID()
        sizeWatcher = DirectorySizeWatcher(onChange: { [weak self] paths in
            self?.invalidateSizes(paths: paths)
        }, onRescan: { [weak self] in
            self?.scheduleSizeCalibration(force: true)
        })
        sizeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleSizeCalibration() }
        }
        sizeTimer?.tolerance = 20
        scheduleSizeWatcherUpdate()
        scheduleSizeCalibration()
    }

    /// App-lifetime work, independently testable without advancing the run loop.
    /// Only previously observed roots are due; browsing never starts a disk-wide scan.
    func runScheduledSizeRefresh(now: Date = Date(), force: Bool = false) async {
        let session = sizeSessionID
        var urls = force ? await sizeCache.observedDirectories()
            : await sizeCache.dueDirectories(now: now, interval: sizeCalibrationInterval)
        urls.append(contentsOf: visibleSizeDirectories.filter {
            guard let record = sizeRecords[$0.path] else { return false }
            return force || record.isStale || now.timeIntervalSince(record.updatedAt) >= sizeCalibrationInterval
        })
        let cached = await sizeCache.records(for: urls)
        guard sizeBackgroundStarted, sizeSessionID == session else { return }
        for (path, record) in cached { sizeRecords[path] = record }
        let retryInterval = min(3600, sizeCalibrationInterval)
        let due = urls.filter { force || now.timeIntervalSince(lastSizeAttempt[$0.path] ?? .distantPast) >= retryInterval }
        enqueueSizeRequests(due, mode: .calibration, cached: cached)
    }

    private func scheduleSizeCalibration(force: Bool = false) {
        guard sizeScheduleTask == nil else {
            if force { sizeCalibrationRequested = true }
            return
        }
        let session = sizeSessionID
        sizeScheduleTask = Task { [weak self] in
            guard let self else { return }
            await self.runScheduledSizeRefresh(force: force)
            guard !Task.isCancelled, self.sizeSessionID == session else { return }
            self.sizeScheduleTask = nil
            if self.sizeCalibrationRequested {
                self.sizeCalibrationRequested = false
                self.scheduleSizeCalibration(force: true)
            }
        }
    }

    private func enqueueSizeRequests(_ urls: [URL], mode: DirectorySizeRefreshMode,
                                     cached: [String: DirectorySizeRecord], force: Bool = false) {
        guard sizeBackgroundStarted else { return }
        for url in urls {
            let path = url.standardizedFileURL.path
            guard mode == .calibration || cached[path]?.isStale != false else { continue }
            if activeSizeRequest?.url.path == path, !force,
               activeSizeRequest?.mode == .calibration || activeSizeRequest?.mode == mode { continue }
            if pendingSizeRequests[path] == nil { sizeRequestOrder.append(path) }
            let nextMode: DirectorySizeRefreshMode = pendingSizeRequests[path]?.mode == .calibration ? .calibration : mode
            pendingSizeRequests[path] = (url.standardizedFileURL, nextMode)
            if force { urgentSizeIDs.insert(path) }
            unavailableSizeIDs.remove(path)
        }
        // Foreground folders first, then invalidated paths, then periodic work.
        // A large historical inventory cannot delay newly browsed folders.
        let visible = Set(entries.map(\.id))
        let foreground = sizeRequestOrder.filter { visible.contains($0) }
        let incremental = sizeRequestOrder.filter { !visible.contains($0)
            && (urgentSizeIDs.contains($0) || pendingSizeRequests[$0]?.mode == .incremental) }
        let scheduled = sizeRequestOrder.filter { !visible.contains($0)
            && !urgentSizeIDs.contains($0) && pendingSizeRequests[$0]?.mode != .incremental }
        sizeRequestOrder = foreground + incremental + scheduled
        updateSizeActivity()
        scheduleSizeWatcherUpdate()
        guard sizeTask == nil, !sizeRequestOrder.isEmpty else { return }
        let session = sizeSessionID
        // One utility worker avoids multiplying disk walks when searches,
        // navigation and filesystem notifications arrive at the same time.
        sizeTask = Task(priority: .utility) { [weak self, sizeCache] in
            while !Task.isCancelled {
                guard let self, self.sizeSessionID == session, !self.sizeRequestOrder.isEmpty else { break }
                let path = self.sizeRequestOrder.removeFirst()
                guard let request = self.pendingSizeRequests.removeValue(forKey: path) else { continue }
                self.urgentSizeIDs.remove(path)
                self.activeSizeRequest = request
                self.lastSizeAttempt[path] = Date()
                self.updateSizeActivity()
                // Subscribe before reading the first branch. The watcher replays
                // undelivered events across root-set changes, closing restart gaps.
                self.sizeWatcher?.watch(self.sizeObservedURLs
                    + self.visibleSizeDirectories + self.pendingSizeRequests.values.map(\.url) + [request.url])
                let record = await sizeCache.refresh(request.url, mode: request.mode)
                guard !Task.isCancelled, self.sizeSessionID == session else { break }
                if let record { self.sizeRecords[path] = record }
                else {
                    self.sizeRecords.removeValue(forKey: path)
                    self.unavailableSizeIDs.insert(path)
                }
                // Retain completed subscriptions while the remaining queue runs.
                self.sizeObservedURLs = await sizeCache.observedDirectories()
                guard !Task.isCancelled, self.sizeSessionID == session else { break }
                self.activeSizeRequest = nil
                self.updateSizeActivity()
            }
            guard let self, self.sizeSessionID == session else { return }
            self.sizeTask = nil
            self.activeSizeRequest = nil
            self.updateSizeActivity()
            self.scheduleSizeWatcherUpdate()
        }
    }

    private func updateSizeActivity() {
        let working = activeSizeRequest != nil || !pendingSizeRequests.isEmpty
        let calibrating = activeSizeRequest?.mode == .calibration
            || pendingSizeRequests.values.contains { $0.mode == .calibration }
        if isCalculatingSizes != working { isCalculatingSizes = working }
        if isCalibratingSizes != calibrating { isCalibratingSizes = calibrating }
        applySizeRecords()
    }

    private func applySizeRecords() {
        var states: [String: DirectorySizeState] = [:]
        var timestamps: [String: Date] = [:]
        var partial: Set<String> = []
        var displayed = entries
        for position in displayed.indices {
            let item = displayed[position]
            guard item.isDirectory && !item.isSymbolicLink else {
                states[item.id] = item.allocatedBytes == nil ? .unavailable : .complete
                continue
            }
            let updating = pendingSizeRequests[item.id] != nil || activeSizeRequest?.url.path == item.id
            if let record = sizeRecords[item.id] {
                displayed[position].allocatedBytes = record.result.bytes
                timestamps[item.id] = record.updatedAt
                if !record.result.isComplete { partial.insert(item.id) }
                states[item.id] = updating ? .updating : record.isStale ? .stale
                    : record.result.isComplete ? .complete : .partial
            } else {
                displayed[position].allocatedBytes = nil
                states[item.id] = unavailableSizeIDs.contains(item.id) ? .unavailable : .pending
            }
        }
        if entries != displayed { entries = displayed }
        if sizeStates != states { sizeStates = states }
        if sizeUpdatedAt != timestamps { sizeUpdatedAt = timestamps }
        if sizePartialIDs != partial { sizePartialIDs = partial }
    }

    private func invalidateSizes(paths: [URL]) {
        // Atomic cache writes must not invalidate their own containing inventory.
        // The dedicated storage directory belongs entirely to this cache.
        let paths = paths.map(\.standardizedFileURL).filter {
            $0.path != sizeStorageDirectory.path && !$0.path.hasPrefix(sizeStorageDirectory.path + "/")
        }
        guard sizeBackgroundStarted, !paths.isEmpty else { return }
        pendingSizeChanges.formUnion(paths)
        for (path, record) in sizeRecords where paths.contains(where: { Self.sizePathsIntersect(path, $0.path) }) {
            sizeRecords[path] = DirectorySizeRecord(result: record.result, updatedAt: record.updatedAt, isStale: true)
        }
        applySizeRecords()
        guard sizeChangeTask == nil else { return }
        let session = sizeSessionID
        sizeChangeTask = Task { [weak self, sizeCache] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled, self.sizeSessionID == session else { return }
            while !self.pendingSizeChanges.isEmpty {
                let paths = Array(self.pendingSizeChanges)
                self.pendingSizeChanges.removeAll()
                await sizeCache.invalidate(paths: paths)
                var observed = await sizeCache.observedDirectories()
                guard !Task.isCancelled, self.sizeSessionID == session else { return }
                observed.append(contentsOf: self.pendingSizeRequests.values.map(\.url))
                observed.append(contentsOf: self.visibleSizeDirectories)
                if let active = self.activeSizeRequest { observed.append(active.url) }
                let affected = observed.filter { root in paths.contains { Self.sizePathsIntersect(root.path, $0.path) } }
                let cached = await sizeCache.records(for: affected)
                guard !Task.isCancelled, self.sizeSessionID == session else { return }
                for (path, record) in cached { self.sizeRecords[path] = record }
                self.enqueueSizeRequests(affected, mode: .incremental, cached: cached, force: true)
            }
            self.sizeChangeTask = nil
        }
    }

    private static func sizePathsIntersect(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs == "/" ? "/" : rhs + "/")
            || rhs.hasPrefix(lhs == "/" ? "/" : lhs + "/")
    }

    private var visibleSizeDirectories: [URL] {
        entries.filter { $0.isDirectory && !$0.isSymbolicLink }.map(\.url)
    }

    private func scheduleSizeWatcherUpdate() {
        guard sizeBackgroundStarted, sizeWatchTask == nil else { return }
        let session = sizeSessionID
        sizeWatchTask = Task { [weak self, sizeCache] in
            guard let self, !Task.isCancelled else { return }
            var urls = await sizeCache.observedDirectories()
            guard !Task.isCancelled, self.sizeSessionID == session else { return }
            self.sizeObservedURLs = urls
            urls.append(contentsOf: self.visibleSizeDirectories)
            urls.append(contentsOf: self.pendingSizeRequests.values.map(\.url))
            if let request = self.activeSizeRequest { urls.append(request.url) }
            self.sizeWatcher?.watch(urls)
            self.sizeWatchTask = nil
            let retained = Set(urls.map(\.path)).union(self.entries.map(\.id))
            self.sizeRecords = self.sizeRecords.filter { retained.contains($0.key) }
            self.lastSizeAttempt = self.lastSizeAttempt.filter { retained.contains($0.key) }
            self.unavailableSizeIDs.formIntersection(retained)
        }
    }

    /// The owning cache file was deleted by cleanup. Forget queued and
    /// in-flight requests so a finishing scan cannot write old roots back;
    /// visible rows fall back to the pending state.
    func resetSizeCache() async {
        sizeTask?.cancel()
        sizeTask = nil
        activeSizeRequest = nil
        pendingSizeRequests.removeAll()
        sizeRequestOrder.removeAll()
        urgentSizeIDs.removeAll()
        lastSizeAttempt.removeAll()
        unavailableSizeIDs.removeAll()
        pendingSizeChanges.removeAll()
        sizeRecords.removeAll()
        sizeObservedURLs = []
        await sizeCache.reset()
        updateSizeActivity()
        scheduleSizeWatcherUpdate()
    }

    /// Explicit teardown for model fixtures and owners that release the workspace.
    /// Normal tab switching deliberately calls suspend() instead.
    func stopSizeBackgroundWork() {
        sizeSessionID = UUID()
        sizeTimer?.invalidate()
        sizeTimer = nil
        sizeWatcher?.stop()
        sizeWatcher = nil
        sizeTask?.cancel()
        sizeScheduleTask?.cancel()
        sizeWatchTask?.cancel()
        sizeChangeTask?.cancel()
        sizeTask = nil
        sizeScheduleTask = nil
        sizeWatchTask = nil
        sizeChangeTask = nil
        pendingSizeRequests.removeAll()
        pendingSizeChanges.removeAll()
        sizeRequestOrder.removeAll()
        urgentSizeIDs.removeAll()
        activeSizeRequest = nil
        sizeObservedURLs = []
        sizeCalibrationRequested = false
        sizeBackgroundStarted = false
        updateSizeActivity()
    }

    func select(entry: DirectoryEntry, extending: Bool, range: Bool = false) {
        if range, let anchor = selectionAnchor,
           let start = entries.firstIndex(where: { $0.id == anchor }),
           let end = entries.firstIndex(where: { $0.id == entry.id }) {
            let rangeIDs = Set(entries[min(start, end)...max(start, end)].map(\.id))
            selectedIDs = extending ? selectedIDs.union(rangeIDs) : rangeIDs
        } else if extending {
            if selectedIDs.contains(entry.id) { selectedIDs.remove(entry.id) } else { selectedIDs.insert(entry.id) }
            selectionAnchor = entry.id
        } else {
            selectedIDs = [entry.id]
            selectionAnchor = entry.id
        }
    }

    func open(entry: DirectoryEntry) {
        if entry.isDirectory { navigate(to: entry.url) }
        else if !NSWorkspace.shared.open(entry.url) { errorMessage = L10n.shared.t("dir.error.open") }
    }
    func revealSelectionInFinder() {
        let urls = selectedEntries.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [breadcrumbDirectory] : urls)
    }
    func copySelection() { writeClipboard(cutting: false) }
    func cutSelection() { writeClipboard(cutting: true) }
    private func writeClipboard(cutting: Bool) {
        let urls = selectedEntries.map(\.url)
        guard !urls.isEmpty else { return }
        let clipboard = pasteboard
        clipboard.clearContents()
        clipboard.writeObjects(urls as [NSURL])
        cutURLs = cutting ? urls : []
        cutChangeCount = cutting ? clipboard.changeCount : -1
        statusMessage = L10n.shared.tf(cutting ? "dir.cut.done" : "dir.copy.done", urls.count)
        updateClipboardState()
    }
    private func updateClipboardState() {
        let clipboard = pasteboard
        guard clipboard.changeCount != clipboardChangeCount else { return }
        clipboardChangeCount = clipboard.changeCount
        canPaste = clipboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if cutChangeCount != clipboard.changeCount { cutURLs = []; cutChangeCount = -1 }
    }
    func paste(into directory: URL? = nil) {
        let clipboard = pasteboard
        let urls = (clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { errorMessage = L10n.shared.t("dir.error.clipboard"); return }
        let moving = clipboard.changeCount == cutChangeCount && Set(urls) == Set(cutURLs)
        let destination = directory ?? breadcrumbDirectory
        perform(changedPaths: moving ? urls : [], itemCount: urls.count, consumedCutURLs: moving ? urls : []) {
            moving ? try DirectoryFileService.move(urls, into: destination) : try DirectoryFileService.copy(urls, into: destination)
        }
    }
    func importFiles(_ urls: [URL], into directory: URL? = nil) {
        let destination = directory ?? breadcrumbDirectory
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        perform(changedPaths: [], itemCount: files.count) { try DirectoryFileService.copy(files, into: destination) }
    }
    func renameSelected(to name: String) {
        guard let item = selectedEntries.first, selectedIDs.count == 1 else { return }
        perform(changedPaths: [item.url], itemCount: 1) {
            [try DirectoryFileService.rename(item.url, to: name)]
        }
    }
    func createFolder(name: String) {
        let destination = breadcrumbDirectory
        perform(changedPaths: [], itemCount: 1) { [try DirectoryFileService.createDirectory(in: destination, name: name)] }
    }
    func createFile(name: String) {
        let destination = breadcrumbDirectory
        perform(changedPaths: [], itemCount: 1) { [try DirectoryFileService.createFile(in: destination, name: name)] }
    }
    func trashSelection() {
        let urls = selectedEntries.map(\.url)
        guard !urls.isEmpty else { return }
        perform(changedPaths: urls, itemCount: urls.count) { try DirectoryFileService.trash(urls); return [] }
    }
    private func perform(changedPaths: [URL], itemCount: Int, consumedCutURLs: [URL] = [],
                         action: @escaping @Sendable () throws -> [URL]) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try action() } }.value
            guard let self else { return }
            self.isWorking = false
            var updatedPaths = changedPaths
            switch result {
            case .success(let urls):
                updatedPaths += urls
                self.statusMessage = L10n.shared.tf("dir.operation.done", itemCount)
                if !consumedCutURLs.isEmpty, self.cutURLs == consumedCutURLs,
                   self.pasteboard.changeCount == self.cutChangeCount {
                    self.pasteboard.clearContents()
                    self.pasteboard.writeObjects(urls as [NSURL])
                    self.cutURLs = []
                    self.cutChangeCount = -1
                    self.updateClipboardState()
                }
            case .failure(let error):
                if let batch = error as? DirectoryFileBatchError {
                    updatedPaths += batch.succeededURLs
                    if batch.operation == .move, !consumedCutURLs.isEmpty,
                       self.cutURLs == consumedCutURLs, self.pasteboard.changeCount == self.cutChangeCount {
                        let failedURLs = batch.failures.map(\.url)
                        self.pasteboard.clearContents()
                        self.pasteboard.writeObjects(failedURLs as [NSURL])
                        self.cutURLs = failedURLs
                        self.cutChangeCount = self.pasteboard.changeCount
                        self.updateClipboardState()
                    }
                    self.statusMessage = L10n.shared.tf("dir.operation.partial", batch.succeededURLs.count,
                        batch.failures.count, batch.failures.map { $0.url.lastPathComponent + ": " + $0.message }.joined(separator: "\n"))
                } else { self.statusMessage = nil }
                self.errorMessage = L10n.shared.tf("dir.error.operation", error.localizedDescription)
            }
            if self.isActive {
                let failure = self.errorMessage
                self.reloadDirectory()
                self.errorMessage = failure
            }
            self.invalidateSizes(paths: updatedPaths)
            self.enqueueIndexChanges(updatedPaths)
        }
    }

    private func enqueueIndexChanges(_ paths: [URL]) {
        guard let index else { return }
        pendingIndexChanges.formUnion(paths)
        guard !isIndexing, indexRefreshTask == nil, !pendingIndexChanges.isEmpty else { return }
        indexRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !self.pendingIndexChanges.isEmpty, !self.isIndexing {
                let paths = Array(self.pendingIndexChanges)
                self.pendingIndexChanges.removeAll()
                do { try await index.refresh(paths: paths); await self.readIndexStatus() }
                catch { self.errorMessage = L10n.shared.tf("dir.index.failed", error.localizedDescription) }
            }
            self.indexRefreshTask = nil
            if self.isActive, self.hasSearchQuery { self.updateSearch() }
        }
    }

    private func readIndexStatus() async {
        guard let index else { return }
        do {
            let status = try await index.status()
            indexCount = status.indexedItemCount
            indexUpdated = status.lastUpdated
            indexRoots = status.roots
        } catch { errorMessage = L10n.shared.tf("dir.index.failed", error.localizedDescription) }
    }
    func rebuildIndex() { buildIndex(roots: indexRoots.isEmpty ? [homeDirectory] : indexRoots) }
    func chooseIndexFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.buildIndex(roots: (self.indexRoots.isEmpty ? [self.homeDirectory] : self.indexRoots) + [url])
            }
        }
    }
    private func buildIndex(roots: [URL]) {
        guard !isIndexing, let index else { return }
        guard indexRefreshTask == nil else {
            statusMessage = L10n.shared.t("dir.searchError.busy")
            return
        }
        isIndexing = true
        indexScanned = 0
        indexSkipped = 0
        errorMessage = nil
        indexTask = Task { [weak self] in
            do {
                let status = try await index.rebuild(roots: roots) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.indexScanned = progress.scannedCount
                        self?.indexSkipped = progress.skippedCount
                    }
                }
                guard let self else { return }
                self.indexRoots = status.roots
                self.indexCount = status.indexedItemCount
                self.indexUpdated = status.lastUpdated
                self.isIndexing = false
                self.enqueueIndexChanges([])
                if self.isActive { self.updateSearch() }
            } catch {
                guard let self else { return }
                self.isIndexing = false
                self.enqueueIndexChanges([])
                if Task.isCancelled { self.statusMessage = L10n.shared.t("dir.index.cancelled") }
                else { self.errorMessage = L10n.shared.tf("dir.index.failed", error.localizedDescription) }
            }
        }
    }
    func cancelIndexing() { indexTask?.cancel() }

    /// The index database file is protected at the deletion edge; cleanup
    /// empties it in place through SQL instead of unlinking the open database.
    func clearSearchIndex() async throws {
        guard let index else { return }
        try await index.clear()
        await readIndexStatus()
    }
}

/// Search is global, but the current browsing location supplies result priority.
enum DirectorySearchRanking {
    static func locationPriority(_ url: URL, directory: URL) -> Int {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        if parent == root { return 0 }
        let prefix = root == "/" ? "/" : root + "/"
        if parent.hasPrefix(prefix) || url.standardizedFileURL.path == root { return 1 }
        return 2
    }

    static func sorted(_ entries: [DirectoryEntry], query: String, directory: URL) -> [DirectoryEntry] {
        let foldedQuery = DirectoryPathQuery.fold(query)
        // Compute I/O-dependent ranks once per entry, outside the comparator.
        let ranked = entries.map { entry in
            (entry: entry, location: locationPriority(entry.url, directory: directory),
             exact: DirectoryPathQuery.fold(entry.name) == foldedQuery)
        }
        return ranked.sorted { left, right in
            if left.location != right.location { return left.location < right.location }
            if left.exact != right.exact { return left.exact }
            let order = left.entry.name.localizedStandardCompare(right.entry.name)
            if order != .orderedSame { return order == .orderedAscending }
            return left.entry.id < right.entry.id
        }.map { $0.entry }
    }
}
