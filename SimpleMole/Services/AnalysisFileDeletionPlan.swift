import Darwin
import Foundation

/// Bind a confirmed selection to the cached scan objects and to their current
/// identities before launching work. A replaced file requires a fresh scan.
struct AnalysisFileDeletionPlan {
    let items: [DeletionPlan.Item]
    let refusedCount: Int
    private let fingerprints: [String: AnalysisFileFingerprint]
    private let allowsDirectories: Bool

    init(requestedPaths: [String], inventoryPaths: Set<String>,
         scanFingerprints: [String: AnalysisFileFingerprint]? = nil,
         allowsDirectories: Bool = false) {
        self.allowsDirectories = allowsDirectories
        var planned: [DeletionPlan.Item] = []
        var captured: [String: AnalysisFileFingerprint] = [:]
        var refused = 0
        for path in Set(requestedPaths).sorted() {
            guard inventoryPaths.contains(path), Self.isPhysicalItem(path, allowsDirectories: allowsDirectories),
                  let fingerprint = AnalysisFileFingerprint.read(path),
                  scanFingerprints == nil || scanFingerprints?[path] == fingerprint,
                  let identity = DeletionPlan.identity(at: path) else {
                refused += 1
                continue
            }
            planned.append(DeletionPlan.Item(record: path, identity: identity, metadata: DeletionPlan.Metadata.read(path)))
            captured[path] = fingerprint
        }
        items = planned
        refusedCount = refused
        fingerprints = captured
    }

    static func requiresPermanentDeletion(paths: [String], homeDirectory: String = NSHomeDirectory()) -> Bool {
        paths.contains { CleanupRiskPolicy.core(section: "Cache", path: $0,
            homeDirectory: homeDirectory).risk == .safe }
    }

