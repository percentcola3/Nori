import AppKit
import SwiftUI

/// Single-level app uninstaller. The row owns its optional file drawer; the
/// uninstall action confirms removal and forced process shutdown before
/// entering the serialized background queue.
struct UninstallTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isListPresented = false

    private var isActive: Bool {
        let pages = state.visiblePages
        return pages.indices.contains(state.selectedTab) && pages[state.selectedTab] == .uninstall
    }

    private var presentationPhase: Int {
        if !isListPresented || state.isRestoringInstalledApps
            || (!state.installedApps.isEmpty && state.filteredApps.isEmpty
                && state.uninstallSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (state.isScanningApps && state.installedApps.isEmpty) { return 1 }
        if state.installedApps.isEmpty { return 0 }
        return state.filteredApps.isEmpty ? 3 : 2
    }

    var body: some View {
        NoriPageTransition(phase: state.uninstallSegment == 1 ? 10 + toolsPhase : presentationPhase) {
        VStack(spacing: 0) {
            toolbar
            if state.uninstallSegment == 1 {
                CommandLineToolsSection(state: state)
            } else {
                statusRow
                content
            }
        }
        }
        .task(id: "\(isActive)-\(state.uninstallSegment)") {
            guard isActive, state.uninstallSegment == 1 else { return }
            state.scanCommandLineTools()
        }
        .animation(reduceMotion ? nil : MoleMotion.panel,
                   value: state.uninstallQueue.jobs)
        // 扫描中 → 应用列表/空态/无匹配 的整块互换走弹簧过渡。
        .task(id: isActive) {
            guard isActive else {
                isListPresented = false
                return
            }
            // Commit the tab highlight and a lightweight placeholder first.
            // Leaving the page cancels this delay, even during its transition.
            do { try await Task.sleep(nanoseconds: 160_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            isListPresented = true
            if state.installedApps.isEmpty, !state.isRestoringInstalledApps {
                state.scanInstalledApps(background: true)
            }
        }
    }

    /// 清单由目录监听自动刷新，不再提供手动扫描；搜索框独占一行。
    private var toolsPhase: Int {
        if state.isScanningCommandLineTools && state.commandLineTools.isEmpty { return 1 }
        return state.commandLineTools.isEmpty ? 0 : 2
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            PillPicker(items: [l10n.t("uninstall.segment.apps"), l10n.t("uninstall.segment.tools")],
                       selection: $state.uninstallSegment, alignment: .leading)
                .frame(width: 220)
                .accessibilityIdentifier("uninstall-segment")
            searchField
            Button { state.checkSoftwareUpdates() } label: {
                Label(l10n.t(state.isCheckingSoftwareUpdates ? "software.updates.checking" : "software.updates.check"),
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(SecondaryButtonStyle())
            .controlSize(.small)
            .disabled(state.isCheckingSoftwareUpdates || state.isScanningApps || state.isScanningCommandLineTools
                      || state.uninstallQueue.hasWork || state.commandLineToolBusyID != nil || state.softwareUpdatingID != nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField(l10n.t("uninstall.search"), text: $state.uninstallSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !state.uninstallSearch.isEmpty {
                Button { state.uninstallSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.surface2))
    }

    // Completed jobs belong in the log, never in a persistent page banner.
    private var statusJob: UninstallJob? {
        if state.isScanningApps && !state.uninstallQueue.hasWork { return nil }
        return state.uninstallQueue.activeJob
            ?? state.uninstallQueue.jobs.first { $0.state.isPending }
    }

    @ViewBuilder private var statusRow: some View {
        if statusJob != nil || (state.isScanningApps && !state.appListStatus.isEmpty) {
        HStack(spacing: 8) {
            if let job = statusJob {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.message?.components(separatedBy: "\n").first ?? job.app.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    UninstallJobStateLabel(job: job,
                                           position: state.uninstallQueuePosition(for: job.app))
                }
            } else {
                if !state.appListStatus.isEmpty {
                    Text(state.appListStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isListPresented || state.isRestoringInstalledApps
            || (!state.installedApps.isEmpty && state.filteredApps.isEmpty
                && state.uninstallSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            NoriScanActivity(text: l10n.t("uninstall.loading"), assetName: "nori-apps", quiet: true)
        } else if state.isScanningApps && state.installedApps.isEmpty {
            NoriScanActivity(text: state.appListStatus, assetName: "nori-apps", quiet: true)
        } else if state.installedApps.isEmpty {
            EmptyStateView(
                symbol: "app.dashed",
                title: state.isScanningApps
                    ? l10n.t("uninstall.status.scanning")
                    : l10n.t("uninstall.status.none"),
                subtitle: state.isScanningApps ? nil : l10n.t("uninstall.empty.subtitle"))
        } else if state.filteredApps.isEmpty {
            EmptyStateView(symbol: "magnifyingglass",
                           title: l10n.t("uninstall.noMatch.title"),
                           subtitle: l10n.t("uninstall.noMatch.subtitle"))
        } else {
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(state.filteredApps) { app in
                        UninstallAppRow(
                            app: app,
                            plan: state.uninstallPlan(for: app),
                            job: state.uninstallJob(for: app),
                            queuePosition: state.uninstallQueuePosition(for: app),
                            update: state.softwareUpdateResults[SoftwareUpdateService.appKey(app)],
                            isCheckingUpdate: state.softwareUpdateCheckingIDs.contains(SoftwareUpdateService.appKey(app)),
                            updatingID: state.softwareUpdatingID,
                            externalPending: state.softwareUpdateHandoffIDs.contains(SoftwareUpdateService.appKey(app)),
                            dataSelection: Binding(
                                get: { state.uninstallDataSelections[app.id] ?? [] },
                                set: { state.uninstallDataSelections[app.id] = $0.isEmpty ? nil : $0 }),
                            onCancel: { job in state.cancelQueuedUninstall(id: job.id) },
                            onUpdate: { state.updateSoftware(app) },
                            onUninstall: { state.previewUninstall(app) })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }
}

private struct UninstallAppRow: View {
    let app: UninstallApp
    let plan: UninstallPlan?
    let job: UninstallJob?
    let queuePosition: Int?
    let update: SoftwareUpdateResult?
    let isCheckingUpdate: Bool
    let updatingID: String?
    let externalPending: Bool
    @Binding var dataSelection: Set<String>
    let onCancel: (UninstallJob) -> Void
    let onUpdate: () -> Void
    let onUninstall: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    private var space: UninstallSpaceBreakdown? { plan?.space }
    private var totalText: String {
        space.map { ByteFormat.format($0.footprintBytes) } ?? app.size
    }
    private var actionTitle: String {
        job?.state == .failed
            ? L10n.shared.t("uninstall.queue.retry")
            : L10n.shared.t("uninstall.action")
    }
    private var actionSymbol: String {
        job?.state == .failed ? "arrow.clockwise" : "trash"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                appIcon
                appIdentity
                Spacer(minLength: 12)
                breakdown
                SizeBadge(text: totalText, prominent: plan != nil)
                    .help(space.map { L10n.shared.tf("uninstall.space.footprint",
                        ByteFormat.format($0.totalBytes), ByteFormat.format($0.optionalDataBytes)) } ?? "")
                disclosureButton
                if update?.state == .available {
                    Button(action: onUpdate) {
                        Label(L10n.shared.t(updatingID == SoftwareUpdateService.appKey(app)
                            ? "software.install.working" : "software.install.action"), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
                    .disabled(updatingID != nil || job?.state.isActive == true || job?.state.isPending == true)
                }
                if let job, job.state.isPending || job.state.isActive {
                    HStack(spacing: 5) {
                        UninstallJobStateLabel(job: job, position: queuePosition)
                            .frame(maxWidth: 150, alignment: .leading)
                        if job.state.isPending {
                            Button { onCancel(job) } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(MoleIconButtonStyle(size: 20))
                            .accessibilityLabel(L10n.shared.t("uninstall.queue.cancel"))
                        }
                    }
                } else {
                    Button {
                        onUninstall()
                    } label: {
                        Label(actionTitle, systemImage: actionSymbol)
                    }
                    .buttonStyle(DangerButtonStyle())
                    .controlSize(.small)
                    .disabled(updatingID != nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if isExpanded, let plan {
                Divider().opacity(0.45).padding(.horizontal, 12)
                UninstallFileDrawer(files: plan.files, selection: $dataSelection,
                                    selectable: job.map { !($0.state.isPending || $0.state.isActive) } ?? true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .transition(.molePanelReveal)
            }
        }
        .clipped()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface2))
    }

    private var appIcon: some View {
        UninstallAppIcon(path: app.path, identity: app.appIdentity + app.infoIdentity, size: 34)
    }

    private var appIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(app.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if app.source == "Homebrew" {
                    Text("Brew")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.moleOnAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accent.opacity(0.85)))
                }
            }
            Text(app.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            SoftwareUpdateBadge(result: update, isChecking: isCheckingUpdate, showsInstalled: true, externalPending: externalPending)
            if let job, job.state == .failed {
                UninstallJobStateLabel(job: job, position: queuePosition)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var breakdown: some View {
        HStack(spacing: 14) {
            BreakdownValue(symbol: "app.fill", label: L10n.shared.t("file.app"),
                           bytes: space?.appBytes)
            BreakdownValue(symbol: "sparkles", label: L10n.shared.t("uninstall.space.cache"),
                           bytes: space?.cacheBytes, accented: true)
            BreakdownValue(symbol: "archivebox.fill",
                           label: L10n.shared.t("uninstall.space.data"),
                           bytes: space.map { $0.dataBytes &+ $0.optionalDataBytes })
        }
        .frame(width: 270)
    }

    private var disclosureButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : MoleMotion.panel) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: "chevron.down")
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .buttonStyle(MoleIconButtonStyle(isActive: isExpanded, size: 24))
        .disabled(plan == nil)
        .opacity(plan == nil ? 0.25 : 1)
    }
}

/// Inline progress stays with the app and the current operation status.
private struct UninstallJobStateLabel: View {
    let job: UninstallJob
    let position: Int?

    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 4) {
            stateIcon
            Text(stateText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(stateColor)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch job.state {
        case .queued:
            Image(systemName: "clock")
        case .preparing, .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var stateText: String {
        switch job.state {
        case .queued:
            if let position {
                return l10n.tf("uninstall.queue.waiting", position)
            }
            return l10n.t("uninstall.queue.queued")
        case .preparing:
            return l10n.t("uninstall.queue.preparing")
        case .running:
            return l10n.t("uninstall.queue.running")
        case .succeeded:
            return l10n.t("uninstall.queue.succeeded")
        case .failed:
            return l10n.t("uninstall.queue.failed")
        }
    }

    private var stateColor: Color {
        switch job.state {
        case .queued: return .secondary
        case .preparing, .running: return Color.moleAccentText
        case .succeeded: return Color.success
        case .failed: return Color.warning
        }
    }
}

/// Shared asynchronous app icon loader. `NSWorkspace` can be relatively
/// expensive for large lists, so it runs at utility priority and keeps the
/// placeholder stable until the image is ready.
private struct UninstallAppIcon: View {
    let path: String
    let identity: String
    let size: CGFloat

    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.fill")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .task(id: path + identity, priority: .utility) {
            icon = nil
            guard !Task.isCancelled else { return }
            let image = await UninstallIconLoader.image(path: path, identity: identity)
            guard !Task.isCancelled else { return }
            icon = image
        }
    }
}

private struct BreakdownValue: View {
    let symbol: String
    let label: String
    let bytes: UInt64?
    var accented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(accented ? Color.moleAccentText : Color.secondary)
                .lineLimit(1)
            Text(bytes.map(ByteFormat.format) ?? "—")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(accented ? Color.moleAccentText : Color.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UninstallFileDrawer: View {
    let files: [UninstallFile]
    @Binding var selection: Set<String>
    var selectable = true

    private var dataPaths: [String] { files.filter { $0.isOptionalData }.map(\.path) }

    var body: some View {
        LazyVStack(spacing: 4) {
            if !dataPaths.isEmpty {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { !dataPaths.isEmpty && dataPaths.allSatisfy(selection.contains) },
                        set: { selection = $0 ? Set(dataPaths) : [] })) {
                        Text(L10n.shared.t("uninstall.data.includeAll"))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .disabled(!selectable)
                    Spacer()
                    Text(L10n.shared.t("uninstall.data.hint"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 2)
            }
            ForEach(files) { file in
                let chosen = file.isOptionalData && selection.contains(file.path)
                HStack(spacing: 8) {
                    if file.isOptionalData {
                        Toggle("", isOn: Binding(
                            get: { selection.contains(file.path) },
                            set: { if $0 { selection.insert(file.path) } else { selection.remove(file.path) } }))
                            .toggleStyle(.checkbox)
                            .controlSize(.mini)
                            .labelsHidden()
                            .disabled(!selectable)
                    }
                    Image(systemName: symbol(for: file))
                        .font(.system(size: 10))
                        .foregroundStyle(file.informational
                            ? Color.secondary
                            : (file.isCache ? Color.moleAccentText : Color.moleAccent))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((file.path as NSString).lastPathComponent)
                            .font(.system(size: 10, weight: file.isAppBundle ? .semibold : .regular))
                            .lineLimit(1)
                        Text(file.path)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(file.informational && !chosen
                         ? (file.isOptionalData
                            ? ByteFormat.format(file.bytes) + " · " + L10n.shared.t("uninstall.notDeleted")
                            : L10n.shared.t("uninstall.notDeleted"))
                         : ByteFormat.format(file.bytes))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(file.informational && !chosen ? .tertiary : .secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.surface1.opacity(file.informational && !chosen ? 0.6 : 1)))
                .opacity(file.informational && !chosen ? 0.7 : 1)
            }
        }
    }

    private func symbol(for file: UninstallFile) -> String {
        if file.isCache { return "sparkles" }
        switch file.label {
        case "app": return "app.fill"
        case "system", "diag": return "shield.lefthalf.filled"
        case "review": return "eye"
        case "brew": return "shippingbox.fill"
        default: return "doc.badge.gearshape"
        }
    }
}

/// 软件页「命令行工具」：包管理器安装的工具清单，卸载走对应的包管理器。
private struct CommandLineToolsSection: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @State private var pendingUninstall: CommandLineTool?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if state.isScanningCommandLineTools && !state.commandLineTools.isEmpty {
                    NoriStatusAnimation(mood: .working, size: 24, assetName: "nori-working")
                }
                Text(state.commandLineToolStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { state.scanCommandLineTools(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(MoleIconButtonStyle(size: 22))
                .disabled(state.isScanningCommandLineTools || state.commandLineToolBusyID != nil || state.isCheckingSoftwareUpdates || state.softwareUpdatingID != nil)
                .help(l10n.t("common.rescan"))
                .accessibilityLabel(l10n.t("common.rescan"))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            if state.isScanningCommandLineTools && state.commandLineTools.isEmpty {
                NoriScanActivity(text: l10n.t("cli.status.scanning"), assetName: "nori-apps", quiet: true)
            } else if state.commandLineTools.isEmpty {
                EmptyStateView(symbol: "terminal", title: l10n.t("cli.empty.title"),
                               subtitle: l10n.t("cli.empty.subtitle"))
            } else if state.filteredCommandLineTools.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: l10n.t("uninstall.noMatch.title"),
                               subtitle: l10n.t("uninstall.noMatch.subtitle"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(state.filteredCommandLineTools) { tool in toolRow(tool) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
        .alert(l10n.tf("cli.uninstall.confirm.title", pendingUninstall?.name ?? ""),
               isPresented: Binding(get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } })) {
            Button(l10n.t("common.cancel"), role: .cancel) { pendingUninstall = nil }
            Button(l10n.t("uninstall.action"), role: .destructive) {
                if let tool = pendingUninstall { state.uninstallCommandLineTool(tool) }
                pendingUninstall = nil
            }
        } message: {
            Text(pendingUninstall.map { tool in
                l10n.tf(tool.agentID == nil ? "cli.uninstall.confirm.message" : "cli.uninstall.confirm.agentMessage",
                        tool.installationSource ?? tool.manager.displayName, tool.path)
            } ?? "")
        }
    }

    private func toolRow(_ tool: CommandLineTool) -> some View {
        let busy = state.commandLineToolBusyID == tool.id
        return HStack(spacing: 10) {
            Image(systemName: tool.agentID == nil ? "terminal" : "sparkles.rectangle.stack")
                .font(.system(size: 13))
                .foregroundStyle(Color.moleAccentText)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !tool.version.isEmpty {
                        Text(tool.version).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    DevTag(text: tool.installationSource ?? tool.manager.displayName)
                    if !tool.installedOnRequest {
                        DevTag(text: l10n.t("cli.tag.dependency"))
                    }
                    if !tool.dependents.isEmpty {
                        DevTag(text: l10n.tf("cli.tag.dependents", tool.dependents.count), color: .warning)
                            .help(tool.dependents.joined(separator: ", "))
                    }
                }
                Text(tool.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            SoftwareUpdateBadge(result: state.softwareUpdateResults[SoftwareUpdateService.toolKey(tool)],
                                isChecking: state.softwareUpdateCheckingIDs.contains(SoftwareUpdateService.toolKey(tool)))
            if state.softwareUpdateResults[SoftwareUpdateService.toolKey(tool)]?.state == .available {
                Button { state.updateSoftware(tool) } label: {
                    Label(l10n.t(state.softwareUpdatingID == SoftwareUpdateService.toolKey(tool)
                        ? "software.install.working" : "software.install.action"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
                .disabled(state.isBusy || state.isCheckingSoftwareUpdates || state.isScanningCommandLineTools)
            }
            if tool.agentID != nil {
                Button { state.jump(to: .agents) } label: {
                    Label(l10n.t("cli.agentData"), systemImage: "arrow.up.forward")
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
                .help(l10n.t("cli.agentData.hint"))
            }
            SizeBadge(text: tool.sizeIsKnown ? ByteFormat.format(tool.bytes) : "—", prominent: false)
            if tool.manager == .local && !tool.canUninstall {
                Text(l10n.t("software.tools.readOnly"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else if busy {
                ProgressView().controlSize(.small)
            } else {
                Button { pendingUninstall = tool } label: {
                    Label(l10n.t("uninstall.action"), systemImage: "trash")
                }
                .buttonStyle(DangerButtonStyle())
                .controlSize(.small)
                .disabled(!tool.canUninstall || state.isBusy || state.commandLineToolBusyID != nil)
                .help(tool.canUninstall ? "" : l10n.tf("cli.tag.dependents", tool.dependents.count))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface2))
    }
}
