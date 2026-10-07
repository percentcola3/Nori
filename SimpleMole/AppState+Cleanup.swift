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
        // A read-only inventory can overlap an uninstall. Never cancel that
        // unrelated mutation through the engine's global cancellation hook.
        if uninstallQueue.activeJob == nil { MoleEngine.shared.cancelAll() }
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
        guard !isBusyExcludingUninstall, !cleanupQueued else { return }
        family = .clean
        installerCandidates = nil
        if mode == .quick, !force, let cached = CleanupCache.restore() {
            beginCleanupProgress()
            isScanning = true
            cleanupScanComplete = false
            statusText = l10n.t("status.scanningCleanup")
            let control = CleanupScanControl(mode: .deep)
            cleanupRuntime.scanControl = control
            Task {
                defer { cleanupRuntime.scanControl = nil }
                async let runtime = captureRunningApplicationSnapshot()
                let preflight = await Task.detached(priority: .utility) {
                    NativeCore.shared.preflightCleanupCategories(cached.categories, control: control,
                        includingAdministratorRequired: true)
                }.value
                let snapshot = await runtime
                categories = finalizedCleanupCategories(
                    await appendNoriManagedPaths(to: preflight.categories), running: snapshot)
                cleanupDeferredPaths = preflight.deferredPaths
                cleanupScanComplete = preflight.succeeded && !control.isCancelled
                if !cleanupScanComplete {
                    for index in categories.indices { categories[index].selected = false }
                    CleanupCache.invalidate()
                }
                if !preflight.diagnostics.isEmpty { log(preflight.diagnostics) }
                finishCleanupProgress()
                isScanning = false
                noteHeaderReaction(cleanupScanComplete ? .success : .attention)
                let minutes = max(1, Int(cached.age / 60))
                statusText = cleanupScanComplete
                    ? l10n.tf("status.cacheRestored", minutes)
                    : l10n.t("log.scanPartial")
                log(l10n.tf("log.cacheUsed", categories.reduce(0) { $0 + $1.paths.count },
                            ByteFormat.format(totalBytes)))
                if !cleanupScanComplete, !control.isCancelled {
                    presentTaskFailure(message: statusText, details: [preflight.error ?? ""])
                }
            }
            return
        }
        categories = []
        beginCleanupProgress(mode: mode)
        isScanning = true
        cleanupScanComplete = false
        statusText = l10n.t("status.scanningCleanup")
        log(l10n.t("log.buildList"))

        Task {
            let scan = await unifiedCleanupScan(mode: mode, excludingScannedRoots: excludingScannedRoots)
            let combined = finalizedCleanupCategories(
                await appendNoriManagedPaths(to: completedCategories + scan.categories),
                running: scan.runningSnapshot)
            categories = combined
            cleanupDeferredPaths = scan.deferredPaths
            cleanupScanComplete = scan.sourceScansSucceeded
            if !cleanupScanComplete {
                for index in categories.indices { categories[index].selected = false }
            }
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
                    ? l10n.tf("log.scanDone", combined.reduce(0) { $0 + $1.paths.count },
                              ByteFormat.format(totalBytes))
                    : l10n.t("log.scanPartial"))
            }
            // Persist a successful empty result as well as a non-empty one.
            // A manual request may reuse a valid snapshot, including an
            // empty one. The cache stores only static scanner output; runtime
            // protection is still reapplied on every restore/use.
            if mode == .quick && scan.cacheable { CleanupCache.save(scan.categories) }
            // 合并入口的自动升级：快速扫描有 45s/8s 限时，被截断的目录
            // 直接续跑深度补扫，用户只感知一次“扫描”。
            if deepFollowUp, mode == .quick, !scan.cancelled, !scan.deferredPaths.isEmpty {
                log(l10n.t("cleanup.scan.deepFollowUp"))
                statusText = l10n.t("cleanup.scan.deepFollowUp")
                let completedCategories = scan.categories.compactMap { category in
                    category.retainingPaths(category.paths.filter { path in
                        scan.completedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
                    })
                }
                scanCleanup(force: true, mode: .deep, excludingScannedRoots: scan.completedRoots,
                            completedCategories: completedCategories)
            }
        }
    }

    /// 清理页唯一的扫描入口：先限时快速扫描给出结果，未完成的目录自动
    /// 升级为深度补扫。只准备清单，绝不自动打开确认或后台删除。
    func startCleanupScan() {
        guard !isBusyExcludingUninstall, !cleanupQueued else { return }
        family = .clean
        jump(to: .cleanup)
        scanCleanup(force: true, mode: .quick, deepFollowUp: true)
    }

    // MARK: - 系统维护（原系统优化页分流能力）

    /// 清理页“系统数据库”卡片：只体检、列出可执行项，逐项确认后执行。
    func scanSystemMaintenance() {
        guard !isSystemMaintenanceRunning, !isApplying else { return }
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
        guard !isBusy else { return }
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

        init(categories: [CleanupCategory], sourceResults: [RunResult],
             requiredSourceResults: [RunResult], runtimeResult: RunResult,
             runningSnapshot: RunningApplicationSnapshot,
             deferredPaths: [String] = [], cancelled: Bool = false,
             completedRoots: Set<String> = []) {
            self.categories = categories
            self.sourceResults = sourceResults
            self.requiredSourceResults = requiredSourceResults
            self.runtimeResult = runtimeResult
            self.runningSnapshot = runningSnapshot
            self.deferredPaths = deferredPaths
            self.cancelled = cancelled
            self.completedRoots = completedRoots
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
        async let core = NativeCore.shared.scanCleanup(progress: progress, mode: mode, control: control,
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
        let combined = CleanupCategory.safeCleanupCandidates(from: coreScan.categories)
            + coreScan.categories.filter(\.isAppDataReview).map { $0.clearingSelection() }
        if control.isCancelled {
            let cancelledResult = RunResult(output: "", errorOutput: "Scan cancelled.", exitCode: 1, timedOut: false)
            return UnifiedCleanupScan(categories: [], sourceResults: [cancelledResult],
                requiredSourceResults: [cancelledResult], runtimeResult: runtimeResult,
                runningSnapshot: .unavailable, cancelled: true)
        }


        let snapshot = RuntimeStore.runningApplicationSnapshot(
            fromProcessText: runtimeResult.output, isComplete: runtimeResult.succeeded)
        return UnifiedCleanupScan(
            categories: combined,
            sourceResults: [coreResult],
            requiredSourceResults: [coreResult],
            runtimeResult: runtimeResult,
            runningSnapshot: snapshot,
            deferredPaths: coreScan.deferredPaths, completedRoots: coreScan.completedRoots)
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
        return RuntimeStore.runningApplicationSnapshot(
            fromProcessText: result.output, isComplete: result.succeeded)
    }


    /// 原生扫描和缓存预检先产出当前可删除的文件单元，再按最新运行态
    /// 实际裁剪展示路径。清空选择不能把受保护的兄弟路径留在清单中。
    /// 执行前仍使用新的文件占用、身份与权限检查复核。
    private func finalizedCleanupCategories(_ source: [CleanupCategory],
                                             running snapshot: RunningApplicationSnapshot) -> [CleanupCategory] {
        let candidates = CleanupCategory.safeCleanupCandidates(from: source)
        let available = candidates.compactMap { category -> CleanupCategory? in
            let reviewed = category.selectingPaths(category.paths)
            return CleanupRiskPolicy.runtimeEligibleSubset(reviewed, running: snapshot)?
                .selectedSubset?.selectingPaths(Array(category.selectedPaths))
        }
        return CleanupCategory.mergingLongTail(
            available
        ).sorted(by: CleanupCategory.sizeDescending)
    }

    /// 开发工具扫描：包管理器卸载命令，Warning 项留给人工判断。
    func scanDeveloperTools() {
        guard authorize(.developerToolsScan, presentingPermissionCenter: true) else { return }
        guard !isBusy else { return }
        let scanEnvironment = fullDiskScanEnvironment
        guard scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1" else { return }
        family = .tools
        categories = []
        isScanning = true
        cleanupScanComplete = false
        statusText = l10n.t("status.scanning")
        log(l10n.t("log.scanningSafe"))
        Task {
            async let scanResult = MoleEngine.shared.runBridge(
                "bin/app_tool_scan.sh", extraEnvironment: scanEnvironment,
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

    func applyCleanup() {
        guard !isBusyExcludingUninstall, !cleanupQueued, !isSystemMaintenanceRunning,
              cleanupScanComplete else {
            if !cleanupScanComplete { statusText = l10n.t("log.scanPartial") }
            return
        }
        let installerSelection = installerCandidates?.selectedSubset
        let maintenanceIDs = systemMaintenanceRows
            .filter { systemMaintenanceSelection.contains($0.id) }.map(\.id)
        guard selectedCount > 0 || installerSelection != nil || !maintenanceIDs.isEmpty else {
            statusText = l10n.t("cleanup.selectNone")
            return
        }
        // Task {} inherits MainActor. Snapshot the selection and move the
        // potentially large filtering/sorting pass off the UI executor.
        let source = categories
        let applyFamily = family
        cleanupOutcomeMood = nil
        cleanupOutcomeDetails = []
        cleanupReclaimedBytes = 0
        cleanupCelebrating = false
        cleanupTaskProgress = .init()
        isApplying = true
        statusText = l10n.tf("status.processing",
                             selectedCount + (installerSelection?.paths.count ?? 0) + maintenanceIDs.count)
        Task {
            let selectedCategories = await Task.detached(priority: .utility) {
                let subsets = source.compactMap(\.selectedSubset)
                return applyFamily == .clean
                    ? CleanupCategory.manualCleanupCandidates(from: subsets) : subsets
            }.value
            // 普通项目直接执行；管理员项目由最终复核后的计划单独询问。
            performApply(categories: selectedCategories,
                         family: applyFamily, mode: .manual,
                         installers: installerSelection, maintenanceIDs: maintenanceIDs)
        }
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
        if uninstallQueue.activeJob != nil {
            guard pendingCleanup == nil else { return }
            cleanupQueued = true
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
        Task {
            let originalRequest = retryScope ?? requested
            let snapshot = await captureRunningApplicationSnapshot()
            let blocked = await Task.detached(priority: .utility) {
                var waiting: [CleanupCategory] = []
                var ready: [CleanupCategory] = []
                var owners = Set<String>()
                for category in requested {
                    var blockedPaths = Set<String>()
                    if case .manual = mode, snapshot.isComplete {
                        for path in category.paths {
                            let subset = category.selectingPaths([path])
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
            for index in categories.indices {
                if let reason = prepared.1[categories[index].id] {
                    categories[index].risk = .protected
                    categories[index].reasonKey = reason
                    categories[index].selected = false
                }
            }

            let eligibleCount = eligible.reduce(0) { $0 + $1.paths.count }
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
                let verified = await refreshCleanupInventory(after: applyFamily)
                configureCleanupRetry(originalRequest, family: applyFamily, mode: mode,
                                      installers: installers,
                                      maintenanceIDs: Array(Set(maintenanceIDs + pendingMaintenanceIDs)),
                                      result: executionResult, verified: verified)
                reportCleanupResult(executionResult,
                                    permanently: applyFamily == .clean, verified: verified,
                                    waitingApplications: Array(Set(Self.blockingApplicationNames(blocked.2)
                                        + busyCleanupApplications(executionResult, categories: originalRequest,
                                                                  running: snapshot))).sorted())
                isApplying = false
                recordRemainingCleanup(blocked.1, owners: blocked.2)
                return
            }

            // Partition the final, freshly validated plan before any destructive work.
            // Route executors never elevate independently, even if permissions change later.
            let administratorItems = await Task.detached(priority: .utility) {
                guard applyFamily == .clean else { return [DeletionPlan.Item]() }
                if case .automatic = mode { return [DeletionPlan.Item]() }
                return eligible.filter {
                    $0.risk == .safe && $0.disposal == .permanentDelete
                        && [.genericTrash, .developerCacheTrash, .aiTrash, .xcodeTrash].contains($0.applyRoute)
                }.flatMap { category in
                    category.paths.compactMap { path -> DeletionPlan.Item? in
                        guard NativeCore.shared.requiresAdministratorDeletion(path) else { return nil }
                        return .init(record: path, identity: category.pathIdentities[path] ?? "",
                                     metadata: DeletionPlan.Metadata.read(path))
                    }
                }
            }.value
            var includeAdministrator = false
            if !administratorItems.isEmpty {
                guard let decision = await confirmAdministratorCleanup(administratorItems) else {
                    cleanupTaskProgress = nil
                    isApplying = false
                    return
                }
                includeAdministrator = decision
            }
            let administratorPaths = Set(administratorItems.map(\.record))
            let directCategories = eligible.compactMap { category in
                category.retainingPaths(category.paths.filter { !administratorPaths.contains($0) })
            }
            if !includeAdministrator {
                executionResult.merge(.init(skipped: administratorItems.count))
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
            var completed = 0
            cleanupTaskProgress = .init(phase: .cleaning, completed: 0, total: total)
            for route in CleanupApplyRoute.allCases {
                guard let routeCategories = grouped[route], !routeCategories.isEmpty else { continue }
                let started = Date()
                log("cleanup route=\(route.rawValue) started paths=\(routeCategories.reduce(0) { $0 + $1.paths.count })")
                let routeResult = await executeCleanupRoute(
                    route, categories: routeCategories, mode: mode,
                    permanently: applyFamily == .clean,
                    onProgress: cleanupProgressCallback(generation: generation, offset: completed,
                        weight: routeCounts[route] ?? 0, total: total, categories: routeCategories))
                log(String(format: "cleanup route=%@ completed %.2fs", route.rawValue, Date().timeIntervalSince(started)))
                executionResult.merge(routeResult)
                completed += routeCounts[route] ?? 0
                cleanupTaskProgress = .init(phase: .cleaning, completed: completed, total: total)
            }

            // One verified elevation for all routes; a cancellation is never retried automatically.
            if includeAdministrator {
                let administrator = await AdministratorCleanupService.apply(items: administratorItems,
                    onProgress: cleanupProgressCallback(generation: generation, offset: completed,
                        weight: administratorItems.count, total: total, categories: eligible))
                executionResult.merge(administrator)
                completed += administratorItems.count
            }

            // 安装包可能是用户唯一的副本：勾选后由统一“清理”分发到废纸篓路线。
            if let installers {
                let routeResult = await executeCleanupRoute(
                    .installerTrash, categories: [installers], mode: mode,
                    permanently: false,
                    onProgress: cleanupProgressCallback(generation: generation, offset: completed,
                        weight: DeletionPlan.nonOverlappingPaths(installers.paths).count,
                        total: total, categories: [installers]))
                executionResult.merge(routeResult)
                completed += DeletionPlan.nonOverlappingPaths(installers.paths).count
                self.installerCandidates = self.installerCandidates?.retainingPaths(
                    self.installerCandidates?.paths.filter {
                        FileManager.default.fileExists(atPath: $0)
                    } ?? [])
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
            let verified = await refreshCleanupInventory(after: applyFamily)
            configureCleanupRetry(originalRequest, family: applyFamily, mode: mode,
                                  installers: self.installerCandidates?.selectedSubset,
                                  maintenanceIDs: remainingMaintenance,
                                  result: executionResult, verified: verified)
            reportCleanupResult(executionResult,
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
                                       verified: Bool) {
        let listed = Set(categories.flatMap(\.paths))
        let remaining = requested.compactMap { category in
            category.selectingPaths(result.remainingPaths(in: category.paths).filter {
                family != .clean || !verified || listed.contains($0)
            }).selectedSubset
        }
        cleanupRetryAvailable = !remaining.isEmpty || installers != nil || !maintenanceIDs.isEmpty
        cleanupRuntime.retryAction = cleanupRetryAvailable ? { [weak self] in
            self?.performApply(categories: remaining, family: family, mode: mode,
                               installers: installers, maintenanceIDs: maintenanceIDs)
        } : nil
    }

    func retryFailedCleanup() {
        guard !isBusyExcludingUninstall, !cleanupQueued, let retry = cleanupRuntime.retryAction else { return }
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
        cleanupFailureApplications = Array(Set(cleanupFailureApplications + Self.blockingApplicationNames(owners))).sorted()
        // 所有未完成路径已经保存在页面的清理重试里。成功反馈保持可见，
        // 用户下一次点击清理才提交剩余项，不再弹关闭应用/重试窗口。
    }

    private func refreshCleanupInventory(after family: CleanupFamily) async -> Bool {
        CleanupCache.invalidate()
        guard family == .clean else { return true }
        statusText = l10n.t("cleanup.refreshing")
        let displayed = categories
        let refreshed = await Task.detached(priority: .utility) {
            CleanupInventoryRefresh.refresh(displayed)
        }.value
        categories = refreshed.categories
        cleanupDeferredPaths = Array(Set(cleanupDeferredPaths + refreshed.deferredPaths)).sorted()
        return refreshed.deferredPaths.isEmpty
    }

    private func reportCleanupResult(_ result: CleanupExecutionResult,
                                     permanently: Bool,
                                     maintenance: CleanupExecutionResult = .init(),
                                     verified: Bool = true,
                                     waitingApplications: [String] = []) {
        var combined = result
        combined.merge(maintenance)
        cleanupOutcomeMood = combined.removed > 0 ? .success : .attention
        noteHeaderReaction(cleanupOutcomeMood)
        cleanupOutcomeDetails = combined.removed > 0 ? [] : combined.messages
            .filter { !$0.hasPrefix("Open-file check ") }.map(localizedCleanupDetail)
        if combined.removed == 0 {
            if !verified { cleanupOutcomeDetails.append(l10n.t("cleanup.execution.verificationIncomplete")) }
            if !waitingApplications.isEmpty {
                cleanupOutcomeDetails.append(l10n.t("task.closeApps.remaining"))
                cleanupOutcomeDetails.append(waitingApplications.joined(separator: ", "))
            }
        }
        cleanupTaskProgress = nil
        cleanupCompletedCount = combined.removed
        cleanupReclaimedBytes = combined.reclaimedBytes
        cleanupFailureApplications = waitingApplications
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
            : l10n.t("task.failure.message")
        log(summary)
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

    private func executeCleanupRoute(_ route: CleanupApplyRoute,
                                     categories routeCategories: [CleanupCategory],
                                     mode: CleanupExecutionMode,
                                     permanently: Bool = false,
                                     onProgress: ((Int, Int, String) -> Void)? = nil) async
        -> CleanupExecutionResult {
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
                let appDataCategories = directCategories.filter(\.isAppDataReview)
                let genericCategories = directCategories.filter {
                    $0.reasonKey != "cleanup.risk.agentLeftover" && !$0.isAppDataReview
                }
                let agentUnits = DeletionPlan.nonOverlappingPaths(agentLeftovers.flatMap(\.paths)).count
                let nativePaths = genericCategories.flatMap(\.paths)
                    .filter { !NoriOwnedStorage.isManagedPath($0, home: home) }
                let genericUnits = DeletionPlan.nonOverlappingPaths(nativePaths).count
                let appData = NativeCore.shared.applyAppDataReview(appDataCategories, homeDirectory: home)
                let routeUnits = agentUnits + genericUnits + administratorUnits + managedUnits
                let agentOutcome = agentLeftovers.isEmpty
                    ? AgentCleanupExecutor.Outcome(summary: .init(removed: 0, skipped: 0, failed: 0, messages: []), refused: 0)
                    : AgentCleanupExecutor.execute(agentLeftovers, running: agentSnapshot,
                                                   home: home, permanent: permanently,
                                                   onProgress: { done, _, path in
                                                       onProgress?(done, routeUnits, path)
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
                            onProgress?(agentUnits + done, routeUnits, path)
                        }, onCurrentFile: { path in
                            onProgress?(agentUnits + genericHandled, routeUnits, path)
                        })
                let agent = agentOutcome.summary
                return (agentUnits + genericUnits, NativeCore.ApplySummary(
                    removed: generic.removed + agent.removed + appData.removed,
                    skipped: generic.skipped + agent.skipped + agentOutcome.refused + appData.skipped,
                    failed: generic.failed + agent.failed + appData.failed,
                    messages: generic.messages + agent.messages + appData.messages,
                    removedPaths: generic.removedPaths.union(agent.removedPaths).union(appData.removedPaths),
                    reclaimedBytes: generic.reclaimedBytes &+ agent.reclaimedBytes &+ appData.reclaimedBytes))
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
                reclaimedBytes: applied.1.reclaimedBytes &+ managed.reclaimedBytes)
            if !summary.messages.isEmpty { log(summary.messages.joined(separator: "\n")) }
            let execution = CleanupExecutionResult(
                removed: summary.removed,
                skipped: summary.skipped,
                failed: summary.failed,
                messages: summary.messages,
                removedPaths: summary.removedPaths,
                reclaimedBytes: summary.reclaimedBytes)
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
        environment.merge(fullDiskScanEnvironment) { _, authorized in authorized }
        if route == .installerTrash, permanently {
            environment["SIMPLEMOLE_DELETE_MODE"] = "permanent"
        }
        let result = await MoleEngine.shared.runBridgeWithStdin(
            bridgeName, stdinData: stdinData, extraEnvironment: environment, timeout: 900)
        if !result.output.isEmpty { log(result.output) }
        logFailure(result, stdoutAlreadyLogged: true, notifyingUser: false)
        var summary = CleanupExecutionResult.reconciled(
            bridgeOutput: result.output, expectedCount: records.count)
        if summary.removed == records.count {
            summary.removedPaths = Set(records)
            summary.removed += coalescedCount
        } else {
            summary.skipped += coalescedCount
        }
        if !result.succeeded {
            summary.executionFailed = true
            summary.messages.append(result.errorOutput.isEmpty ? result.output : result.errorOutput)
        }
        return summary
    }
}
