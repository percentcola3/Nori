import SwiftUI

/// 可再生目录的自动清理规则管理。
struct AutoCleanupRulesView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions: PermissionCenter

    init(state: AppState) {
        self.state = state
        _permissions = ObservedObject(wrappedValue: state.permissionCenter)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusBar
            diskAccessBanner
            content
        }
        .frame(width: 680, height: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Color.moleAccentText)

            VStack(alignment: .leading, spacing: 5) {
                Text(l10n.t("auto.title"))
                    .font(.system(size: 15, weight: .semibold))
                Label {
                    Text(l10n.t("auto.safety"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(Color.moleAccentText)
                }
            }

            Spacer(minLength: 12)

            Button {
                state.addAutoCleanupRule()
            } label: {
                Label(l10n.t("auto.addDirectory"), systemImage: "folder.badge.plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .labelStyle(.iconOnly)
            .disabled(state.isBusy)

            Button {
                state.showAutoCleanupSheet = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.t("auto.close"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private var statusBar: some View {
        if !state.autoCleanupRules.isEmpty || state.isAutoCleanupScanning || !state.autoCleanupStatus.isEmpty {
            HStack(spacing: 7) {
                if !state.autoCleanupRules.isEmpty {
                    Text(l10n.tf("auto.groups.summary", state.autoCleanupRules.count,
                                 state.autoCleanupRules.reduce(0) { $0 + $1.directories.count }))
                        .font(.system(size: 10, weight: .medium))
                }
                if state.isAutoCleanupScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(state.autoCleanupStatus.isEmpty
                     ? l10n.t("auto.scanning")
                     : state.autoCleanupStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(.quinary)
        }
    }

    /// 后台定时静默跳过只留一行日志；面板里显式提示，避免“已开启却
    /// 从不执行”的无反馈状态。
    @ViewBuilder
    private var diskAccessBanner: some View {
        if !permissions.fullDiskAccessGranted, !state.autoCleanupRules.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.warning)
                Text(l10n.t("auto.fda.banner"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(l10n.t("auto.fda.open")) {
                    state.presentPermissionCenter()
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.warning.opacity(0.08))
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.autoCleanupRules.isEmpty {
            EmptyStateView(
                symbol: "calendar.badge.clock",
                title: l10n.t("auto.empty.title"),
                subtitle: l10n.t("auto.empty.subtitle")
            )
            .padding(24)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(state.autoCleanupRules) { rule in
                        AutoCleanupRuleRow(state: state, rule: rule)
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct AutoCleanupRuleRow: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    let rule: AutoCleanupRule

    private let gigabyte = 1_000_000_000.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            Divider()
                .padding(.vertical, 10)
            configuration
            if rule.directories.count > 1 {
                Text(l10n.t("auto.policy.task"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                DisclosureGroup(l10n.tf("auto.task.scope", rule.directories.count)) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(rule.directories, id: \.self) { path in
                            Text(path)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 10))
                .padding(.top, 10)
            }

            if let issue = state.autoCleanupRuleIssues[rule.id] {
                Divider()
                    .padding(.vertical, 10)
                Label {
                    Text(l10n.tf("auto.row.issue", issue))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.warning)
                }
            }

            if let plan = previewPlan {
                Divider()
                    .padding(.vertical, 10)
                AutoCleanupPreviewView(plan: plan)
            }
        }
        .padding(12)
        .modifier(ListRowSurface())
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(MoleSwitchToggleStyle())
                .controlSize(.mini)
                .fixedSize()
                .tint(Color.moleAccentText)
                .accessibilityLabel(l10n.t("auto.enabled"))
                .disabled(state.isBusy || !currentRule.isSafetyAuthorized)

            Image(systemName: "folder.fill")
                .foregroundStyle(Color.moleAccentText)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.sourceName ?? URL(fileURLWithPath: rule.directory).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(rule.directories.count > 1
                     ? l10n.tf("auto.entry.paths", rule.directories.count) : rule.directory)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(lastRunText)
                Text(l10n.tf("auto.lastReclaimed", ByteFormat.format(rule.lastReclaimedBytes)))
                if currentRule.executionCount > 0 {
                    // 累计统计：让用户看到这条规则长期以来的实际产出。
                    Text(l10n.tf("auto.stats", currentRule.executionCount,
                                 ByteFormat.format(currentRule.totalReclaimedBytes)))
                        .foregroundStyle(Color.moleAccentText.opacity(0.85))
                }
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.tertiary)

            Button {
                state.removeAutoCleanupRule(rule.id)
            } label: {
                Label(l10n.t("auto.delete"), systemImage: "trash")
            }
            .buttonStyle(DangerButtonStyle())
            .disabled(state.isBusy)
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(l10n.t("auto.policy.label"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker(l10n.t("auto.policy.label"), selection: policyBinding) {
                    Text(l10n.t("auto.policy.sizeLimit"))
                        .tag(AutoCleanupPolicy.sizeLimit)
                    Text(l10n.t("auto.policy.retentionDays"))
                        .tag(AutoCleanupPolicy.retentionDays)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
                .disabled(state.isBusy)

                policyValueEditor
                    .fixedSize()

                Spacer(minLength: 6)

                Button {
                    state.previewAutoCleanup(rule.id)
                } label: {
                    Label(previewButtonTitle, systemImage: "magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(state.isBusy || !currentRule.isSafetyAuthorized)

                Button {
                    state.runAutoCleanupNow(rule.id)
                } label: {
                    Label(l10n.t("auto.cleanNow"), systemImage: "trash")
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(state.isBusy || !currentRule.isSafetyAuthorized)
            }

            Toggle(isOn: regenerableBinding) {
                Label {
                    Text(l10n.t(rule.directories.count > 1
                                ? "auto.task.confirm" : "auto.regenerable.confirm"))
                        .font(.system(size: 10,
                                      weight: currentRule.isSafetyAuthorized ? .medium : .semibold))
                        .foregroundStyle(currentRule.isSafetyAuthorized
                                         ? Color.secondary : Color.warning)
                } icon: {
                    Image(systemName: currentRule.isSafetyAuthorized
                          ? "checkmark.shield" : "shield.lefthalf.filled")
                        .foregroundStyle(currentRule.isSafetyAuthorized
                                         ? Color.moleAccentText : Color.warning)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(state.isBusy)
            .help(l10n.t("auto.regenerable.help"))
        }
    }

    @ViewBuilder
    private var policyValueEditor: some View {
        if rule.policy == .sizeLimit {
            HStack(spacing: 4) {
                TextField(
                    l10n.t("auto.sizeLimit.input"),
                    value: sizeLimitGBBinding,
                    format: .number.precision(.fractionLength(1))
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 68)

                Text(l10n.t("auto.unit.gb"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Stepper(
                    l10n.t("auto.sizeLimit.input"),
                    value: sizeLimitGBBinding,
                    in: 0.1...1024,
                    step: 0.1
                )
                .labelsHidden()
                .fixedSize()
            }
            .disabled(state.isBusy)
        } else {
            HStack(spacing: 4) {
                TextField(
                    l10n.t("auto.retention.input"),
                    value: retentionDaysBinding,
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 54)

                Text(l10n.t("auto.unit.days"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Stepper(
                    l10n.t("auto.retention.input"),
                    value: retentionDaysBinding,
                    in: 1...365
                )
                .labelsHidden()
                .fixedSize()
            }
            .disabled(state.isBusy)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { currentRule.isEnabled },
            set: { value in updateRule { $0.isEnabled = value } }
        )
    }

    private var regenerableBinding: Binding<Bool> {
        Binding(
            get: { currentRule.isRegenerable },
            set: { value in
                updateRule {
                    $0.isRegenerable = value
                    if !value { $0.isEnabled = false }
                }
            }
        )
    }

    private var policyBinding: Binding<AutoCleanupPolicy> {
        Binding(
            get: { currentRule.policy },
            set: { value in updateRule { $0.policy = value } }
        )
    }

    private var sizeLimitGBBinding: Binding<Double> {
        Binding(
            get: { Double(currentRule.sizeLimitBytes) / gigabyte },
            set: { value in
                let clamped = min(max(value, 0.1), 1024)
                updateRule { $0.sizeLimitBytes = UInt64((clamped * gigabyte).rounded()) }
            }
        )
    }

    private var retentionDaysBinding: Binding<Int> {
        Binding(
            get: { currentRule.retentionDays },
            set: { value in
                updateRule { $0.retentionDays = min(max(value, 1), 365) }
            }
        )
    }

    private var currentRule: AutoCleanupRule {
        state.autoCleanupRules.first(where: { $0.id == rule.id }) ?? rule
    }

    private var previewPlan: AutoCleanupPlan? {
        guard state.autoCleanupPreviewRuleID == rule.id else { return nil }
        return state.autoCleanupPreview
    }

    private var previewButtonTitle: String {
        if state.isAutoCleanupScanning && state.autoCleanupPreviewRuleID == rule.id {
            return l10n.t("auto.scanning")
        }
        return l10n.t("auto.preview")
    }

    private var lastRunText: String {
        guard let lastRunAt = rule.lastRunAt else {
            return l10n.t("auto.lastRun.never")
        }
        return l10n.tf(
            "auto.lastRun",
            lastRunAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

    private func updateRule(_ update: (inout AutoCleanupRule) -> Void) {
        guard !state.isBusy else { return }
        guard var latest = state.autoCleanupRules.first(where: { $0.id == rule.id }) else { return }
        update(&latest)
        state.updateAutoCleanupRule(latest)
    }
}

private struct AutoCleanupPreviewView: View {
    let plan: AutoCleanupPlan
    @ObservedObject private var l10n = L10n.shared

    private var visibleCandidates: ArraySlice<AutoCleanupCandidate> {
        plan.candidates.prefix(20)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.t("auto.preview.title"))
                .font(.system(size: 11, weight: .semibold))

            HStack(spacing: 6) {
                AutoCleanupPreviewMetric(
                    title: l10n.t("auto.preview.candidates"),
                    value: "\(plan.candidates.count)"
                )
                AutoCleanupPreviewMetric(
                    title: l10n.t("auto.preview.total"),
                    value: ByteFormat.format(plan.totalBytes)
                )
                AutoCleanupPreviewMetric(
                    title: l10n.t("auto.preview.reclaimable"),
                    value: ByteFormat.format(plan.reclaimableBytes),
                    prominent: true
                )
                AutoCleanupPreviewMetric(
                    title: l10n.t("auto.preview.remaining"),
                    value: ByteFormat.format(plan.remainingBytes)
                )
            }

            if visibleCandidates.isEmpty {
                Text(l10n.t("auto.preview.empty"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(visibleCandidates) { candidate in
                        VStack(spacing: 0) {
                            if candidate.id != visibleCandidates.first?.id {
                                Divider()
                            }
                            AutoCleanupCandidateRow(candidate: candidate)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))

                if plan.candidates.count > visibleCandidates.count {
                    Text(l10n.tf(
                        "auto.preview.more",
                        plan.candidates.count - visibleCandidates.count
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

private struct AutoCleanupPreviewMetric: View {
    let title: String
    let value: String
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(prominent ? Color.moleAccentText : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
    }
}

private struct AutoCleanupCandidateRow: View {
    let candidate: AutoCleanupCandidate

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: candidate.path).lastPathComponent)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Text(candidate.path)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(ByteFormat.format(candidate.bytes))
                Text(candidate.modifiedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}
