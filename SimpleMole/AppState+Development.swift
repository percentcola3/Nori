import Foundation
import AppKit
import Darwin

/// Session-wide scan gates are independent of the developer page's UI state.
@MainActor
final class DevelopmentRuntimeState {
    fileprivate var gcScanned = false
    fileprivate var configAuditsStarted = false
}

@MainActor
extension AppState {
    /// Navigation refreshes read-only inventories; edits and repairs have their own actions.
    func refreshDeveloperWorkspace() {
        devWorkspaceRefreshToken &+= 1
        developerWorkspaceRefreshTask?.cancel()
        developerWorkspaceRefreshTask = nil
        devWorkspaceRefreshPending = false
        permissionCenter.refresh()
        if isDeveloperTaskBusy {
            devWorkspaceRefreshPending = true
            developerWorkspaceRefreshTask = Task { [weak self] in
                guard let self else { return }
                while self.isDeveloperTaskBusy {
                    guard !Task.isCancelled, self.isDeveloperWorkspaceVisible else { return }
                    do { try await Task.sleep(nanoseconds: 300_000_000) }
                    catch { return }
                }
                guard !Task.isCancelled, self.isDeveloperWorkspaceVisible else { return }
                self.devWorkspaceRefreshPending = false
                self.developerWorkspaceRefreshTask = nil
                self.scanDevEnv(announce: false, presentingPermissionCenter: false, notifyingUser: true)
                self.scanGc(force: true, notifyingUser: true)
            }
        } else {
            scanDevEnv(announce: false, presentingPermissionCenter: false, notifyingUser: true)
        }
        scanGc(force: true, notifyingUser: true)
    }

    private var isDeveloperWorkspaceVisible: Bool {
        visiblePages.indices.contains(selectedTab) && visiblePages[selectedTab] == .devenv
    }

    // MARK: - 网络与系统服务修复（开发环境页）

    /// DNS 缓存刷新 / 网络栈重置（管理员任务，复用提权桥接）。
    func runAdminNetworkTask(_ task: String) {
        guard !isNetworkToolRunning, confirmation == nil else { return }
        confirmation = Confirmation(
            title: l10n.t("nettool.confirm.title"),
            message: l10n.t("nettool.confirm.\(task)"),
            confirmLabel: l10n.t("nettool.confirm.ok")) { [weak self] in
                self?.performAdminNetworkTask(task)
            }
    }

