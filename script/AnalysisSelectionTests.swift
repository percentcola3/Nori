import Foundation

enum MediaKind { case image, video }
struct MediaFile {
    let name: String
    let path: String
    let size: UInt64
    let kind: MediaKind
}
struct FixtureLargeFile {
    let name: String
    let path: String
    let size: UInt64
}
struct AnalyzeEntry {
    let name: String
    let path: String
    let size: UInt64
    let isDir: Bool
    var isPartial: Bool? = nil
}
enum SlimOperation {
    case compressImage, transcodeVideo, archive
    static func operation(for path: String) -> Self { .compressImage }
}
// The executor's location policy is a boundary here; deletion-plan tests cover
// its live identity, owner, age and permission checks.
enum AnalysisFileDeletionPlan {
    static func isEligible(path: String, homeDirectory: String, allowsDirectories: Bool = false) -> Bool {
        MediaSlimPolicy.isEligible(path, home: homeDirectory)
    }
}

// PRODUCTION_TYPES
// PRODUCTION_POLICY

@MainActor
final class AppState {
    var isBusy = false
    var analyzeMode = AnalyzeMode.largeFiles
    var analyzeLargeFiles: [FixtureLargeFile] = []
    var analyzeMedia: [MediaFile] = []
    var slimSelection: Set<String> = []
    var analysisFileSelection: Set<String> = []
    var analysisFileSelectionsByMode: [AnalyzeMode: Set<String>] = [:]
    var diskBrowserRootPath = "/fixture"
    var diskBrowserHomePath = "/fixture"
    var diskBrowserNavigation = ["/fixture"]
    var diskBrowserEntriesByPath: [String: [AnalyzeEntry]] = [:]

    // PRODUCTION_METHODS
}

