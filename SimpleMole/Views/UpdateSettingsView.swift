import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdateController
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        SettingsSection(title: l10n.t("updates.title")) {
            SettingsRow(divider: true) {
                Toggle(l10n.t("updates.automatic"), isOn: $updater.automaticallyUpdates)
                    .help(l10n.t("updates.automatic.hint"))
            }
            SettingsRow {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.tf("updates.current", version))
                        if updater.status != .idle {
                            Text(statusText)
                                .font(.system(size: 10))
                                .foregroundStyle(isFailure ? Color.warning : Color.secondary)
                                .lineLimit(2)
                                .help(errorDetail)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(l10n.t("updates.check")) { updater.checkForUpdates() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .toggleStyle(MoleSwitchToggleStyle())
        .controlSize(.small)
        .tint(Color.moleAccentText)
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var statusText: String {
        switch updater.status {
        case .idle: return ""
        case .checking: return l10n.t("updates.checking")
        case .updateAvailable(let version): return l10n.tf("updates.available", version)
        case .upToDate: return l10n.t("updates.latest")
        case .deferred: return l10n.t("updates.busy")
        case .failed: return l10n.t("updates.failed")
        }
    }

    private var isFailure: Bool {
        if case .failed = updater.status { return true }
        return false
    }

    private var errorDetail: String {
        if case .failed(let detail) = updater.status { return detail }
        return statusText
    }
}
