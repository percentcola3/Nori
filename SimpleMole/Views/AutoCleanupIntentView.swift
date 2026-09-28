import SwiftUI

/// 自动清理入口的意图：一组目标目录 + 是否已由清理策略验证可再生。
/// 清理页的缓存项 cacheVerified 为 true（创建规则时直接记录安全授权）；
/// 磁盘分析的任意目录为 false（用户需要在规则面板自行确认）。
struct AutoCleanupIntent: Identifiable {
    let paths: [String]
    let cacheVerified: Bool

    var id: String { (cacheVerified ? "1" : "0") + "|" + paths.joined(separator: "\n") }
}

/// 从清理页（可再生缓存）或磁盘分析（目录）发起的规则创建面板：选择
/// 策略（容量上限 / 保留天数）后批量创建规则。规则默认关闭，创建完成
/// 后打开规则面板供审阅与启用。
struct AutoCleanupIntentSheet: View {
    @ObservedObject var state: AppState
    let intent: AutoCleanupIntent
    let onDone: () -> Void
    @ObservedObject private var l10n = L10n.shared
    @State private var policy: AutoCleanupPolicy = .sizeLimit
    @State private var sizeLimitGB: Double = 5
    @State private var retentionDays = 30
    private let gigabyte = 1_000_000_000.0
    private let displayedPaths = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.tf("auto.entry.paths", intent.paths.count))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(intent.paths.prefix(displayedPaths), id: \.self) { path in
                    Text(path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if intent.paths.count > displayedPaths {
                    Text(l10n.tf("cleanup.morePaths", intent.paths.count - displayedPaths))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text(l10n.t("auto.policy.label"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker(l10n.t("auto.policy.label"), selection: $policy) {
                    Text(l10n.t("auto.policy.sizeLimit"))
                        .tag(AutoCleanupPolicy.sizeLimit)
                    Text(l10n.t("auto.policy.retentionDays"))
                        .tag(AutoCleanupPolicy.retentionDays)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
                policyValueEditor
                Spacer(minLength: 4)
            }

            Label {
                Text(l10n.t(intent.cacheVerified
                            ? "auto.entry.note.verified" : "auto.entry.note.manual"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(Color.moleAccentText)
            }

            HStack {
                Spacer()
                Button { onDone() } label: {
                    Text(l10n.t("common.cancel"))
                }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button { create() } label: {
                    Label(l10n.t("auto.entry.confirm"), systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(intent.paths.isEmpty || state.isBusy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(Color.surface2)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(Color.moleAccentText)
            Text(l10n.t("auto.entry.title"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { onDone() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(l10n.t("auto.close"))
        }
    }

    @ViewBuilder
    private var policyValueEditor: some View {
        if policy == .sizeLimit {
            HStack(spacing: 4) {
                TextField(l10n.t("auto.sizeLimit.input"), value: $sizeLimitGB,
                          format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Text(l10n.t("auto.unit.gb"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Stepper(l10n.t("auto.sizeLimit.input"), value: $sizeLimitGB,
                        in: 0.1...1024, step: 0.1)
                    .labelsHidden()
                    .fixedSize()
            }
            .help(l10n.t("auto.sizeLimit.help"))
        } else {
            HStack(spacing: 4) {
                TextField(l10n.t("auto.retention.input"), value: $retentionDays,
                          format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 54)
                Text(l10n.t("auto.unit.days"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Stepper(l10n.t("auto.retention.input"), value: $retentionDays,
                        in: 1...365, step: 1)
                    .labelsHidden()
                    .fixedSize()
            }
            .help(l10n.t("auto.retention.help"))
        }
    }

    private func create() {
        let result = state.addAutoCleanupRules(
            forDirectories: intent.paths,
            policy: policy,
            sizeLimitBytes: UInt64((min(max(sizeLimitGB, 0.1), 1024) * gigabyte).rounded()),
            retentionDays: min(max(retentionDays, 1), 365),
            cacheVerifiedRegenerable: intent.cacheVerified)
        let status = l10n.tf("auto.entry.status", result.added, result.skipped)
        state.autoCleanupStatus = status
        state.log(status)
        onDone()
        state.showAutoCleanupSheet = true
    }
}
