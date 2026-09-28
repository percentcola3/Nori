import SwiftUI

struct AutomationSettingsView: View {
    @ObservedObject var automations: AutomationStore
    let canMutate: Bool
    let onClose: () -> Void
    @ObservedObject private var l10n = L10n.shared

    @State private var showsRuleEditor = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    safetyNotice
                    triggersSection
                }
                .padding(16)
            }
        }
        .frame(minWidth: 680, idealWidth: 740, minHeight: 560, idealHeight: 640)
        .sheet(isPresented: $showsRuleEditor) {
            SmartTriggerEditor(canMutate: canMutate) { rule in
                guard canMutate else { return }
                _ = automations.add(rule)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Color.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.t("automation.header"))
                    .font(.system(size: 16, weight: .semibold))
                Text(l10n.t("automation.subtitle"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(l10n.t("common.close")) { onClose() }
                .buttonStyle(.bordered)
        }
        .padding(16)
    }

    private var safetyNotice: some View {
        Label {
            Text(l10n.t("automation.safety"))
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(Color.success)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.success.opacity(0.08)))
    }

    private var triggersSection: some View {
        section(title: l10n.t("automation.triggers"),
                actionTitle: l10n.t("automation.addTrigger"),
                actionSymbol: "plus.circle",
                actionDisabled: !canMutate,
                action: {
                    guard canMutate else { return }
                    showsRuleEditor = true
                }) {
            if let error = automations.lastError, !error.isEmpty {
                persistenceError(error)
            }
            if automations.triggers.isEmpty {
                emptyRow(l10n.t("automation.empty"))
            } else {
                ForEach(automations.triggers) { rule in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: {
                                guard canMutate else { return }
                                _ = automations.setEnabled($0, id: rule.id)
                            }))
                            .labelsHidden()
                            .toggleStyle(MoleSwitchToggleStyle())
                            .controlSize(.mini)
                            .disabled(!canMutate || !rule.isValid)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name.isEmpty ? actionTitle(rule.action) : rule.name)
                                .font(.system(size: 11, weight: .medium))
                            Text(triggerSummary(rule))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(rule.isValid
                                                 ? Color.secondary : Color.danger)
                        }
                        Spacer()
                        if !rule.isValid {
                            Text(l10n.t("automation.invalidDisabled"))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color.danger)
                        }
                        Button(role: .destructive) {
                            guard canMutate else { return }
                            _ = automations.remove(id: rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canMutate)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func section<Content: View>(title: String,
                                        actionTitle: String? = nil,
                                        actionSymbol: String? = nil,
                                        actionDisabled: Bool = false,
                                        action: (() -> Void)? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let actionTitle, let actionSymbol, let action {
                    Button(action: action) {
                        Label(actionTitle, systemImage: actionSymbol)
                    }
                    .controlSize(.small)
                    .disabled(actionDisabled)
                }
            }
            VStack(alignment: .leading, spacing: 5) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator.opacity(0.45), lineWidth: 1))
        }
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func persistenceError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 9))
            .foregroundStyle(Color.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func triggerSummary(_ rule: SmartTriggerRule) -> String {
        let target = l10n.t("automation.scope.allSafe")
        switch rule.condition.kind {
        case .dailySchedule:
            return l10n.tf("automation.summary.daily",
                           rule.condition.hour ?? 0, rule.condition.minute ?? 0,
                           actionTitle(rule.action), target)
        case .weeklySchedule:
            return l10n.tf("automation.summary.weekly",
                           rule.condition.weekday ?? 0, actionTitle(rule.action), target)
        }
    }

    private func actionTitle(_ action: AutomationAction) -> String {
        l10n.t("automation.action.\(action.rawValue)")
    }

}

private struct SmartTriggerEditor: View {
    @Environment(\.dismiss) private var dismiss
    let canMutate: Bool
    let onSave: (SmartTriggerRule) -> Void
    @ObservedObject private var l10n = L10n.shared
    @State private var name = ""
    @State private var hour = 3
    @State private var minute = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.t("automation.editor.kind.dailyQuickClean"))
                .font(.system(size: 16, weight: .semibold))
            Text(l10n.t("automation.editor.subtitle"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Form {
                TextField(l10n.t("automation.editor.name"), text: $name)
                Stepper(l10n.tf("automation.editor.hour", hour), value: $hour, in: 0...23)
                Stepper(l10n.tf("automation.editor.minute", minute), value: $minute, in: 0...59, step: 5)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(l10n.t("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(l10n.t("automation.editor.saveDisabled")) {
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(SmartTriggerRule(
                        name: title.isEmpty ? l10n.t("automation.editor.kind.dailyQuickClean") : title,
                        condition: .daily(hour: hour, minute: minute),
                        action: .quickCleanSafe, scope: .allSafe))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canMutate)
            }
        }
        .padding(20)
        .frame(width: 480, height: 340)
    }
}
