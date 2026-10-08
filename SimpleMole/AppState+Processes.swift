import Foundation
import AppKit

/// Sampling history and automatic-cleanup attempts belong to the process
/// session; they do not publish unrelated presentation changes.
@MainActor
final class ProcessRuntimeState {
    fileprivate var history = ProcessHistory(capacity: 30)
    fileprivate var highUsageTracker = HighUsageTracker()
    fileprivate var sampleInFlight = false
    fileprivate var automaticTracker = RuntimeStore.AutomaticCandidateTracker()
    fileprivate var cleanupAttempted = 0
    fileprivate var cleanupSucceeded = 0
    fileprivate var cleanupTokens: Set<String> = []
}

@MainActor
extension AppState {
    // MARK: - 进程与端口

    func refreshRuntimeIfNeeded() {
        guard mainWindowVisible, !runtimeInFlight else { return }
        guard visiblePages.indices.contains(selectedTab) else { return }
        if visiblePages[selectedTab] == .processes {
            if advancedProcesses { refreshProcesses() } else { refreshNativeProcesses() }
        } else if visiblePages[selectedTab] == .ports { refreshPorts() }
        // Traffic uses its own timer while the page is visible or monitoring is enabled.
    }

    func refreshProcesses(allowAutomaticCleanup: Bool = true) {
        guard advancedProcesses else {
            resetAutomaticProcessCleanup()
            refreshNativeProcesses()
            return
        }
        guard !runtimeInFlight else { return }
        let requestedAdvancedMode = advancedProcesses
        runtimeInFlight = true
        if processRows.isEmpty { processStatus = l10n.t("proc.status.reading") }
        Task {
            let result = await MoleEngine.shared.runRuntime("processes")
            guard requestedAdvancedMode == advancedProcesses else {
                runtimeInFlight = false
                refreshProcesses()
                return
            }
            guard result.succeeded else {
                if requestedAdvancedMode {
                    processRuntime.automaticTracker.breakSequence()
                }
                runtimeInFlight = false
                processStatus = l10n.t("proc.status.readFailed")
                logFailure(result, notifyingUser: false)
                return
            }
            if requestedAdvancedMode {
                let rows = RuntimeStore.rows(fromProcessText: result.output, advanced: true)
                processRows = rows
                // 验证重扫也必须更新 tracker，确保恢复正常或已消失的进程
                // 及时打断旧计数；只禁止这一拍继续执行自动动作。
                let candidates = processRuntime.automaticTracker.candidates(in: rows)
                let selection = allowAutomaticCleanup
                    ? automaticCleanupSelection(fromCandidates: candidates)
                    : (actions: [], attemptedRows: [])
                if !selection.actions.isEmpty {
                    processStatus = l10n.tf("proc.status.autoProcessing", selection.actions.count)
                    await runAutomaticProcessCleanup(selection.actions)
                    return
                }
                runtimeInFlight = false
                updateAdvancedProcessStatus(for: rows)
            } else {
                resetAutomaticProcessCleanup()
                let native = RuntimeStore.nativeRows(fromProcessText: result.output)
                processRows = native.rows
                processStatus = l10n.tf("proc.status.apps", native.total)
                runtimeInFlight = false
            }
        }
    }

    // MARK: 应用级进程视图（libproc）

    /// 当前可见的进程组：搜索过滤 + 排序。
    var visibleProcessGroups: [ProcessGroup] {
        ProcessAggregator.sorted(ProcessAggregator.filter(processGroups, query: processSearch),
                                 by: processSort)
    }

    func processCPUHistory(_ pid: Int32) -> [Double] { processRuntime.history.series(for: pid) }

