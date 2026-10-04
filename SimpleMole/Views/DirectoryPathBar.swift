import AppKit
import SwiftUI

/// The complete navigation surface: ancestors remain reachable when space is limited.
struct DirectoryPathBar: View {
    let url: URL
    let isPathCopied: Bool
    let isRefreshing: Bool
    let onNavigate: (URL) -> Void
    let onCopy: () -> Void
    let onGoToPath: () -> Void
    let onRefresh: () -> Void

    @ObservedObject private var l10n = L10n.shared
    private var crumbs: [DirectoryPathCrumb] { DirectoryPathCrumb.components(for: url) }
    private func makePlan(for crumbs: [DirectoryPathCrumb], width: CGFloat) -> DirectoryPathOverflowPlan {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        return DirectoryPathOverflowPlan.make(
            widths: crumbs.map { crumb in
                let textWidth = (crumb.title as NSString).size(withAttributes: [.font: font]).width
                return ceil(textWidth) + 12
            }, availableWidth: max(0, width))
    }

    var body: some View {
        // Read the proposed width without feeding a measured fixed width back into
        // the window's minimum/ideal size during page transitions.
        GeometryReader { geometry in
            let crumbs = self.crumbs
            let plan = makePlan(for: crumbs, width: geometry.size.width)
            HStack(spacing: 4) {
                pathContent(crumbs: crumbs, plan: plan)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 30)
        .accessibilityIdentifier("directory-breadcrumbs")
    }

    private func pathContent(crumbs: [DirectoryPathCrumb], plan: DirectoryPathOverflowPlan) -> some View {
        HStack(spacing: 0) {
            ForEach(plan.visibleIndices.map { crumbs[$0] }) { crumb in
                let index = crumb.position
                if index != 0 { separator(width: plan.separatorWidth) }
                if index == 0 {
                    rootMenu(crumb: crumb, width: plan.itemWidths[index])
                } else if index == crumbs.count - 1 {
                    currentMenu(crumb: crumb, width: plan.itemWidths[index])
                } else {
                    Button { onNavigate(crumb.url) } label: { crumbLabel(crumb, width: plan.itemWidths[index]) }
                        .buttonStyle(MolePlainButtonStyle())
                        .help(crumb.url.path)
                        .accessibilityLabel(crumb.url.path)
                }
                if index == 0 && !plan.collapsedIndices.isEmpty {
                    separator(width: plan.separatorWidth)
                    collapsedMenu(crumbs: plan.collapsedIndices.map { crumbs[$0] }, width: plan.ellipsisWidth)
                }
            }
        }
        .frame(width: plan.totalWidth, height: 30, alignment: .leading)
        .clipped()
    }

    private func separator(width: CGFloat) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            .frame(width: width, height: 26)
            .accessibilityHidden(true)
    }

    private func collapsedMenu(crumbs: [DirectoryPathCrumb], width: CGFloat) -> some View {
        Menu {
            ForEach(crumbs) { crumb in
                Button { onNavigate(crumb.url) } label: { Text(crumb.url.path) }
            }
        } label: {
            Text("…").font(.system(size: 13, weight: .medium))
                .frame(width: width, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: width, height: 26)
        .clipped()
        .help(l10n.t("dir.path.ancestors"))
        .accessibilityLabel(l10n.t("dir.path.ancestors"))
        .accessibilityIdentifier("directory-breadcrumb-overflow")
    }

    private func rootMenu(crumb: DirectoryPathCrumb, width: CGFloat) -> some View {
        Menu {
            Button(l10n.t("dir.path.root")) { onNavigate(crumb.url) }
            Button(l10n.t("dir.home")) { onNavigate(FileManager.default.homeDirectoryForCurrentUser) }
            Button(l10n.t("dir.downloads")) {
                onNavigate(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true))
            }
            Divider()
            Button(l10n.t("dir.path.go"), action: onGoToPath)
            Button(l10n.t("dir.refresh"), action: onRefresh).disabled(isRefreshing)
            Button(l10n.t("dir.path.copy"), action: onCopy)
        } label: {
            crumbLabel(crumb, width: width)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: width, height: 26).clipped()
        .help(l10n.t("dir.path.root"))
        .accessibilityLabel(l10n.t("dir.path.root"))
    }

    private func currentMenu(crumb: DirectoryPathCrumb, width: CGFloat) -> some View {
        Menu {
            Button(crumb.url.path) { onNavigate(crumb.url) }
            Divider()
            Button(l10n.t("dir.path.go"), action: onGoToPath)
            Button(l10n.t("dir.path.copy"), action: onCopy)
            Button(l10n.t("dir.refresh"), action: onRefresh).disabled(isRefreshing)
        } label: {
            crumbLabel(crumb, width: width, current: true)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: width, height: 26).clipped()
        .help(crumb.url.path)
        .accessibilityLabel(crumb.url.path)
    }

