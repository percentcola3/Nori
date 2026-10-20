import SwiftUI

struct MenuBarCollectionSettingsView: View {
    @ObservedObject var controller: MenuBarCollectionController
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(l10n.t("menubar.enable"), isOn: Binding(
                get: { controller.enabled }, set: { controller.setEnabled($0) }))
                .disabled(!controller.available)
                .toggleStyle(MoleSwitchToggleStyle()).controlSize(.small)
                .font(.system(size: 12))
            Text(l10n.t(controller.hintKey))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if controller.enabled {
                if controller.backend == .nativeExperimental {
                    Toggle(l10n.t("menubar.tray.show"), isOn: Binding(
                        get: { controller.trayIconVisible }, set: { controller.setTrayIconVisible($0) }))
                        .toggleStyle(MoleSwitchToggleStyle()).controlSize(.small)
                        .font(.system(size: 12))
                    HStack {
                        Text(l10n.t("menubar.apps.hint"))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(l10n.t("menubar.refresh")) { controller.refreshCandidates() }
                            .buttonStyle(SecondaryButtonStyle()).disabled(controller.busy)
                    }
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(controller.candidates) { app in
                                appRow(app)
                            }
                        }
                    }.frame(height: 184)
                }
                HStack(spacing: 8) {
                    Button(l10n.t("menubar.collapse")) { controller.collapse() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(controller.collapsed || controller.busy)
                    Button(l10n.t("menubar.restore")) { controller.restore() }
                        .buttonStyle(SecondaryButtonStyle())
                    if controller.busy { ProgressView().controlSize(.small) }
                    Spacer(minLength: 8)
                    Text(l10n.t(controller.collapsed ? "menubar.collapsed" : "menubar.expanded"))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(l10n.t("menubar.native.access"), systemImage: controller.canControlNativeIcons ? "checkmark.circle" : "hand.tap")
                        Spacer()
                        if !controller.canControlNativeIcons {
                            Button(l10n.t("menubar.access.authorize")) { controller.requestAccessibility() }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    Text(l10n.t(controller.canControlNativeIcons ? "menubar.native.hint" : "menubar.preview.fallback"))
                        .foregroundStyle(.secondary)
                    if controller.canControlNativeIcons && !controller.canCaptureNativeIcons {
                        Text(l10n.t("menubar.capture.hint")).foregroundStyle(.secondary)
                    }
                }.font(.system(size: 10.5))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(controller.$error.removeDuplicates()) { error in
            if let error { TaskFeedbackNotice.reportFailure(details: [error], detailsAreLocalized: true) }
        }
        .onAppear { if !controller.collapsed { controller.refreshCandidates(clearError: false) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !controller.collapsed { controller.refreshCandidates(clearError: false) }
        }
    }

    private func appRow(_ app: MenuBarCollectionController.Candidate) -> some View {
        let selected = controller.selected.contains(app.id)
        return Button { controller.setSelected(app.id, !selected) } label: {
            HStack(spacing: 9) {
                Image(nsImage: app.icon).resizable().scaledToFit().frame(width: 20, height: 20)
                Text(app.name).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentText : Color.secondary)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .modifier(ListRowSurface(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.name)
        .accessibilityValue(l10n.t(selected ? "menubar.selected" : "menubar.unselected"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A cluster of cached icons occupies one configurable island slot. No separate
/// tray button or separate NSWindow is created for collection settings.
struct IslandMenuBarCollectionPreview: View {
    @ObservedObject var controller: MenuBarCollectionController
    @ObservedObject private var l10n = L10n.shared
    var onOpen: () -> Void
    var onHoverChange: (Bool) -> Void

    private var previews: [CollectedMenuBarIcon] { controller.enabled ? controller.icons : [] }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: -7) {
                if previews.isEmpty {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 19, weight: .medium)).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(previews.prefix(3))) { icon in
                        Image(nsImage: icon.image).resizable().scaledToFit()
                            .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    if previews.count > 3 {
                        Text("+\(previews.count - 3)").font(.system(size: 9, weight: .semibold)).padding(.leading, 9)
                    }
                }
            }.frame(height: 24)
            Text(l10n.t("island.item.collection"))
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .allowsHitTesting(false).accessibilityHidden(true)
        .overlay {
            IslandActionTarget(label: l10n.t("menubar.drawer.open")) { onOpen() }
        }
        .onHover(perform: onHoverChange)
    }
}

struct IslandMenuBarCollectionDrawer: View {
    @ObservedObject var controller: MenuBarCollectionController
    @ObservedObject private var l10n = L10n.shared
    var onNativeAction: (CollectedMenuBarIcon, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
                    ForEach(controller.icons) { icon in
                        IslandCollectedIconTile(icon: icon,
                            onPrimary: { onNativeAction(icon, false) },
                            onSecondary: { onNativeAction(icon, true) })
                    }
                }
            }.frame(maxHeight: 208)
            if !controller.canControlNativeIcons {
                Text(l10n.t("menubar.preview.fallback"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }
}

private struct IslandCollectedIconTile: View {
    let icon: CollectedMenuBarIcon
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: icon.image).resizable().scaledToFit()
                .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
            Text(icon.name).font(.system(size: 9)).lineLimit(1)
        }
        .frame(maxWidth: .infinity).frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovered ? Color.surface2 : Color.surface1))
        .allowsHitTesting(false).accessibilityHidden(true)
        .overlay {
            IslandActionTarget(label: icon.title, onSecondaryAction: onSecondary, action: onPrimary)
        }
        .onHover { hovered = $0 }
        .help(icon.title)
    }
}
