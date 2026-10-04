import SwiftUI

// Shared presentation contracts for the isolated Shell, Network and CLI checks.
// The production build and screenshot fixtures verify real materials/layout.
enum AppLanguage { case zhHans, zhHant, en }
final class L10n: ObservableObject {
    static let shared = L10n()
    @Published var resolved = AppLanguage.en
    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ arguments: CVarArg...) -> String { key }
}

extension Color {
    static let danger = Color.red
    static let warning = Color.orange
    static let success = Color.green
    static let accentText = Color.blue
    static let moleAccent = Color.blue
    static let hairline = Color.gray
    static let surface1 = Color.gray
    static let surface2 = Color.gray
    static let surface3 = Color.gray
}
struct ListRowGlass: ViewModifier {
    var selected = false
    var interactive = true
    func body(content: Content) -> some View { content }
}
struct GlassSurface: View {
    let cornerRadius: CGFloat
    var usesSystemGlass = true
    var highlighted = false
    var body: some View { Color.clear }
}
struct LiquidGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}
enum MoleMotion { static let panel = Animation.default }
extension AnyTransition { static let molePanelReveal = AnyTransition.opacity }
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
struct MolePlainButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.98
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
struct MoleIconButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var size: CGFloat = 26
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
struct MoleSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
struct PillPicker: View {
    let items: [String]
    @Binding var selection: Int
    var alignment: Alignment = .center
    var body: some View { Text(items[selection]) }
}
extension View {
    func taskFeedback(_ notice: Binding<TaskFeedbackNotice?>,
                      retry: ((TaskFeedbackNotice) -> Void)? = nil) -> some View { self }
}
