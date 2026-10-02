import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdateController
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(l10n.t("updates.title"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            surface
        }
    }

    @ViewBuilder private var surface: some View {
        if #available(macOS 26.0, *), !reduceTransparency, controlActiveState == .key {
            content
                .glassEffect(.regular.interactive(!reduceMotion),
                             in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .clipGlassEdge(in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            content.background(GlassSurface(cornerRadius: 13, usesSystemGlass: false))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(l10n.t("updates.autoCheck"), isOn: $updater.automaticallyChecksForUpdates)
                .padding(14)
            Divider().padding(.horizontal, 14)
            Toggle(l10n.t("updates.autoDownload"), isOn: $updater.automaticallyDownloadsUpdates)
                .disabled(!updater.automaticallyChecksForUpdates)
                .padding(14)
            Divider().padding(.horizontal, 14)
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
            .padding(14)
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