    /// 用 libproc 采样并按应用聚合。不占用 runtimeInFlight，采样在后台线程，
    /// 只有 NSWorkspace 的应用列表在主线程读取。
    func refreshNativeProcesses() {
        guard !processRuntime.sampleInFlight else { return }
        processRuntime.sampleInFlight = true
        if processGroups.isEmpty { processStatus = l10n.t("proc.status.reading") }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Nori"
        let applications: [(pid: Int32, name: String, startIdentity: String)] =
            NSWorkspace.shared.runningApplications.compactMap { application in
                guard !application.isTerminated,
                      application.processIdentifier > 1,
                      application.processIdentifier != ownPID,
                      application.activationPolicy != .prohibited,
                      let identity = RuntimeStore.nativeStartIdentity(for: application) else { return nil }
                let name = application.localizedName ?? application.bundleIdentifier ?? ""
                guard !name.isEmpty, name != ownName, name != "Mole" else { return nil }
                return (application.processIdentifier, name, identity)
            }
        Task {
            let sampled: (groups: [ProcessGroup], total: Int) = await Task.detached(priority: .utility) {
                let samples = ProcessSampler.shared.sample()
                let groups = ProcessAggregator.groups(
                    samples: samples, applications: applications, ownPID: ownPID,
                    detail: { L10n.shared.tf("proc.detail.app", $0) },
                    childDetail: { L10n.shared.tf("proc.detail.pid", $0.pid) })
                return (groups, samples.count)
            }.value
            processRuntime.sampleInFlight = false
            guard !advancedProcesses else { return }
            processGroups = sampled.groups
            let liveTokens = Set(sampled.groups.map { $0.app.signalToken })
            processQuitFeedback = processQuitFeedback.filter {
                liveTokens.contains($0.key) || $0.value == .waiting
            }
            processRows = sampled.groups.map(\.app)
            processRuntime.history.record(sampled.groups)
            processAlerts = processRuntime.highUsageTracker.update(sampled.groups)
            // 数量汇总对用户无感：正常采样后不再展示统计文案。
            processStatus = ""
        }
    }

    private func runningApplication(for row: ProcessRow) -> NSRunningApplication? {
        guard let application = NSRunningApplication(processIdentifier: row.pid),
              !application.isTerminated,
              RuntimeStore.nativeStartIdentity(for: application) == row.startIdentity else { return nil }
        return application
    }