    private func performAdminNetworkTask(_ task: String) {
        isNetworkToolRunning = true
        networkToolStatus = l10n.t("nettool.status.running")
        let testMode = ProcessInfo.processInfo.environment["MOLE_TEST_NO_AUTH"] == "1"
            || ProcessInfo.processInfo.environment["MOLE_TEST_MODE"] == "1"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isNetworkToolRunning = false
            }
            guard !testMode else {
                self.networkToolStatus = self.l10n.t("nettool.status.skipped")
                return
            }
            let result = await MoleEngine.shared.runPrivilegedBridge(
                "bin/app_optimize_admin.sh", arguments: [String(getuid()), task], timeout: 300)
            // 桥接输出 `task<TAB>state<TAB>message`，取本任务的回报行。
            let message = result.output.split(whereSeparator: \.isNewline)
                .last { $0.hasPrefix(task + "\t") }
                .map { $0.split(separator: "\t", maxSplits: 2).last.map(String.init) ?? "" } ?? ""
            let failed = !result.succeeded || message.isEmpty
            self.networkToolStatus = failed ? self.l10n.t("nettool.status.failed") : message
            if failed {
                self.logFailure(result, notifyingUser: false)
                self.presentTaskFailure(message: self.networkToolStatus, details: [result.diagnosticOutput])
            }
            self.noteHeaderReaction(failed ? .attention : .success)
        }
    }


    // MARK: - 开发环境

    func scanDevEnv(announce: Bool = true, presentingPermissionCenter: Bool = true,
                    notifyingUser: Bool? = nil) {
        guard !isDeveloperTaskBusy else { return }
        var scanEnvironment = fullDiskScanEnvironment
        scanEnvironment["NORI_DEV_SCAN_FAST"] = "1"
        isScanningEnv = true
        devEnvStatus = l10n.t("devenv.status.scanning")
        Task {
            let terminal = await DeveloperTerminalEnvironmentService.shared.snapshot()
            scanEnvironment.merge(terminal.environment) { _, sampled in sampled }
            let result = await MoleEngine.shared.runBridge(
                "bin/app_env_scan.sh", extraEnvironment: scanEnvironment,
                timeout: 180)
            isScanningEnv = false
            if announce { noteHeaderReaction(result.succeeded ? .success : .attention) }
            if result.succeeded {
                devEnvEntries = Parsers.devEnvEntries(result.output)
                let selectable = Set(devEnvEntries.filter(DeveloperRuntimePolicy.canClean).map(\.path))
                devEnvSelection.formIntersection(selectable)
                devEnvStatus = devEnvEntries.isEmpty ? l10n.t("devenv.status.none") : ""
            } else {
                devEnvSelection.removeAll()
                devEnvStatus = l10n.t("gc.failed")
            }
            logFailure(result, notifyingUser: notifyingUser ?? (announce || presentingPermissionCenter))
        }
    }

    func applyDevEnvCleanup() {
        guard !isDeveloperTaskBusy, confirmation == nil else { return }
        let paths = devEnvEntries.filter {
            DeveloperRuntimePolicy.canClean($0) && devEnvSelection.contains($0.path)
        }.map(\.path)
        guard !paths.isEmpty else {
            devEnvStatus = l10n.t("devenv.selectFirst")
            return
        }
        let bytes = devEnvSelectedBytes
        let globalPackageBytes = devEnvSelectedGlobalPackageBytes
        let deletionPlan = DeletionPlan(paths: paths)
        confirmation = Confirmation(
            title: l10n.tf("confirm.env.title", paths.count),
            message: globalPackageBytes > 0
                ? l10n.tf("confirm.env.msg.node", paths.count, ByteFormat.format(bytes),
                           ByteFormat.format(globalPackageBytes))
                : l10n.tf("confirm.env.msg", paths.count, ByteFormat.format(bytes)),
            confirmLabel: l10n.t("confirm.apply.trash.ok")) { [weak self] in
                guard let self, !self.isDeveloperTaskBusy else { return }
                self.isApplyingDevEnv = true
                self.devEnvStatus = self.l10n.t("status.envCleaning")
                self.log(self.l10n.tf("log.envClean", paths.count))
                Task {
                    let result = await MoleEngine.shared.runBridgeWithStdin(
                        "bin/app_apply.sh", stdinData: deletionPlan.stdinData, timeout: 900)
                    self.isApplyingDevEnv = false
                    if !result.output.isEmpty { self.log(result.output) }
                    self.logFailure(result, stdoutAlreadyLogged: true, notifyingUser: false)
                    let summary = CleanupExecutionResult.reconciled(
                        bridgeOutput: result.output, expectedCount: deletionPlan.items.count)
                    let fullySucceeded = result.succeeded && summary.failed == 0 && summary.skipped == 0
                    self.noteHeaderReaction(fullySucceeded ? .success : .attention)
                    self.resampleAfterMutation()
                    self.devEnvStatus = fullySucceeded
                        ? self.l10n.tf("status.envDone", summary.removed)
                        : self.l10n.tf("status.envPartial", summary.failed + summary.skipped)
                    self.log(fullySucceeded
                        ? self.l10n.tf("log.envDone", summary.removed)
                        : self.l10n.tf("log.envPartial", summary.removed, summary.failed + summary.skipped))
                    if !fullySucceeded {
                        self.presentTaskFailure(message: self.devEnvStatus, details: [result.diagnosticOutput])
                    }
                    self.scanDevEnv(announce: false)
                    // 环境删除可能让 PATH 条目/初始化块失效：重跑体检引导用户处理。
                    self.runConfigAudits(force: true)
                    self.log(self.l10n.t("log.envRcHint"))
                }
            }
    }

    // MARK: - 包管理 GC（owner 命令）

    /// 列出本机可用的官方 GC 命令（只读扫描，每次会话最多一次）。
    func scanGc(force: Bool = false, notifyingUser: Bool = false) {
        if (developmentRuntime.gcScanned && !force) || isRefreshingGc || gcRunningId != nil { return }
        developmentRuntime.gcScanned = true
        isRefreshingGc = true
        Task {
            let environment = await DeveloperTerminalEnvironmentService.shared.snapshot().environment
            let result = await MoleEngine.shared.runBridge("bin/app_gc_scan.sh", extraEnvironment: environment, timeout: 60)
            isRefreshingGc = false
            gcActions = result.output.components(separatedBy: "\n").compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2, !parts[0].isEmpty else { return nil }
                return GcAction(id: parts[0], command: parts[1],
                                bytes: parts.count > 2 ? UInt64(parts[2]) : nil)
            }
            logFailure(result, notifyingUser: notifyingUser)
        }
    }

    /// 运行一个白名单内的官方 GC 命令，输出逐行流入日志抽屉。
    func runGc(_ action: GcAction) {
        guard !isDeveloperTaskBusy, confirmation == nil else { return }
        confirmation = Confirmation(
            title: l10n.tf("gc.confirm.title", action.id),
            message: l10n.tf("gc.confirm.msg", action.command),
            confirmLabel: l10n.t("gc.run")) { [weak self] in
                guard let self, !self.isDeveloperTaskBusy else { return }
                self.gcRunningId = action.id
                self.devEnvStatus = self.l10n.tf("log.gcRun", action.command)
                self.log(self.l10n.tf("log.gcRun", action.command))
                Task {
                    let result = await MoleEngine.shared.runBridge(
                        "bin/app_gc_run.sh", arguments: [action.id],
                        timeout: 1200, onLine: self.streamLog)
                    self.gcRunningId = nil
                    self.noteHeaderReaction(result.succeeded ? .success : .attention)
                    self.resampleAfterMutation()
                    self.devEnvStatus = result.succeeded
                        ? self.l10n.t("gc.finished")
                        : self.l10n.t("gc.failed")
                    self.log(result.succeeded
                        ? self.l10n.t("gc.finished")
                        : self.l10n.t("gc.failed"))
                    self.logFailure(result, stdoutAlreadyLogged: true)
                    self.developmentRuntime.gcScanned = false
                    self.scanGc()
                }
            }
    }

    /// Shell 配置体检（只读，每次会话一次）。
    func runConfigAudits(force: Bool = false) {
        if developmentRuntime.configAuditsStarted && !force { return }
        developmentRuntime.configAuditsStarted = true
        log(l10n.t("log.shellAudit"))
        Task {
            let shell = await MoleEngine.shared.runBridge("bin/app_shell_audit.sh", timeout: 60)
            shellIssues = Parsers.shellIssues(shell.output)
            shellAudited = true
        }
    }

    func openInEditor(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
