import AppKit
import SwiftUI

/// The familiar Git diamond is distinct from a generic branching arrow.
struct GitRepositoryIcon: View {
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.08)
                .fill(Color.accentText)
                .frame(width: size * 0.72, height: size * 0.72)
                .rotationEffect(.degrees(45))
            Path { path in
                path.move(to: CGPoint(x: size * 0.32, y: size * 0.19))
                path.addLine(to: CGPoint(x: size * 0.64, y: size * 0.51))
                path.move(to: CGPoint(x: size * 0.41, y: size * 0.28))
                path.addLine(to: CGPoint(x: size * 0.41, y: size * 0.73))
            }
            .stroke(Color.onAccent, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round, lineJoin: .round))
            Path { path in
                for point in [CGPoint(x: 0.41, y: 0.28), CGPoint(x: 0.64, y: 0.51), CGPoint(x: 0.41, y: 0.73)] {
                    path.addEllipse(in: CGRect(x: size * (point.x - 0.075), y: size * (point.y - 0.075),
                        width: size * 0.15, height: size * 0.15))
                }
            }
            .fill(Color.onAccent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct DirectoryGitRowControls: View {
    let url: URL
    @ObservedObject var model: DirectoryBrowserModel
    @ObservedObject private var l10n = L10n.shared
    @State private var snapshot: DirectoryGitSnapshot?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isMutating = false
    @State private var refreshID = UUID()
    @State private var readTicket = UUID()

    private struct ReadRequest: Hashable {
        let url: URL
        let revision: Int
        let refreshID: UUID
    }

    var body: some View {
        HStack(spacing: 6) {
            if let snapshot {
                branches(snapshot)
                syncButton(snapshot)
            } else if isLoading {
                ProgressView().controlSize(.mini).scaleEffect(0.65)
                    .frame(width: 12, height: 12)
                Text("Git…").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Button { refreshID = UUID() } label: {
                    Label(l10n.t("dir.git.statusUnavailable"), systemImage: "exclamationmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.warning)
                .help(errorMessage ?? l10n.t("dir.git.refresh"))
            }
        }
        .font(.system(size: 10))
        .frame(height: 28)
        .task(id: ReadRequest(url: url, revision: model.gitStatusRevision, refreshID: refreshID)) {
            await readSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshID = UUID()
        }
    }

    private func branches(_ repository: DirectoryGitSnapshot) -> some View {
        Menu {
            if let upstream = repository.upstream {
                Text(l10n.tf("dir.git.upstream", upstream))
                Text(l10n.tf("dir.git.syncCounts", repository.aheadCount, repository.behindCount))
            }
            if repository.isDirty { Text(l10n.t("dir.git.dirty")) }
            if repository.operationInProgress { Text(l10n.t("dir.git.operationInProgress")) }
            Divider()
            ForEach(repository.branches, id: \.self) { branch in
                Button { mutate(branch: branch, repository: repository) } label: {
                    if branch == repository.branch { Label(branch, systemImage: "checkmark") }
                    else if repository.occupiedBranches.contains(branch) {
                        Label(l10n.tf("dir.git.occupiedBranch", branch), systemImage: "lock")
                    } else { Text(branch) }
                }
                .disabled(operationsDisabled(repository) || branch == repository.branch
                    || repository.occupiedBranches.contains(branch))
            }
            Divider()
            Button(l10n.t("dir.git.refresh")) { refreshID = UUID() }
        } label: {
            HStack(spacing: 4) {
                if repository.isDirty || repository.operationInProgress {
                    Circle().fill(Color.warning).frame(width: 5, height: 5)
                }
                Text(repository.branch ?? String(repository.head.prefix(8)))
                    .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .disabled(isLoading || isMutating || model.isWorking)
        .foregroundStyle(Color.accentText)
        .help(repository.branch ?? l10n.t("dir.git.detached"))
        .accessibilityLabel(l10n.t("dir.git.switch"))
        .accessibilityValue(repository.branch ?? repository.head)
        .accessibilityIdentifier("directory-row-git-branches-" + url.path)
    }

    private func syncButton(_ repository: DirectoryGitSnapshot) -> some View {
        Button { mutate(branch: nil, repository: repository) } label: {
            HStack(spacing: 3) {
                if isMutating { ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 11, height: 11) }
                else { Image(systemName: "arrow.down.circle") }
                Text(l10n.t("dir.git.sync"))
                if repository.behindCount > 0 { Text("↓\(repository.behindCount)").monospacedDigit() }
                if repository.aheadCount > 0 { Text("↑\(repository.aheadCount)").monospacedDigit() }
            }
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.surface2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(operationsDisabled(repository) || repository.branch == nil || repository.upstream == nil)
        .help(syncHelp(repository))
        .accessibilityLabel(l10n.t("dir.git.pull"))
        .accessibilityIdentifier("directory-row-git-sync-" + url.path)
    }

    private func syncHelp(_ repository: DirectoryGitSnapshot) -> String {
        if repository.operationInProgress { return l10n.t("dir.git.operationInProgress") }
        if repository.isDirty { return l10n.t("dir.git.dirty") }
        if repository.branch == nil { return l10n.t("dir.git.detached") }
        guard let upstream = repository.upstream else { return l10n.t("dir.git.noUpstream") }
        return [l10n.t("dir.git.pull"), l10n.tf("dir.git.upstream", upstream),
                l10n.tf("dir.git.syncCounts", repository.aheadCount, repository.behindCount),
                l10n.t("dir.git.cachedStatus")].joined(separator: "\n")
    }

    private func operationsDisabled(_ repository: DirectoryGitSnapshot) -> Bool {
        isLoading || isMutating || model.isWorking || repository.isDirty || repository.operationInProgress
    }

    @MainActor private func readSnapshot() async {
        let ticket = UUID()
        readTicket = ticket
        isLoading = true
        errorMessage = nil
        defer { if readTicket == ticket { isLoading = false } }
        do {
            let value = try await DirectoryGitReadQueue.shared.snapshot(at: url)
            guard !Task.isCancelled, readTicket == ticket else { return }
            snapshot = value
        } catch {
            guard !Task.isCancelled, readTicket == ticket else { return }
            snapshot = nil
            errorMessage = error.localizedDescription
        }
    }

    private func mutate(branch: String?, repository: DirectoryGitSnapshot) {
        guard !operationsDisabled(repository), model.beginGitOperation() else { return }
        isMutating = true
        Task { @MainActor [model] in
            let writer = DirectoryGitService()
            var failure: String?
            do {
                if let branch { try await writer.switchBranch(branch, at: repository.root) }
                else { try await writer.pull(at: repository.root) }
            } catch { failure = error.localizedDescription }
            isMutating = false
            model.finishGitOperation(at: repository.root, error: failure)
        }
    }
}
