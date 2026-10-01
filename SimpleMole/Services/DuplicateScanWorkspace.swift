import Combine
import Foundation

enum DuplicateMode: String, CaseIterable, Identifiable, Sendable {
    case exact, similarImages
    var id: String { rawValue }
}

struct DuplicateImageInfo: Sendable {
    let width: Int
    let height: Int
    let sharpness: Double
}

struct DuplicateFileRecord: Identifiable, Sendable {
    let file: DuplicateFile
    var imageInfo: DuplicateImageInfo? = nil
    var id: String { file.path }
    var path: String { file.path }
    var name: String { file.name }
    var size: UInt64 { file.size }
}

struct DuplicateFileGroup: Identifiable, Sendable {
    let id: String
    let members: [DuplicateFileRecord]
}

/// The scanner and the potentially large presentation mapping share one background job.
struct DuplicateScanSnapshot: Sendable {
    let groups: [DuplicateFileGroup]
    let roots: [String]
    let scanned: Int
    let skipped: Int
    let partial: Bool
    let cancelled: Bool
    let error: String?
    let exactCopiesSkipped: Int
    let reclaimableBytes: UInt64
}

enum DuplicateScanWorker {
    static func scan(mode: DuplicateMode, roots: [String], control: DuplicateScanControl,
                     home: String = NSHomeDirectory(),
                     progress: ((DuplicateScanProgress) -> Void)? = nil) -> DuplicateScanSnapshot {
        switch mode {
        case .exact:
            let result = DuplicateScanner.scan(roots: roots, control: control, home: home, progress: progress)
            let cancelled = result.cancelled || control.isCancelled
            return DuplicateScanSnapshot(
                groups: cancelled ? [] : result.groups.map { group in
                    DuplicateFileGroup(id: group.id, members: group.files.map { DuplicateFileRecord(file: $0) })
                }, roots: result.roots, scanned: result.files.count, skipped: result.skippedFiles,
                partial: result.isPartial, cancelled: cancelled, error: result.error,
                exactCopiesSkipped: 0,
                reclaimableBytes: cancelled ? 0 : result.groups.reduce(0) { $0 + $1.reclaimableBytes })
        case .similarImages:
            let result = SimilarImageScanner.scan(roots: roots, control: control, home: home, progress: progress)
            let cancelled = result.cancelled || control.isCancelled
            return DuplicateScanSnapshot(
                groups: cancelled ? [] : result.groups.map { group in
                    DuplicateFileGroup(id: group.id, members: group.files.map { image in
                        DuplicateFileRecord(file: image.file,
                            imageInfo: DuplicateImageInfo(width: image.pixelWidth,
                                height: image.pixelHeight, sharpness: image.sharpnessScore))
                    })
                }, roots: result.roots, scanned: result.scannedFiles, skipped: result.skippedFiles,
                partial: result.isPartial, cancelled: cancelled, error: result.error,
                exactCopiesSkipped: result.exactCopiesSkipped, reclaimableBytes: 0)
        }
    }
}

enum DuplicateSelectionPolicy {
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
