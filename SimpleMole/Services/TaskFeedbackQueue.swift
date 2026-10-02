import Foundation

/// Preserve independently completed task failures while another notice is open.
/// Repeated diagnostics from one passive failure share a notice; retry actions
/// always keep their own captured task context.
struct TaskFeedbackQueue {
    private(set) var active: TaskFeedbackNotice?
    private var pending: [TaskFeedbackNotice] = []

    mutating func enqueue(_ notice: TaskFeedbackNotice) {
        let existing = active.map { [$0] } ?? []
        if notice.kind == .failure, notice.onRetry == nil,
           (existing + pending).contains(where: {
               $0.kind == notice.kind && $0.onRetry == nil && $0.message == notice.message
                   && $0.details == notice.details && $0.applicationNames == notice.applicationNames
                   && $0.detailsAreLocalized == notice.detailsAreLocalized
           }) { return }
        if active == nil { active = notice }
        else { pending.append(notice) }
    }

    mutating func dismiss() {
        active = pending.isEmpty ? nil : pending.removeFirst()
    }
}