    /// 温和退出（等同 ⌘Q）：应用可以弹出保存提示；5 秒后仍在运行则提示可强制退出。
    func quitApplication(_ row: ProcessRow) {
        guard processQuitFeedback[row.signalToken] != .waiting else { return }
        guard let application = runningApplication(for: row) else {
            processQuitFeedback[row.signalToken] = .stale
            processActionStatus = l10n.t("proc.refusal.identity")
            presentTaskFailure(message: processActionStatus)
            refreshNativeProcesses()
            return
        }
        processQuitFeedback[row.signalToken] = .waiting
        processActionStatus = l10n.tf("proc.status.quitRequested", row.name)
        guard application.terminate() else {
            processQuitFeedback[row.signalToken] = .refused
            processActionStatus = l10n.t("status.quitRefused")
            presentTaskFailure(message: processActionStatus)
            return
        }
        Task {
            for _ in 0..<50 {
                if application.isTerminated { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            processActionStatus = application.isTerminated
                ? l10n.tf("proc.status.quitDone", row.name)
                : l10n.tf("proc.status.stillRunning", row.name)
            processQuitFeedback[row.signalToken] = application.isTerminated ? nil : .stillRunning
            if !application.isTerminated { presentTaskFailure(message: processActionStatus) }
            refreshNativeProcesses()
            resampleAfterMutation()
        }
    }

    /// 结束整组：主进程 terminate → 5 秒 → forceTerminate；子进程 SIGTERM → 3 秒 → SIGKILL。
    /// 每个子进程结束前都重新核对启动身份、用户与路径。
    func endProcessGroup(_ group: ProcessGroup) {
        confirmation = Confirmation(
            title: l10n.tf("proc.confirm.endGroup.title", group.app.name),
            message: l10n.tf("proc.confirm.endGroup.msg", group.children.count),
            confirmLabel: l10n.t("proc.endGroup")) { [weak self] in
                guard let self else { return }
                Task { await self.performEndGroup(group) }
            }
    }

    private func performEndGroup(_ group: ProcessGroup) async {
        guard processQuitFeedback[group.app.signalToken] != .waiting else { return }
        processQuitFeedback[group.app.signalToken] = .waiting
        defer { processQuitFeedback[group.app.signalToken] = nil }
        processActionStatus = l10n.tf("proc.status.quitRequested", group.app.name)
        let application = runningApplication(for: group.app)
        var mainEnded = application == nil
        if let application {
            if !application.terminate() { _ = application.forceTerminate() }
            for _ in 0..<50 {
                if application.isTerminated { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !application.isTerminated { _ = application.forceTerminate() }
            for _ in 0..<10 where !application.isTerminated {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            mainEnded = application.isTerminated
        }
        var endedChildren = 0
        for child in group.children {
            guard let identity = Self.childIdentity(child) else { continue }
            if await ProcessTerminator.terminateThenKill(identity, grace: 3) { endedChildren += 1 }
        }
        processActionStatus = mainEnded
            ? l10n.tf("proc.status.groupEnded", group.app.name, endedChildren)
            : l10n.tf("proc.status.stillRunning", group.app.name)
        if !mainEnded || endedChildren < group.children.count {
            presentTaskFailure(message: processActionStatus,
                details: group.children.map { "\($0.name) · PID \($0.pid)" }, detailsAreLocalized: true)
        }
        refreshNativeProcesses()
        resampleAfterMutation()
    }

    /// 结束单个子进程（非应用主进程）。
    func terminateChildProcess(_ row: ProcessRow) {
        guard let identity = Self.childIdentity(row) else { return }
        confirmation = Confirmation(
            title: l10n.tf("proc.confirm.child.title", row.name),
            message: l10n.tf("proc.confirm.kill.msg", row.pid),
            confirmLabel: l10n.t("proc.kill")) { [weak self] in
                guard let self else { return }
                Task {
                    switch ProcessTerminator.validate(identity) {
                    case .failure(let refusal):
                        self.processActionStatus = self.l10n.t(Self.refusalKey(refusal))
                        self.presentTaskFailure(message: self.processActionStatus)
                        return
                    case .success:
                        break
                    }
                    let ended = await ProcessTerminator.terminateThenKill(identity, grace: 3)
                    self.processActionStatus = ended
                        ? self.l10n.t("status.signalSent") : self.l10n.t("status.signalFailed")
                    if !ended { self.presentTaskFailure(message: self.processActionStatus) }
                    self.refreshNativeProcesses()
                    self.resampleAfterMutation()
                }
            }
    }

    private static func childIdentity(_ row: ProcessRow) -> ProcessIdentity? {
        guard let startTime = UInt64(row.startIdentity, radix: 16) else { return nil }
        return ProcessIdentity(pid: row.pid, startTime: startTime, ppid: row.ppid, uid: row.uid)
    }

    private static func refusalKey(_ refusal: ProcessTerminator.Refusal) -> String {
        switch refusal {
        case .identityChanged: return "proc.refusal.identity"
        case .otherUser: return "proc.refusal.otherUser"
        case .protectedPath: return "proc.refusal.protected"
        case .ownProcessTree: return "proc.refusal.own"
        }
    }

    /// 连续采样达到阈值后才自动处理。每轮最多执行四个动作；多个 zombie
    /// 共用同一 UID + PPID 时只通知父进程一次，但会一起标记为已尝试。
    private func automaticCleanupSelection(fromCandidates candidates: [ProcessRow])
        -> (actions: [ProcessRow], attemptedRows: [ProcessRow]) {
        guard !candidates.isEmpty else { return ([], []) }

        var actions: [ProcessRow] = []
        var attemptedRows: [ProcessRow] = []
        var selectedZombieParents: Set<String> = []

        for row in candidates {
            if row.lifecycle == .zombie {
                let parentKey = "\(row.uid):\(row.ppid)"
                if selectedZombieParents.contains(parentKey) {
                    attemptedRows.append(row)
                    continue
                }
                guard actions.count < 4 else { continue }
                selectedZombieParents.insert(parentKey)
                actions.append(row)
                attemptedRows.append(row)
            } else {
                guard actions.count < 4 else { continue }
                actions.append(row)
                attemptedRows.append(row)
            }
        }

        processRuntime.automaticTracker.markAttempted(attemptedRows)
        processRuntime.cleanupTokens.formUnion(attemptedRows.map(\.staleCleanupToken))
        return (actions, attemptedRows)
    }

    private func runAutomaticProcessCleanup(_ rows: [ProcessRow]) async {
        var attempted = 0
        var succeeded = 0
        var failureDetails: [String] = []
        for row in rows {
            guard advancedProcesses else { break }
            attempted += 1
            let result = await MoleEngine.shared.runRuntime("cleanup-stale", row.staleCleanupToken)
            if result.succeeded {
                succeeded += 1
            } else {
                logFailure(result, notifyingUser: false)
                failureDetails.append(row.name + " · PID \(row.pid)\n" + result.diagnosticOutput)
            }
        }

        processRuntime.cleanupAttempted += attempted
        processRuntime.cleanupSucceeded += succeeded
        runtimeInFlight = false
        if !failureDetails.isEmpty { presentTaskFailure(details: failureDetails) }
        guard advancedProcesses else {
            resetAutomaticProcessCleanup()
            return
        }
        // 以重扫结果作为最终状态，避免把已变化或未回收的进程误报为成功。
        // 验证重扫不继续取下一批，单轮最多自动处理四个；其余候选交给下次定时刷新。
        refreshProcesses(allowAutomaticCleanup: false)
    }

    private func updateAdvancedProcessStatus(for rows: [ProcessRow]) {
        let abnormalRows = rows.filter { $0.lifecycle != .normal }
        let abnormalCount = abnormalRows.count
        processRuntime.cleanupTokens.formIntersection(abnormalRows.map(\.staleCleanupToken))
        if processRuntime.cleanupAttempted > 0 {
            let succeeded = processRuntime.cleanupSucceeded
            processRuntime.cleanupAttempted = 0
            processRuntime.cleanupSucceeded = 0
            if abnormalCount == 0, succeeded > 0 {
                processStatus = l10n.tf("proc.status.autoCleaned", succeeded)
            } else if abnormalCount == 0 {
                // 处理失败后目标可能自行退出；此时不把自然消失误报成清理成功。
                processStatus = rows.isEmpty ? l10n.t("proc.status.none") : ""
            } else {
                processStatus = l10n.tf("proc.status.abnormalRemaining", abnormalCount)
            }
        } else if !processRuntime.cleanupTokens.isEmpty {
            processStatus = l10n.tf("proc.status.abnormalRemaining", abnormalCount)
        } else if abnormalCount > 0 {
            processStatus = l10n.tf("proc.status.abnormalDetected", abnormalCount)
        } else {
            processStatus = rows.isEmpty ? l10n.t("proc.status.none") : ""
        }
    }

    func resetAutomaticProcessCleanup() {
        processRuntime.automaticTracker = RuntimeStore.AutomaticCandidateTracker()
        processRuntime.cleanupAttempted = 0
        processRuntime.cleanupSucceeded = 0
        processRuntime.cleanupTokens.removeAll()
    }

    func refreshPorts() {
        guard !runtimeInFlight else { return }
        runtimeInFlight = true
        portStatus = l10n.t("ports.status.reading")
        Task {
            let result = await MoleEngine.shared.runRuntime("ports")
            runtimeInFlight = false
            // 读取失败时保留上一轮列表，不把"读不到"显示成"没有端口"。
            guard result.succeeded else {
                portStatus = l10n.t("ports.status.readFailed")
                logFailure(result, notifyingUser: false)
                return
            }
            portRows = RuntimeStore.portRows(fromText: result.output)
            portStatus = portRows.isEmpty ? l10n.t("ports.status.none") : ""
        }
    }

    func terminateProcess(_ row: ProcessRow) {
        if row.isNativeApp {
            guard processQuitFeedback[row.signalToken] != .waiting else { return }
            confirmation = Confirmation(
                title: l10n.tf("proc.confirm.quit.title", row.name),
                message: l10n.t("proc.force.message"),
                confirmLabel: l10n.t("proc.force.action")) {
                    guard self.processQuitFeedback[row.signalToken] != .waiting else { return }
                    let application = NSRunningApplication(processIdentifier: row.pid)
                    let identityMatches = application.flatMap(RuntimeStore.nativeStartIdentity(for:))
                        == row.startIdentity
                    let requested = identityMatches && !(application?.isTerminated ?? true)
                        ? (application?.forceTerminate() ?? false)
                        : false
                    self.processQuitFeedback[row.signalToken] = requested ? .waiting : .refused
                    Task { @MainActor in
                        self.processActionStatus = requested
                            ? self.l10n.t("status.quitRequested")
                            : self.l10n.t("status.quitRefused")
                        guard requested, let application else {
                            self.presentTaskFailure(message: self.processActionStatus)
                            return
                        }
                        for _ in 0..<20 {
                            if application.isTerminated { break }
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                        self.processActionStatus = application.isTerminated
                            ? self.l10n.t("proc.force.done") : self.l10n.t("status.quitRefused")
                        self.processQuitFeedback[row.signalToken] = application.isTerminated ? nil : .refused
                        if !application.isTerminated { self.presentTaskFailure(message: self.processActionStatus) }
                        self.refreshProcesses(allowAutomaticCleanup: false)
                        self.resampleAfterMutation()
                    }
                }
            return
        }
        if row.lifecycle != .normal {
            confirmation = Confirmation(
                title: l10n.t("proc.confirm.cleanupStale.title"),
                message: l10n.t("proc.confirm.cleanupStale.msg"),
                confirmLabel: l10n.t("proc.cleanupStale")) { [weak self] in
                    self?.cleanupStaleProcess(row)
                }
            return
        }
        let mode = advancedProcesses ? "kill-pid" : "kill-group"
        let title = advancedProcesses
            ? l10n.t("proc.confirm.killPid.title")
            : l10n.t("proc.confirm.killGroup.title")
        confirmation = Confirmation(
            title: title,
            message: l10n.tf("proc.confirm.kill.msg", row.pid),
            confirmLabel: l10n.t("proc.kill")) { [weak self] in
                guard let self else { return }
                Task {
                    while self.runtimeInFlight {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    self.runtimeInFlight = true
                    let result = await MoleEngine.shared.runRuntime(mode, row.signalToken)
                    self.processActionStatus = result.succeeded
                        ? self.l10n.t("status.signalSent")
                        : self.l10n.t("status.signalFailed")
                    self.logFailure(result)
                    self.runtimeInFlight = false
                    self.refreshProcesses(allowAutomaticCleanup: false)
                    self.resampleAfterMutation()
                }
            }
    }

    private func cleanupStaleProcess(_ row: ProcessRow) {
        guard advancedProcesses, !runtimeInFlight, row.lifecycle != .normal else { return }
        let coveredRows: [ProcessRow]
        if row.lifecycle == .zombie {
            coveredRows = processRows.filter {
                $0.lifecycle == .zombie && $0.uid == row.uid && $0.ppid == row.ppid
            }
        } else {
            coveredRows = [row]
        }
        processRuntime.automaticTracker.markAttempted(coveredRows)
        processRuntime.cleanupTokens.formUnion(coveredRows.map(\.staleCleanupToken))
        runtimeInFlight = true
        processStatus = l10n.tf("proc.status.autoProcessing", 1)
        Task {
            let result = await MoleEngine.shared.runRuntime("cleanup-stale", row.staleCleanupToken)
            processRuntime.cleanupAttempted += 1
            if result.succeeded {
                processRuntime.cleanupSucceeded += 1
            } else {
                logFailure(result)
            }
            runtimeInFlight = false
            resampleAfterMutation()
            guard advancedProcesses else {
                resetAutomaticProcessCleanup()
                return
            }
            refreshProcesses(allowAutomaticCleanup: false)
        }
    }

    func closePort(_ row: PortRow) {
        guard confirmation == nil else { return }
        confirmation = Confirmation(
            title: l10n.tf("ports.confirm.title", row.pid),
            message: l10n.tf("ports.confirm.msg", row.port, row.command),
            confirmLabel: l10n.t("ports.close")) { [weak self] in
                guard let self else { return }
                Task {
                    let result = await MoleEngine.shared.runRuntime("kill-pid", row.signalToken)
                    self.portStatus = result.succeeded
                        ? self.l10n.t("status.signalSent")
                        : self.l10n.t("status.signalFailed")
                    self.logFailure(result)
                    self.refreshPorts()
                    self.resampleAfterMutation()
                }
            }
    }
}
