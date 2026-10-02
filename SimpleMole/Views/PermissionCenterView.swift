import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 一项权限当前所处的阶段。视图只根据阶段渲染一条引导，避免多条提示叠在一起。
private enum PermissionPhase: Equatable {
    /// 本进程已能使用。
    case granted
    /// 系统已授予，本进程仍按旧结果缓存：重启即可。
    case needsRelaunch
    /// 系统不会再弹窗；若设置里开关是开的，记录属于旧签名。
    case stale
    /// 尚未授权。
    case missing
}

struct PermissionCenterView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var permissions: PermissionCenter
    @ObservedObject private var l10n = L10n.shared

    /// 设置页内直接展示时不带弹层标题、底栏和固定尺寸。
    var embedded = false

    init(state: AppState, embedded: Bool = false) {
        self.state = state
        self.embedded = embedded
        _permissions = ObservedObject(wrappedValue: state.permissionCenter)
    }

    var body: some View {
        Group {
            if embedded {
                permissionCards
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        permissionCards
                            .padding(18)
                    }
                    Divider()
                    footer
                }
                .frame(width: 580, height: 500)
            }
        }
        .animation(MoleMotion.control, value: diskPhase)
        .animation(MoleMotion.control, value: screenPhase)
        .task { await pollWhileVisible() }
        .onDisappear { permissions.clearRepairMessage() }
    }

    private var permissionCards: some View {
        VStack(spacing: 12) {
            if permissions.signingWarningNeeded {
                signingBanner
            }
            if let repairKey = permissions.repairMessageKey {
                notice(l10n.t(repairKey),
                       icon: repairKey.hasSuffix("failed")
                           ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                       tint: repairKey.hasSuffix("failed") ? .warning : .success)
            } else if let errorKey = permissions.diskAuthorizationErrorKey,
                      diskPhase == .missing {
                notice(l10n.t(errorKey), icon: "exclamationmark.triangle.fill", tint: .warning)
            }

            diskAccessCard
            screenRecordingCard

            Label(l10n.t("permissions.noAccessibility"), systemImage: "checkmark.shield")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - 阶段

    private var diskPhase: PermissionPhase {
        if permissions.fullDiskAccessGranted { return .granted }
        if permissions.fullDiskNeedsRelaunch { return .needsRelaunch }
        return .missing
    }

    private var screenPhase: PermissionPhase {
        if permissions.screenRecordingGranted { return .granted }
        if permissions.screenRecordingNeedsRelaunch { return .needsRelaunch }
        if permissions.screenRecordingDecisionStale { return .stale }
        return .missing
    }

    /// 权限中心可见期间每 3 秒复检一次：用户在系统设置里打开开关后回来，
    /// 不必再手动点"重新检测"；两项权限都用子进程绕开进程内缓存。
    private func pollWhileVisible() async {
        while !Task.isCancelled {
            if !permissions.fullDiskAccessGranted || !permissions.screenRecordingGranted {
                state.refreshAuthorizationAndResume()
                permissions.scheduleLiveCheck(force: true)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    // MARK: - 头尾

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentText)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.t("permissions.title"))
                    .font(.system(size: 17, weight: .semibold))
                Text(l10n.t("permissions.subtitle"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { state.cancelPermissionCenter() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(Color.surface2))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        let hasPendingAction = state.hasPendingPermissionAction
        let isWaitingForDiskAccess = hasPendingAction
            && !permissions.fullDiskAccessGranted

        return HStack(spacing: 10) {
            Text(l10n.t(hasPendingAction
                        ? "permissions.footer.pendingScan"
                        : "permissions.footer"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(l10n.t("common.cancel")) { state.cancelPermissionCenter() }
                .buttonStyle(SecondaryButtonStyle())
            Button(l10n.t(hasPendingAction
                          ? "permissions.continue"
                          : "common.done")) {
                state.completePermissionSetup()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isWaitingForDiskAccess)
            .opacity(isWaitingForDiskAccess ? 0.50 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .animation(MoleMotion.control, value: isWaitingForDiskAccess)
    }

    // MARK: - 提示条

    private var signingBanner: some View {
        let key = permissions.signing.kind == .adhoc
            ? "permissions.signing.adhoc" : "permissions.signing.unknown"
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.warning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.t(key))
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(l10n.t("permissions.signing.fix"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.warning.opacity(0.10)))
    }

    private func notice(_ text: String, icon: String, tint: Color) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.opacity(0.10)))
    }

    // MARK: - 完全磁盘访问

    private var diskAccessCard: some View {
        let phase = diskPhase
        return PermissionCard(
            icon: "externaldrive.badge.checkmark",
            title: l10n.t("permissions.fullDisk.title"),
            detail: l10n.t("permissions.fullDisk.detail"),
            chip: chip(for: phase, optional: false),
            primary: phase == .granted
                ? CardAction(title: l10n.t("permissions.openSettings"), icon: "gearshape",
                             prominent: false) { permissions.openSystemSettings(.fullDisk) }
                : CardAction(title: l10n.t("permissions.openFullDiskSettings"), icon: "gearshape",
                             prominent: phase == .missing) { permissions.openSystemSettings(.fullDisk) },
            guidance: diskGuidance(phase),
            dragProvider: permissions.fullDiskAccessGranted ? nil : applicationDragProvider,
            dragHint: permissions.fullDiskAccessGranted ? nil : l10n.t("permissions.drag.hint.disk"))
    }

    private func diskGuidance(_ phase: PermissionPhase) -> CardGuidance? {
        switch phase {
        case .granted:
            return nil
        case .needsRelaunch:
            return CardGuidance(
                tone: .success, icon: "checkmark.circle.fill",
                text: l10n.t("permissions.disk.needsRelaunch"),
                action: CardAction(title: l10n.t("permissions.screen.relaunchNow"),
                                   icon: "arrow.triangle.2.circlepath", prominent: true) {
                    state.relaunchApplication()
                })
        case .stale, .missing:
            return CardGuidance(
                tone: .neutral, icon: "hand.draw.fill",
                text: l10n.t("permissions.guide.disk"),
                action: CardAction(title: l10n.t("permissions.recheck"),
                                   icon: "arrow.clockwise", prominent: false) {
                    state.recheckFullDiskAccess()
                    permissions.scheduleLiveCheck(force: true)
                },
                link: CardAction(title: l10n.t("permissions.disk.resetLink"),
                                 icon: "arrow.counterclockwise", prominent: false,
                                 disabled: permissions.repairInFlight) {
                    state.repairFullDiskAuthorization()
                })
        }
    }

    // MARK: - 屏幕录制

    private var screenRecordingCard: some View {
        let phase = screenPhase
        return PermissionCard(
            icon: "rectangle.inset.filled.and.person.filled",
            title: l10n.t("permissions.screen.title"),
            detail: l10n.t("permissions.screen.detail"),
            chip: chip(for: phase, optional: true),
            primary: phase == .granted
                ? CardAction(title: l10n.t("permissions.openSettings"), icon: "gearshape",
                             prominent: false) { permissions.openSystemSettings(.screenRecording) }
                : CardAction(title: l10n.t("permissions.screen.action"), icon: "record.circle",
                             prominent: false) { state.requestScreenRecordingAccess() },
            guidance: screenGuidance(phase),
            dragProvider: permissions.screenRecordingGranted ? nil : applicationDragProvider,
            dragHint: permissions.screenRecordingGranted ? nil : l10n.t("permissions.drag.hint.screen"))
    }

    private func screenGuidance(_ phase: PermissionPhase) -> CardGuidance? {
        switch phase {
        case .granted:
            return nil
        case .needsRelaunch:
            return CardGuidance(
                tone: .success, icon: "checkmark.circle.fill",
                text: l10n.t("permissions.screen.needsRelaunch"),
                action: CardAction(title: l10n.t("permissions.screen.relaunchNow"),
                                   icon: "arrow.triangle.2.circlepath", prominent: true) {
                    state.relaunchApplication()
                })
        case .stale:
            return CardGuidance(
                tone: .warning, icon: "arrow.counterclockwise.circle.fill",
                text: l10n.t("permissions.screen.stale"),
                action: CardAction(title: l10n.t("permissions.screen.repair"),
                                   icon: "arrow.counterclockwise", prominent: false,
                                   disabled: permissions.repairInFlight) {
                    state.repairScreenRecordingAuthorization()
                })
        case .missing:
            return CardGuidance(
                tone: .neutral, icon: "hand.draw.fill",
                text: l10n.t("permissions.guide.screen"),
                action: CardAction(title: l10n.t("permissions.openSettings"),
                                   icon: "gearshape", prominent: false) {
                    permissions.openSystemSettings(.screenRecording)
                },
                link: CardAction(title: l10n.t("permissions.screen.restartLink"),
                                 icon: "arrow.triangle.2.circlepath", prominent: false) {
                    state.relaunchApplication()
                })
        }
    }

    // MARK: - 状态胶囊

    private func chip(for phase: PermissionPhase, optional: Bool) -> CardChip {
        switch phase {
        case .granted:
            return CardChip(text: l10n.t("permissions.status.granted"), tint: .success)
        case .needsRelaunch:
            return CardChip(text: l10n.t("permissions.status.pendingRelaunch"), tint: .success)
        case .stale:
            return CardChip(text: l10n.t("permissions.status.stale"), tint: .warning)
        case .missing:
            if permissions.liveCheckInFlight {
                return CardChip(text: l10n.t("permissions.status.checking"), tint: .secondary,
                                showsProgress: true)
            }
            return optional
                ? CardChip(text: l10n.t("permissions.status.optional"), tint: .secondary)
                : CardChip(text: l10n.t("permissions.status.required"), tint: .warning)
        }
    }

    private func applicationDragProvider() -> NSItemProvider {
        // Export only the original file URL. NSURL's file representations can
        // materialize a temporary .app copy under com.apple.SwiftUI.Drag-*;
        // privacy settings must authorize the bundle that is actually running.
        let provider = NSItemProvider()
        let data = Data(Bundle.main.bundleURL.absoluteString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier,
                                            visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        provider.suggestedName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return provider
    }
}

// MARK: - 卡片构件

private struct CardAction {
    let title: String
    let icon: String
    let prominent: Bool
    var disabled = false
    let perform: () -> Void

    init(title: String, icon: String, prominent: Bool, disabled: Bool = false,
         perform: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.prominent = prominent
        self.disabled = disabled
        self.perform = perform
    }
}

private struct CardChip {
    let text: String
    let tint: Color
    var showsProgress = false
}

private struct CardGuidance {
    enum Tone { case neutral, success, warning }

    let tone: Tone
    let icon: String
    let text: String
    var action: CardAction?
    /// 次级出路：小号文字按钮，不与主动作抢视线。
    var link: CardAction?

    var tint: Color {
        switch tone {
        case .neutral: .accentText
        case .success: .success
        case .warning: .warning
        }
    }
}

/// 单张权限卡：标题行（图标 / 标题 / 状态胶囊 / 主按钮）、说明，以及最多一条
/// 由阶段决定的引导。整张卡在未授权时可以拖进系统设置的列表。
private struct PermissionCard: View {
    let icon: String
    let title: String
    let detail: String
    let chip: CardChip
    let primary: CardAction
    let guidance: CardGuidance?
    var dragProvider: (() -> NSItemProvider)? = nil
    /// 拖拽目标提示：授权哪个权限，卡片就指向哪个系统设置列表。
    var dragHint: String? = nil

    var body: some View {
        content
            .modifier(ConditionalDragModifier(provider: dragProvider,
                                               help: dragProvider == nil ? nil : dragHint))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentText)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                        chipView
                    }
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                actionButton(primary)
            }
            if let guidance {
                guidanceStrip(guidance)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.surface1))
    }

    private var chipView: some View {
        HStack(spacing: 4) {
            if chip.showsProgress {
                ProgressView().controlSize(.mini)
            }
            Text(chip.text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(chip.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(chip.tint.opacity(0.12)))
    }

    @ViewBuilder
    private func actionButton(_ action: CardAction) -> some View {
        if action.prominent {
            Button(action: action.perform) {
                Label(action.title, systemImage: action.icon)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(action.disabled)
            .opacity(action.disabled ? 0.5 : 1)
        } else {
            Button(action: action.perform) {
                Label(action.title, systemImage: action.icon)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(action.disabled)
            .opacity(action.disabled ? 0.5 : 1)
        }
    }

    private func guidanceStrip(_ guidance: CardGuidance) -> some View {
        let isDrop = guidance.tone == .neutral && dragProvider != nil
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: guidance.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(guidance.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(guidance.text)
                    .font(.system(size: 11))
                    .foregroundStyle(guidance.tone == .neutral ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link = guidance.link {
                    Button(action: link.perform) {
                        Label(link.title, systemImage: link.icon)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentText)
                    .disabled(link.disabled)
                    .opacity(link.disabled ? 0.5 : 1)
                }
            }
            Spacer(minLength: 8)
            if let action = guidance.action {
                actionButton(action)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(guidance.tone == .neutral ? Color.surface2 : guidance.tint.opacity(0.10)))
        .overlay {
            if isDrop {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accent.opacity(0.45),
                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
    }
}

private struct ConditionalDragModifier: ViewModifier {
    let provider: (() -> NSItemProvider)?
    let help: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let provider {
            content
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onDrag(provider)
        } else {
            content
        }
    }
}
