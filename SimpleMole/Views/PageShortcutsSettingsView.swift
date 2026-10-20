import SwiftUI
import Carbon.HIToolbox

struct PageShortcutsSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @State private var recordingPage: AppState.PageKey?
    @State private var monitor: Any?
    @State private var recordingID = UUID()
    @State private var errorPage: AppState.PageKey?
    @State private var errorMessage: String?

    var body: some View {
        SettingsSection(title: l10n.t("settings.pageShortcuts.title")) {
            SettingsRow(divider: true) {
                HStack(spacing: 12) {
                    Text(l10n.t("settings.pageShortcuts.hint"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(l10n.t("settings.pageShortcuts.resetAll")) {
                        stopRecording()
                        state.resetPageShortcuts()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(state.pageShortcutPreferences.overrides.isEmpty || recordingPage != nil)
                }
            }
            ForEach(AppState.PageKey.allCases) { page in
                SettingsRow(divider: page != .settings) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(l10n.t(page.titleKey))
                                .font(.system(size: 12))
                            Spacer(minLength: 8)
                            Button {
                                if recordingPage == page { stopRecording() }
                                else { startRecording(page) }
                            } label: {
                                Text(recordingPage == page
                                     ? l10n.t("settings.screenshot.hotkey.recording")
                                     : state.pageShortcut(for: page)?.displayLabel
                                         ?? l10n.t("settings.pageShortcuts.unset"))
                                    .frame(minWidth: 106)
                            }
                            .buttonStyle(SecondaryButtonStyle(
                                tint: recordingPage == page ? Color.moleAccentText : nil))
                            .accessibilityLabel(l10n.tf("settings.pageShortcuts.record", l10n.t(page.titleKey)))
                            .accessibilityValue(state.pageShortcut(for: page)?.displayLabel
                                                ?? l10n.t("settings.pageShortcuts.unset"))
                            .accessibilityIdentifier("page-shortcut-record-" + page.rawValue)

                            Button {
                                stopRecording()
                                state.setPageShortcut(nil, for: page)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .help(l10n.tf("settings.pageShortcuts.clear", l10n.t(page.titleKey)))
                            .accessibilityLabel(l10n.tf("settings.pageShortcuts.clear", l10n.t(page.titleKey)))
                            .disabled(state.pageShortcut(for: page) == nil || recordingPage != nil)
                        }
                        if errorPage == page, let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if state.pageShortcutRegistrationFailures.contains(page) {
                            Label(l10n.t("settings.pageShortcuts.globalConflict"),
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: .smShortcutRecordingChanged)) { notification in
            if notification.object as? UUID != recordingID { stopRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
        }
    }

    private func startRecording(_ page: AppState.PageKey) {
        stopRecording()
        recordingPage = page
        // 录制期间暂停全局截图热键，避免候选按键先触发截图。
        state.beginRecordingShortcut(owner: recordingID)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode != UInt16(kVK_Escape) else {
                stopRecording()
                return nil
            }
            guard let shortcut = PageKeyboardShortcut(event: event) else {
                showError(l10n.t("settings.pageShortcuts.invalid"), for: page)
                return nil
            }
            let combo = HotKeyCombo(keyCode: UInt32(event.keyCode), modifierFlags: event.modifierFlags)
            if state.screenshotHotKeyEnabled && state.screenshotHotKey == combo {
                showError(l10n.tf("settings.pageShortcuts.conflict", l10n.t("shot.hotkey")), for: page)
            } else if state.ratioCaptureHotKeyEnabled && state.ratioCaptureHotKey == combo {
                showError(l10n.tf("settings.pageShortcuts.conflict", l10n.t("settings.ratiohotkey")), for: page)
            } else if let error = state.setPageShortcut(shortcut, for: page) {
                showError(error, for: page)
            } else {
                stopRecording()
            }
            return nil
        }
    }

    private func showError(_ message: String, for page: AppState.PageKey) {
        errorPage = page
        errorMessage = message
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        let wasRecording = recordingPage != nil
        monitor = nil
        recordingPage = nil
        errorPage = nil
        errorMessage = nil
        if wasRecording {
            state.endRecordingShortcut(owner: recordingID)
        }
    }
}
