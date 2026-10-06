import Combine
import Foundation

enum DuplicateMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case exact, similarImages
    var id: String { rawValue }
}

struct DuplicateImageInfo: Codable, Sendable {
    let width: Int
    let height: Int
    let sharpness: Double
}

struct DuplicateFileRecord: Identifiable, Codable, Sendable {
    let file: DuplicateFile
    var imageInfo: DuplicateImageInfo? = nil
    var id: String { file.path }
    var path: String { file.path }
    var name: String { file.name }
    var size: UInt64 { file.size }
}

struct DuplicateFileGroup: Identifiable, Codable, Sendable {
    let id: String
    let members: [DuplicateFileRecord]
    var kind: DuplicateMode = .exact

    init(id: String, members: [DuplicateFileRecord], kind: DuplicateMode = .exact) {
        self.id = id
        self.members = members
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        members = try container.decode([DuplicateFileRecord].self, forKey: .members)
        kind = try container.decodeIfPresent(DuplicateMode.self, forKey: .kind) ?? .exact
    }
}

/// The scanner and the potentially large presentation mapping share one background job.
struct DuplicateScanSnapshot: Codable, Sendable {
    let groups: [DuplicateFileGroup]
    let roots: [String]
    let scanned: Int
    let skipped: Int
    let partial: Bool
    let cancelled: Bool
    let error: String?
    let exactCopiesSkipped: Int
    let reclaimableBytes: UInt64
    let defaultSelection: Set<String>
    var scannedPaths: Set<String> = []

    /// Patch known mutations without traversing the home folder again. Changed
    /// files leave their old groups until the next explicit or automatic scan.
    func refreshing(removedPaths: Set<String>, changedPaths: Set<String>) -> DuplicateScanSnapshot {
        let invalidPaths = removedPaths.union(changedPaths)
        let remainingGroups = groups.compactMap { group -> DuplicateFileGroup? in
            let members = group.members.filter { !DuplicatePathMutation.contains($0.path, in: invalidPaths) }
            return members.count > 1 ? DuplicateFileGroup(id: group.id, members: members, kind: group.kind) : nil
        }
        let remainingScannedPaths = scannedPaths.filter { !DuplicatePathMutation.contains($0, in: removedPaths) }
        let removedCount = scannedPaths.count - remainingScannedPaths.count
        let remainingPaths = Set(remainingGroups.flatMap { $0.members.map(\.path) })
        return DuplicateScanSnapshot(groups: remainingGroups, roots: roots, scanned: max(0, scanned - removedCount),
            skipped: skipped, partial: partial, cancelled: cancelled, error: error,
            exactCopiesSkipped: exactCopiesSkipped,
            reclaimableBytes: reclaimableBytes == 0 ? 0
                : remainingGroups.filter { $0.kind == .exact }
                    .reduce(0) { $0 + $1.members.dropFirst().reduce(0) { $0 + $1.size } },
            defaultSelection: defaultSelection.intersection(remainingPaths), scannedPaths: remainingScannedPaths)
    }
}

struct DuplicateCachedResult: Codable, Sendable {
    var snapshot: DuplicateScanSnapshot
    var selection: Set<String>
    var status: String
    var coverage: String
    let scannedAt: Date
}

/// Result lists, selections and verified fingerprints survive app restarts.
/// Atomic writes are serialized and debounced off the main thread.
final class DuplicateWorkspaceStore: @unchecked Sendable {
    private struct Archive: Codable {
        let version: Int
        let home: String
        let results: [DuplicateMode: DuplicateCachedResult]
        let content: Data
        let features: Data
    }

    private let fileURL: URL
    private let home: String
    private let queue = DispatchQueue(label: "com.nori.duplicate-cache", qos: .utility)
    private let lock = NSLock()
    private var pendingWrite: DispatchWorkItem?
    private var pendingOperation: (@Sendable () -> Void)?
    private var revision: UInt64 = 0

    var currentRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    func noteMutation() {
        lock.lock()
        revision &+= 1
        lock.unlock()
    }

    init(directory: URL? = nil, home: String = NSHomeDirectory()) {
        self.home = URL(fileURLWithPath: home).standardized.path
        fileURL = (directory ?? URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Nori/Analysis"))
            .appendingPathComponent("duplicates.plist")
    }

    func load(contentCache: DuplicateContentCache,
              featureCache: SimilarImageFeatureCache) -> [DuplicateMode: DuplicateCachedResult] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let bytes = attributes[.size] as? NSNumber, bytes.uint64Value <= 96 * 1_024 * 1_024,
              let data = try? Data(contentsOf: fileURL),
              let archive = try? PropertyListDecoder().decode(Archive.self, from: data),
              archive.version == 1, archive.home == home else { return [:] }
        contentCache.restore(from: archive.content)
        featureCache.restore(from: archive.features)
        return archive.results.filter { _, result in
            !result.snapshot.cancelled && result.snapshot.error == nil
                && result.snapshot.roots.allSatisfy { $0 == home || $0.hasPrefix(home + "/") || $0.hasPrefix("/Volumes/") }
        }
    }

