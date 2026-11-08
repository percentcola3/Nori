import Foundation
import os

/// Cleanup cancellation, progress generations and retry actions share one
/// session owner; presentation values remain Published on AppState.
@MainActor
final class CleanupRuntimeState {
    fileprivate var retryAction: (() -> Void)?
    fileprivate var taskGeneration = UUID()
    fileprivate var scanControl: CleanupScanControl?
    fileprivate var progressGeneration = 0
    fileprivate var administratorRequiredPaths = Set<String>()
    fileprivate var traceRequestID: UUID?
    fileprivate var confirmationToken: UUID?
    fileprivate var reviewedSelection: ReviewedSelection?

    struct ReviewedSelection {
        let categories: [CleanupCategory]
        let installers: CleanupCategory?
        let maintenanceIDs: [String]
        let family: CleanupFamily
        let generation: UUID
        let selectedCount: Int
    }
}

@MainActor
extension AppState {
    // MARK: - 扫描

    private func beginCleanupProgress(mode: CleanupScanMode = .quick) {
        cleanupOutcomeMood = nil
        cleanupOutcomeDetails = []
        cleanupReclaimedBytes = 0
        cleanupCelebrating = false
        cleanupTaskProgress = nil
        cleanupRuntime.retryAction = nil
        cleanupRetryAvailable = false
        cleanupFailureApplications = []
        cleanupRuntime.taskGeneration = UUID()
        cleanupRuntime.progressGeneration += 1
        cleanupScanMode = mode
        cleanupDeferredPaths = []
        cleanupProgress = CleanupScanProgress(
            phase: l10n.t("cleanup.progress.discovery"),
            completed: 0,
            total: 0,
            currentPath: NSHomeDirectory())
    }

