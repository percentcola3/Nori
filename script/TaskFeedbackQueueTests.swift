import Foundation

@main
struct TaskFeedbackQueueTests {
    static func main() {
        var queue = TaskFeedbackQueue()
        let first = TaskFeedbackNotice(message: "Cleanup failed", details: ["Permission denied"])
        let second = TaskFeedbackNotice(message: "Uninstall failed", details: ["Application is running"])
        queue.enqueue(first)
        precondition(queue.active?.id == first.id)
        queue.enqueue(second)
        precondition(queue.active?.id == first.id, "A later failure cannot replace the visible notice")
        queue.dismiss()
        precondition(queue.active?.id == second.id, "Dismissal must reveal the next independent failure")
        queue.dismiss()
        precondition(queue.active == nil)

        queue.enqueue(first)
        queue.enqueue(TaskFeedbackNotice(message: first.message, details: first.details))
        queue.enqueue(second)
        queue.enqueue(TaskFeedbackNotice(message: second.message, details: second.details))
        queue.dismiss()
        precondition(queue.active?.id == second.id, "Repeated visible diagnostics must share one notice")
        queue.dismiss()
        precondition(queue.active == nil, "Repeated pending diagnostics must not fill the notice queue")
        queue.enqueue(TaskFeedbackNotice(message: first.message, details: first.details))
        precondition(queue.active != nil, "A new failure after dismissal must be shown again")
        queue.dismiss()

        let localizedDetails = TaskFeedbackNotice(message: first.message, details: first.details,
                                                  detailsAreLocalized: true)
        queue.enqueue(first)
        queue.enqueue(localizedDetails)
        queue.dismiss()
        precondition(queue.active?.id == localizedDetails.id,
                     "Distinct detail interpretation cannot be coalesced into another notice")
        queue.dismiss()

        var retries = 0
        let prerequisite = TaskFeedbackNotice(kind: .closeApplications,
            message: "Close these applications", details: ["Codex cache"], applicationNames: ["Codex"],
            onRetry: { retries += 1 })
        let otherRetry = TaskFeedbackNotice(kind: .closeApplications,
            message: prerequisite.message, details: prerequisite.details, applicationNames: ["Codex"],
            onRetry: { retries += 10 })
        queue.enqueue(prerequisite)
        queue.enqueue(otherRetry)
        let firstRetry = queue.active?.onRetry
        queue.dismiss()
        firstRetry?()
        precondition(retries == 1 && queue.active?.id == otherRetry.id,
                     "Identical looking prerequisites must keep their captured retry actions")
        queue.active?.onRetry?()
        queue.dismiss()
        precondition(retries == 11 && queue.active == nil)
        print("Task feedback: FIFO delivery, repeated diagnostic coalescing, and preserved retry contexts passed")
    }
}