    func save(_ results: [DuplicateMode: DuplicateCachedResult], contentCache: DuplicateContentCache,
              featureCache: SimilarImageFeatureCache) {
        let operation: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard let content = try? contentCache.encodedData(),
                  let features = try? featureCache.encodedData() else { return }
            let archive = Archive(version: 1, home: home, results: results, content: content, features: features)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(archive) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
        let write = DispatchWorkItem(block: operation)
        lock.lock()
        pendingWrite?.cancel()
        pendingWrite = write
        pendingOperation = operation
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.2, execute: write)
    }

    /// The cleanup pipeline deleted the workspace file. Queued writes are
    /// cancelled and the removal is queued behind any in-flight write, so a
    /// debounced persist cannot recreate the archive afterwards.
    func discardPendingWrites() {
        lock.lock()
        let write = pendingWrite
        pendingWrite = nil
        pendingOperation = nil
        write?.cancel()
        lock.unlock()
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
        noteMutation()
    }

    /// Test and shutdown callers can await durable storage without waiting on the UI actor.
    func flush() {
        lock.lock()
        let write = pendingWrite
        let operation = pendingOperation
        pendingWrite = nil
        pendingOperation = nil
        write?.cancel()
        lock.unlock()
        queue.sync { operation?() }
    }
}

enum DuplicateScanWorker {
    static func scan(mode: DuplicateMode, roots: [String], control: DuplicateScanControl,
                     home: String = NSHomeDirectory(),
                     contentCache: DuplicateContentCache? = nil,
                     featureCache: SimilarImageFeatureCache? = nil,
                     progress: ((DuplicateScanProgress) -> Void)? = nil) -> DuplicateScanSnapshot {
        switch mode {
        case .exact:
            let result = DuplicateScanner.scan(roots: roots, control: control, home: home,
                                               cache: contentCache, progress: progress)
            let cancelled = result.cancelled || control.isCancelled
            let groups: [DuplicateFileGroup] = cancelled ? [] : result.groups.map { group in
                DuplicateFileGroup(id: group.id, members: group.files.map { DuplicateFileRecord(file: $0) })
            }
            return DuplicateScanSnapshot(
                groups: groups, roots: result.roots, scanned: result.files.count, skipped: result.skippedFiles,
                partial: result.isPartial, cancelled: cancelled, error: result.error,
                exactCopiesSkipped: 0,
                reclaimableBytes: cancelled ? 0 : result.groups.reduce(0) { $0 + $1.reclaimableBytes },
                defaultSelection: cancelled || result.error != nil ? []
                    : DuplicateSelectionPolicy.defaultSelection(groups: groups, mode: .exact),
                scannedPaths: Set(result.files.map(\.path)))
        case .similarImages:
            let result = SimilarImageScanner.scan(roots: roots, control: control, home: home,
                contentCache: contentCache, featureCache: featureCache, progress: progress)
            let cancelled = result.cancelled || control.isCancelled
            return DuplicateScanSnapshot(
                groups: cancelled ? [] : result.groups.map { group in
                    DuplicateFileGroup(id: group.id, members: group.files.map { image in
                        DuplicateFileRecord(file: image.file,
                            imageInfo: DuplicateImageInfo(width: image.pixelWidth,
                                height: image.pixelHeight, sharpness: image.sharpnessScore))
                    }, kind: .similarImages)
                }, roots: result.roots, scanned: result.scannedFiles, skipped: result.skippedFiles,
                partial: result.isPartial, cancelled: cancelled, error: result.error,
                exactCopiesSkipped: result.exactCopiesSkipped, reclaimableBytes: 0,
                defaultSelection: [], scannedPaths: result.scannedPaths)
        }
    }
}

extension DuplicateScanWorker {
    /// 一次查重：先完全重复，再相似图片，合并为一份清单。已在完全重复组里的
    /// 文件不再进入相似组，任一路径只属于一个组，保留规则互不干扰。
    static func scanAll(roots: [String], control: DuplicateScanControl,
                        home: String = NSHomeDirectory(),
                        contentCache: DuplicateContentCache? = nil,
                        featureCache: SimilarImageFeatureCache? = nil,
                        progress: ((DuplicateScanProgress) -> Void)? = nil) -> DuplicateScanSnapshot {
        let exact = scan(mode: .exact, roots: roots, control: control, home: home,
                         contentCache: contentCache, featureCache: featureCache, progress: progress)
        guard !exact.cancelled, exact.error == nil, !control.isCancelled else { return exact }
        let similar = scan(mode: .similarImages, roots: roots, control: control, home: home,
                           contentCache: contentCache, featureCache: featureCache, progress: progress)
        return merged(exact: exact, similar: similar)
    }

