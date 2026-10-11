import SwiftUI

struct AwakeSessionRow: View {
    @ObservedObject var state: AppState
    @ObservedObject private var awake: AwakeSessionController
    @ObservedObject private var l10n = L10n.shared

    init(state: AppState) {
        self.state = state
        _awake = ObservedObject(wrappedValue: state.awake)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: enabledBinding) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(Color.moleAccentText)
                    Text(l10n.t("awake.title"))
                    if let session = awake.session {
                        Text(l10n.t(session.mode == .systemOnly
                            ? "awake.mode.systemOnly" : "awake.mode.systemAndDisplay"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(MoleSwitchToggleStyle())
            .controlSize(.small)
            .tint(Color.moleAccentText)
            .font(.system(size: 12))
            Text(l10n.t("awake.hint"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let lastEnd = awake.lastEnd, endMessage(lastEnd.reason) != nil {
                HStack(spacing: 6) {
                    Text(endMessage(lastEnd.reason) ?? "")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button { awake.dismissLastEnd() } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(MoleIconButtonStyle(size: 20))
                }
            }
            if let error = awake.errorMessage, awake.session == nil {
                Text(error)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { awake.session != nil }, set: { enabled in
            if enabled {
                state.startAwakeSession()
            } else {
                state.endAwakeSession()
            }
        })
    }

    private func endMessage(_ reason: AwakeEndReason) -> String? {
        switch reason {
        case .battery(let percent): return l10n.tf("awake.notice.battery", percent)
        case .thermal: return l10n.t("awake.notice.thermal")
        case .manual, .quit: return nil
        }
    }
}