    static func isEligible(path: String, homeDirectory: String = NSHomeDirectory(),
                           allowsDirectories: Bool = false) -> Bool {
        guard isPhysicalItem(path, allowsDirectories: allowsDirectories) else { return false }
        if MediaSlimPolicy.isEligible(path, home: homeDirectory) {
            // Check directory packages as ancestors as well, so an application
            // or library bundle is not offered as an ordinary personal folder.
            return AnalysisFileFingerprint.read(path)?.isDirectory != true
                || MediaSlimPolicy.isEligible(path + "/nori-directory-entry", home: homeDirectory)
        }
        let policy = CleanupRiskPolicy.core(section: "Cache", path: path, homeDirectory: homeDirectory)
        guard policy.risk == .safe && policy.disposal == .permanentDelete,
              !CleanupRiskPolicy.isProtectedCleanupPath(path, homeDirectory: homeDirectory,
                rebuildableRoot: CleanupRiskPolicy.auditedRebuildableRoot(containing: path, homeDirectory: homeDirectory) ?? path,
                rootIsVerifiedRebuildable: CleanupRiskPolicy.auditedRebuildableRoot(containing: path, homeDirectory: homeDirectory) != nil)
            else { return false }
        var metadata = stat(), account = stat()
        guard lstat(path, &metadata) == 0, lstat(homeDirectory, &account) == 0 else { return false }
        guard CleanupRiskPolicy.systemCleanupAccountScopeEligible(path: path, homeDirectory: homeDirectory) else { return false }
        return CleanupRiskPolicy.systemCleanupMetadataEligible(path: path,
            ownerUID: metadata.st_uid, userUID: account.st_uid,
            modified: Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)),
            accessed: Date(timeIntervalSince1970: TimeInterval(metadata.st_atimespec.tv_sec)),
            homeDirectory: homeDirectory)
    }

    private struct Groups {
        var trash: [DeletionPlan.Item] = []
        var permanent: [DeletionPlan.Item] = []
        var administrator: [DeletionPlan.Item] = []
        var refused = 0
    }

    private func groups(homeDirectory: String) -> Groups {
        var groups = Groups(refused: refusedCount)
        for item in items {
            guard Self.isEligible(path: item.record, homeDirectory: homeDirectory, allowsDirectories: allowsDirectories),
                  DeletionPlan.identity(at: item.record) == item.identity,
                  AnalysisFileFingerprint.read(item.record) == fingerprints[item.record] else {
                groups.refused += 1
                continue
            }
            let policy = CleanupRiskPolicy.core(section: "Cache", path: item.record, homeDirectory: homeDirectory)
            if policy.risk == .safe && policy.disposal == .permanentDelete {
                if NativeCore.shared.requiresAdministratorDeletion(item.record, homeDirectory: homeDirectory) {
                    groups.administrator.append(item)
                } else { groups.permanent.append(item) }
            } else { groups.trash.append(item) }
        }
        return groups
    }

    func execute(homeDirectory: String = NSHomeDirectory()) -> NativeCore.ApplySummary {
        let groups = groups(homeDirectory: homeDirectory)
        var result = executeUser(groups, homeDirectory: homeDirectory)
        // Synchronous callers cannot trigger the privileged UI. The app uses
        // executeWithAdministrator and submits exactly these bound records.
        if !groups.administrator.isEmpty {
            result = NativeCore.ApplySummary(removed: result.removed,
                skipped: result.skipped + groups.administrator.count, failed: result.failed,
                messages: result.messages + ["Administrator authentication is required for selected system caches."],
                removedPaths: result.removedPaths, reclaimedBytes: result.reclaimedBytes)
        }
        return result
    }

    func executeWithAdministrator(homeDirectory: String = NSHomeDirectory(),
        administratorApply: ([DeletionPlan.Item]) async -> CleanupExecutionResult) async -> NativeCore.ApplySummary {
        let (selectedGroups, userResult) = await Task.detached(priority: .utility) {
            let selectedGroups = self.groups(homeDirectory: homeDirectory)
            return (selectedGroups, executeUser(selectedGroups, homeDirectory: homeDirectory))
        }.value
        guard !selectedGroups.administrator.isEmpty else { return userResult }
        let privileged = await administratorApply(selectedGroups.administrator)
        return NativeCore.ApplySummary(removed: userResult.removed + privileged.removed,
            skipped: userResult.skipped + privileged.skipped,
            failed: userResult.failed + privileged.failed + (privileged.executionFailed && privileged.failed == 0 ? 1 : 0),
            messages: userResult.messages + privileged.messages,
            removedPaths: userResult.removedPaths.union(privileged.removedPaths),
            reclaimedBytes: userResult.reclaimedBytes &+ privileged.reclaimedBytes)
    }

    private func executeUser(_ groups: Groups, homeDirectory: String) -> NativeCore.ApplySummary {
        let identities = Dictionary(items.map { ($0.record, $0.identity) },
                                    uniquingKeysWith: { first, _ in first })
        let confirmedFingerprints = fingerprints
        let finalValidation: (String) -> Bool = { path in
            Self.isEligible(path: path, homeDirectory: homeDirectory, allowsDirectories: allowsDirectories)
                && DeletionPlan.identity(at: path) == identities[path]
                && AnalysisFileFingerprint.read(path) == confirmedFingerprints[path]
        }
        let trash = NativeCore.shared.applyCleanup(items: groups.trash, permanent: false,
            homeDirectory: homeDirectory,
            allowedRoots: groups.trash.map(\.record).filter {
                $0.hasPrefix("/Volumes/") && MediaSlimPolicy.isEligible($0, home: homeDirectory)
            }, finalValidation: finalValidation)
        let permanent = NativeCore.shared.applyCleanup(items: groups.permanent, permanent: true,
            homeDirectory: homeDirectory, liveCleanupTargets: Set(groups.permanent.map(\.record)),
            finalValidation: finalValidation)
        return NativeCore.ApplySummary(removed: trash.removed + permanent.removed,
            skipped: trash.skipped + permanent.skipped + groups.refused,
            failed: trash.failed + permanent.failed, messages: trash.messages + permanent.messages,
            removedPaths: trash.removedPaths.union(permanent.removedPaths),
            reclaimedBytes: permanent.reclaimedBytes)
    }

    private static func isPhysicalItem(_ path: String, allowsDirectories: Bool) -> Bool {
        guard DeletionPlan.isLexicallySafePath(path) else { return false }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return false }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return false }
        for name in parts.dropLast() {
            let next = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            close(parent)
            parent = next
            guard parent >= 0 else { return false }
        }
        defer { close(parent) }
        var metadata = stat()
        guard fstatat(parent, parts.last!, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        let kind = metadata.st_mode & S_IFMT
        return kind == S_IFREG || (allowsDirectories && kind == S_IFDIR)
    }
}
