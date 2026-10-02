import SwiftUI

// Minimal shared APIs for independently checking the new panel while other
// workbench agents edit AppState and the neighboring views.
@MainActor final class AppState: ObservableObject {
    struct Confirmation {
        let title: String
        let message: String
        let confirmLabel: String
        let onConfirm: () -> Void
    }
    @Published var confirmation: Confirmation?
    @Published var isNetworkToolRunning = false
    @Published var networkToolStatus = ""
    func runAdminNetworkTask(_ task: String) {}
    func log(_ message: String) {}
}
enum AppLanguage { case zhHans, zhHant, en }
final class L10n: ObservableObject {
    static let shared = L10n()
    @Published var resolved = AppLanguage.en
    func t(_ key: String) -> String { key }
}
extension Color {
    static let accentText = Color.blue
    static let warning = Color.orange
    static let danger = Color.red
    static let success = Color.green
}
struct LiquidGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}
struct GlassSurface: View {
    let cornerRadius: CGFloat
    var body: some View { Color.clear }
}
struct MolePlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
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
// Layout/material rendering is verified by the complete production app build.
// This fixture exposes only the shared APIs used by the independent panel check.
struct DeveloperWorkspaceContent<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder let content: Content
    var body: some View {
        if isExpanded { content }
    }
}
struct ListRowGlass: ViewModifier {
    func body(content: Content) -> some View { content }
}
