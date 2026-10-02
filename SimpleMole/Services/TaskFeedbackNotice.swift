import Foundation

/// A task result or a prerequisite that needs the user's attention.
struct TaskFeedbackNotice: Identifiable {
    enum Kind { case failure, closeApplications }

    let id = UUID()
    var kind: Kind = .failure
    var message: String
    var details: [String] = []
    var detailsAreLocalized = false
    var applicationNames: [String] = []
    var onRetry: (() -> Void)? = nil

    /// Detached tool panels report to the same queue as main-window tasks.
    static func reportFailure(messageKey: String = "task.failure.message", details: [String] = [],
                              detailsAreLocalized: Bool = false) {
        NotificationCenter.default.post(name: .noriTaskFailure, object: nil,
            userInfo: ["messageKey": messageKey, "details": details,
                       "detailsAreLocalized": detailsAreLocalized])
    }
}

extension Notification.Name {
    static let noriTaskFailure = Notification.Name("NoriTaskFailure")
    static let smOpenMainWindow = Notification.Name("SMOpenMainWindow")
}
