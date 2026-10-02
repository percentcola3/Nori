import AppKit
import SwiftUI

struct DeveloperRuntimePanel: View {
    @ObservedObject var state: AppState
    var isExpanded = true
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
        DeveloperWorkspaceContent(isExpanded: isExpanded) {
            runtimeContent
        }
    }

    private var runtimeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Toggle(DevWorkspaceText.choose("仅可清理", "Cleanable only"), isOn: $onlyCleanable)
                    .toggleStyle(.checkbox).font(.system(size: 11))
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                accessNotice
                Text(DevWorkspaceText.choose("保留当前 / 默认 nvm；旧版本及其全局 npm 包可移入废纸篓。",
                                            "Current / default nvm versions stay protected. Old versions include their global npm packages."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !state.devEnvStatus.isEmpty {
                    Text(state.devEnvStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if groups.isEmpty && !state.isScanningEnv {
                    Text(DevWorkspaceText.choose("没有符合条件的运行时。", "No matching runtimes."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(groups, id: \.manager) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.manager).font(.system(size: 12, weight: .semibold))
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
                            .padding(.leading, 16)
                        }
                    }
                }
                cacheSection
                resources
            }
            if !state.devEnvSelection.isEmpty {
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(l10n.tf("devenv.apply.selected", state.devEnvSelection.count, ByteFormat.format(state.devEnvSelectedBytes)))
                            .font(.system(size: 11))
                        if state.devEnvSelectedGlobalPackageBytes > 0 {
                            Text(DevWorkspaceText.choose("包含该版本的全局 npm 包：", "Includes version-specific global npm packages: ")
                                 + ByteFormat.format(state.devEnvSelectedGlobalPackageBytes))
                                .font(.system(size: 10)).foregroundStyle(Color.warning)
                        }
                    }
                    Spacer()
                    Button { state.applyDevEnvCleanup() } label: {
                        Label(DevWorkspaceText.choose("移入废纸篓", "Move to Trash"), systemImage: "trash")
                    }.buttonStyle(PrimaryButtonStyle()).disabled(state.isBusy)
                }.padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private var accessNotice: some View {
        if !state.permissionCenter.fullDiskAccessGranted {
            HStack(spacing: 12) {
                Text(DevWorkspaceText.choose("运行时扫描需要完全磁盘访问权限。", "Runtime inventory needs Full Disk Access."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { state.requestScanAccess(.developmentEnvironmentScan) } label: {
                    Label(DevWorkspaceText.choose("查看访问权限", "Review access"), systemImage: "lock")
                }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DevWorkspaceText.choose("包与构建缓存", "Package and build caches"))
                .font(.system(size: 12, weight: .semibold))
            Text(DevWorkspaceText.choose("按官方命令清理；下次构建可能重新下载缓存。",
                                        "Uses official cleanup commands. The next build may download caches again."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(state.gcActions.filter { !["docker-builder", "docker-system", "simctl"].contains($0.id) }) { action in
                DeveloperCacheActionRow(action: action, running: state.gcRunningId == action.id,
                                        enabled: !state.isBusy && !state.isRefreshingGc) { state.runGc(action) }
                    .padding(.leading, 16)
            }
            if state.gcActions.isEmpty && !state.isRefreshingGc {
                Text(DevWorkspaceText.choose("当前检查范围未发现可用的缓存清理工具。", "No cache cleanup tools were found in the current search paths."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(.top, 8)
    }

    private var resources: some View {
        HStack(spacing: 12) {
            Button { state.showDockerDetails = true } label: {
                Label(DevWorkspaceText.choose("Docker 空间管理", "Docker storage"), systemImage: "shippingbox")
            }.buttonStyle(SecondaryButtonStyle())
            Button { state.showSimulatorDevices = true } label: {
                Label(DevWorkspaceText.choose("模拟器管理", "Simulators"), systemImage: "iphone.gen3")
            }.buttonStyle(SecondaryButtonStyle())
            Spacer(minLength: 0)
        }.padding(.top, 10)
    }
}

private struct DeveloperRuntimeRow: View {
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
                    .foregroundStyle(.secondary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.versionLabel.isEmpty ? entry.name : entry.versionLabel)
                        .font(.system(size: 12, weight: .medium))
                    if entry.isCurrent {
                        Text(DevWorkspaceText.choose("当前 / 默认", "Current / default"))
                            .font(.system(size: 10)).foregroundStyle(Color.warning)
                    } else if !DeveloperRuntimePolicy.canClean(entry) {
                        Text(DevWorkspaceText.choose(entry.isBuiltin ? "系统内置" : "由工具管理",
                                                    entry.isBuiltin ? "System" : "Manager-owned"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Text(entry.path).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                if entry.hasVersionGlobalPackages {
                    Text(DevWorkspaceText.choose("全局 npm 包随版本一起清理：", "Global npm packages are included: ") + ByteFormat.format(entry.relatedBytes))
                        .font(.system(size: 10)).foregroundStyle(Color.warning)
                }
                if let command = DeveloperRuntimePolicy.ownerRemovalCommand(entry) {
                    HStack {
                        Text(command).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copied = true
                        } label: {
                            Label(DevWorkspaceText.choose(copied ? "已复制" : "复制卸载命令", copied ? "Copied" : "Copy uninstall command"),
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }.buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    }
                    Text(DevWorkspaceText.choose("先检查项目依赖与默认版本；卸载可能不可恢复。",
                                                "Check project dependencies and defaults first. Uninstall may be irreversible."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if entry.bytes > 0 { SizeBadge(text: ByteFormat.format(entry.bytes), prominent: selected) }
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) } label: {
                Image(systemName: "folder")
            }.buttonStyle(MoleIconButtonStyle(size: 22))
                .help(DevWorkspaceText.choose("在 Finder 中查看", "Reveal in Finder"))
        }.padding(12)
            .modifier(DeveloperWorkspaceSurface(id: "dev-runtime-" + entry.id, selected: selected,
                                               interactive: DeveloperRuntimePolicy.canClean(entry)))
    }
}

private struct DeveloperCacheActionRow: View {
    let action: GcAction
    let running: Bool
    let enabled: Bool
    let run: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(action.id).font(.system(size: 12, weight: .medium))
                Text(action.command).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if action.bytes > 0 { SizeBadge(text: ByteFormat.format(action.bytes)) }
            if running {
                ProgressView().controlSize(.mini)
            } else {
                Button(action: run) {
                    Label(DevWorkspaceText.choose("清理缓存", "Clean cache"), systemImage: "sparkles")
                }.buttonStyle(SecondaryButtonStyle()).disabled(!enabled)
            }
        }.padding(12).modifier(DeveloperWorkspaceSurface(id: "dev-cache-" + action.id))
    }
}
