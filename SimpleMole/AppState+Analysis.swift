import Foundation

/// Owns the pending scan, active cancellation token and outstanding repairs.
@MainActor
final class AnalysisRuntimeState {
    fileprivate var cacheRefreshCount = 0
    fileprivate var pendingScan: (mode: AnalyzeMode, forceFull: Bool)?
    fileprivate var scanControl: CleanupScanControl?
    fileprivate var visible = false
    fileprivate var loadedModes = Set<AnalyzeMode>()
    fileprivate var restoreTask: Task<Void, Never>?
    fileprivate var releaseTask: Task<Void, Never>?
    fileprivate var restoreToken = UUID()
}

@MainActor
extension AppState {
    // MARK: - 磁盘分析

    func applyAnalysisSummaries(_ summaries: [AnalysisInventoryKind: AnalysisInventorySummary]) {
        for (kind, summary) in summaries {
            let mode = analysisMode(for: kind)
            analysisSummariesByMode[mode] = summary
            if analysisScanDates[mode] == nil { analysisScanDates[mode] = summary.scannedAt }
            if !analysisRuntime.loadedModes.contains(mode) { analysisReportsByMode[mode] = summary.report }
            if analysisStatuses[mode] == nil {
                analysisStatuses[mode] = l10n.t(summary.report.isPartial == true ? "analyze.scan.partial" : "analyze.scan.scope")
            }
        }
    }

    func resumeAnalysisPresentation() {
        analysisRuntime.visible = true
        analysisRuntime.releaseTask?.cancel()
        restoreAnalysisPageIfVisible()
    }

    func pauseAnalysisPresentation() {
        analysisRuntime.visible = false
        analysisRuntime.restoreTask?.cancel()
        analysisRuntime.restoreToken = UUID()
        isRestoringAnalysis = false
        scheduleAnalysisDetailRelease()
    }

    func restoreAnalysisPageIfVisible() {
        guard analysisRuntime.visible else { return }
        let mode = analyzeMode
        analysisRuntime.restoreTask?.cancel()
        analysisRuntime.restoreToken = UUID()
        let token = analysisRuntime.restoreToken
        guard let kind = analysisInventoryKind(for: mode), !analysisRuntime.loadedModes.contains(mode) else {
            isRestoringAnalysis = false
            scheduleAnalysisDetailRelease()
            return
        }
        isRestoringAnalysis = true
        let cache = analysisInventoryCache
        analysisRuntime.restoreTask = Task { [weak self] in
            let restored = await Task.detached(priority: .utility) { cache.restoreState(for: kind) }.value
            guard let self, !Task.isCancelled, self.analysisRuntime.restoreToken == token else { return }
            self.isRestoringAnalysis = false
            guard restored.revision == cache.currentRevision else { self.restoreAnalysisPageIfVisible(); return }
            if let snapshot = restored.snapshots[kind] {
                self.analysisRuntime.loadedModes.insert(mode)
                self.analysisReportsByMode[mode] = restored.reports[kind]
                self.analysisScanDates[mode] = snapshot.scannedAt
                if let report = restored.reports[kind] {
                    self.analysisSummariesByMode[mode] = .init(snapshot: snapshot, report: report)
                }
                if kind == .disk { self.publishDiskBrowser(restored.diskBrowser) }
            } else {
                self.analysisReportsByMode.removeValue(forKey: mode)
                self.analysisSummariesByMode.removeValue(forKey: mode)
                self.analysisScanDates.removeValue(forKey: mode)
            }
            self.publishAnalysisReports()
            self.scheduleAnalysisDetailRelease()
            self.runScheduledAnalysisScans()
        }
    }

