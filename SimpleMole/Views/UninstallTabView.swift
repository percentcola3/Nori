import AppKit
import SwiftUI

/// Single-level app uninstaller. The row owns its optional file drawer; the
/// uninstall action goes straight into the serialized background queue and
/// never navigates away or opens an app-level confirmation dialog.
struct UninstallTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isListPresented = false
    @State private var showsResultDetails = false

    private var isActive: Bool {
        let pages = state.visiblePages
        return pages.indices.contains(state.selectedTab) && pages[state.selectedTab] == .uninstall
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            statusRow
            content
        }
        .animation(reduceMotion ? nil : MoleMotion.panel,
                   value: state.uninstallQueue.jobs)
        // 扫描中 → 应用列表/空态/无匹配 的整块互换走弹簧过渡。
        .animation(reduceMotion ? nil : MoleMotion.panel, value: isListPresented)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: state.isScanningApps)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: state.installedApps.isEmpty)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: state.filteredApps.isEmpty)
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

    /// 搜索与扫描共用一行：搜索框占满剩余宽度，扫描按钮固定在行尾。
    private var toolbar: some View {
        HStack(spacing: 8) {
            searchField
            Button { state.scanInstalledApps() } label: {
                Label(state.isScanningApps
                      ? l10n.t("common.scanning")
                      : l10n.t("uninstall.scan"),
                      systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.uninstallQueue.hasWork || state.isScanningApps)
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
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.separator.opacity(0.4), lineWidth: 1))
    }

    // One status line follows the current operation; no separate task list.
    private var statusJob: UninstallJob? {
        if state.isScanningApps && !state.uninstallQueue.hasWork { return nil }
        return state.uninstallQueue.activeJob
            ?? state.uninstallQueue.jobs.first { $0.state.isPending }
            ?? state.uninstallQueue.jobs.last { job in
                job.state == .failed
                    || (job.state == .succeeded && job.message?.contains("\n") == true)
            }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if let job = statusJob {
                if job.state.isActive || job.state.isPending {
                    NoriStatusAnimation(mood: .working, size: 64, assetName: "nori-uninstalling")
                        .id(job.id)
                } else if job.state == .failed {
                    NoriStatusAnimation(mood: .attention, size: 44)
                        .id(job.id)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.message?.components(separatedBy: "\n").first ?? job.app.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    UninstallJobStateLabel(job: job,
                                           position: state.uninstallQueuePosition(for: job.app))
                }
                if job.state.isFinished, let message = job.message {
                    Button { showsResultDetails.toggle() } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(MoleIconButtonStyle(size: 22))
                    .accessibilityLabel(l10n.t("uninstall.resultDetails"))
                    .popover(isPresented: $showsResultDetails) {
                        ScrollView {
                            Text(message)
                                .font(.system(size: 11))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        }
                        .frame(width: 480, height: 220)
                    }
                }
            } else {
                if state.isScanningApps && !state.installedApps.isEmpty {
                    NoriStatusAnimation(mood: .working, size: 64)
                }
                Text(state.appListStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onChange(of: statusJob?.id) { _ in showsResultDetails = false }
    }

    @ViewBuilder
    private var content: some View {
        if !isListPresented || state.isRestoringInstalledApps
            || (!state.installedApps.isEmpty && state.filteredApps.isEmpty
                && state.uninstallSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(l10n.t("uninstall.loading"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(reduceMotion ? .opacity : .moleStateSwap)
        } else if state.isScanningApps && state.installedApps.isEmpty {
            NoriScanActivity(text: state.appListStatus)
                .transition(reduceMotion ? .opacity : .moleStateSwap)
        } else if state.installedApps.isEmpty {
            EmptyStateView(
                symbol: "app.dashed",
                title: state.isScanningApps
                    ? l10n.t("uninstall.status.scanning")
                    : l10n.t("uninstall.status.none"),
                subtitle: state.isScanningApps ? nil : l10n.t("uninstall.empty.subtitle"))
            .transition(reduceMotion ? .opacity : .moleStateSwap)
        } else if state.filteredApps.isEmpty {
            EmptyStateView(symbol: "magnifyingglass",
                           title: l10n.t("uninstall.noMatch.title"),
                           subtitle: l10n.t("uninstall.noMatch.subtitle"))
            .transition(reduceMotion ? .opacity : .moleStateSwap)
        } else {
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(state.filteredApps) { app in
                        UninstallAppRow(
                            app: app,
                            plan: state.uninstallPlan(for: app),
                            job: state.uninstallJob(for: app),
                            queuePosition: state.uninstallQueuePosition(for: app),
                            onCancel: { job in state.cancelQueuedUninstall(id: job.id) },
                            onUninstall: { state.previewUninstall(app) })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .transition(reduceMotion ? .opacity : .moleStateSwap)
        }
    }
}

private struct UninstallAppRow: View {
    let app: UninstallApp
    let plan: UninstallPlan?
    let job: UninstallJob?
    let queuePosition: Int?
    let onCancel: (UninstallJob) -> Void
    let onUninstall: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    private var space: UninstallSpaceBreakdown? { plan?.space }
    private var totalText: String {
        space.map { ByteFormat.format($0.totalBytes) } ?? app.size
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
                disclosureButton
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
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if isExpanded, let plan {
                Divider().opacity(0.45).padding(.horizontal, 12)
                UninstallFileDrawer(files: plan.files)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .transition(.molePanelReveal)
            }
        }
        .clipped()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(.separator.opacity(0.35), lineWidth: 1))
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
                           bytes: space?.dataBytes)
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

    var body: some View {
        LazyVStack(spacing: 4) {
            ForEach(files) { file in
                HStack(spacing: 8) {
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
                    Text(file.informational
                         ? L10n.shared.t("uninstall.notDeleted")
                         : ByteFormat.format(file.bytes))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(file.informational ? .tertiary : .secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.surface1.opacity(file.informational ? 0.6 : 1)))
                .opacity(file.informational ? 0.7 : 1)
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
