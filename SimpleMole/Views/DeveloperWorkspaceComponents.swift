import SwiftUI
import AppKit

/// One glass layer per card. The header, rows and footer all sit on the same surface,
/// separated by hairlines instead of nested cards.
struct DevCard<Header: View, Content: View>: View {
    let id: String
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) { header }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .modifier(ListRowGlass(interactive: false))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }
}

/// Selected rows inside a card become a glass lens; unselected rows add no layer.
struct DevSelectionLens: ViewModifier {
    let id: String
    let selected: Bool
    var groupNamespace: Namespace.ID? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Namespace private var localNamespace

    @ViewBuilder func body(content: Content) -> some View {
        if !selected {
            content
        } else if #available(macOS 26.0, *), !reduceTransparency, controlActiveState == .key {
            content
                .glassEffect(.regular.tint(Color.moleAccent.opacity(0.20)).interactive(!reduceMotion), in: RoundedRectangle(cornerRadius: 8))
                .glassEffectID(id, in: groupNamespace ?? localNamespace)
                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
        } else {
            content.background(GlassSurface(cornerRadius: 8, usesSystemGlass: false, highlighted: true))
        }
    }
}

struct DevCardTitle: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentText)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .semibold))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

struct DevDivider: View {
    var inset: CGFloat = 0
    var body: some View {
        Rectangle().fill(Color.hairline).frame(height: 1).padding(.leading, inset)
    }
}

/// Group label inside a card, with an optional trailing action.
struct DevSubheader<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

extension DevSubheader where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// A single-line status inside a card: success, warning or neutral guidance.
struct DevNotice: View {
    let symbol: String
    let text: String
    var color: Color = .secondary

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.system(size: 11))
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Text-only action used in card headers and subheaders; the card already provides the surface.
struct DevLinkButton: View {
    let title: String
    let symbol: String
    var tint: Color = .accentText
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(MolePlainButtonStyle())
        .foregroundStyle(tint)
    }
}

/// Small rounded tag for hostnames, sources and states.
struct DevTag: View {
    let text: String
    var color: Color?

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color ?? .secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.surface2))
    }
}

enum DevFiles {
    /// Shell profiles have no extension; fall back to TextEdit when nothing claims them.
    static func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil, NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil {
                Task { @MainActor in TaskFeedbackNotice.reportFailure(messageKey: "task.reason.terminal") }
            }
        }
    }

    static func chooseDirectory(startingAt path: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let path { panel.directoryURL = URL(fileURLWithPath: path) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
