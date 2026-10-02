import AppKit
import SwiftUI

struct AgentIconView: View {
    let agentID: String
    var size: CGFloat = 24
    @State private var icon: AgentIconImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon.image)
                    .resizable()
                    .renderingMode(icon.isTemplate ? .template : .original)
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(Color.primary)
            } else {
                AgentDefaultIcon(size: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: agentID) {
            icon = nil
            let loaded = await AgentIconLoader.image(agentID: agentID)
            guard !Task.isCancelled else { return }
            icon = loaded
        }
        .accessibilityHidden(true)
    }
}

/// A small coding badge remains deliberate even when no app/brand icon exists.
private struct AgentDefaultIcon: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color.surface2, Color.surface1],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(Color.moleAccentText)
        }
    }
}
