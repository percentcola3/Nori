import SwiftUI

// Isolated contracts; the production build verifies the common glass overlay.
@MainActor final class AppState: ObservableObject {
    @Published var taskNotice: TaskFeedbackNotice?
    func dismissTaskNotice() { taskNotice = nil }
    func retryTaskNotice(_ notice: TaskFeedbackNotice) {}
}
enum AppLanguage { case zhHans, zhHant, en }
final class L10n: ObservableObject {
    static let shared = L10n()
    var resolved: AppLanguage { .en }
    func t(_ key: String) -> String { key }
}
extension Color {
    static let danger = Color.red
    static let warning = Color.orange
    static let success = Color.green
    static let accentText = Color.blue
    static let hairline = Color.gray
}
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
struct ListRowGlass: ViewModifier {
    func body(content: Content) -> some View { content }
}
struct DeveloperWorkspaceContent<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder let content: Content
    var body: some View { if isExpanded { content } }
}
enum DeveloperWorkspaceSearchSource: Hashable { case shell, network, cli }
struct DeveloperWorkspaceSearchState: Equatable {
    let refreshToken: Int
    let isSearching: Bool
}
struct DeveloperWorkspaceSearchKey: PreferenceKey {
    static let defaultValue: [DeveloperWorkspaceSearchSource: DeveloperWorkspaceSearchState] = [:]
    static func reduce(value: inout [DeveloperWorkspaceSearchSource: DeveloperWorkspaceSearchState],
                       nextValue: () -> [DeveloperWorkspaceSearchSource: DeveloperWorkspaceSearchState]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
extension View {
    func taskFeedback(_ notice: Binding<TaskFeedbackNotice?>,
                      retry: ((TaskFeedbackNotice) -> Void)? = nil) -> some View { self }
}