    static func merged(exact: DuplicateScanSnapshot, similar: DuplicateScanSnapshot) -> DuplicateScanSnapshot {
        let similarUsable = !similar.cancelled && similar.error == nil
        let exactPaths = Set(exact.groups.flatMap { $0.members.map(\.path) })
        let reclaim = { (group: DuplicateFileGroup) in group.members.dropFirst().reduce(UInt64(0)) { $0 + $1.size } }
        let total = { (group: DuplicateFileGroup) in group.members.reduce(UInt64(0)) { $0 + $1.size } }
        let similarGroups = !similarUsable ? [] : similar.groups.compactMap { group -> DuplicateFileGroup? in
            let members = group.members.filter { !exactPaths.contains($0.path) }
            return members.count > 1
                ? DuplicateFileGroup(id: "similar-" + group.id, members: members, kind: .similarImages) : nil
        }
        let groups = exact.groups.sorted { reclaim($0) > reclaim($1) } + similarGroups.sorted { total($0) > total($1) }
        return DuplicateScanSnapshot(groups: groups, roots: exact.roots,
            scanned: max(exact.scanned, similar.scanned), skipped: max(exact.skipped, similar.skipped),
            partial: exact.partial || similar.partial || !similarUsable,
            cancelled: similar.cancelled, error: nil, exactCopiesSkipped: 0,
            reclaimableBytes: exact.reclaimableBytes,
            defaultSelection: similar.cancelled ? [] : DuplicateSelectionPolicy.suggestedSelection(groups: groups, mode: .exact),
            scannedPaths: exact.scannedPaths.union(similar.scannedPaths))
    }
}

enum DuplicateSelectionPolicy {
    /// Exact copies keep the newest modification time. A plain path comparison
    /// makes identical timestamps deterministic, independent of scan order.
    static func newestKeeper(in group: DuplicateFileGroup) -> DuplicateFileRecord? {
        group.members.min { left, right in
            let lhs = left.file.identity, rhs = right.file.identity
            if lhs.modifiedSeconds != rhs.modifiedSeconds { return lhs.modifiedSeconds > rhs.modifiedSeconds }
            if lhs.modifiedNanoseconds != rhs.modifiedNanoseconds { return lhs.modifiedNanoseconds > rhs.modifiedNanoseconds }
            return left.path < right.path
        }
    }

    /// Built with the background scan snapshot; committed once by AppState.
    /// Similar images still require an explicit choice of copies.
    static func defaultSelection(groups: [DuplicateFileGroup], mode: DuplicateMode) -> Set<String> {
        guard mode == .exact else { return [] }
        return suggestedSelection(groups: groups, mode: mode)
    }

    /// Similar images only use this policy when the user explicitly requests
    /// default choices or selects all. Keep the largest resolution, then clarity.
    static func suggestedSelection(groups: [DuplicateFileGroup], mode: DuplicateMode) -> Set<String> {
        var selected: Set<String> = [], keepers: Set<String> = []
        for group in groups {
            let keeper: DuplicateFileRecord?
            if mode == .similarImages || group.kind == .similarImages {
                keeper = group.members.min { left, right in
                    let leftPixels = (left.imageInfo?.width ?? 0) * (left.imageInfo?.height ?? 0)
                    let rightPixels = (right.imageInfo?.width ?? 0) * (right.imageInfo?.height ?? 0)
                    if leftPixels != rightPixels { return leftPixels > rightPixels }
                    let leftSharpness = left.imageInfo?.sharpness ?? 0
                    let rightSharpness = right.imageInfo?.sharpness ?? 0
                    if leftSharpness != rightSharpness { return leftSharpness > rightSharpness }
                    return left.path < right.path
                }
            } else { keeper = newestKeeper(in: group) }
            guard let keeper else { continue }
            keepers.insert(keeper.path)
            for member in group.members where member.path != keeper.path { selected.insert(member.path) }
        }
        // Even overlapping input groups must retain every group's chosen copy.
        selected.subtract(keepers)
        return selected
    }

    static func safeSelection(_ selection: Set<String>, groups: [DuplicateFileGroup],
                              mode: DuplicateMode) -> Set<String> {
        let paths = Set(groups.flatMap { $0.members.map(\.path) })
        var selected = selection.intersection(paths)
        let suggested = suggestedSelection(groups: groups, mode: mode)
        for group in groups where !group.members.isEmpty && group.members.allSatisfy({ selected.contains($0.path) }) {
            if let keeper = group.members.first(where: { !suggested.contains($0.path) }) ?? group.members.first {
                selected.remove(keeper.path)
            }
        }
        return selected
    }

    /// Rows already belong to the group. Count the remaining keepers once per group.
    static func canSelect(isSelected: Bool, unselectedCount: Int) -> Bool {
        isSelected || unselectedCount > 1
    }
}

/// Only the scan placeholder subscribes to these frequent updates.
/// AppState publishes operation boundaries, so progress does not redraw the whole app.
@MainActor
final class DuplicateScanProgressStore: ObservableObject {
    @Published private(set) var progress: DuplicateScanProgress?

    func update(_ event: DuplicateScanProgress) {
        progress = event
    }

    func reset() { progress = nil }
}
