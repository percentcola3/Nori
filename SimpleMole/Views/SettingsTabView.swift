import SwiftUI
import Carbon.HIToolbox
import os

// MARK: - 设置面板（通用 + 灵动岛 + 工具 + 功能页显隐）

/// 设置分区卡：小节标题浮在卡片上方，卡内各行之间用细分隔线呼吸。
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: title.isEmpty ? 0 : 9) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            )
        }
    }
}

/// 卡片内的设置行：统一左右留白与行高；`divider` 在行下补一条细分隔线。
private struct SettingsRow<Content: View>: View {
    var divider = false
    var vertical: CGFloat = 9
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, vertical)
            if divider {
                Rectangle()
                    .fill(Color.hairline)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var languageExpanded = false
    @StateObject private var loginItem = LoginItemController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pagesSection
                generalSection
                UpdateSettingsView(updater: .shared)
                islandSection
                maintenanceSection
                SettingsSection(title: l10n.t("permissions.title")) {
                    PermissionCenterView(state: state, embedded: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: 740, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .clipped()
        .contentShape(Rectangle())
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    // MARK: 通用（语言 + 启动 + 截图快捷键）

    private var generalSection: some View {
        SettingsSection(title: l10n.t("settings.general")) {
            SettingsRow(divider: true) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(l10n.t("header.language"))
                            .font(.system(size: 12))
                        Spacer()
                        languagePickerButton
                    }
                    if languageExpanded {
                        languageGrid
                    }
                }
            }

            SettingsRow(divider: true) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(l10n.t("settings.launchAtLogin"), isOn: Binding(
                        get: { loginItem.isRequested },
                        set: { enabled in Task { await loginItem.setEnabled(enabled) } }))
                        .toggleStyle(MoleSwitchToggleStyle())
                        .controlSize(.small)
                        .tint(Color.moleAccentText)
                        .font(.system(size: 12))
                        .disabled(loginItem.isUpdating)

                    Text(l10n.t("settings.background.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if loginItem.needsApproval {
                        Label(l10n.t("settings.launchAtLogin.approval"), systemImage: "exclamationmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.warning)
                        Button(l10n.t("settings.launchAtLogin.openSettings")) {
                            loginItem.openSystemSettings()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    if let error = loginItem.errorMessage {
                        Text(l10n.tf("settings.launchAtLogin.failed", error))
                            .font(.system(size: 10))
                            .foregroundStyle(Color.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            screenshotRow
        }
    }

    private var languagePickerButton: some View {
        Button {
            if reduceMotion { languageExpanded.toggle() }
            else { withAnimation(MoleMotion.panel) { languageExpanded.toggle() } }
        } label: {
            HStack {
                Text(L10n.shared.language.displayName)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(languageExpanded ? 180 : 0))
            }
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(Capsule().fill(.quinary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var languageGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    L10n.shared.setLanguage(language)
                    if reduceMotion { languageExpanded = false }
                    else { withAnimation(MoleMotion.panel) { languageExpanded = false } }
                } label: {
                    HStack(spacing: 6) {
                        Text(language.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Image(systemName: "checkmark")
                            .opacity(L10n.shared.language == language ? 1 : 0)
                    }
                    .font(.system(size: 10, weight: L10n.shared.language == language ? .semibold : .regular))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(L10n.shared.language == language
                              ? Color.moleAccent.opacity(0.15) : Color.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(L10n.shared.language == language
                                      ? Color.moleAccentText.opacity(0.30) : Color.hairline,
                                      lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .transition(.molePanelReveal)
    }

    // MARK: 灵动岛

    private var islandSection: some View {
        SettingsSection(title: l10n.t("settings.island")) {
            SettingsRow(divider: true) {
                Toggle(l10n.t("settings.menubaricon"), isOn: menuBarIconBinding)
                    .toggleStyle(MoleSwitchToggleStyle())
                    .controlSize(.small)
                    .tint(Color.moleAccentText)
                    .font(.system(size: 12))
            }

            SettingsRow(divider: true, vertical: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.t("settings.island.edge"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(AppState.IslandEdge.allCases) { edge in
                            edgeChip(edge)
                        }
                    }
                }
            }

            SettingsRow(divider: true, vertical: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.t("island.items"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 6)], spacing: 6) {
                        ForEach(AppState.IslandItem.allCases) { item in
                            islandItemChip(item)
                        }
                    }
                }
            }

            SettingsRow(vertical: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(l10n.t("settings.island.hint"))
                    Text(l10n.t("settings.background.keepEntry"))
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func islandItemChip(_ item: AppState.IslandItem) -> some View {
        let isSelected = state.islandItems.contains(item)
        let isLastRemaining = isSelected && state.islandItems.count == 1
        return Button {
            state.setIslandItem(item, enabled: !isSelected)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(l10n.t(item.labelKey))
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(isSelected ? 1 : 0)
            }
            .foregroundStyle(isSelected ? Color.moleAccentText : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.moleAccent.opacity(0.15) : Color.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.moleAccentText.opacity(0.30) : Color.hairline,
                              lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isLastRemaining ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isLastRemaining)
    }

    // MARK: 截图

    @ViewBuilder
    private var screenshotRow: some View {
        SettingsRow(divider: !state.screenshotHotKeyRegistrationFailed) {
            shortcutLine(title: l10n.t("shot.hotkey"),
                         isOn: $state.screenshotHotKeyEnabled,
                         combo: $state.screenshotHotKey,
                         defaultCombo: .default)
        }
        if state.screenshotHotKeyRegistrationFailed {
            SettingsRow(divider: true, vertical: 6) { hotKeyConflict }
        }
        SettingsRow(divider: state.ratioCaptureHotKeyRegistrationFailed) {
            shortcutLine(title: l10n.t("settings.ratiohotkey"),
                         isOn: $state.ratioCaptureHotKeyEnabled,
                         combo: $state.ratioCaptureHotKey,
                         defaultCombo: .ratioDefault)
        }
        if state.ratioCaptureHotKeyRegistrationFailed {
            SettingsRow(vertical: 6) { hotKeyConflict }
        }
    }

    /// 开关和对应快捷键在同一行。按比例截取的快捷键不再单独标成「截图快捷键」。
    private func shortcutLine(title: String,
                              isOn: Binding<Bool>,
                              combo: Binding<HotKeyCombo>,
                              defaultCombo: HotKeyCombo) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(MoleSwitchToggleStyle())
            .controlSize(.small)
            .tint(Color.moleAccentText)
            Spacer(minLength: 8)
            if isOn.wrappedValue {
                HotKeyRecorderRow(combo: combo, defaultCombo: defaultCombo)
            }
        }
    }

    private var hotKeyConflict: some View {
        Label(l10n.t("settings.screenshot.conflict"), systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5))
            .foregroundStyle(Color.warning)
    }

    // MARK: 目录清理与定时清理

    private var maintenanceSection: some View {
        SettingsSection(title: "") {
            SettingsRow(divider: true) {
                actionRow(title: l10n.t("auto.header"),
                          detail: l10n.t("auto.empty.subtitle"),
                          symbol: "calendar.badge.clock") {
                    state.showAutoCleanupSheet = true
                }
            }
            SettingsRow {
                actionRow(title: l10n.t("header.whitelist"),
                          detail: l10n.t("wl.subtitle"),
                          symbol: "shield.lefthalf.filled") {
                    state.showWhitelistSheet = true
                }
            }
        }
    }

    private func actionRow(title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.moleAccentText)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 功能页显隐

    private var pagesSection: some View {
        SettingsSection(title: l10n.t("settings.pages")) {
            SettingsRow(vertical: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                    ForEach(AppState.PageKey.configurableCases) { key in
                        pageChip(key)
                    }
                    clipboardChip
                }
            }
            SettingsRow(vertical: 6) {
                Text(l10n.t("settings.pages.hint"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 功能页标签：激活用品牌色淡染 + 描边 + 加粗表达，不加对号。
    private func chipLabel(_ title: String, isActive: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: isActive ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 27)
            .foregroundStyle(isActive ? Color.moleAccentText : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.moleAccent.opacity(0.15) : Color.surface2))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isActive ? Color.moleAccentText.opacity(0.30) : Color.hairline,
                                  lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func pageChip(_ key: AppState.PageKey) -> some View {
        let isSelected = !state.hiddenPages.contains(key.rawValue)
        let isLastRemaining = isSelected && AppState.PageKey.configurableCases.filter {
            !state.hiddenPages.contains($0.rawValue)
        }.count == 1
        return Button {
            state.setPageVisible(key, !isSelected)
        } label: {
            chipLabel(l10n.t(key.titleKey), isActive: isSelected)
        }
        .buttonStyle(MolePlainButtonStyle())
        .disabled(isLastRemaining)
        .opacity(isLastRemaining ? 0.55 : 1)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 剪贴板历史与其他功能页同样以标签激活；开关本身负责启停剪贴板监听。
    private var clipboardChip: some View {
        Button {
            if reduceMotion { state.clipboardHistoryEnabled.toggle() }
            else { withAnimation(MoleMotion.panel) { state.clipboardHistoryEnabled.toggle() } }
        } label: {
            chipLabel(l10n.t("clip.title"), isActive: state.clipboardHistoryEnabled)
        }
        .buttonStyle(MolePlainButtonStyle())
        .accessibilityAddTraits(state.clipboardHistoryEnabled ? .isSelected : [])
    }

    /// 浮动位置单选胶囊：与功能页/岛上内容标签同一套视觉。
    private func edgeChip(_ edge: AppState.IslandEdge) -> some View {
        let isSelected = state.islandEdge == edge
        return Button {
            state.setIslandEdge(edge)
        } label: {
            chipLabel(l10n.t(edge.labelKey), isActive: isSelected)
        }
        .buttonStyle(MolePlainButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var menuBarIconBinding: Binding<Bool> {
        Binding(get: { state.menuBarIconVisible },
                set: { state.setMenuBarIconVisible($0) })
    }
}

/// 快捷键录制行：点按钮进入监听，按下新组合立即生效；Esc 取消。
/// 仅 ⇧ 或无修饰键的组合会被拒绝（全局热键会在打字时误触发）。
private struct HotKeyRecorderRow: View {
    @Binding var combo: HotKeyCombo
    let defaultCombo: HotKeyCombo
    @State private var recording = false
    @State private var monitor: Any?
    @State private var needsModifierHint = false
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 6) {
            if needsModifierHint && recording {
                Text(l10n.t("settings.screenshot.hotkey.needModifier"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.warning)
                    .lineLimit(1)
            }
            if combo != defaultCombo {
                Button(l10n.t("settings.screenshot.hotkey.reset")) {
                    combo = defaultCombo
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(recording)
            }
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording
                     ? l10n.t("settings.screenshot.hotkey.recording")
                     : combo.displayLabel)
                    .frame(minWidth: 86)
            }
            .buttonStyle(SecondaryButtonStyle(
                tint: recording ? Color.moleAccentText : nil))
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        recording = true
        needsModifierHint = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            let recorded = HotKeyCombo(keyCode: UInt32(event.keyCode),
                                       modifierFlags: event.modifierFlags)
            guard recorded.hasStrongModifier else {
                needsModifierHint = true
                return nil
            }
            combo = recorded
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        needsModifierHint = false
    }
}
