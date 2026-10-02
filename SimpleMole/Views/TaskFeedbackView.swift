import SwiftUI

struct TaskFeedbackView: View {
    let notice: TaskFeedbackNotice
    let dismiss: () -> Void
    let retry: () -> Void
    @ObservedObject private var l10n = L10n.shared

    private var needsApplicationsClosed: Bool { notice.kind == .closeApplications }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(l10n.t(needsApplicationsClosed ? "task.closeApps.title" : "task.failure.title"),
                  systemImage: needsApplicationsClosed ? "app.badge" : "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.warning)
            Text(notice.message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if !notice.applicationNames.isEmpty {
                Text(notice.applicationNames.joined(separator: "\n"))
                    .font(.system(size: 13, weight: .semibold))
                    .textSelection(.enabled)
            }
            let details = notice.detailsAreLocalized
                ? notice.details : TaskFeedbackDiagnostic.localized(notice.details)
            if !details.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.t("task.details")).font(.system(size: 11, weight: .medium))
                    ScrollView {
                        Text(details.joined(separator: "\n\n"))
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(l10n.t(needsApplicationsClosed ? "task.cancel" : "task.dismiss"), action: dismiss)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(needsApplicationsClosed ? .cancelAction : .defaultAction)
                if needsApplicationsClosed, notice.onRetry != nil {
                    Button(l10n.t("task.closeApps.check"), action: retry)
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 580, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Independent editors keep their failure notice in the window where the task ran.
private struct TaskFeedbackPresentation: ViewModifier {
    @Binding var notice: TaskFeedbackNotice?
    var onRetry: ((TaskFeedbackNotice) -> Void)?
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        LiquidGlassGroup {
            ZStack {
                content.disabled(notice != nil).accessibilityHidden(notice != nil)
                if let notice {
                    Color.surface1.opacity(0.45).ignoresSafeArea().contentShape(Rectangle())
                    TaskFeedbackView(notice: notice, dismiss: { self.notice = nil }, retry: {
                        if let onRetry { onRetry(notice) }
                        else {
                            self.notice = nil
                            notice.onRetry?()
                        }
                    })
                    .liquidSurface(notice.id.uuidString)
                    .padding(16)
                    .transition(.opacity)
                }
            }
        }
        .environment(\.liquidNamespace, namespace)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: notice?.id)
    }
}

extension View {
    func taskFeedback(_ notice: Binding<TaskFeedbackNotice?>,
                      retry: ((TaskFeedbackNotice) -> Void)? = nil) -> some View {
        modifier(TaskFeedbackPresentation(notice: notice, onRetry: retry))
    }
}