    private func crumbLabel(_ crumb: DirectoryPathCrumb, width: CGFloat, current: Bool = false) -> some View {
        Text(crumb.title)
            .font(.system(size: 11, weight: current ? .semibold : .medium))
            .foregroundStyle(current ? Color.accentText : Color.primary)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, min(6, max(0, width / 4 - 1)))
            .frame(width: width, height: 26, alignment: .leading)
            .contentShape(Rectangle())
    }

}

struct DirectoryPathCrumb: Identifiable, Equatable {
    let url: URL
    let title: String
    let position: Int
    var id: String { url.path }

    static func components(for url: URL) -> [DirectoryPathCrumb] {
        var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
        var crumbs = [DirectoryPathCrumb(url: ancestor, title: "/", position: 0)]
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            ancestor.appendPathComponent(component, isDirectory: true)
            crumbs.append(DirectoryPathCrumb(url: ancestor, title: component, position: crumbs.count))
        }
        return crumbs
    }
}

/// Pure width allocation: retain the root/current and the closest possible parents.
/// Hidden indices are never dropped; they become the ancestor menu's contents.
struct DirectoryPathOverflowPlan: Equatable {
    let visibleIndices: [Int]
    let collapsedIndices: [Int]
    let itemWidths: [CGFloat]
    let separatorWidth: CGFloat
    let ellipsisWidth: CGFloat

    var totalWidth: CGFloat {
        visibleIndices.reduce(0) { $0 + itemWidths[$1] }
            + CGFloat(max(0, visibleIndices.count - 1) + (collapsedIndices.isEmpty ? 0 : 1)) * separatorWidth
            + (collapsedIndices.isEmpty ? 0 : ellipsisWidth)
    }

    static func make(widths proposedWidths: [CGFloat], availableWidth: CGFloat) -> DirectoryPathOverflowPlan {
        let available = availableWidth.isFinite ? max(0, availableWidth) : 0
        let widths = proposedWidths.map { $0.isFinite ? max(0, $0) : 0 }
        guard !widths.isEmpty else {
            return DirectoryPathOverflowPlan(visibleIndices: [], collapsedIndices: [], itemWidths: [], separatorWidth: 0, ellipsisWidth: 0)
        }
        if widths.count == 1 {
            return DirectoryPathOverflowPlan(visibleIndices: [0], collapsedIndices: [], itemWidths: [min(widths[0], available)], separatorWidth: 0, ellipsisWidth: 0)
        }
        let separator: CGFloat = 12
        let ellipsis: CGFloat = 24
        let allWidth = widths.reduce(0, +) + CGFloat(widths.count - 1) * separator
        if allWidth <= available {
            return DirectoryPathOverflowPlan(visibleIndices: Array(widths.indices), collapsedIndices: [], itemWidths: widths, separatorWidth: separator, ellipsisWidth: 0)
        }
        let last = widths.count - 1
        let rootWidth = widths[0]
        let currentMinimum = min(widths[last], 72)
        var parents: [Int] = []
        func usedWidth(_ selected: [Int]) -> CGFloat {
            let hidden = last - 1 - selected.count
            return rootWidth + currentMinimum + selected.reduce(0) { $0 + min(widths[$1], 144) }
                + CGFloat(selected.count + 1 + (hidden > 0 ? 1 : 0)) * separator
                + (hidden > 0 ? ellipsis : 0)
        }
        if last > 1 {
            for parent in stride(from: last - 1, through: 1, by: -1) {
                let candidate = Array(parent..<last)
                if usedWidth(candidate) <= available { parents = candidate }
            }
        }
        let visible = [0] + parents + [last]
        let firstParent = parents.first ?? last
        let hidden = Array(1..<firstParent)
        var assigned = Array(repeating: CGFloat.zero, count: widths.count)
        assigned[0] = rootWidth
        for parent in parents { assigned[parent] = min(widths[parent], 144) }
        assigned[last] = currentMinimum
        let base = usedWidth(parents)
        if base > available {
            let scale = base > 0 ? available / base : 0
            assigned = assigned.map { $0 * scale }
            return DirectoryPathOverflowPlan(visibleIndices: visible, collapsedIndices: hidden, itemWidths: assigned,
                                             separatorWidth: separator * scale, ellipsisWidth: ellipsis * scale)
        }
        assigned[last] += min(max(0, widths[last] - currentMinimum), max(0, available - base))
        return DirectoryPathOverflowPlan(visibleIndices: visible, collapsedIndices: hidden, itemWidths: assigned,
                                         separatorWidth: separator, ellipsisWidth: ellipsis)
    }
}
