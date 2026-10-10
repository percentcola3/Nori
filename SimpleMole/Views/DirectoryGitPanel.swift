import SwiftUI

struct DirectoryGitPanel: View {
    let url: URL
    @ObservedObject var model: DirectoryBrowserModel
    let onClose: () -> Void
    @ObservedObject private var l10n = L10n.shared
    @State private var snapshot: DirectoryGitSnapshot?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isMutating = false
    @State private var refreshID = UUID()

    private struct ReadRequest: Hashable {
        let url: URL
        let refreshID: UUID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(l10n.t("dir.git.repository"), systemImage: "arrow.triangle.branch")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(MoleIconButtonStyle(size: 26))
                    .keyboardShortcut(.cancelAction)
                    .help(l10n.t("dir.git.close"))
                    .accessibilityLabel(l10n.t("dir.git.close"))
            }
            Text(url.path)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                .help(url.path)
            Rectangle().fill(Color.hairline).frame(height: 1)
            if let snapshot {
                controls(snapshot)
                repositoryStatus(snapshot)
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(l10n.t("dir.git.loading")).foregroundStyle(.secondary)
                }
                .frame(height: 32)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11)).foregroundStyle(Color.warning)
                    .lineLimit(5).textSelection(.enabled)
                    .help(errorMessage)
            }
            if snapshot == nil, !isLoading {
                HStack {
                    Spacer()
                    Button { refreshID = UUID() } label: {
                        Label(l10n.t("dir.git.refresh"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .font(.system(size: 12))
        .task(id: ReadRequest(url: url, refreshID: refreshID)) { await readSnapshot() }
        .accessibilityIdentifier("directory-git-panel")
    }

    private func controls(_ repository: DirectoryGitSnapshot) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(repository.branches, id: \.self) { branch in
                    Button { mutate(branch: branch, repository: repository) } label: {
                        if branch == repository.branch {
                            Label(branch, systemImage: "checkmark")
                        } else if repository.occupiedBranches.contains(branch) {
                            Label(l10n.tf("dir.git.occupiedBranch", branch), systemImage: "lock")
                        } else {
                            Text(branch)
                        }
                    }
                    .disabled(branch == repository.branch || repository.occupiedBranches.contains(branch))
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(repository.branch ?? String(repository.head.prefix(8)))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .disabled(operationsDisabled(repository) || repository.branches.isEmpty)
            .help(repository.branch ?? l10n.t("dir.git.detached"))
            .accessibilityLabel(l10n.t("dir.git.switch"))
            .accessibilityValue(repository.branch ?? repository.head)
            .accessibilityIdentifier("directory-git-branches")

            Button { mutate(branch: nil, repository: repository) } label: {
                if isMutating {
                    ProgressView().controlSize(.mini).scaleEffect(0.65)
                } else {
                    Image(systemName: "arrow.down")
                }
            }
            .buttonStyle(MoleIconButtonStyle(size: 30))
            .disabled(operationsDisabled(repository) || repository.branch == nil || repository.upstream == nil)
            .help(l10n.t("dir.git.pull"))
            .accessibilityLabel(l10n.t("dir.git.pull"))
            .accessibilityIdentifier("directory-git-pull")

            Button { refreshID = UUID() } label: {
                if isLoading { ProgressView().controlSize(.mini).scaleEffect(0.65) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(MoleIconButtonStyle(size: 30))
            .disabled(isLoading || isMutating || model.isWorking)
            .help(l10n.t("dir.git.refresh"))
            .accessibilityLabel(l10n.t("dir.git.refresh"))
        }
    }

    @ViewBuilder private func repositoryStatus(_ repository: DirectoryGitSnapshot) -> some View {
        if isMutating {
            Text(l10n.t("dir.git.working")).foregroundStyle(.secondary)
        } else if repository.operationInProgress {
            Text(l10n.t("dir.git.operationInProgress")).foregroundStyle(Color.warning)
        } else if repository.isDirty {
            Text(l10n.t("dir.git.dirty")).foregroundStyle(Color.warning)
        } else if repository.branch == nil {
            Text(l10n.t("dir.git.detached")).foregroundStyle(.secondary)
        } else if repository.upstream == nil {
            Text(l10n.t("dir.git.noUpstream")).foregroundStyle(.secondary)
        }
        if let upstream = repository.upstream {
            Text(l10n.tf("dir.git.upstream", upstream))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(upstream)
        }
    }

    private func operationsDisabled(_ repository: DirectoryGitSnapshot) -> Bool {
        isLoading || isMutating || model.isWorking || repository.isDirty || repository.operationInProgress
    }

    @MainActor private func readSnapshot() async {
        isLoading = true
        errorMessage = nil
        if snapshot?.root != url { snapshot = nil }
        let requestReader = DirectoryGitService()
        do {
            let value = try await withTaskCancellationHandler {
                try await requestReader.snapshot(at: url)
            } onCancel: {
                requestReader.cancel()
            }
            guard !Task.isCancelled else { return }
            snapshot = value
        } catch {
            guard !Task.isCancelled else { return }
            snapshot = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func mutate(branch: String?, repository: DirectoryGitSnapshot) {
        guard !operationsDisabled(repository), model.beginGitOperation() else { return }
        isMutating = true
        errorMessage = nil
        let root = repository.root
        // A user-started Git operation finishes even when this panel is closed.
        Task { @MainActor [model] in
            let writer = DirectoryGitService()
            var failure: String?
            do {
                if let branch { try await writer.switchBranch(branch, at: root) }
                else { try await writer.pull(at: root) }
            } catch {
                failure = error.localizedDescription
            }
            model.finishGitOperation(at: root, error: failure)
            errorMessage = failure
            do { snapshot = try await writer.snapshot(at: root) }
            catch { snapshot = nil; errorMessage = failure ?? error.localizedDescription }
            isMutating = false
        }
    }
}
