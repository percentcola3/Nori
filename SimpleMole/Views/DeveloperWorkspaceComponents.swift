import SwiftUI

enum DevWorkspaceText {
    static func choose(_ chinese: String, _ english: String) -> String {
        switch L10n.shared.resolved {
        case .zhHans, .zhHant: return chinese
        default: return english
        }
    }
}

enum DeveloperWorkspaceSearchSource: CaseIterable, Hashable, Sendable {
    case shell, network, cli
}

struct DeveloperWorkspaceSearchState: Equatable, Sendable {
    let refreshToken: Int
    let isSearching: Bool
}

/// Panel owners report even while their visible content is collapsed.
struct DeveloperWorkspaceSearchKey: PreferenceKey {
    static let defaultValue: [DeveloperWorkspaceSearchSource: DeveloperWorkspaceSearchState] = [:]

    static func reduce(value: inout [DeveloperWorkspaceSearchSource: DeveloperWorkspaceSearchState],
                       nextValue: () -> [DeveloperWorkspaceSearchSource: DeveloperWorkspaceSearchState]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Uses the same layout-first surface as cleanup rows.
struct DeveloperWorkspaceSurface: ViewModifier {
    let id: String
    var selected = false
    var interactive = false

    func body(content: Content) -> some View {
        content
            .clipped()
            .modifier(ListRowGlass(selected: selected, interactive: interactive))
            .accessibilityIdentifier(id)
    }
}

/// The panel owning this content stays mounted, so its model and drafts survive collapse.
struct DeveloperWorkspaceContent<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded {
                content.transition(.molePanelReveal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

struct DeveloperWorkspaceSection<Content: View>: View {
    let id: String
    let symbol: String
    let title: String
    @ViewBuilder var content: (Bool) -> Content
    @State private var isExpanded = true
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : MoleMotion.panel) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.moleAccentText)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accent.opacity(0.14)))
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.surface2))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .modifier(ListRowGlass())
            }
            .buttonStyle(MolePlainButtonStyle(pressedScale: 0.995))
            .accessibilityIdentifier("dev-section-" + id)
            .accessibilityLabel(title)
            .accessibilityValue(DevWorkspaceText.choose(isExpanded ? "已展开" : "已收起",
                                                       isExpanded ? "Expanded" : "Collapsed"))
            .accessibilityHint(DevWorkspaceText.choose(isExpanded ? "收起区域" : "展开区域",
                                                      isExpanded ? "Collapse section" : "Expand section"))

            content(isExpanded)
                .padding(.top, isExpanded ? 8 : 0)
        }
        .clipped()
    }
}
