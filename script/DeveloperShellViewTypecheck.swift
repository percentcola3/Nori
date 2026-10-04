import SwiftUI

// Isolated contracts; the production build verifies the common glass overlay.
@MainActor final class AppState: ObservableObject {
    @Published var taskNotice: TaskFeedbackNotice?
    func dismissTaskNotice() { taskNotice = nil }
    func retryTaskNotice(_ notice: TaskFeedbackNotice) {}
}