@main
struct AnalysisSelectionTests {
    @MainActor
    static func main() {
        let image = "/fixture/large-image.jpg"
        let otherImage = "/fixture/Pictures/image.png"
        let video = "/fixture/large-video.mp4"
        let state = AppState()
        state.analyzeLargeFiles = [.init(name: "large-image.jpg", path: image, size: 120),
                                  .init(name: "large-video.mp4", path: video, size: 140)]
        state.analyzeMedia = [.init(name: "large-image.jpg", path: image, size: 120, kind: .image),
                             .init(name: "image.png", path: otherImage, size: 20, kind: .image),
                             .init(name: "large-video.mp4", path: video, size: 140, kind: .video)]
        let imageItems = state.analysisFileItems(for: .images)
        precondition(Set(imageItems.map(\.path)) == [image, otherImage], "Images are absent from the deletion inventory")
        precondition(state.analysisFileItems(for: .duplicates).isEmpty)
        precondition(AnalyzeMode.menuOrder == [.disk, .largeFiles, .duplicates, .videos, .images])

        state.diskBrowserEntriesByPath["/fixture"] = [
            .init(name: "Pictures", path: "/fixture/Pictures", size: 140, isDir: true),
            .init(name: "large-image.jpg", path: image, size: 120, isDir: false),
            .init(name: "large-video.mp4", path: video, size: 140, isDir: false),
            .init(name: "outside.bin", path: "/outside.bin", size: 40, isDir: false),
            .init(name: "managed.bin", path: "/fixture/Library/managed.bin", size: 20, isDir: false),
            .init(name: "partial.bin", path: "/fixture/partial.bin", size: 30,
                  isDir: false, isPartial: true),
            .init(name: "partial-folder", path: "/fixture/partial-folder", size: 90,
                  isDir: true, isPartial: true),
            .init(name: "Home", path: "/fixture", size: 1_000, isDir: true),
            .init(name: "Library", path: "/fixture/Library", size: 500, isDir: true)
        ]
        precondition(Set(state.analysisFileItems(for: .disk).map(\.path)) == ["/fixture/Pictures", image, video],
                     "Disk selection must include ordinary folders while excluding partial or protected items")
        state.analyzeMode = .disk
        precondition(state.analysisFileSelectedItems.isEmpty, "Disk files were selected by default")
        state.toggleAnalysisFileSelection(.init(name: "Pictures", path: "/fixture/Pictures", size: 140))
        precondition(state.analysisSelection(for: .disk) == ["/fixture/Pictures"]
            && state.analysisFileSelectedBytes == 140 && state.diskBrowserNavigation == ["/fixture"],
            "Checking a folder should count its size without opening it")
        state.selectAllAnalysisFiles()
        precondition(state.analysisSelection(for: .disk) == ["/fixture/Pictures", image, video])
        precondition(state.analysisFileSelectedItems.count == 3 && state.analysisFileSelectedBytes == 400)
        precondition(state.analysisSelection(for: .largeFiles).isEmpty,
                     "Disk and large-file inventories share their selection")
        precondition(state.slimSelectedCandidates.isEmpty, "Disk selection became a compression selection")
        state.diskBrowserEntriesByPath["/fixture/Pictures"] = [
            .init(name: "image.png", path: otherImage, size: 20, isDir: false)
        ]
        state.openDiskBrowserDirectory(state.diskBrowserEntries(at: "/fixture")[0], in: "/fixture")
        precondition(state.diskBrowserNavigation == ["/fixture", "/fixture/Pictures"])
        precondition(state.analysisSelection(for: .disk).isEmpty,
                     "Opening a directory retained the previous column's selection")
        state.selectAllAnalysisFiles()
        precondition(state.analysisSelection(for: .disk) == [otherImage],
                     "Select all included files outside the current column")
        state.toggleAnalysisFileSelection(.init(name: "large-video.mp4", path: video, size: 140))
        precondition(state.analysisSelection(for: .disk) == [otherImage],
                     "A previous column or forged item entered the current selection")
        state.navigateDiskBrowser(to: "/fixture")
        precondition(state.diskBrowserNavigation == ["/fixture"])
        precondition(state.analysisSelection(for: .disk).isEmpty,
                     "Returning to a parent retained a stale selection")
        state.navigateDiskBrowser(to: "/not-in-navigation")
        precondition(state.diskBrowserNavigation == ["/fixture"],
                     "Navigation opened an unknown directory outside the saved columns")
        state.deselectAllAnalysisFiles()
        precondition(state.analysisSelection(for: .disk).isEmpty)
        state.analyzeMode = .largeFiles

        state.selectAllAnalysisFiles()
        precondition(state.analysisSelection(for: .largeFiles) == [image, video])
        precondition(state.analysisFileSelectedItems.count == 2 && state.analysisFileSelectedBytes == 260)
        precondition(state.slimSelectedCandidates.isEmpty, "Large-file selection became a compression selection")

        state.analyzeMode = .videos
        precondition(state.analysisFileSelectedItems.isEmpty, "Switching sections leaked the previous selection")
        state.toggleAnalysisFileSelection(state.analysisFileItems(for: .videos)[0])
        precondition(state.analysisSelection(for: .videos) == [video])
        state.analyzeMode = .largeFiles
        state.deselectAllAnalysisFiles()
        precondition(state.analysisSelection(for: .largeFiles).isEmpty)
        precondition(state.analysisSelection(for: .videos) == [video], "Overlapping large/video paths share selection")
        state.toggleSelectAllAnalysisFiles()
        precondition(state.analysisSelection(for: .largeFiles) == [image, video])
        state.toggleSelectAllAnalysisFiles()
        precondition(state.analysisSelection(for: .largeFiles).isEmpty)

        state.analyzeMode = .images
        state.selectAllAnalysisFiles()
        precondition(state.analysisSelection(for: .images) == [image, otherImage])
        precondition(state.slimSelection == [image, otherImage])
        precondition(Set(state.slimSelectedCandidates.map(\.path)) == [image, otherImage])
        precondition(state.slimSelectedBytes == state.analysisFileSelectedBytes)
        state.toggleAnalysisFileSelection(imageItems[0])
        precondition(state.analysisSelection(for: .images) == [otherImage])
        precondition(state.slimSelection == [otherImage], "Image checkbox and compression selection differ")

        let previousSelections = state.analysisFileSelectionsByMode
        let previousSlim = state.slimSelection
        let previousCurrent = state.analysisFileSelection
        state.isBusy = true
        state.selectAllAnalysisFiles()
        state.deselectAllAnalysisFiles()
        state.selectDefaultAnalysisFiles()
        state.toggleSelectAllAnalysisFiles()
        state.toggleAnalysisFileSelection(imageItems[0])
        precondition(state.analysisFileSelectionsByMode == previousSelections)
        precondition(state.slimSelection == previousSlim && state.analysisFileSelection == previousCurrent,
                     "Busy state did not freeze every selection surface")
        state.isBusy = false
        state.selectDefaultAnalysisFiles()
        precondition(state.analysisSelection(for: .images).isEmpty && state.slimSelection.isEmpty,
                     "Default image selection did not retain personal files")
        precondition(state.analysisSelection(for: .videos) == [video])
        state.analyzeMode = .videos
        state.selectDefaultAnalysisFiles()
        precondition(state.analysisSelection(for: .videos).isEmpty)
        state.analyzeMode = .largeFiles
        state.selectAllAnalysisFiles()
        state.selectDefaultAnalysisFiles()
        precondition(state.analysisSelection(for: .largeFiles).isEmpty)
        print("Analysis selection: disk folder/file eligibility and independent folder checks, image cleanup, per-category overlap isolation, all/none/default, busy guards and image-compression synchronization passed")
    }
}
