import Foundation
import AppKit

/// Scheduling bookkeeping has a single owner separate from rule presentation.
@MainActor
final class AutomationRuntimeState {
    fileprivate var scheduledRetry: DispatchWorkItem?
    fileprivate var reportedPermissionRequirement = false
}

@MainActor
extension AppState {
    // MARK: - 自动目录清理

    private static let autoCleanupLastCheckKey = "SMAutoCleanupLastCheck"
    private static let autoCleanupMinimumInterval: TimeInterval = 6 * 60 * 60

    /// 选择目录后进入同一个创建面板，在创建前确认用途与策略。
    func chooseAutoCleanupDirectory() -> String? {
        guard !isBusy else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = l10n.t("auto.pick.message")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let directory = try AutoCleanupPlanner.validatedRoot(url)
            guard !autoCleanupRules.contains(where: { $0.directories.contains(directory) }) else {
                autoCleanupStatus = l10n.t("auto.status.duplicate")
                return nil
            }
            return directory
        } catch {
            autoCleanupStatus = l10n.tf("auto.status.invalid", error.localizedDescription)
            log(autoCleanupStatus)
            presentTaskFailure(message: autoCleanupStatus)
            return nil
        }
    }

    /// 清理类目的多个缓存目录归入一个任务，共用策略、开关和执行统计。
    /// 清理页的路径已由风险策略判定为可再生缓存，创建时直接记录
    /// 安全授权；磁盘分析的目录由用户在创建面板里自行确认“仅可再生
    /// 内容”。确认发生在创建面板里；创建成功就启用并立即检查。
    @discardableResult
    func addAutoCleanupRules(forDirectories directories: [String],
                             policy: AutoCleanupPolicy,
                             sizeLimitBytes: UInt64,
                             retentionDays: Int,
                             regenerableConfirmed: Bool,
                             sourceName: String? = nil) -> (added: Int, skipped: Int) {
        guard !isBusy, regenerableConfirmed else {
            autoCleanupStatus = l10n.t("auto.status.needsConfirmation")
            return (0, directories.count)
        }
        var added = 0
        var skipped = 0
        var addedDirectories = Set<String>()
        var failures: [String] = []
        for directory in directories {
            do {
                let validated = try AutoCleanupPlanner.validatedRoot(
                    URL(fileURLWithPath: directory))
                guard !autoCleanupRules.contains(where: { $0.directories.contains(validated) }) else {
                    skipped += 1
                    continue
                }
                let rule = AutoCleanupRule(
                    directory: validated,
                    sourceName: sourceName,
                    policy: policy,
                    sizeLimitBytes: sizeLimitBytes,
                    retentionDays: retentionDays,
                    isEnabled: true,
                    isRegenerable: true,
                    lastRunAt: nil,
                    lastReclaimedBytes: 0)
                guard rule.isSafetyAuthorized, rule.isEnabled else {
                    throw AutoCleanupPlannerError.rootAuthorizationChanged(validated)
                }
                autoCleanupRules.append(rule)
                addedDirectories.insert(validated)
                added += 1
            } catch {
                skipped += 1
                log(l10n.tf("auto.status.invalid", error.localizedDescription))
                failures.append(directory + "\n" + error.localizedDescription)
            }
        }
        if added > 0 {
            autoCleanupRules = AutoCleanupRuleStore.consolidatedTasks(from: autoCleanupRules)
            // 合并任务的迁移规则可能因旧策略不同而暂停；明确的新建操作
            // 仍须启用它触及的、已确认完整范围的任务。
            for index in autoCleanupRules.indices where
                !addedDirectories.isDisjoint(with: autoCleanupRules[index].directories) {
                autoCleanupRules[index].policy = policy
                autoCleanupRules[index].sizeLimitBytes = sizeLimitBytes
                autoCleanupRules[index].retentionDays = retentionDays
                autoCleanupRules[index].isEnabled = autoCleanupRules[index].isSafetyAuthorized
            }
            persistAutoCleanupRules()
        }
        if !failures.isEmpty { presentTaskFailure(details: failures) }
        if added > 0 {
            UserDefaults.standard.removeObject(forKey: Self.autoCleanupLastCheckKey)
            runScheduledAutoCleanup(force: true, notifyingUser: true)
        }
        return (added, skipped)
    }

    func updateAutoCleanupRule(_ updated: AutoCleanupRule) {
        guard !isBusy else { return }
        guard let index = autoCleanupRules.firstIndex(where: { $0.id == updated.id }) else { return }
        let previous = autoCleanupRules[index]
        var normalized = updated
        normalized.sizeLimitBytes = min(
            AutoCleanupRule.maximumSizeLimitBytes,
            max(AutoCleanupRule.minimumSizeLimitBytes, normalized.sizeLimitBytes))
        normalized.retentionDays = min(3650, max(1, normalized.retentionDays))
        if normalized.isRegenerable {
            if !previous.isRegenerable || previous.directories != normalized.directories {
                normalized.authorizedRootIdentity = AutoCleanupRule.rootIdentity(
                    at: normalized.directory)
                for index in normalized.additionalRoots.indices {
                    normalized.additionalRoots[index].authorizedIdentity = AutoCleanupRule.rootIdentity(
                        at: normalized.additionalRoots[index].directory)
                }
            } else {
                normalized.authorizedRootIdentity = previous.authorizedRootIdentity
                normalized.additionalRoots = previous.additionalRoots
            }
            if normalized.roots.allSatisfy({ root in
                guard let authorized = root.authorizedIdentity else { return false }
                return AutoCleanupRule.rootIdentity(at: root.directory) == authorized
            }) {
                normalized.safetyVersion = AutoCleanupRule.currentSafetyVersion
            } else {
                normalized.isRegenerable = false
                normalized.isEnabled = false
                normalized.authorizedRootIdentity = nil
                for index in normalized.additionalRoots.indices {
                    normalized.additionalRoots[index].authorizedIdentity = nil
                }
                autoCleanupStatus = l10n.t("auto.status.authorizationRequired")
            }
        } else {
            normalized.isEnabled = false
            normalized.authorizedRootIdentity = nil
            for index in normalized.additionalRoots.indices {
                normalized.additionalRoots[index].authorizedIdentity = nil
            }
        }
        if normalized.isEnabled && !normalized.isSafetyAuthorized {
            normalized.isEnabled = false
            autoCleanupStatus = l10n.t("auto.status.authorizationRequired")
        }
        let becameEnabled = normalized.isEnabled && !previous.isEnabled
        let scheduleAdjusted = normalized.isEnabled && (
            previous.policy != normalized.policy
                || previous.sizeLimitBytes != normalized.sizeLimitBytes
                || previous.retentionDays != normalized.retentionDays)
        autoCleanupRules[index] = normalized
        if autoCleanupPreviewRuleID == normalized.id {
            autoCleanupPreview = nil
            autoCleanupPreviewRuleID = nil
        }
        autoCleanupRuleIssues[normalized.id] = nil
        persistAutoCleanupRules()
        if becameEnabled || scheduleAdjusted {
            UserDefaults.standard.removeObject(forKey: Self.autoCleanupLastCheckKey)
        }
        if becameEnabled {
            // 开启规则立即执行一轮；只清限频不触发会让用户以为定时没生效。
            runScheduledAutoCleanup(force: true, notifyingUser: true)
        }
    }

    func removeAutoCleanupRule(_ id: UUID) {
        guard !isBusy else { return }
        autoCleanupRules.removeAll { $0.id == id }
        autoCleanupRuleIssues[id] = nil
        if autoCleanupPreviewRuleID == id {
            autoCleanupPreview = nil
            autoCleanupPreviewRuleID = nil
        }
        persistAutoCleanupRules()
    }

    func previewAutoCleanup(_ id: UUID) {
        guard authorize(.previewAutoCleanup(ruleID: id),
                        presentingPermissionCenter: true) else { return }
        guard !isBusy, let rule = autoCleanupRules.first(where: { $0.id == id }) else { return }
        isAutoCleanupScanning = true
        autoCleanupStatus = l10n.t("auto.status.scanning")
        Task {
            do {
                let plan = try await AutoCleanupPlanner.plan(
                    for: rule, protecting: protectedAutoCleanupDirectories(excluding: id))
                autoCleanupPreview = plan
                autoCleanupPreviewRuleID = id
                autoCleanupRuleIssues[id] = nil
                autoCleanupStatus = plan.candidates.isEmpty
                    ? l10n.t("auto.status.empty")
                    : l10n.tf("auto.status.preview", plan.candidates.count,
                              ByteFormat.format(plan.reclaimableBytes))
            } catch {
                autoCleanupPreview = nil
                autoCleanupPreviewRuleID = nil
                autoCleanupRuleIssues[id] = error.localizedDescription
                autoCleanupStatus = l10n.tf("auto.status.invalid", error.localizedDescription)
                log(autoCleanupStatus)
                presentTaskFailure(message: autoCleanupStatus)
            }
            isAutoCleanupScanning = false
        }
    }

    /// 手动执行仍需二次确认；确认后会重新规划，避免使用过期预览。
    func runAutoCleanupNow(_ id: UUID) {
        guard authorize(.runAutoCleanup(ruleID: id),
                        presentingPermissionCenter: true) else { return }
        guard !isBusy, let rule = autoCleanupRules.first(where: { $0.id == id }) else { return }
        isAutoCleanupScanning = true
        autoCleanupStatus = l10n.t("auto.status.scanning")
        Task {
            do {
                let plan = try await AutoCleanupPlanner.plan(
                    for: rule, protecting: protectedAutoCleanupDirectories(excluding: id))
                autoCleanupPreview = plan
                autoCleanupPreviewRuleID = id
                isAutoCleanupScanning = false
                guard !plan.candidates.isEmpty else {
                    autoCleanupStatus = l10n.t("auto.status.empty")
                    return
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = l10n.t("auto.confirm.title")
                alert.informativeText = l10n.tf(
                    "auto.confirm.message", plan.candidates.count,
                    ByteFormat.format(plan.reclaimableBytes))
                alert.addButton(withTitle: l10n.t("confirm.apply.trash.ok"))
                alert.addButton(withTitle: l10n.t("common.cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                isAutoCleanupScanning = true
                let result = await applyAutoCleanup(rule: rule, plan: plan)
                isAutoCleanupScanning = false
                autoCleanupRuleIssues[id] = result.failed == 0 ? nil
                    : l10n.tf("auto.status.partial", result.removed, result.failed)
                autoCleanupStatus = result.failed == 0
                    ? l10n.tf("auto.status.done", result.removed,
                              ByteFormat.format(result.reclaimedBytes))
                    : l10n.tf("auto.status.partial", result.removed, result.failed)
                if result.failed > 0 {
                    presentTaskFailure(message: autoCleanupStatus, details: result.messages)
                }
            } catch {
                isAutoCleanupScanning = false
                autoCleanupRuleIssues[id] = error.localizedDescription
                autoCleanupStatus = l10n.tf("auto.status.invalid", error.localizedDescription)
                log(autoCleanupStatus)
                presentTaskFailure(message: autoCleanupStatus)
            }
        }
    }

    /// 启动后与每小时定时器都会调用；这里把实际目录扫描限频为每六小时一次。
    func runScheduledAutoCleanup(force: Bool = false, notifyingUser: Bool = true) {
        let hasScheduledWork = autoCleanupRules.contains {
            $0.isEnabled && $0.isSafetyAuthorized
        }
        guard hasScheduledWork else {
            cancelAutomationRetry()
            return
        }

        // Background work must never trigger macOS Desktop/Documents/Downloads
        // consent dialogs. Automated scans require the same one-time Full Disk
        // Access grant as manual protected scans, but skip silently instead of
        // presenting the permission center when the grant is absent.
        permissionCenter.refresh()
        guard permissionCenter.fullDiskAccessGranted else {
            cancelAutomationRetry()
            autoCleanupStatus = l10n.t("auto.status.diskPermissionRequired")
            if !automationRuntime.reportedPermissionRequirement {
                log(l10n.t("auto.log.diskPermissionRequired"))
                automationRuntime.reportedPermissionRequirement = true
            }
            return
        }
        automationRuntime.reportedPermissionRequirement = false

        guard !isBusy, taskNotice == nil else {
            scheduleAutomationRetry()
            return
        }
        cancelAutomationRetry()
        let rules = autoCleanupRules.filter { $0.isEnabled && $0.isSafetyAuthorized }
        guard !rules.isEmpty else { return }
        let defaults = UserDefaults.standard
        let lastCheck = defaults.object(forKey: Self.autoCleanupLastCheckKey) as? Date
        if !force, let lastCheck,
           Date().timeIntervalSince(lastCheck) < Self.autoCleanupMinimumInterval {
            return
        }
        defaults.set(Date(), forKey: Self.autoCleanupLastCheckKey)

        isAutoCleanupScanning = true
        autoCleanupStatus = l10n.t("auto.status.scanning")
        Task {
            var removed = 0
            var reclaimed: UInt64 = 0
            var failures = 0
            var failureDetails: [String] = []
            for snapshot in rules {
                guard let current = autoCleanupRules.first(where: { $0.id == snapshot.id }),
                      current.isEnabled, current.isSafetyAuthorized else { continue }
                do {
                    let protectedDirectories = protectedAutoCleanupDirectories(excluding: current.id)
                    let plan = try await AutoCleanupPlanner.plan(
                        for: current,
                        protecting: protectedDirectories)
                    // Planning suspends the main actor. A disabled/edited rule or
                    // newly nested rule must invalidate the old deletion plan.
                    guard autoCleanupRules.first(where: { $0.id == current.id }) == current,
                          protectedAutoCleanupDirectories(excluding: current.id) == protectedDirectories else {
                        defaults.removeObject(forKey: Self.autoCleanupLastCheckKey)
                        continue
                    }
                    guard !plan.candidates.isEmpty else {
                        autoCleanupRuleIssues[current.id] = nil
                        noteAutoCleanupCheck(current.id)
                        continue
                    }
                    let result = await applyAutoCleanup(rule: current, plan: plan)
                    noteAutoCleanupCheck(current.id)
                    removed += result.removed
                    reclaimed &+= result.reclaimedBytes
                    failures += result.failed
                    if result.failed > 0 { failureDetails += result.messages }
                    autoCleanupRuleIssues[current.id] = result.failed == 0 ? nil
                        : l10n.tf("auto.status.partial", result.removed, result.failed)
                } catch {
                    failures += 1
                    noteAutoCleanupCheck(current.id)
                    autoCleanupRuleIssues[current.id] = error.localizedDescription
                    log(l10n.tf("auto.log.ruleFailed", current.directory, error.localizedDescription))
                    failureDetails.append(current.directory + "\n" + error.localizedDescription)
                }
            }
            isAutoCleanupScanning = false
            if failures > 0 {
                // 临时权限或文件竞争失败时，让下一次小时调度重试，而不是静默等待六小时。
                defaults.removeObject(forKey: Self.autoCleanupLastCheckKey)
            }
            autoCleanupStatus = failures == 0
                ? l10n.tf("auto.status.done", removed, ByteFormat.format(reclaimed))
                : l10n.tf("auto.status.partial", removed, failures)
            if notifyingUser && failures > 0 {
                presentTaskFailure(message: autoCleanupStatus, details: failureDetails)
            }
        }
    }

    private func noteAutoCleanupCheck(_ id: UUID) {
        guard let index = autoCleanupRules.firstIndex(where: { $0.id == id }) else { return }
        autoCleanupRules[index].lastCheckedAt = Date()
        persistAutoCleanupRules()
    }

    private func scheduleAutomationRetry() {
        guard automationRuntime.scheduledRetry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.automationRuntime.scheduledRetry = nil
                self.runScheduledAutoCleanup()
            }
        }
        automationRuntime.scheduledRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60, execute: work)
    }

    private func cancelAutomationRetry() {
        automationRuntime.scheduledRetry?.cancel()
        automationRuntime.scheduledRetry = nil
    }

    private func applyAutoCleanup(rule: AutoCleanupRule, plan: AutoCleanupPlan) async
        -> (removed: Int, failed: Int, reclaimedBytes: UInt64, messages: [String]) {
        guard autoCleanupRules.first(where: { $0.id == rule.id }) == rule,
              rule.isSafetyAuthorized,
              plan.candidates.allSatisfy(\.automaticEligible) else {
            return (0, max(1, plan.candidates.count), 0, [l10n.t("auto.status.authorizationRequired")])
        }
        var planned: [AutoCleanupCandidate] = []
        var preparationFailures = 0
        for candidate in plan.candidates {
            // Every candidate is a direct child of its own authorized cache root.
            // 根授权由原生最终验证再次检查，不能凭路径字符串继承。
            let candidateRoot = URL(fileURLWithPath: candidate.path).deletingLastPathComponent().path
            guard !candidate.identity.isEmpty,
                  let root = rule.roots.first(where: { $0.directory == candidateRoot }),
                  root.authorizedIdentity != nil,
                  !protectedAutoCleanupDirectories(excluding: rule.id).contains(where: {
                      $0 == candidate.path || $0.hasPrefix(candidate.path + "/")
                  }) else {
                preparationFailures += 1
                continue
            }
            planned.append(candidate)
        }
        guard !planned.isEmpty else {
            return (0, max(1, preparationFailures), 0, [l10n.t("cleanup.execution.changed")])
        }

        autoCleanupStatus = l10n.tf("auto.status.cleaning", planned.count)
        log(l10n.tf("auto.log.cleaning", planned.count, rule.directory))
        let candidatesByPath = Dictionary(planned.map { ($0.path, $0) },
                                          uniquingKeysWith: { first, _ in first })
        let protectedDirectories = protectedAutoCleanupDirectories(excluding: rule.id)
        let summary = await Task.detached(priority: .utility) {
            NativeCore.shared.applyCleanup(
                items: planned.map { DeletionPlan.Item(record: $0.path, identity: $0.identity) },
                permanent: false, allowedRoots: rule.directories,
                finalValidation: { path in
                    guard let candidate = candidatesByPath[path] else { return false }
                    return AutoCleanupPlanner.revalidate(candidate, for: rule,
                                                        protecting: protectedDirectories)
                })
        }.value
        let failed = preparationFailures + summary.failed + summary.skipped
        let reclaimed = summary.removedPaths.reduce(UInt64(0)) {
            $0 &+ (candidatesByPath[$1]?.bytes ?? 0)
        }
        if autoCleanupPreviewRuleID == rule.id {
            autoCleanupPreview = nil
            autoCleanupPreviewRuleID = nil
        }
        if let index = autoCleanupRules.firstIndex(where: { $0.id == rule.id }) {
            autoCleanupRules[index].lastRunAt = Date()
            autoCleanupRules[index].lastReclaimedBytes = reclaimed
            autoCleanupRules[index].executionCount += 1
            autoCleanupRules[index].totalReclaimedBytes &+= reclaimed
            persistAutoCleanupRules()
        }
        CleanupCache.invalidate()
        return (summary.removed, failed, reclaimed, failed > 0 ? summary.messages : [])
    }

    private func persistAutoCleanupRules() {
        AutoCleanupRuleStore.save(autoCleanupRules)
    }

    private func protectedAutoCleanupDirectories(excluding id: UUID) -> [String] {
        Array(autoCleanupRules.lazy.filter { $0.id != id }.flatMap(\.directories))
    }

    /// 目录是否已被自动清理规则管理：规则目录为该目录自身或其祖先。
    /// 清理页与磁盘分析用它给已设置定时的条目打“已定时”标记。
    func autoCleanupRuleCovering(directory: String) -> AutoCleanupRule? {
        let path = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
        for rule in autoCleanupRules {
            for directory in rule.directories {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                    .standardizedFileURL.path
                if path == root || path.hasPrefix(root + "/") {
                    return rule
                }
            }
        }
        return nil
    }
}