    private func cleanupProgressSink() -> CleanupScanProgressSink {
        let generation = cleanupRuntime.progressGeneration
        return CleanupScanProgressSink { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self,
                      self.cleanupRuntime.progressGeneration == generation,
                      self.isCleanupScanning else { return }
                guard !self.cleanupProgress.isComplete else { return }
                var progress = self.cleanupProgress
                progress.currentPath = event.currentPath
                switch event.phase {
                case "discovery": progress.phase = self.l10n.t("cleanup.progress.discovery")
                case "occupancy": progress.phase = self.l10n.t("cleanup.progress.occupancy")
                default: progress.phase = self.l10n.t("cleanup.progress.scanning")
                }
                if event.phase == "native", event.total > 0 {
                    progress.completed = max(progress.completed, event.completed)
                    progress.total = event.total
                    progress.detailCompleted = progress.completed
                    progress.detailTotal = event.total
                }
                if progress != self.cleanupProgress { self.cleanupProgress = progress }
            }
        }
    }

    func cancelCleanupScan() {
        cleanupRuntime.scanControl?.cancel()
    }

    private func finishCleanupProgress() {
        let total = max(1, cleanupProgress.total)
        cleanupProgress.completed = total
        cleanupProgress.total = total
        cleanupProgress.isComplete = true
        cleanupProgress.detailCompleted = max(cleanupProgress.detailCompleted,
                                              cleanupProgress.detailTotal)
        cleanupProgress.phase = l10n.t("cleanup.progress.done")
        cleanupProgress.currentPath = l10n.t("cleanup.progress.done")
    }

    func scanCleanup(force: Bool = false, mode: CleanupScanMode = .quick,
                     deepFollowUp: Bool = false,
                     excludingScannedRoots: Set<String> = [],
                     completedCategories: [CleanupCategory] = []) {
        let operation: ProtectedOperation = mode == .deep ? .deepCleanupScan : .cleanupScan(force: force)
        guard authorize(operation, presentingPermissionCenter: true) else {
            return
        }
        guard !isCleanupTaskBusy else { return }
        family = .clean
        installerCandidates = nil
        categories = []
        if excludingScannedRoots.isEmpty { cleanupRuntime.administratorRequiredPaths = [] }
        beginCleanupProgress(mode: mode)
        isScanning = true
        cleanupScanComplete = false
        statusText = l10n.t("status.scanningCleanup")
        log(l10n.t("log.buildList"))

        Task {
            if mode == .quick, !force,
               let cached = await Task.detached(priority: .utility, operation: { CleanupCache.restore() }).value {
                await restoreCachedCleanup(cached)
                return
            }
            let scan = await unifiedCleanupScan(mode: mode, excludingScannedRoots: excludingScannedRoots)
            let source = await Task.detached(priority: .utility) { completedCategories + scan.categories }.value
            let managed = await appendNoriManagedPaths(to: source)
            let priorAdministratorPaths = cleanupRuntime.administratorRequiredPaths
            let prepared = await Task.detached(priority: .utility) {
                var combined = CleanupRiskPolicy.presentationCategories(managed, running: scan.runningSnapshot)
                if !scan.sourceScansSucceeded {
                    combined = combined.map { $0.clearingSelection() }
                }
                let administratorPaths = priorAdministratorPaths.union(scan.administratorRequiredPaths)
                    .intersection(Set(combined.flatMap(\.paths)))
                let pathCount = combined.reduce(0) { $0 + $1.paths.count }
                let completed = mode == .quick && deepFollowUp && !scan.cancelled && !scan.deferredPaths.isEmpty
                    ? scan.categories.compactMap { category in
                        category.retainingPaths(category.paths.filter { path in
                            NativeCore.isCoveredByScannedRoot(path, roots: scan.completedRoots)
                        })
                    } : []
                if mode == .quick && scan.cacheable { CleanupCache.save(scan.categories) }
                let bytes = Self.uniqueAgentBytes(combined.filter(\.quickCleanEligible).flatMap { category in
                    category.paths.map { ($0, category.pathBytes[$0] ?? 0) }
                })
                return (combined, administratorPaths, pathCount, completed, bytes)
            }.value
            let combined = prepared.0
            categories = combined
            cleanupRuntime.administratorRequiredPaths = prepared.1
            cleanupDeferredPaths = scan.deferredPaths
            cleanupScanComplete = scan.sourceScansSucceeded
            finishCleanupProgress()
            isScanning = false
            noteHeaderReaction(cleanupScanComplete ? .success : .attention)

            scan.results.filter { !$0.succeeded }.forEach { logFailure($0, notifyingUser: false) }
            let willDeepFollowUp = deepFollowUp && mode == .quick && !scan.cancelled
                && !scan.deferredPaths.isEmpty
            if !scan.sourceScansSucceeded && !scan.cancelled && !willDeepFollowUp {
                presentTaskFailure(message: l10n.t("log.scanPartial"), details:
                    scan.results.filter { !$0.succeeded }.map(\.diagnosticOutput))
            }
            if combined.isEmpty {
                statusText = scan.sourceScansSucceeded
                    ? l10n.t("status.scanEmpty")
                    : l10n.t("log.scanPartial")
                log(scan.sourceScansSucceeded ? l10n.t("log.scanEmpty") : l10n.t("log.scanPartial"))
            } else {
                statusText = scan.sourceScansSucceeded
                    ? l10n.tf("status.scanDone", combined.count)
                    : l10n.t("log.scanPartial")
                log(scan.sourceScansSucceeded
                    ? l10n.tf("log.scanDone", prepared.2,
                              ByteFormat.format(prepared.4))
                    : l10n.t("log.scanPartial"))
            }
            // Persist a successful empty result as well as a non-empty one.
            // A manual request may reuse a valid snapshot, including an
            // empty one. The cache stores only static scanner output; runtime
            // protection is still reapplied on every restore/use.
            // Cache encoding and persistence finished on the utility executor
            // before releasing this scan's busy state.
            // 合并入口的自动升级：快速扫描有 45s/8s 限时，被截断的目录
            // 直接续跑深度补扫，用户只感知一次“扫描”。
            if deepFollowUp, mode == .quick, !scan.cancelled, !scan.deferredPaths.isEmpty {
                log(l10n.t("cleanup.scan.deepFollowUp"))
                statusText = l10n.t("cleanup.scan.deepFollowUp")
                scanCleanup(force: true, mode: .deep, excludingScannedRoots: scan.completedRoots,
                            completedCategories: prepared.3)
            }
        }
    }

    /// Disk cache decode, recursive preflight and final presentation are all
    /// prepared away from MainActor. A cache never bypasses the worker boundary.
    private func restoreCachedCleanup(_ cached: (categories: [CleanupCategory], age: TimeInterval)) async {
        let control = CleanupScanControl(mode: .deep)
        cleanupRuntime.scanControl = control
        defer { cleanupRuntime.scanControl = nil }
        async let runtime = captureRunningApplicationSnapshot()
        let preflight = await CleanupScanProcess.scanCleanup(progress: cleanupProgressSink(), mode: .deep,
            control: control, includingAdministratorRequired: true, cachedCategories: cached.categories)
        let snapshot = await runtime
        let managed = await appendNoriManagedPaths(to: preflight.categories)
        let succeeded = preflight.succeeded && !control.isCancelled
        let prepared = await Task.detached(priority: .utility) {
            var combined = CleanupRiskPolicy.presentationCategories(managed, running: snapshot)
            if !succeeded {
                combined = combined.map { $0.clearingSelection() }
                CleanupCache.invalidate()
            }
            let bytes = Self.uniqueAgentBytes(combined.filter(\.quickCleanEligible).flatMap { category in
                category.paths.map { ($0, category.pathBytes[$0] ?? 0) }
            })
            return (combined, combined.reduce(0) { $0 + $1.paths.count }, bytes)
        }.value
        categories = prepared.0
        cleanupDeferredPaths = preflight.deferredPaths
        cleanupRuntime.administratorRequiredPaths = preflight.administratorRequiredPaths
        cleanupScanComplete = succeeded
        if !preflight.diagnostics.isEmpty { log(preflight.diagnostics) }
        finishCleanupProgress()
        isScanning = false
        noteHeaderReaction(succeeded ? .success : .attention)
        let minutes = max(1, Int(cached.age / 60))
        statusText = succeeded ? l10n.tf("status.cacheRestored", minutes) : l10n.t("log.scanPartial")
        log(l10n.tf("log.cacheUsed", prepared.1, ByteFormat.format(prepared.2)))
        if !succeeded, !control.isCancelled {
            presentTaskFailure(message: statusText, details: [preflight.error ?? ""])
        }
    }

    /// 清理页唯一的扫描入口：先限时快速扫描给出结果，未完成的目录自动
    /// 升级为深度补扫。只准备清单，绝不自动打开确认或后台删除。
    func startCleanupScan() {
        guard !isCleanupTaskBusy else { return }
        family = .clean
        jump(to: .cleanup)
        scanCleanup(force: true, mode: .quick, deepFollowUp: true)
    }

    // MARK: - 系统维护（原系统优化页分流能力）

    /// 清理页“系统数据库”卡片：只体检、列出可执行项，逐项确认后执行。
    func scanSystemMaintenance() {
        guard !isCleanupTaskBusy else { return }
        isSystemMaintenanceRunning = true
        systemMaintenanceStatus = l10n.t("sysmaint.status.inspecting")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let rows = await NativeCore.shared.inspectSystemMaintenance()
            self.systemMaintenanceRows = rows.filter { $0.preview.need == .needed }
            self.systemMaintenanceSelection.formIntersection(self.systemMaintenanceRows.map(\.id))
            self.isSystemMaintenanceRunning = false
            self.systemMaintenanceStatus = self.systemMaintenanceRows.isEmpty
                ? l10n.t("sysmaint.status.clean")
                : l10n.tf("sysmaint.status.found", self.systemMaintenanceRows.count)
        }
    }

    /// 维护项勾选由统一“清理”分发执行，不再有逐项确认按钮。
    func toggleSystemMaintenance(_ rowID: String) {
        guard !isCleanupTaskBusy else { return }
        if systemMaintenanceSelection.contains(rowID) {
            systemMaintenanceSelection.remove(rowID)
        } else {
            systemMaintenanceSelection.insert(rowID)
        }
    }

    /// 执行单个维护项并刷新该行体检结果。
    private func runSystemMaintenanceTask(_ rowID: String) async -> CleanupExecutionResult {
        guard let row = systemMaintenanceRows.first(where: { $0.id == rowID }) else {
            return CleanupExecutionResult(failed: 1)
        }
        isSystemMaintenanceRunning = true
        systemMaintenanceStatus = l10n.t("sysmaint.status.running")
        let result = await NativeCore.shared.runMaintenanceTask(
            id: row.id, preview: row.preview)
        let fresh = await NativeCore.shared.inspectSystemMaintenance(only: row.id).first
        if let index = systemMaintenanceRows.firstIndex(where: { $0.id == row.id }) {
            if let fresh, fresh.preview.need == .clean,
               result.state == .applied || result.state == .unchanged {
                systemMaintenanceRows.remove(at: index)
                systemMaintenanceSelection.remove(rowID)
            } else if let fresh {
                systemMaintenanceRows[index] = fresh
            }
        }
        isSystemMaintenanceRunning = false
        systemMaintenanceStatus = result.message
        log("\(l10n.t(row.item.titleKey)): \(result.message)")
        let message = "\(l10n.t(row.item.titleKey)): \(result.message)"
        if fresh?.preview.need == .clean,
           result.state == .applied || result.state == .unchanged {
            return CleanupExecutionResult(removed: 1)
        }
        if result.state == .failed || result.state == .unavailable || fresh == nil {
            return CleanupExecutionResult(failed: 1, messages: [message])
        }
        return CleanupExecutionResult(skipped: 1, messages: [message])
    }

    private struct UnifiedCleanupScan {
        let categories: [CleanupCategory]
        /// Keep filesystem scanners separate from the process snapshot. A
        /// process-table failure must not discard completed cache discovery;
        /// the apply boundary still clears/reevaluates runtime-sensitive paths.
        let sourceResults: [RunResult]
        /// Only fully measured paths enter the result. Coverage gaps are
        /// reported separately and prevent persisting a complete snapshot.
        let requiredSourceResults: [RunResult]
        let runtimeResult: RunResult
        let runningSnapshot: RunningApplicationSnapshot
        let deferredPaths: [String]
        /// 用户取消：合并扫描不允许把取消当作“需要深度补扫”。
        let cancelled: Bool
        let completedRoots: Set<String>
        let administratorRequiredPaths: Set<String>

        init(categories: [CleanupCategory], sourceResults: [RunResult],
             requiredSourceResults: [RunResult], runtimeResult: RunResult,
             runningSnapshot: RunningApplicationSnapshot,
             deferredPaths: [String] = [], cancelled: Bool = false,
             completedRoots: Set<String> = [], administratorRequiredPaths: Set<String> = []) {
            self.categories = categories
            self.sourceResults = sourceResults
            self.requiredSourceResults = requiredSourceResults
            self.runtimeResult = runtimeResult
            self.runningSnapshot = runningSnapshot
            self.deferredPaths = deferredPaths
            self.cancelled = cancelled
            self.completedRoots = completedRoots
            self.administratorRequiredPaths = administratorRequiredPaths
        }

        var results: [RunResult] { sourceResults + [runtimeResult] }

        /// Runtime failure does not discard completed cache discovery. The
        /// apply boundary still rechecks every runtime-sensitive path.
        var sourceScansSucceeded: Bool {
            requiredSourceResults.allSatisfy(\.succeeded)
        }

        var cacheable: Bool { sourceScansSucceeded && deferredPaths.isEmpty }
    }

    private func unifiedCleanupScan(mode: CleanupScanMode = .quick,
                                    excludingScannedRoots: Set<String> = []) async -> UnifiedCleanupScan {
        guard permissionCenter.refresh() else {
            let denied = RunResult(
                output: "", errorOutput: "Full Disk Access is required for protected scan.",
                exitCode: 77, timedOut: false)
            return UnifiedCleanupScan(
                categories: [], sourceResults: [denied],
                requiredSourceResults: [denied],
                runtimeResult: denied, runningSnapshot: .unavailable)
        }
        let control = CleanupScanControl(mode: mode)
        cleanupRuntime.scanControl = control
        defer { cleanupRuntime.scanControl = nil }
        let progress = isCleanupScanning ? cleanupProgressSink() : nil
        async let core = CleanupScanProcess.scanCleanup(progress: progress, mode: mode, control: control,
            includingAdministratorRequired: true, excludingScannedRoots: excludingScannedRoots)
        async let runtimeText = Task.detached(priority: .utility) {
            SystemMetrics.processSnapshotText()
        }.value

        let (coreScan, runtimeOutput) = await (core, runtimeText)
        log(coreScan.diagnostics)
        let runtimeResult = RunResult(
            output: runtimeOutput ?? "",
            errorOutput: runtimeOutput == nil ? "Native process snapshot unavailable." : "",
            exitCode: runtimeOutput == nil ? 1 : 0,
            timedOut: false)
        let coreResult = RunResult(
            output: "", errorOutput: coreScan.error ?? "",
            exitCode: coreScan.succeeded ? 0 : 1, timedOut: false)

        // 普通清理只发布已经确认为垃圾的 Safe 单元。安装包可能是唯一
        // 副本，卸载 Agent 整根也可能含历史和凭据，不能借这次扫描推荐。
        let combined = await Task.detached(priority: .utility) {
            CleanupCategory.safeCleanupCandidates(from: coreScan.categories)
                + coreScan.categories.filter(\.isAppDataReview).map { $0.clearingSelection() }
        }.value
        if control.isCancelled {
            let cancelledResult = RunResult(output: "", errorOutput: "Scan cancelled.", exitCode: 1, timedOut: false)
            return UnifiedCleanupScan(categories: [], sourceResults: [cancelledResult],
                requiredSourceResults: [cancelledResult], runtimeResult: runtimeResult,
                runningSnapshot: .unavailable, cancelled: true)
        }


        let snapshot = await Task.detached(priority: .utility) {
            RuntimeStore.runningApplicationSnapshot(
                fromProcessText: runtimeResult.output, isComplete: runtimeResult.succeeded)
        }.value
        return UnifiedCleanupScan(
            categories: combined,
            sourceResults: [coreResult],
            requiredSourceResults: [coreResult],
            runtimeResult: runtimeResult,
            runningSnapshot: snapshot,
            deferredPaths: coreScan.deferredPaths, completedRoots: coreScan.completedRoots,
            administratorRequiredPaths: coreScan.administratorRequiredPaths)
    }

    func captureRunningApplicationSnapshot() async -> RunningApplicationSnapshot {
        let output = await Task.detached(priority: .utility) {
            SystemMetrics.processSnapshotText()
        }.value
        let result = RunResult(
            output: output ?? "",
            errorOutput: output == nil ? "Native process snapshot unavailable." : "",
            exitCode: output == nil ? 1 : 0,
            timedOut: false)
        if !result.succeeded { logFailure(result, notifyingUser: false) }
        return await Task.detached(priority: .utility) {
            RuntimeStore.runningApplicationSnapshot(
                fromProcessText: result.output, isComplete: result.succeeded)
        }.value
    }


    /// 开发工具扫描：包管理器卸载命令，Warning 项留给人工判断。
    func scanDeveloperTools() {
        guard authorize(.developerToolsScan, presentingPermissionCenter: true) else { return }
        guard !isCleanupTaskBusy else { return }
        let scanEnvironment = fullDiskScanEnvironment
        guard scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1" else { return }
        family = .tools
        categories = []
        isScanning = true
        cleanupScanComplete = false
        statusText = l10n.t("status.scanning")
        log(l10n.t("log.scanningSafe"))
        Task {
            let terminalEnvironment = await DeveloperTerminalEnvironmentService.shared.snapshot().environment
            let toolEnvironment = terminalEnvironment.merging(scanEnvironment) { _, authorized in authorized }
            async let scanResult = MoleEngine.shared.runBridge(
                "bin/app_tool_scan.sh", extraEnvironment: toolEnvironment,
                timeout: 180, onLine: streamLog)
            async let runtimeText = Task.detached(priority: .utility) {
                SystemMetrics.processSnapshotText()
            }.value
            let (result, runtimeOutput) = await (scanResult, runtimeText)
            let runtime = RunResult(
                output: runtimeOutput ?? "",
                errorOutput: runtimeOutput == nil ? "Native process snapshot unavailable." : "",
                exitCode: runtimeOutput == nil ? 1 : 0,
                timedOut: false)
            isScanning = false
            cleanupScanComplete = result.succeeded && runtime.succeeded
            noteHeaderReaction(cleanupScanComplete ? .success : .attention)
            // 运行态保护交给执行前的重新评估。
            categories = Parsers.toolCategories(result.output)
                .sorted(by: CleanupCategory.sizeDescending)
            if !cleanupScanComplete {
                for index in categories.indices { categories[index].selected = false }
            }
            if categories.isEmpty {
                statusText = cleanupScanComplete
                    ? l10n.t("status.specialEmpty") : l10n.t("log.specialFail")
                log(cleanupScanComplete ? l10n.t("log.specialEmpty") : l10n.t("log.specialFail"))
                logFailure(result, notifyingUser: false)
            } else {
                statusText = cleanupScanComplete
                    ? l10n.tf("status.scanSpecialDone", categories.count)
                    : l10n.t("log.specialFail")
                log(cleanupScanComplete
                    ? l10n.tf("log.specialDone", categories.reduce(0) { $0 + $1.paths.count },
                              ByteFormat.format(totalBytes))
                    : l10n.t("log.specialFail"))
                logFailure(result, notifyingUser: false)
            }
            logFailure(runtime, notifyingUser: false)
            if !cleanupScanComplete {
                presentTaskFailure(message: statusText, details: [result.diagnosticOutput, runtime.diagnosticOutput])
            }
        }
    }

    // MARK: - 清理执行

    var cleanupTraceRequestID: UUID? { cleanupRuntime.traceRequestID }

    /// The view and the submission boundary share the same inexpensive gates.
    /// This reads scalar state and category counts, never file metadata or paths.
    var cleanupButtonBlockReason: String? {
        if isApplying { return "applying" }
        if isScanning { return "scanning" }
        if cleanupQueued { return "queued" }
        if isAutoCleanupScanning { return "automatic_scan" }
        if isSystemMaintenanceRunning { return "maintenance" }
        if isCleanupSubmissionBlocked { return "shared_mutation" }
        if !cleanupScanComplete { return "scan_incomplete" }
        if !hasCleanupSelection { return "no_selection" }
        if confirmation != nil || taskNotice != nil || uninstallDataReview != nil
            || showPermissionCenter || showAutoCleanupSheet || showWhitelistSheet { return "modal_active" }
        return nil
    }

    var cleanupGateSignature: String {
        [cleanupButtonBlockReason ?? "ready", String(selectedCount), String(categories.count),
         String(cleanupScanComplete), String(isCleanupTaskBusy), String(cleanupQueued),
         String(isCleanupSubmissionBlocked), String(isSystemMaintenanceRunning),
         String(confirmation != nil), String(taskNotice != nil), String(uninstallDataReview != nil),
         String(showPermissionCenter), String(showAutoCleanupSheet), String(showWhitelistSheet)]
            .joined(separator: "|")
    }

    func traceCleanupInteraction(_ event: String, requestID: UUID? = nil,
                                 fields: [String: String] = [:]) {
        var values = fields
        values["gate"] = cleanupButtonBlockReason ?? "ready"
        values["selectedCount"] = String(selectedCount)
        values["categoryCount"] = String(categories.count)
        values["scanComplete"] = String(cleanupScanComplete)
        values["applying"] = String(isApplying)
        values["queued"] = String(cleanupQueued)
        values["mutationBlocked"] = String(isCleanupSubmissionBlocked)
        values["maintenanceRunning"] = String(isSystemMaintenanceRunning)
        values["confirmationActive"] = String(confirmation != nil)
        values["taskNoticeActive"] = String(taskNotice != nil)
        values["scanning"] = String(isScanning)
        values["automaticScan"] = String(isAutoCleanupScanning)
        values["agentMutation"] = String(isAgentMutationBusy)
        values["commandLineMutation"] = String(commandLineToolBusyID != nil)
        values["softwareUpdateMutation"] = String(softwareUpdatingID != nil)
        CleanupTrace.record(event, requestID: requestID ?? cleanupRuntime.traceRequestID, fields: values)
    }

    /// Confirmation belongs to the stable window state. Freeze the reviewed
    /// selection now; a later selection or scan cannot widen the accepted work.
    func requestCleanupFromPage() {
        let requestID = UUID()
        traceCleanupInteraction("button.clicked", requestID: requestID)
        if let reason = cleanupButtonBlockReason {
            traceCleanupInteraction("submission.rejected", requestID: requestID, fields: ["reason": reason])
            statusText = l10n.t(reason == "scan_incomplete" ? "log.scanPartial"
                : reason == "no_selection" ? "cleanup.selectNone" : "island.clean.busy")
            return
        }
        cleanupRuntime.traceRequestID = requestID
        let reviewed = CleanupRuntimeState.ReviewedSelection(categories: categories,
            installers: installerCandidates,
            maintenanceIDs: systemMaintenanceRows.filter { systemMaintenanceSelection.contains($0.id) }.map(\.id),
            family: family, generation: cleanupRuntime.taskGeneration, selectedCount: selectedCount)
        // Selecting uninstall leftovers and pressing Clean is the submission.
        // Preserve their owner/identity metadata for the execution-time review.
        let warnings = reviewed.categories.filter {
            $0.isAppDataReview && $0.source != .appLeftover
                && CleanupSelectionPresentation.selectedCount($0) > 0
        }
        guard !warnings.isEmpty else {
            cleanupRuntime.reviewedSelection = reviewed
            traceCleanupInteraction("confirmation.not_required")
            applyCleanup()
            return
        }
        let token = UUID()
        cleanupRuntime.confirmationToken = token
        let names = warnings.prefix(6).map {
            L10nLocalizationAuditTables.categoryName($0.name, isAppLeftover: $0.source == .appLeftover)
        }.joined(separator: "、")
        confirmation = Confirmation(title: l10n.tf("cleanup.appData.confirm.title", warnings.count),
            message: l10n.tf("cleanup.appData.confirm.message", names),
            confirmLabel: l10n.t("cleanup.appData.confirm.action"), onConfirm: { [weak self] in
                guard let self else { return }
                guard self.cleanupRuntime.confirmationToken == token else {
                    self.traceCleanupInteraction("confirmation.stale_callback", requestID: requestID)
                    return
                }
                self.cleanupRuntime.confirmationToken = nil
                self.traceCleanupInteraction("confirmation.accepted", requestID: requestID)
                self.cleanupRuntime.reviewedSelection = reviewed
                self.applyCleanup()
            })
        traceCleanupInteraction("confirmation.requested", fields: ["warningCategories": String(warnings.count)])
    }

    func cancelCleanupConfirmation() {
        traceCleanupInteraction("confirmation.cancelled")
        cleanupRuntime.confirmationToken = nil
        cleanupRuntime.reviewedSelection = nil
        confirmation = nil
    }

    func applyCleanup() {
        if cleanupRuntime.traceRequestID == nil { cleanupRuntime.traceRequestID = UUID() }
        traceCleanupInteraction("submission.entered")
        let reviewed = cleanupRuntime.reviewedSelection
        cleanupRuntime.reviewedSelection = nil
        guard !isCleanupTaskBusy, !isCleanupSubmissionBlocked,
              cleanupScanComplete else {
            statusText = l10n.t(!cleanupScanComplete ? "log.scanPartial" : "island.clean.busy")
            traceCleanupInteraction("submission.rejected", fields: ["reason": cleanupButtonBlockReason ?? "busy"])
            return
        }
        guard reviewed == nil || reviewed?.generation == cleanupRuntime.taskGeneration else {
            statusText = l10n.t("log.scanPartial")
            traceCleanupInteraction("submission.rejected", fields: ["reason": "review_generation_changed"])
            return
        }
        let installerSource: CleanupCategory?
        if let reviewed { installerSource = reviewed.installers }
        else { installerSource = installerCandidates }
        let maintenanceIDs = reviewed?.maintenanceIDs ?? systemMaintenanceRows
            .filter { systemMaintenanceSelection.contains($0.id) }.map(\.id)
        let count = reviewed?.selectedCount ?? selectedCount
        guard count > 0 || CleanupSelectionPresentation.selectedCount(installerSource) > 0 || !maintenanceIDs.isEmpty else {
            statusText = l10n.t("cleanup.selectNone")
            traceCleanupInteraction("submission.rejected", fields: ["reason": "no_selection"])
            return
        }
        // Task {} inherits MainActor. Snapshot the selection and move the
        // potentially large filtering/sorting pass off the UI executor.
        let source = reviewed?.categories ?? categories
        let applyFamily = reviewed?.family ?? family
        let requestID = cleanupRuntime.traceRequestID
        let sourceGeneration = cleanupRuntime.taskGeneration
        cleanupOutcomeMood = nil
        cleanupOutcomeDetails = []
        cleanupReclaimedBytes = 0
        cleanupCelebrating = false
        cleanupTaskProgress = .init()
        isApplying = true
        statusText = l10n.tf("status.processing",
                             count + CleanupSelectionPresentation.selectedCount(installerSource) + maintenanceIDs.count)
        traceCleanupInteraction("submission.preparing")
        Task {
            let prepared = await Task.detached(priority: .utility) {
                let started = ProcessInfo.processInfo.systemUptime
                CleanupTrace.record("selection.prepare.started", requestID: requestID)
                let subsets = source.compactMap(\.selectedSubset)
                let selected = applyFamily == .clean
                    ? CleanupCategory.manualCleanupCandidates(from: subsets) : subsets
                let installers = installerSource?.selectedSubset
                CleanupTrace.record("selection.prepare.finished", requestID: requestID, fields: [
                    "categories": String(selected.count),
                    "paths": String(selected.reduce(0) { $0 + $1.paths.count }),
                    "elapsedMS": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
                return (selected, installers)
            }.value
            guard cleanupRuntime.taskGeneration == sourceGeneration, isApplying, !Task.isCancelled else {
                traceCleanupInteraction("selection.prepare.abandoned", requestID: requestID,
                    fields: ["reason": "generation_or_cancellation"])
                if cleanupRuntime.taskGeneration == sourceGeneration, Task.isCancelled {
                    cleanupTaskProgress = nil
                    isApplying = false
                }
                return
            }
            traceCleanupInteraction("submission.prepared")
            performApply(categories: prepared.0,
                         family: applyFamily, mode: .manual,
                         installers: prepared.1, maintenanceIDs: maintenanceIDs)
        }
    }

    /// Recheck only selected, exact administrator candidates in the read-only
    /// worker before asking for consent. cachedCategories is a preflight input,
    /// not an inventory-cache lookup; no filesystem fallback runs on MainActor.
    private func freshAdministratorCleanupItems(_ requested: [CleanupCategory],
                                               administratorRequiredPaths: Set<String>,
                                               family: CleanupFamily,
                                               mode: CleanupExecutionMode) async -> [DeletionPlan.Item] {
        traceCleanupInteraction("administrator.preflight.started")
        let preview = await Task.detached(priority: .utility) {
            guard family == .clean else { return ([DeletionPlan.Item](), [CleanupCategory]()) }
            if case .automatic = mode { return ([DeletionPlan.Item](), [CleanupCategory]()) }
            let items = AdministratorCleanupPlan.confirmationItems(requested,
                administratorRequiredPaths: administratorRequiredPaths)
            let paths = Set(items.map(\.record))
            let selected = requested.compactMap { category in
                category.retainingPaths(category.paths.filter(paths.contains))
            }
            return (items, selected)
        }.value
        guard !preview.0.isEmpty, !Task.isCancelled else {
            traceCleanupInteraction("administrator.preflight.not_required", fields: ["cancelled": String(Task.isCancelled)])
            return []
        }
        traceCleanupInteraction("administrator.worker.started", fields: ["proposedItems": String(preview.0.count)])
        let fresh = await CleanupScanProcess.scanCleanup(mode: .deep,
            includingAdministratorRequired: true, cachedCategories: preview.1)
        traceCleanupInteraction("administrator.worker.finished", fields: [
            "succeeded": String(fresh.succeeded), "categories": String(fresh.categories.count)])
        if !fresh.diagnostics.isEmpty { log(fresh.diagnostics) }
        let cancelled = Task.isCancelled
        return await Task.detached(priority: .utility) {
            let identities = fresh.categories.reduce(into: [String: String]()) { result, category in
                guard category.risk == .safe, category.disposal == .permanentDelete,
                      [.genericTrash, .developerCacheTrash, .aiTrash, .xcodeTrash].contains(category.applyRoute) else { return }
                for path in category.paths {
                    let identity = category.pathIdentities[path] ?? ""
                    if let existing = result[path], existing != identity { result[path] = "" }
                    else { result[path] = identity }
                }
            }
            return CleanupExecutionResult.freshlyEligibleAdministratorItems(preview.0,
                freshIdentities: identities, administratorPaths: fresh.administratorRequiredPaths,
                succeeded: fresh.succeeded && !cancelled)
        }.value
    }

    /// 执行阶段再次读取进程表，并按每个类别自己的 route 分流。扫描来源不会再
    /// 因为 UI 合并展示而退化成通用删除入口。安装包走废纸篓路线、系统维护
    /// 逐项执行，都在这同一次“清理”里完成。
    private func performApply(categories requested: [CleanupCategory],
                              family applyFamily: CleanupFamily,
                              mode: CleanupExecutionMode,
                              installers: CleanupCategory? = nil,
                              maintenanceIDs: [String] = [],
                              priorResult: CleanupExecutionResult = .init(),
                              retryScope: [CleanupCategory]? = nil,
                              pendingMaintenanceIDs: [String] = []) {
        traceCleanupInteraction("execution.entered", fields: ["categories": String(requested.count)])
        if uninstallQueue.activeJob != nil {
            guard pendingCleanup == nil else {
                traceCleanupInteraction("execution.rejected", fields: ["reason": "already_queued"])
                return
            }
            traceCleanupInteraction("execution.queued", fields: ["reason": "uninstall_active"])
            cleanupQueued = true
            isApplying = false
            statusText = l10n.t("cleanup.queued")
            pendingCleanup = { [weak self] in
                self?.performApply(categories: requested,
                                   family: applyFamily, mode: mode,
                                   installers: installers, maintenanceIDs: maintenanceIDs,
                                   priorResult: priorResult, retryScope: retryScope,
                                   pendingMaintenanceIDs: pendingMaintenanceIDs)
            }
            return
        }
        guard !isCleanupSubmissionBlocked else {
            traceCleanupInteraction("execution.blocked", fields: ["reason": "shared_mutation"])
            // Selection preparation yields to other pages. Keep the original
            // request intact if another shared mutation claimed the boundary.
            cleanupRuntime.retryAction = { [weak self] in
                self?.performApply(categories: requested,
                                   family: applyFamily, mode: mode,
                                   installers: installers, maintenanceIDs: maintenanceIDs,
                                   priorResult: priorResult, retryScope: retryScope,
                                   pendingMaintenanceIDs: pendingMaintenanceIDs)
            }
            cleanupRetryAvailable = true
            cleanupTaskProgress = nil
            isApplying = false
            statusText = l10n.t("island.clean.busy")
            return
        }
        let requestedCount = requested.reduce(0) { $0 + $1.paths.count }
        let generation = UUID()
        cleanupRuntime.taskGeneration = generation
        cleanupCelebrating = false
        cleanupOutcomeMood = nil
        cleanupOutcomeDetails = []
        cleanupReclaimedBytes = priorResult.reclaimedBytes
        cleanupFailureApplications = []
        cleanupRetryAvailable = false
        cleanupRuntime.retryAction = nil
        cleanupTaskProgress = .init()
        isApplying = true
        statusText = l10n.tf("status.processing", requestedCount)
        let administratorRequiredPaths = cleanupRuntime.administratorRequiredPaths
        traceCleanupInteraction("execution.scheduled", fields: ["paths": String(requestedCount), "generation": generation.uuidString])
        Task {
            traceCleanupInteraction("execution.started")
            let retryBudget = CleanupRetryPolicy.Budget()
            let originalRequest = retryScope ?? requested
            let proposedAdministratorItems = await freshAdministratorCleanupItems(requested,
                administratorRequiredPaths: administratorRequiredPaths, family: applyFamily, mode: mode)
            guard cleanupRuntime.taskGeneration == generation, isApplying, !Task.isCancelled else {
                traceCleanupInteraction("execution.abandoned", fields: ["reason": "generation_or_cancellation"])
                return
            }
            var includeAdministrator = false
            if !proposedAdministratorItems.isEmpty {
                guard let decision = await confirmAdministratorCleanup(proposedAdministratorItems) else {
                    traceCleanupInteraction("execution.cancelled", fields: ["reason": "administrator_confirmation"])
                    cleanupTaskProgress = nil
                    isApplying = false
                    return
                }
                includeAdministrator = decision
            }
            let reviewStarted = Date()
            traceCleanupInteraction("runtime.snapshot.started")
            let snapshot = await captureRunningApplicationSnapshot()
            traceCleanupInteraction("runtime.snapshot.finished", fields: ["complete": String(snapshot.isComplete)])
            let blocked = await Task.detached(priority: .utility) {
                var waiting: [CleanupCategory] = []
                var ready: [CleanupCategory] = []
                var owners = Set<String>()
                for category in requested {
                    var blockedPaths = Set<String>()
                    if case .manual = mode, snapshot.isComplete,
                       !CleanupRiskPolicy.usesFileActivityGuard(category) {
                        for (index, path) in category.paths.enumerated() {
                            // The path is already part of this captured category.
                            // Avoid intersecting the full inventory for each item.
                            let subset = category.selectingPath(at: index)
                            let matched = CleanupRiskPolicy.blockingOwners([subset], running: snapshot)
                            if !matched.isEmpty { blockedPaths.insert(path); owners.formUnion(matched) }
                        }
                    }
                    if let subset = category.selectingPaths(Array(blockedPaths)).selectedSubset { waiting.append(subset) }
                    if let subset = category.selectingPaths(category.paths.filter {
                        !blockedPaths.contains($0)
                    }).selectedSubset { ready.append(subset) }
                }
                return (ready, waiting, Array(owners))
            }.value
            let actionable = blocked.0
            let actionableCount = actionable.reduce(0) { $0 + $1.paths.count }
            let prepared = await Task.detached(priority: .utility) {
                var eligible: [CleanupCategory] = []
                var protectedReasons: [UUID: String] = [:]
                var refusals: [(String, String)] = []
                // Execution must prove freshness for the whole selected plan;
                // a shared quick-scan budget silently rejected every later path.
                let recheckControl = CleanupScanControl(mode: .deep)
                for category in actionable {
                    // 年龄门复核：扫描后重新活跃（或时间证据失效）的条目
                    // 不再进入本次执行，计入跳过而不是放宽门槛。
                    var reviewed = category
                    // A manual cache cleanup explicitly includes regenerable
                    // contents. One recent write must not keep every idle
                    // sibling; automatic cleanup retains its age gate.
                    let manuallyReviewedCache: Bool
                    if case .manual = mode { manuallyReviewedCache = CleanupRiskPolicy.usesFileActivityGuard(category) }
                    else { manuallyReviewedCache = false }
                    if category.retention > 0 && !manuallyReviewedCache {
                        let stillStale = category.paths.filter { path in
                            category.isPathSelected(path)
                        }.filter { path in
                            let recheck = CleanupScanWorker.measure(
                                path, control: recheckControl)
                            let stale = recheck.complete && CleanupAgePolicy.isStale(
                                recheck.activityEvidence, retention: category.retention)
                            if !stale { refusals.append((path, "cleanup.execution.activityChanged")) }
                            return stale
                        }
                        reviewed = category.selectingPaths(stillStale)
                    }
                    guard let reviewed = reviewed.selectedSubset else { continue }
                    let assessment = CleanupRiskPolicy.reassess(reviewed, running: snapshot)
                    let subset = CleanupRiskPolicy.runtimeEligibleSubset(reviewed, running: snapshot)?.selectedSubset
                    let permittedPaths = Set(subset?.paths ?? [])
                    for path in reviewed.paths where !permittedPaths.contains(path) {
                        refusals.append((path, snapshot.isComplete
                            ? "cleanup.risk.runningApplication" : "cleanup.risk.runtimeUnknown"))
                    }
                    if let subset, CleanupRiskPolicy.isEligible(subset, mode: mode, running: snapshot) {
                        eligible.append(subset)
                    } else if assessment.risk == .protected {
                        protectedReasons[category.id] = assessment.reasonKey
                        for path in reviewed.paths where permittedPaths.contains(path) {
                            refusals.append((path, assessment.reasonKey))
                        }
                    }
                }
                return (eligible, protectedReasons, refusals)
            }.value
            let eligible = prepared.0
            log(String(format: "cleanup runtime review %.2fs; paths=%d",
                       Date().timeIntervalSince(reviewStarted), requestedCount))
            for index in categories.indices {
                if let reason = prepared.1[categories[index].id] {
                    categories[index].risk = .protected
                    categories[index].reasonKey = reason
                    categories[index].selected = false
                }
            }

            let eligibleCount = eligible.reduce(0) { $0 + $1.paths.count }
            traceCleanupInteraction("runtime.review.finished", fields: [
                "eligible": String(eligibleCount), "requested": String(requestedCount),
                "elapsedMS": String(Int(Date().timeIntervalSince(reviewStarted) * 1000))])
            var executionResult = priorResult
            executionResult.merge(CleanupExecutionResult(
                skipped: max(0, actionableCount - eligibleCount),
                messages: prepared.2.map { "\($0.0)\n\(l10n.t(Self.taskFeedbackReasonKey($0.1)))" }))
            // The immutable eligible plan, rather than the still-visible UI
            // selection, is the number this execution will actually submit.
            statusText = l10n.tf("status.processing",
                                 eligibleCount + (installers?.paths.count ?? 0) + maintenanceIDs.count)
            guard !eligible.isEmpty || installers != nil || !maintenanceIDs.isEmpty else {
                cleanupTaskProgress = .init(phase: .verifying)
                let verified = await refreshCleanupInventory(after: applyFamily, result: executionResult)
                await configureCleanupRetry(originalRequest, family: applyFamily, mode: mode,
                                      installers: installers,
                                      maintenanceIDs: Array(Set(maintenanceIDs + pendingMaintenanceIDs)),
                                      result: executionResult, verified: verified)
                await reportCleanupResult(executionResult,
                                    permanently: applyFamily == .clean, verified: verified,
                                    waitingApplications: Array(Set(Self.blockingApplicationNames(blocked.2)
                                        + busyCleanupApplications(executionResult, categories: originalRequest,
                                                                  running: snapshot))).sorted())
                isApplying = false
                recordRemainingCleanup(blocked.1, owners: blocked.2)
                return
            }

            // Consent may only shrink to the freshly eligible plan. Preserve
            // the identity/metadata captured before the user answered it.
            let routePlan = await Task.detached(priority: .utility) {
                // Preparing a large selected inventory is also background work;
                // publishing the working stage must not wait for path sorting.
                let eligibleIdentities = eligible.reduce(into: [String: String]()) { result, category in
                    for path in category.paths { result[path] = category.pathIdentities[path] }
                }
                let administratorItems = proposedAdministratorItems.filter {
                    eligibleIdentities[$0.record] == $0.identity
                }
                let administratorPaths = Set(administratorItems.map(\.record))
                let directCategories = eligible.compactMap { category in
                    category.retainingPaths(category.paths.filter { !administratorPaths.contains($0) })
                }
                let grouped = Dictionary(grouping: directCategories, by: \.applyRoute)
                let routeCounts = grouped.mapValues { routeCategories in
                    let paths = routeCategories.flatMap(\.paths)
                    return routeCategories.first?.applyRoute == .toolCommand
                        ? paths.count : DeletionPlan.nonOverlappingPaths(paths).count
                }
                let total = routeCounts.values.reduce(0, +)
                    + DeletionPlan.nonOverlappingPaths(installers?.paths ?? []).count + maintenanceIDs.count
                    + (includeAdministrator ? administratorItems.count : 0)
                return (administratorItems, grouped, routeCounts, total)
            }.value
            let (administratorItems, grouped, routeCounts, total) = routePlan
            if !includeAdministrator {
                executionResult.merge(.init(skipped: administratorItems.count))
            }
            var completed = 0
            cleanupTaskProgress = .init(phase: .cleaning, completed: 0, total: total)
            // Request system authorization before running normal routes, so
            // a large ordinary cleanup cannot postpone the password prompt.
            // Denied authorization still allows the ordinary plan to proceed.
            if includeAdministrator, !administratorItems.isEmpty {
                let administratorStarted = Date()
                let administrator = await AdministratorCleanupService.apply(items: administratorItems,
                    onProgress: cleanupProgressCallback(generation: generation, offset: completed,
                        weight: administratorItems.count, total: total, categories: eligible),
                    retryBudget: retryBudget, requestID: cleanupRuntime.traceRequestID)
                guard cleanupRuntime.taskGeneration == generation, isApplying, !Task.isCancelled else { return }
                log(String(format: "cleanup administrator completed %.2fs; paths=%d",
                           Date().timeIntervalSince(administratorStarted), administratorItems.count))
                executionResult.merge(administrator)
                completed += administratorItems.count
            }
            for route in CleanupApplyRoute.allCases {
                guard let routeCategories = grouped[route], !routeCategories.isEmpty else { continue }
                let started = Date()
                log("cleanup route=\(route.rawValue) started paths=\(routeCategories.reduce(0) { $0 + $1.paths.count })")
                let routeResult = await executeCleanupRoute(
                    route, categories: routeCategories, mode: mode,
                    permanently: applyFamily == .clean,
                    onProgress: cleanupProgressCallback(generation: generation, offset: completed,
                        weight: routeCounts[route] ?? 0, total: total, categories: routeCategories),
                    retryBudget: retryBudget)
                guard cleanupRuntime.taskGeneration == generation, isApplying, !Task.isCancelled else { return }
                log(String(format: "cleanup route=%@ completed %.2fs", route.rawValue, Date().timeIntervalSince(started)))
                executionResult.merge(routeResult)
                completed += routeCounts[route] ?? 0
                cleanupTaskProgress = .init(phase: .cleaning, completed: completed, total: total)
            }

            // 安装包可能是用户唯一的副本：勾选后由统一“清理”分发到废纸篓路线。
            if let installers {
                let routeResult = await executeCleanupRoute(
                    .installerTrash, categories: [installers], mode: mode,
                    permanently: false,
                    onProgress: cleanupProgressCallback(generation: generation, offset: completed,
                        weight: DeletionPlan.nonOverlappingPaths(installers.paths).count,
                        total: total, categories: [installers]),
                    retryBudget: retryBudget)
                guard cleanupRuntime.taskGeneration == generation, isApplying, !Task.isCancelled else { return }
                executionResult.merge(routeResult)
                completed += DeletionPlan.nonOverlappingPaths(installers.paths).count
                let displayedInstallers = self.installerCandidates
                let refreshedInstallers = await Task.detached(priority: .utility) {
                    displayedInstallers?.retainingPaths(displayedInstallers?.paths.filter {
                        FileManager.default.fileExists(atPath: $0)
                    } ?? [])
                }.value
                guard cleanupRuntime.taskGeneration == generation else { return }
                self.installerCandidates = refreshedInstallers
            }
            // 系统数据维护：逐项执行并刷新体检结果。
            var maintenanceResult = CleanupExecutionResult()
            var remainingMaintenance = pendingMaintenanceIDs.filter { !maintenanceIDs.contains($0) }
            for rowID in maintenanceIDs {
                let itemResult = await runSystemMaintenanceTask(rowID)
                maintenanceResult.merge(itemResult)
                if !itemResult.completedSuccessfully { remainingMaintenance.append(rowID) }
                completed += 1
                cleanupTaskProgress = .init(phase: .cleaning, completed: completed, total: total)
            }

            cleanupTaskProgress = .init(phase: .verifying, completed: completed, total: total)
            let verified = await refreshCleanupInventory(after: applyFamily, result: executionResult)
            await configureCleanupRetry(originalRequest, family: applyFamily, mode: mode,
                                  installers: self.installerCandidates?.selectedSubset,
                                  maintenanceIDs: remainingMaintenance,
                                  result: executionResult, verified: verified)
            await reportCleanupResult(executionResult,
                                permanently: applyFamily == .clean,
                                maintenance: maintenanceResult, verified: verified,
                                waitingApplications: Array(Set(Self.blockingApplicationNames(blocked.2)
                                    + busyCleanupApplications(executionResult, categories: originalRequest,
                                                              running: snapshot))).sorted())
            isApplying = false
            recordRemainingCleanup(blocked.1, owners: blocked.2)
        }
    }

    private func busyCleanupApplications(_ result: CleanupExecutionResult,
                                         categories: [CleanupCategory],
                                         running: RunningApplicationSnapshot) -> [String] {
        let prefixes = ["Skipped while the path is open: ", "Skipped while owning application is running: "]
        let paths = result.messages.compactMap { message -> String? in
            guard let prefix = prefixes.first(where: message.hasPrefix) else { return nil }
            return String(message.dropFirst(prefix.count))
        }
        let busyCategories = categories.compactMap { category -> CleanupCategory? in
            let matches = category.paths.filter { root in
                paths.contains { $0 == root || $0.hasPrefix(root + "/") }
            }
            guard var subset = category.selectingPaths(matches).selectedSubset else { return nil }
            // Ownership lookup only. Disable the cache execution exemption
            // here to name an app whose files actually remained occupied.
            subset.disposal = .none
            return subset
        }
        return Self.blockingApplicationNames(CleanupRiskPolicy.blockingOwners(busyCategories, running: running))
    }

    private func cleanupProgressCallback(generation: UUID, offset: Int, weight: Int,
                                         total: Int, categories: [CleanupCategory]) -> (Int, Int, String) -> Void {
        let lastUpdate = OSAllocatedUnfairLock(initialState: Date.distantPast)
        return { [weak self] done, routeTotal, path in
            let publish = lastUpdate.withLock { timestamp in
                let now = Date()
                guard path.isEmpty || done >= routeTotal || now.timeIntervalSince(timestamp) >= 0.12 else { return false }
                timestamp = now
                return true
            }
            guard publish else { return }
            let handled = routeTotal > 0 ? min(weight, max(0, done) * weight / routeTotal) : 0
            Task { @MainActor [weak self] in
                guard let self, self.cleanupRuntime.taskGeneration == generation, self.isApplying,
                      self.cleanupTaskProgress?.phase == .cleaning else { return }
                self.cleanupTaskProgress = .init(phase: .cleaning,
                    completed: max(self.cleanupTaskProgress?.completed ?? 0, offset + handled),
                    total: total, currentItem: path)
            }
        }
    }

    private func configureCleanupRetry(_ requested: [CleanupCategory], family: CleanupFamily,
                                       mode: CleanupExecutionMode, installers: CleanupCategory?,
                                       maintenanceIDs: [String], result: CleanupExecutionResult,
                                       verified: Bool) async {
        let displayed = categories
        let generation = cleanupRuntime.taskGeneration
        let prepared = await Task.detached(priority: .utility) {
            let listed = Set(displayed.flatMap(\.paths))
            var submitted: [String: String] = [:]
            for category in requested + (installers.map { [$0] } ?? []) {
                for path in category.paths {
                    let identity = category.pathIdentities[path] ?? ""
                    if let old = submitted[path], old != identity { submitted[path] = "" }
                    else { submitted[path] = identity }
                }
            }
            let retained = result.retainedPathIdentities(in: submitted)
            let remaining = requested.compactMap { category in
                category.selectingPaths(result.remainingPaths(in: category.paths).filter { path in
                    (family != .clean || !verified || listed.contains(path))
                        && (retained[path] == nil || retained[path] != category.pathIdentities[path])
                }).selectedSubset
            }
            let remainingInstallers = installers.flatMap { category in
                category.retainingPaths(result.remainingPaths(in: category.paths).filter { path in
                    retained[path] == nil || retained[path] != category.pathIdentities[path]
                })?.selectedSubset
            }
            return (remaining, remainingInstallers)
        }.value
        guard cleanupRuntime.taskGeneration == generation else { return }
        cleanupRetryAvailable = !prepared.0.isEmpty || prepared.1 != nil || !maintenanceIDs.isEmpty
        cleanupRuntime.retryAction = cleanupRetryAvailable ? { [weak self] in
            self?.performApply(categories: prepared.0, family: family, mode: mode,
                               installers: prepared.1, maintenanceIDs: maintenanceIDs)
        } : nil
    }

    func retryFailedCleanup() {
        guard !isCleanupTaskBusy, !isCleanupSubmissionBlocked,
              let retry = cleanupRuntime.retryAction else { return }
        cleanupRuntime.retryAction = nil
        cleanupRetryAvailable = false
        retry()
    }

    func finishCleanupCelebration(feedbackID: Int) {
        guard feedbackID == cleanupFeedbackID, !isApplying, cleanupCelebrating else { return }
        cleanupCelebrating = false
        // 保留成功后的闲置页；下一次操作才刷新或重试剩余项目。
    }

    private func recordRemainingCleanup(_ categories: [CleanupCategory], owners: [String]) {
        guard !categories.isEmpty else { return }
        traceCleanupInteraction("execution.retained_silently", fields: [
            "categories": String(categories.count), "owners": String(owners.count)])
    }

    private func refreshCleanupInventory(after family: CleanupFamily,
                                         result: CleanupExecutionResult = .init()) async -> Bool {
        traceCleanupInteraction("verification.started")
        defer { traceCleanupInteraction("verification.returned") }
        let displayed = categories
        let deferred = cleanupDeferredPaths
        let generation = cleanupRuntime.taskGeneration
        if family == .clean { statusText = l10n.t("cleanup.refreshing") }
        let refreshed = await Task.detached(priority: .utility) {
            CleanupCache.invalidate()
            guard family == .clean else { return (displayed, Set<String>(), deferred, true) }
            var identities: [String: String] = [:]
            for category in displayed {
                for path in category.paths {
                    let identity = category.pathIdentities[path] ?? ""
                    if let old = identities[path], old != identity { identities[path] = "" }
                    else { identities[path] = identity }
                }
            }
            var bound = result
            bound.retainedTargets = result.quietRetainedTargets.filter {
                identities[$0.record] == $0.identity && DeletionPlan.identity(at: $0.record) == $0.identity
            }
            let retained = bound.retainedPathIdentities(in: identities)
            let inventory = displayed.compactMap { category in
                category.retainingPaths(category.paths.filter { path in
                    retained[path] == nil || retained[path] != category.pathIdentities[path]
                })
            }
            let report = CleanupInventoryRefresh.refresh(inventory)
            return (report.categories, Set(report.categories.flatMap(\.paths)),
                    Array(Set(deferred + report.deferredPaths)).sorted(), report.deferredPaths.isEmpty)
        }.value
        guard cleanupRuntime.taskGeneration == generation else { return false }
        if family == .clean {
            categories = refreshed.0
            cleanupRuntime.administratorRequiredPaths.formIntersection(refreshed.1)
            cleanupDeferredPaths = refreshed.2
        }
        return refreshed.3
    }

    private func reportCleanupResult(_ result: CleanupExecutionResult,
                                     permanently: Bool,
                                     maintenance: CleanupExecutionResult = .init(),
                                     verified: Bool = true,
                                     waitingApplications: [String] = []) async {
        let generation = cleanupRuntime.taskGeneration
        let prepared = await Task.detached(priority: .utility) {
            var combined = result
            combined.merge(maintenance)
            return (combined, combined.quietSkipped, CleanupExecutionResult.boundedFeedback(combined.messages))
        }.value
        guard cleanupRuntime.taskGeneration == generation else { return }
        let combined = prepared.0
        traceCleanupInteraction("execution.finished", fields: ["removed": String(combined.removed),
            "skipped": String(combined.skipped), "failed": String(combined.failed),
            "executionFailed": String(combined.executionFailed), "verified": String(verified),
            "reclaimedBytes": String(combined.reclaimedBytes)])
        // Recoverable work has already exhausted its bounded automatic retries.
        // Remaining protected, occupied or failed items are diagnostic-only.
        cleanupOutcomeMood = combined.removed > 0 ? .success : nil
        noteHeaderReaction(cleanupOutcomeMood)
        cleanupOutcomeDetails = []
        cleanupRuntime.retryAction = nil
        cleanupRetryAvailable = false
        cleanupTaskProgress = nil
        cleanupCompletedCount = combined.removed
        cleanupReclaimedBytes = combined.reclaimedBytes
        cleanupFailureApplications = []
        cleanupCelebrating = cleanupOutcomeMood == .success
        cleanupFeedbackID += 1
        analyzeCache.clear()
        resampleAfterMutation()
        // 报告文案与执行器的实际动作一致：永久删除与移入废纸篓分开表述。
        let key = permanently
            ? "cleanup.execution.summary.permanent"
            : "cleanup.execution.summary"
        var summaries: [String] = []
        if result.removed + result.skipped + result.failed > 0 {
            summaries.append(l10n.tf(key, result.removed, result.skipped, result.failed))
        }
        if maintenance.removed + maintenance.skipped + maintenance.failed > 0 {
            summaries.append(l10n.tf("cleanup.execution.maintenance", maintenance.removed,
                                    maintenance.skipped, maintenance.failed))
        }
        if combined.executionFailed { summaries.append(l10n.t("cleanup.execution.incomplete")) }
        if !waitingApplications.isEmpty { summaries.append(l10n.t("task.closeApps.remaining")) }
        let summary = summaries.joined(separator: "\n")
        statusText = combined.removed > 0
            ? l10n.tf("cleanup.task.reclaimed", ByteFormat.format(combined.reclaimedBytes))
            : l10n.t("status.ready")
        if !prepared.2.logTail.isEmpty {
            logLines = Array((logLines + prepared.2.logTail).suffix(400))
        }
        log(summary)
        traceCleanupInteraction("execution.settled_silently", fields: [
            "verified": String(verified), "waitingApplications": String(waitingApplications.count),
            "maximumAttempts": String(CleanupRetryPolicy.maximumAttempts)])
    }

    private func localizedCleanupDetail(_ detail: String) -> String {
        TaskFeedbackDiagnostic.localized([detail]).first ?? ""
    }

    private static func taskFeedbackReasonKey(_ key: String) -> String {
        switch key {
        case "cleanup.risk.runningApplication": return "task.reason.runningApps"
        case "cleanup.risk.runtimeUnknown": return "task.reason.runtimeUnknown"
        case "cleanup.execution.activityChanged": return "task.reason.changed"
        case "cleanup.risk.protectedContent": return "task.reason.protected"
        default: return "task.reason.validation"
        }
    }

    /// A logical request shares one per-target budget across all routes. Retry
    /// only the captured objects; a path recreated by another app is never rebound.
    private func executeCleanupRoute(_ route: CleanupApplyRoute,
                                     categories routeCategories: [CleanupCategory],
                                     mode: CleanupExecutionMode,
                                     permanently: Bool = false,
                                     onProgress: ((Int, Int, String) -> Void)? = nil,
                                     retryBudget: CleanupRetryPolicy.Budget? = nil) async
        -> CleanupExecutionResult {
        guard route != .toolCommand, route != .none else {
            // Tool commands may have unreported side effects; never replay them.
            return await executeCleanupRouteAttempt(route, categories: routeCategories,
                mode: mode, permanently: permanently, onProgress: onProgress)
        }
        let generation = cleanupRuntime.taskGeneration
        let budget = retryBudget ?? CleanupRetryPolicy.Budget()
        let requestID = cleanupRuntime.traceRequestID
        var pending = routeCategories
        var combined = CleanupExecutionResult()
        var attempts = 0
        var terminalSkipped = 0
        for attempt in 1...CleanupRetryPolicy.maximumAttempts {
            guard cleanupRuntime.taskGeneration == generation, isApplying,
                  !isCleanupSubmissionBlocked, !Task.isCancelled else { break }
            let snapshot = pending
            let claim = await Task.detached(priority: .utility) {
                let expected = Set(snapshot.flatMap { category in
                    category.paths.filter { category.isPathSelected($0) }
                }).count
                let selected = budget.claim(categories: snapshot)
                let selectedCount = selected.reduce(0) { $0 + $1.paths.count }
                return (selected, expected, selectedCount)
            }.value
            guard cleanupRuntime.taskGeneration == generation, isApplying,
                  !isCleanupSubmissionBlocked, !Task.isCancelled else { break }
            let claimed = claim.0
            if attempt == 1 { terminalSkipped = max(0, claim.1 - claim.2) }
            // Last-pass counters cover every remaining target. Do not replace
            // them with a partial pass after another route consumed a budget.
            if attempt > 1, claim.2 != claim.1 {
                traceCleanupInteraction("route.retry.stopped", requestID: requestID,
                    fields: ["route": route.rawValue, "reason": "partial_budget_exhausted"])
                break
            }
            guard !claimed.isEmpty else { break }
            attempts = attempt
            traceCleanupInteraction("route.attempt.started", requestID: requestID,
                fields: ["route": route.rawValue, "attempt": String(attempt)])
            let result = await executeCleanupRouteAttempt(route, categories: claimed,
                mode: mode, permanently: permanently, onProgress: onProgress)
            let previous = combined
            let prepared = await Task.detached(priority: .utility) {
                let updated = CleanupRetryPolicy.combiningAttempts(previous, result)
                return (updated, CleanupRetryPolicy.remainingCategories(claimed, after: updated))
            }.value
            combined = prepared.0
            traceCleanupInteraction("route.attempt.finished", requestID: requestID, fields: [
                "route": route.rawValue, "attempt": String(attempt),
                "removed": String(result.removed), "skipped": String(result.skipped),
                "failed": String(result.failed), "executionFailed": String(result.executionFailed)])
            // An unknown subprocess outcome is not a safe retry signal. Native
            // item failures have a known result and retain their original identity.
            guard !result.executionFailed, !prepared.1.isEmpty,
                  result.failed > 0 || result.skipped > 0,
                  attempt < CleanupRetryPolicy.maximumAttempts else { break }
            let remaining = prepared.1
            let mayReplayAgeReview = await Task.detached(priority: .utility) {
                remaining.allSatisfy { category in
                    if category.retention <= 0 { return true }
                    if case .manual = mode { return CleanupRiskPolicy.usesFileActivityGuard(category) }
                    return false
                }
            }.value
            guard mayReplayAgeReview else {
                // A prior age review cannot authorize a later attempt after new
                // activity. Stop quietly rather than reuse stale retention proof.
                traceCleanupInteraction("route.retry.stopped", requestID: requestID,
                    fields: ["route": route.rawValue, "reason": "fresh_age_review_required"])
                break
            }
            pending = remaining
            traceCleanupInteraction("route.retry.scheduled", requestID: requestID,
                fields: ["route": route.rawValue, "nextAttempt": String(attempt + 1)])
            do { try await Task.sleep(nanoseconds: attempt == 1 ? 300_000_000 : 750_000_000) }
            catch { break }
        }
        combined.skipped += terminalSkipped
        traceCleanupInteraction("route.settled_silently", requestID: requestID, fields: [
            "route": route.rawValue, "attempts": String(attempts),
            "removed": String(combined.removed), "skipped": String(combined.skipped),
            "failed": String(combined.failed)])
        return combined
    }

    private func executeCleanupRouteAttempt(_ route: CleanupApplyRoute,
                                     categories routeCategories: [CleanupCategory],
                                     mode: CleanupExecutionMode,
                                     permanently: Bool = false,
                                     onProgress: ((Int, Int, String) -> Void)? = nil) async
        -> CleanupExecutionResult {
        let routeStarted = ProcessInfo.processInfo.systemUptime
        let requestID = cleanupRuntime.traceRequestID
        traceCleanupInteraction("route.started", fields: ["route": route.rawValue, "categories": String(routeCategories.count)])
        defer {
            CleanupTrace.record("route.returned", requestID: requestID, fields: ["route": route.rawValue,
                "elapsedMS": String(Int((ProcessInfo.processInfo.systemUptime - routeStarted) * 1000))])
        }
        let preparedRecords = await Task.detached(priority: .utility) {
            let raw = routeCategories.flatMap(\.paths)
            switch route {
            case .genericTrash, .installerTrash, .developerCacheTrash, .aiTrash, .xcodeTrash:
                return (raw.count, DeletionPlan.nonOverlappingPaths(raw))
            case .toolCommand, .none:
                return (raw.count, raw)
            }
        }.value
        let records = preparedRecords.1
        onProgress?(0, records.count, records.first ?? "")
        defer { onProgress?(records.count, records.count, "") }
        let coalescedCount = max(0, preparedRecords.0 - records.count)
        guard !records.isEmpty else {
            return CleanupExecutionResult(skipped: coalescedCount)
        }

        let bridgeName: String
        let stdinData: Data
        switch route {
        case .genericTrash, .developerCacheTrash, .aiTrash, .xcodeTrash:
            let hasAgentLeftovers = routeCategories.contains { $0.reasonKey == "cleanup.risk.agentLeftover" }
            let agentSnapshot = hasAgentLeftovers ? await captureRunningApplicationSnapshot() : .unavailable
            let directCategories = routeCategories
            let administratorUnits = 0
            // Nori 自身的受管路径（文件名索引、截图暂存）不进原生 unlink；
            // 先复位会回写的进程内缓存，再让原生删除开始。
            let home = NSHomeDirectory()
            await prepareNoriOwnedDeletion(paths: directCategories.flatMap(\.paths))
            let managedPaths = directCategories.flatMap(\.paths)
                .filter { NoriOwnedStorage.isManagedPath($0, home: home) }
            let managedUnits = DeletionPlan.nonOverlappingPaths(managedPaths).count
            var managedHandled = 0
            let applied = await Task.detached(priority: .utility) {
                let home = NSHomeDirectory()
                let agentLeftovers = directCategories.filter { $0.reasonKey == "cleanup.risk.agentLeftover" }
                let residueCategories = directCategories.filter { $0.uninstallDataOwner != nil }
                let appDataCategories = directCategories.filter { $0.isAppDataReview && $0.uninstallDataOwner == nil }
                let genericCategories = directCategories.filter {
                    $0.reasonKey != "cleanup.risk.agentLeftover" && !$0.isAppDataReview
                }
                let agentUnits = DeletionPlan.nonOverlappingPaths(agentLeftovers.flatMap(\.paths)).count
                let nativePaths = genericCategories.flatMap(\.paths)
                    .filter { !NoriOwnedStorage.isManagedPath($0, home: home) }
                let genericUnits = DeletionPlan.nonOverlappingPaths(nativePaths).count
                let appDataPaths = DeletionPlan.nonOverlappingPaths(appDataCategories.flatMap(\.paths))
                let residuePaths = DeletionPlan.nonOverlappingPaths(residueCategories.flatMap(\.paths))
                let dataUnits = appDataPaths.count + residuePaths.count
                let routeUnits = dataUnits + agentUnits + genericUnits + administratorUnits + managedUnits
                // Reviewed data is dispatched before ordinary caches. Include
                // those targets in progress even when this is a data-only plan.
                if let path = appDataPaths.first ?? residuePaths.first {
                    onProgress?(0, routeUnits, path)
                }
                CleanupTrace.record("route.app_data.started", requestID: requestID, fields: ["targets": String(appDataPaths.count)])
                let appData = NativeCore.shared.applyAppDataReview(appDataCategories, homeDirectory: home)
                CleanupTrace.record("route.app_data.finished", requestID: requestID, fields: [
                    "removed": String(appData.removed), "skipped": String(appData.skipped), "failed": String(appData.failed)])
                if !appDataPaths.isEmpty {
                    onProgress?(appDataPaths.count, routeUnits, residuePaths.first ?? "")
                }
                CleanupTrace.record("route.residues.started", requestID: requestID, fields: ["targets": String(residuePaths.count)])
                let residues = NativeCore.shared.applyUninstallResidues(residueCategories, homeDirectory: home)
                CleanupTrace.record("route.residues.finished", requestID: requestID, fields: [
                    "removed": String(residues.removed), "skipped": String(residues.skipped), "failed": String(residues.failed)])
                if !residuePaths.isEmpty { onProgress?(dataUnits, routeUnits, "") }
                let agentOutcome = agentLeftovers.isEmpty
                    ? AgentCleanupExecutor.Outcome(summary: .init(removed: 0, skipped: 0, failed: 0, messages: []), refused: 0)
                    : AgentCleanupExecutor.execute(agentLeftovers, running: agentSnapshot,
                                                   home: home,
                                                   onProgress: { done, _, path in
                                                       onProgress?(dataUnits + done, routeUnits, path)
                                                   })
                let native = Set(nativePaths)
                let items = genericCategories.flatMap { category in
                    category.paths.filter(native.contains).map { path in
                        DeletionPlan.Item(record: path, identity: category.pathIdentities[path] ?? "")
                    }
                }
                var genericHandled = 0
                let generic = items.isEmpty
                    ? NativeCore.ApplySummary(removed: 0, skipped: 0, failed: 0, messages: [])
                    : NativeCore.shared.applyCleanup(items: items, permanent: permanently,
                        liveCleanupTargets: Set(genericCategories.filter {
                            CleanupRiskPolicy.usesFileActivityGuard($0)
                        }.flatMap(\.paths).filter {
                            !NoriOwnedStorage.isManagedPath($0, home: home)
                                && CleanupRiskPolicy.core(section: "Cache", path: $0,
                                    homeDirectory: home).risk == .safe
                        }), onProgress: { done, _, path in
                            genericHandled = done
                            onProgress?(dataUnits + agentUnits + done, routeUnits, path)
                        }, onCurrentFile: { path in
                            onProgress?(dataUnits + agentUnits + genericHandled, routeUnits, path)
                        })
                let agent = agentOutcome.summary
                return (dataUnits + agentUnits + genericUnits, NativeCore.ApplySummary(
                    removed: generic.removed + agent.removed + appData.removed + residues.removed,
                    skipped: generic.skipped + agent.skipped + agentOutcome.refused + appData.skipped + residues.skipped,
                    failed: generic.failed + agent.failed + appData.failed + residues.failed,
                    messages: generic.messages + agent.messages + appData.messages + residues.messages,
                    removedPaths: generic.removedPaths.union(agent.removedPaths).union(appData.removedPaths).union(residues.removedPaths),
                    reclaimedBytes: generic.reclaimedBytes &+ agent.reclaimedBytes &+ appData.reclaimedBytes &+ residues.reclaimedBytes,
                    retainedTargets: generic.retainedTargets + agent.retainedTargets + appData.retainedTargets + residues.retainedTargets))
            }.value
            let nativeHandled = applied.0
            let routeUnits = nativeHandled + managedUnits
            let managed = await applyNoriManagedPaths(managedPaths, onProgress: { path in
                managedHandled += 1
                onProgress?(nativeHandled + managedHandled, routeUnits, path)
            })
            let summary = NativeCore.ApplySummary(
                removed: applied.1.removed + managed.removed,
                skipped: applied.1.skipped + managed.skipped,
                failed: applied.1.failed + managed.failed,
                messages: applied.1.messages + managed.messages,
                removedPaths: applied.1.removedPaths.union(managed.removedPaths),
                reclaimedBytes: applied.1.reclaimedBytes &+ managed.reclaimedBytes,
                retainedTargets: applied.1.retainedTargets + managed.retainedTargets)
            let rawDiagnostics = summary.messages
            let logTail = await Task.detached(priority: .utility) {
                CleanupExecutionResult.boundedFeedback(rawDiagnostics).logTail
            }.value
            if !logTail.isEmpty { logLines = Array((logLines + logTail).suffix(400)) }
            let execution = CleanupExecutionResult(
                removed: summary.removed,
                skipped: summary.skipped,
                failed: summary.failed,
                messages: summary.messages,
                removedPaths: summary.removedPaths,
                reclaimedBytes: summary.reclaimedBytes,
                retainedTargets: summary.retainedTargets)
            return execution
        case .installerTrash:
            bridgeName = "bin/app_installer_apply.sh"
            stdinData = await Task.detached(priority: .utility) {
                let items = records.map { path in
                    DeletionPlan.Item(record: path, identity: routeCategories
                        .first { $0.paths.contains(path) }?.pathIdentities[path] ?? "")
                }
                return DeletionPlan(items: items).stdinData
            }.value
        case .toolCommand:
            bridgeName = "bin/app_tool_apply.sh"
            var data = Data()
            for record in records {
                data.append(contentsOf: record.utf8)
                data.append(0)
            }
            stdinData = data
        case .none:
            return CleanupExecutionResult(skipped: coalescedCount, failed: records.count)
        }

        log(l10n.tf("log.pipeline", records.count,
                    (bridgeName as NSString).lastPathComponent))
        var environment: [String: String] = ["SIMPLEMOLE_EXECUTION_MODE": {
            switch mode {
            case .manual: return "manual"
            case .quickClean: return "quickClean"
            case .automatic: return "automatic"
            }
        }()]
        if route == .toolCommand {
            let terminal = await DeveloperTerminalEnvironmentService.shared.snapshot().environment
            environment.merge(terminal) { existing, _ in existing }
        }
        environment.merge(fullDiskScanEnvironment) { _, authorized in authorized }
        if route == .installerTrash, permanently {
            environment["SIMPLEMOLE_DELETE_MODE"] = "permanent"
        }
        let result = await MoleEngine.shared.runBridgeWithStdin(
            bridgeName, stdinData: stdinData, extraEnvironment: environment, timeout: 900)
        if !result.output.isEmpty { log(result.output) }
        logFailure(result, stdoutAlreadyLogged: true, notifyingUser: false)
        var summary: CleanupExecutionResult
        if route == .installerTrash {
            summary = await Task.detached(priority: .utility) {
                CleanupExecutionResult.reconciledInstallerReport(bridgeOutput: result.output,
                    expectedCount: records.count, exitCode: result.exitCode,
                    timedOut: result.timedOut, outputTruncated: result.outputTruncated)
            }.value
        } else {
            summary = CleanupExecutionResult.reconciled(bridgeOutput: result.output, expectedCount: records.count)
            summary.executionFailed = !result.succeeded
        }
        if summary.removed == records.count {
            summary.removedPaths = Set(records)
            summary.removed += coalescedCount
        } else {
            summary.skipped += coalescedCount
        }
        if !result.succeeded {
            summary.messages.append(result.errorOutput.isEmpty ? result.output : result.errorOutput)
        }
        return summary
    }
}