    private func scheduleAnalysisDetailRelease() {
        analysisRuntime.releaseTask?.cancel()
        analysisRuntime.releaseTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            guard let self else { return }
            guard !self.isAnalysisTaskBusy else { self.scheduleAnalysisDetailRelease(); return }
            let token = self.analysisRuntime.restoreToken
            let kind = self.analysisRuntime.visible ? self.analysisInventoryKind(for: self.analyzeMode) : nil
            let retained = Set(kind.map { [$0] } ?? [])
            let cache = self.analysisInventoryCache
            let released = await Task.detached(priority: .utility) { cache.releaseDetails(except: retained) }.value
            guard self.analysisRuntime.restoreToken == token else { return }
            for kind in released {
                let mode = self.analysisMode(for: kind)
                self.analysisRuntime.loadedModes.remove(mode)
                self.analysisReportsByMode[mode] = self.analysisSummariesByMode[mode]?.report
                if kind == .disk { self.diskBrowserEntriesByPath = [:] }
            }
            self.publishAnalysisReports()
        }
    }

    func analysisResultCount(for mode: AnalyzeMode) -> Int {
        if !analysisRuntime.loadedModes.contains(mode), let summary = analysisSummariesByMode[mode] { return summary.itemCount }
        if mode == .disk { return diskBrowserEntries(at: diskBrowserRootPath).count }
        return mode == .duplicates ? duplicateGroups.count : analysisFileItems(for: mode).count
    }

    func resetAnalysisPresentationCache() {
        analysisRuntime.restoreTask?.cancel()
        analysisRuntime.releaseTask?.cancel()
        analysisRuntime.restoreToken = UUID()
        analysisRuntime.loadedModes = []
        analysisSummariesByMode = [:]
        isRestoringAnalysis = false
    }

    /// Compatibility entry point: a requested re-scan now updates only the
    /// current section through its incremental directory/file index.
    func scanDiskOverview(force: Bool = false) {
        let requested = analysisRuntime.pendingScan ?? (mode: analyzeMode, forceFull: false)
        if !force, analysisRuntime.pendingScan == nil, analysisHasScanned(requested.mode) { return }
        scanAnalysisMode(requested.mode, forceFull: requested.forceFull)
    }

    func analysisHasScanned(_ mode: AnalyzeMode) -> Bool {
        mode == .duplicates ? duplicateScanFinished : analysisScanDates[mode] != nil
    }

    func analysisStatus(for mode: AnalyzeMode) -> String {
        mode == .duplicates ? duplicateStatus : analysisStatuses[mode] ?? ""
    }

    func analysisScanDate(for mode: AnalyzeMode) -> Date? {
        mode == .duplicates ? duplicateLastScanDate : analysisScanDates[mode]
    }

    func scanAnalysisMode(_ mode: AnalyzeMode, forceFull: Bool = false) {
        guard !isAnalysisTaskBusy, !isAnalyzing, !isScanningDuplicates, !isDeletingAnalysisFiles, !isRestoringAnalysis else { return }
        if mode == .duplicates {
            scanDuplicateFiles(forceFull: forceFull)
            return
        }
        analysisRuntime.pendingScan = (mode, forceFull)
        guard authorize(.diskOverview(force: true), presentingPermissionCenter: true),
              fullDiskScanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1",
              let kind = analysisInventoryKind(for: mode) else { return }
        analysisRuntime.pendingScan = nil
        noteAnalysisScanAttempt(for: mode)
        let control = CleanupScanControl(mode: .deep)
        analysisRuntime.scanControl = control
        analysisInventoryScanMode = mode
        analysisScanIsFull = forceFull || !analysisHasScanned(mode)
        isAnalyzing = true
        analysisStatuses[mode] = l10n.t("analyze.scanning")
        if analyzeMode == mode {
            analyzeCurrentPath = ""
            analyzeStatus = analysisStatuses[mode] ?? ""
        }
        let cache = analysisInventoryCache
        let progress: (String, UInt64) -> Void = { [weak self] path, bytes in
            Task { @MainActor [weak self] in
                guard let self, self.analysisRuntime.scanControl === control, !control.isCancelled else { return }
                let status = "\(self.l10n.t("common.scanning")) · ≥ \(ByteFormat.format(bytes))"
                self.analysisStatuses[mode] = status
                if self.analyzeMode == mode {
                    self.analyzeCurrentPath = path
                    self.analyzeStatus = status
                }
            }
        }
        Task {
            let result = await Task.detached(priority: .utility) {
                cache.scan(kind, forceFull: forceFull, control: control, progress: progress)
            }.value
            guard analysisRuntime.scanControl === control else { return }
            analysisRuntime.scanControl = nil
            analysisInventoryScanMode = nil
            isAnalyzing = false
            analysisScanIsFull = false
            let completion: DiskAnalysisWorker.Completion
            if control.isCancelled { completion = .cancelled }
            else if result.report.error != nil { completion = .failed }
            else if result.snapshot.issueCount > 0 { completion = .partial }
            else { completion = .complete }
            if result.cacheRevision == cache.currentRevision {
                if result.canReuse, !control.isCancelled {
                    // Include prior mutation repairs for other sections. An
                    // earlier repair publication may have been superseded by
                    // this scan's newer cache revision.
                    for (cachedKind, cachedSnapshot) in result.cachedSnapshots {
                        let cachedMode = analysisMode(for: cachedKind)
                        analysisReportsByMode[cachedMode] = result.cachedReports[cachedKind]
                        if cachedKind != .disk || result.diskBrowser != nil { analysisRuntime.loadedModes.insert(cachedMode) }
                        if cachedKind == .disk { publishDiskBrowser(result.diskBrowser) }
                        analysisScanDates[cachedMode] = cachedSnapshot.scannedAt
                        if let report = result.cachedReports[cachedKind] {
                            analysisSummariesByMode[cachedMode] = .init(snapshot: cachedSnapshot, report: report)
                        }
                    }
                } else if completion == .partial, analysisScanDates[mode] == nil {
                    // First-scan partial data is useful to review, while the
                    // absent completion date keeps it out of result reuse.
                    analysisReportsByMode[mode] = result.report
                    analysisRuntime.loadedModes.insert(mode)
                }
            }
            // A re-scan keeps the previous usable report until its replacement
            // succeeds. Empty successful inventories still carry a scan date.
            switch completion {
            case .complete: analysisStatuses[mode] = l10n.t("analyze.scan.scope")
            case .partial: analysisStatuses[mode] = l10n.t("analyze.scan.partial")
            case .cancelled: analysisStatuses[mode] = l10n.t("scan.reason.cancelled")
            case .failed: analysisStatuses[mode] = l10n.t("analyze.scan.failed")
            }
            analysisDetailsByMode[mode] = completion == .partial || completion == .failed
                ? DiskAnalysisWorker.failureDetails(for: result.report, using: l10n.t) : []
            publishAnalysisReports()
            noteHeaderReaction(NoriHeaderReaction.mood(
                succeeded: completion == .complete, cancelled: completion == .cancelled))
            if completion == .failed {
                presentTaskFailure(message: l10n.t("analyze.scan.failed"),
                    details: DiskAnalysisWorker.failureDetails(for: result.report, using: l10n.t),
                    detailsAreLocalized: true)
            }
            runScheduledAnalysisScans()
            scheduleAnalysisDetailRelease()
        }
    }

    func cancelAnalyze() { analysisRuntime.scanControl?.cancel() }

    /// Delete/compression callers pass the exact changed paths after the native
    /// executor confirms them. All cached sections are repaired without walking
    /// the rest of the filesystem.
    func refreshAnalysisAfterMutation(removedPaths: Set<String>, changedPaths: Set<String> = []) {
        guard !removedPaths.isEmpty || !changedPaths.isEmpty else { return }
        // Do not publish a traversal that raced with these filesystem mutations.
        analysisRuntime.scanControl?.cancel()
        duplicateScanControl?.cancel()
        func removed(_ path: String) -> Bool {
            if removedPaths.contains(path) || removedPaths.contains("/") { return true }
            var ancestor = (path as NSString).deletingLastPathComponent
            while ancestor != "/" && !ancestor.isEmpty {
                if removedPaths.contains(ancestor) { return true }
                let next = (ancestor as NSString).deletingLastPathComponent
                if next == ancestor { break }
                ancestor = next
            }
            return false
        }
        analyzeLargeFiles.removeAll { removed($0.path) }
        analyzeMedia.removeAll { removed($0.path) }
        slimSelection = slimSelection.filter { !removed($0) }
        analysisFileSelection = analysisFileSelection.filter { !removed($0) }
        for mode in Array(analysisFileSelectionsByMode.keys) {
            analysisFileSelectionsByMode[mode] = analysisFileSelectionsByMode[mode]?.filter { !removed($0) }
        }
        refreshDuplicateResultsAfterMutation(removedPaths: removedPaths, changedPaths: changedPaths)
        let cache = analysisInventoryCache
        analysisRuntime.cacheRefreshCount += 1
        isRefreshingAnalysisCache = true
        Task {
            let refreshed = await Task.detached(priority: .utility) {
                cache.refreshState(removedPaths: removedPaths, changedPaths: changedPaths)
            }.value
            defer {
                analysisRuntime.cacheRefreshCount -= 1
                isRefreshingAnalysisCache = analysisRuntime.cacheRefreshCount > 0
                if !isRefreshingAnalysisCache { runScheduledAnalysisScans() }
            }
            guard refreshed.revision == cache.currentRevision else { return }
            for (kind, snapshot) in refreshed.snapshots {
                let mode = analysisMode(for: kind)
                analysisReportsByMode[mode] = refreshed.reports[kind]
                analysisRuntime.loadedModes.insert(mode)
                if kind == .disk { publishDiskBrowser(refreshed.diskBrowser) }
                analysisScanDates[mode] = snapshot.scannedAt
                if let report = refreshed.reports[kind] {
                    analysisSummariesByMode[mode] = .init(snapshot: snapshot, report: report)
                }
            }
            publishAnalysisReports()
            scheduleAnalysisDetailRelease()
        }
    }

    private func analysisInventoryKind(for mode: AnalyzeMode) -> AnalysisInventoryKind? {
        switch mode {
        case .disk: return .disk
        case .largeFiles: return .largeFiles
        case .images: return .images
        case .videos: return .videos
        case .duplicates: return nil
        }
    }

    func analysisMode(for kind: AnalysisInventoryKind) -> AnalyzeMode {
        switch kind {
        case .disk: return .disk
        case .largeFiles: return .largeFiles
        case .images: return .images
        case .videos: return .videos
        }
    }

    func publishDiskBrowser(_ inventory: AnalysisDiskBrowserInventory?) {
        guard let inventory else { return }
        let previous = diskBrowserNavigation
        diskBrowserRootPath = inventory.rootPath
        diskBrowserHomePath = inventory.homePath
        diskBrowserEntriesByPath = inventory.entriesByPath
        var navigation = [inventory.rootPath]
        // A legacy home-only browser becomes overview → home without dropping
        // its existing deeper navigation or rescanning the saved inventory.
        let previousColumns = previous.first == inventory.homePath ? previous : Array(previous.dropFirst())
        if previous.first == inventory.rootPath || previous.first == inventory.homePath {
            for path in previousColumns {
                guard let parent = navigation.last,
                      inventory.entriesByPath[parent]?.contains(where: { $0.path == path && $0.isDir }) == true,
                      inventory.entriesByPath[path] != nil else { break }
                navigation.append(path)
            }
        }
        diskBrowserNavigation = navigation
        if navigation != previous {
            analysisFileSelectionsByMode[.disk] = []
            if analyzeMode == .disk { analysisFileSelection = [] }
        }
    }

    func publishAnalysisReports() {
        analyzeLargeFiles = analysisReportsByMode[.largeFiles]?.largeFiles ?? []
        let imageMedia = analysisReportsByMode[AnalyzeMode.images]?.media ?? []
        let videoMedia = analysisReportsByMode[AnalyzeMode.videos]?.media ?? []
        analyzeMedia = (imageMedia + videoMedia).sorted {
            $0.size == $1.size ? $0.path < $1.path : $0.size > $1.size
        }
        if analysisInventoryScanMode != analyzeMode { analyzeCurrentPath = "" }
        analyzeStatus = analysisStatus(for: analyzeMode)
        let imagePaths = Set(analyzeMedia.filter { $0.kind == .image }.map(\.path))
        if analysisRuntime.loadedModes.contains(.images) { slimSelection.formIntersection(imagePaths) }
        for mode in Array(analysisFileSelectionsByMode.keys) where mode != .duplicates && analysisRuntime.loadedModes.contains(mode) {
            let available: Set<String>
            switch mode {
            case .disk: available = Set(analysisFileItems(for: .disk).map(\.path))
            case .largeFiles: available = Set(analyzeLargeFiles.map(\.path))
            case .images: available = imagePaths
            case .videos: available = Set(analyzeMedia.filter { $0.kind == .video }.map(\.path))
            case .duplicates: continue
            }
            analysisFileSelectionsByMode[mode]?.formIntersection(available)
        }
        analysisFileSelection = analysisSelection(for: analyzeMode)
    }
}
