import AppKit
import SwiftUI

struct DeveloperRuntimePanel: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @State private var onlyCleanable = false

    private var groups: [(manager: String, entries: [DevEnvEntry])] {
        let entries = state.devEnvEntries.filter { entry in
            !onlyCleanable || DeveloperRuntimePolicy.canClean(entry)
        }
        let buckets = Dictionary(grouping: entries, by: \.manager)
        return buckets.keys.sorted { lhs, rhs in
            if lhs == "nvm" { return rhs != "nvm" }
            if rhs == "nvm" { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            runtimeCard
            cacheCard
            resourcesCard
        }
    }

    private var runtimeCard: some View {
        DevCard(id: "dev-runtimes") {
            DevCardTitle(symbol: "shippingbox", title: L10n.shared.t("dev.cleanup.runtimes"),
                         subtitle: L10n.shared.t("dev.cleanup.protected"))
            Spacer(minLength: 8)
            if state.isScanningEnv { ProgressView().controlSize(.small) }
            Toggle(L10n.shared.t("dev.cleanup.cleanableOnly"), isOn: $onlyCleanable)
                .toggleStyle(.checkbox).font(.system(size: 11))
        } content: {
            if !state.devEnvStatus.isEmpty {
                DevDivider()
                DevNotice(symbol: "info.circle", text: state.devEnvStatus)
            }
            if groups.isEmpty && !state.isScanningEnv {
                DevDivider()
                DevNotice(symbol: "info.circle", text: L10n.shared.t("dev.cleanup.runtimes.empty"))
            }
            ForEach(groups, id: \.manager) { group in
                DevDivider()
                DevSubheader(title: group.manager, detail: "\(group.entries.count)")
                ForEach(group.entries) { entry in
                    DeveloperRuntimeRow(entry: entry,
                                        selected: state.devEnvSelection.contains(entry.path),
                                        enabled: !state.isBusy) {
                        guard DeveloperRuntimePolicy.canClean(entry) else { return }
                        if state.devEnvSelection.contains(entry.path) {
                            state.devEnvSelection.remove(entry.path)
                        } else {
                            state.devEnvSelection.insert(entry.path)
                        }
                    }
                }
                Color.clear.frame(height: 4)
            }
            if !state.devEnvSelection.isEmpty {
                DevDivider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(l10n.tf("devenv.apply.selected", state.devEnvSelection.count, ByteFormat.format(state.devEnvSelectedBytes)))
                            .font(.system(size: 12, weight: .medium))
                        if state.devEnvSelectedGlobalPackageBytes > 0 {
                            Text(L10n.shared.tf("dev.cleanup.globalPackages", ByteFormat.format(state.devEnvSelectedGlobalPackageBytes)))
                                .font(.system(size: 10)).foregroundStyle(Color.warning)
                        }
                    }
                    Spacer()
                    Button { state.applyDevEnvCleanup() } label: {
                        Label(L10n.shared.t("dev.cleanup.trash"), systemImage: "trash")
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: .danger))
                    .disabled(state.isBusy)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    private var cacheCard: some View {
        let actions = state.gcActions.filter { !["docker-builder", "docker-system", "simctl"].contains($0.id) }
        return DevCard(id: "dev-caches") {
            DevCardTitle(symbol: "sparkles", title: L10n.shared.t("dev.cleanup.caches"),
                         subtitle: L10n.shared.t("dev.cleanup.caches.help"))
            Spacer(minLength: 8)
            if state.isRefreshingGc { ProgressView().controlSize(.small) }
        } content: {
            if actions.isEmpty && !state.isRefreshingGc {
                DevDivider()
                DevNotice(symbol: "info.circle", text: L10n.shared.t("dev.cleanup.caches.empty"))
            }
            ForEach(Array(actions.enumerated()), id: \.element.id) { offset, action in
                if offset == 0 { DevDivider() } else { DevDivider(inset: 14) }
                DeveloperCacheActionRow(action: action, running: state.gcRunningId == action.id,
                                        enabled: !state.isBusy && !state.isRefreshingGc) { state.runGc(action) }
            }
        }
    }

    private var resourcesCard: some View {
        DevCard(id: "dev-resources") {
            DevCardTitle(symbol: "externaldrive", title: L10n.shared.t("dev.cleanup.resources"))
            Spacer()
        } content: {
            DevDivider()
            resourceRow(title: L10n.shared.t("dev.cleanup.docker"),
                        detail: L10n.shared.t("dev.cleanup.docker.help"),
                        symbol: "shippingbox") { state.showDockerDetails = true }
            DevDivider(inset: 14)
            resourceRow(title: L10n.shared.t("dev.cleanup.simulators"),
                        detail: L10n.shared.t("dev.cleanup.simulators.help"),
                        symbol: "iphone.gen3") { state.showSimulatorDevices = true }
        }
    }

    private func resourceRow(title: String, detail: String, symbol: String, open: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.shared.t("dev.cleanup.manage"), action: open)
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

private struct DeveloperRuntimeRow: View {
    @ObservedObject private var l10n = L10n.shared
    let entry: DevEnvEntry
    let selected: Bool
    let enabled: Bool
    let toggle: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if DeveloperRuntimePolicy.canClean(entry) {
                Toggle("", isOn: Binding(get: { selected }, set: { _ in toggle() }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(!enabled)
                    .accessibilityLabel(entry.name)
            } else {
                Image(systemName: entry.isCurrent || entry.isBuiltin ? "lock" : "shippingbox")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.versionLabel.isEmpty ? entry.name : entry.versionLabel)
                        .font(.system(size: 12, weight: .medium))
                    if entry.isCurrent {
                        DevTag(text: L10n.shared.t("dev.cleanup.current"), color: .success)
                    } else if !DeveloperRuntimePolicy.canClean(entry) {
                        DevTag(text: L10n.shared.t(entry.isBuiltin ? "dev.cleanup.system" : "dev.cleanup.managerOwned"))
                    }
                }
                Text(DevFiles.abbreviate(entry.path)).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                if entry.hasVersionGlobalPackages {
                    Text(L10n.shared.tf("dev.cleanup.row.globalPackages", ByteFormat.format(entry.relatedBytes)))
                        .font(.system(size: 10)).foregroundStyle(Color.warning)
                }
                if let command = DeveloperRuntimePolicy.ownerRemovalCommand(entry) {
                    HStack(spacing: 8) {
                        Text(command).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        DevLinkButton(title: L10n.shared.t(copied ? "dev.cleanup.copied" : "dev.cleanup.copyUninstall"),
                                      symbol: copied ? "checkmark" : "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copied = true
                        }
                    }
                }
            }
            Spacer(minLength: 6)
            if entry.bytes > 0 { SizeBadge(text: ByteFormat.format(entry.bytes), prominent: selected) }
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(MoleIconButtonStyle(size: 22))
            .help(L10n.shared.t("dev.cleanup.reveal"))
            .accessibilityLabel(L10n.shared.t("dev.cleanup.reveal"))
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .modifier(DevSelectionSurface(selected: selected))
        .padding(.horizontal, 6)
        .accessibilityIdentifier("dev-runtime-" + entry.id)
    }
}

private struct DeveloperCacheActionRow: View {
    @ObservedObject private var l10n = L10n.shared
    let action: GcAction
    let running: Bool
    let enabled: Bool
    let run: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.id).font(.system(size: 12, weight: .medium))
                Text(action.command).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            SizeBadge(text: action.bytes.map(ByteFormat.format) ?? L10n.shared.t("dev.cleanup.sizeUnknown"))
            if running {
                ProgressView().controlSize(.small)
            } else {
                Button(L10n.shared.t("dev.cleanup.clean"), action: run)
                    .buttonStyle(SecondaryButtonStyle()).disabled(!enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .accessibilityIdentifier("dev-cache-" + action.id)
    }
}
