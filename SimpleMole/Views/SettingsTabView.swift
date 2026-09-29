import SwiftUI

// MARK: - 设置面板（语言 + 灵动岛 + 工具 + 功能页显隐）

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
                languageSection
                startupSection
                screenshotSection
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

    // MARK: 启动与退出

    private var startupSection: some View {
        SettingsSection(title: l10n.t("settings.startup")) {
            SettingsRow {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(l10n.t("settings.launchAtLogin"), isOn: Binding(
                        get: { loginItem.isRequested },
                        set: { enabled in Task { await loginItem.setEnabled(enabled) } }))
                        .toggleStyle(.checkbox)
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
        }
    }

    // MARK: 语言

    private var languageSection: some View {
        SettingsSection(title: l10n.t("header.language")) {
            SettingsRow(divider: languageExpanded) {
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

            if languageExpanded {
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
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 5)
                .transition(.molePanelReveal)
            }
        }
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
                    Picker(l10n.t("settings.island.edge"), selection: islandEdgeBinding) {
                        ForEach(AppState.IslandEdge.allCases) { edge in
                            Text(l10n.t(edge.labelKey)).tag(edge)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
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
        .help(isLastRemaining ? l10n.t("settings.island.keepOne") : "")
    }

    // MARK: 截图

    private var screenshotSection: some View {
        SettingsSection(title: "") {
            SettingsRow(divider: state.screenshotHotKeyRegistrationFailed) {
                Toggle(l10n.t("shot.hotkey"), isOn: $state.screenshotHotKeyEnabled)
                    .toggleStyle(MoleSwitchToggleStyle())
                    .controlSize(.small)
                    .tint(Color.moleAccentText)
                    .font(.system(size: 12))
            }
            if state.screenshotHotKeyRegistrationFailed {
                SettingsRow(vertical: 6) {
                    Label(l10n.t("settings.screenshot.conflict"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.warning)
                }
            }
        }
    }

    // MARK: 目录清理与定时清理

    private var maintenanceSection: some View {
        SettingsSection(title: "") {
            SettingsRow(divider: true) {
                actionRow(title: l10n.t("auto.header"),
                          detail: l10n.t("auto.empty.subtitle"),
                          symbol: "folder.badge.clock") {
                    state.showAutoCleanupSheet = true
                }
            }
            SettingsRow(divider: true) {
                actionRow(title: l10n.t("automation.triggers"),
                          detail: l10n.t("automation.subtitle"),
                          symbol: "clock.badge.checkmark") {
                    state.openAutomationSettings()
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
            SettingsRow(divider: true) {
                Toggle(l10n.t("clip.title"), isOn: $state.clipboardHistoryEnabled)
                    .toggleStyle(MoleSwitchToggleStyle())
                    .controlSize(.small)
                    .tint(Color.moleAccentText)
                    .font(.system(size: 12))
            }
            if state.clipboardHistoryEnabled {
                SettingsRow(divider: true, vertical: 6) {
                    Stepper(value: clipboardCapacityBinding, in: 10...500, step: 10) {
                        HStack {
                            Text(l10n.t("settings.clipboard.capacity"))
                            Spacer()
                            Text("\(state.clipboardManager.capacity)")
                                .monospacedDigit()
                                .foregroundStyle(Color.moleAccentText)
                        }
                        .font(.system(size: 10.5))
                    }
                    .controlSize(.small)
                }
                SettingsRow(divider: true, vertical: 6) {
                    HStack {
                        Text(l10n.tf("settings.clipboard.count", state.clipboardManager.entries.count))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button(l10n.t("clip.clearUnpinned")) {
                            state.clipboardManager.clearUnpinned()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(state.clipboardManager.unpinnedCount == 0)
                    }
                }
            }
            SettingsRow(vertical: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(AppState.PageKey.configurableCases) { key in
                            pageChip(key)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
            SettingsRow(vertical: 6) {
                Text(l10n.t("settings.pages.hint"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pageChip(_ key: AppState.PageKey) -> some View {
        let isSelected = !state.hiddenPages.contains(key.rawValue)
        let isLastRemaining = isSelected && AppState.PageKey.configurableCases.filter {
            !state.hiddenPages.contains($0.rawValue)
        }.count == 1
        return Button {
            state.setPageVisible(key, !isSelected)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 8)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
                Text(l10n.t(key.titleKey))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .foregroundStyle(isSelected ? Color.onAccent : Color.secondary)
            .background(Capsule().fill(isSelected ? Color.accent : Color.surface2))
            .overlay(Capsule().strokeBorder(isSelected ? Color.accentText.opacity(0.3) : Color.hairline,
                                           lineWidth: 1).allowsHitTesting(false))
            .contentShape(Capsule())
        }
        .buttonStyle(MolePlainButtonStyle())
        .disabled(isLastRemaining)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(isLastRemaining ? l10n.t("settings.pages.hint") : l10n.t(key.titleKey))
    }

    private var islandEdgeBinding: Binding<AppState.IslandEdge> {
        Binding(get: { state.islandEdge },
                set: { state.setIslandEdge($0) })
    }

    private var menuBarIconBinding: Binding<Bool> {
        Binding(get: { state.menuBarIconVisible },
                set: { state.setMenuBarIconVisible($0) })
    }

    private var clipboardCapacityBinding: Binding<Int> {
        Binding(
            get: { state.clipboardManager.capacity },
            set: { state.clipboardManager.updateCapacity($0) })
    }
}
