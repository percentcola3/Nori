import Darwin
import Foundation

@main
struct AnalysisInventoryCacheTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
    }

    static func main() throws {
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let home = fixture.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        func write(_ relative: String, megabytes: Int, value: UInt8 = 1) throws -> URL {
            let target = home.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: target.path, contents: nil)
            let handle = try FileHandle(forWritingTo: target)
            let chunk = Data(repeating: value, count: 1 << 20)
            for _ in 0..<megabytes { try handle.write(contentsOf: chunk) }
            try handle.close()
            return target
        }
        let sharedLargeImage = try write("Pictures/large.png", megabytes: 101)
        let video = try write("Movies/clip.mp4", megabytes: 22)
        let small = try write("Pictures/small.jpg", megabytes: 0)
        _ = try write("Library/private.png", megabytes: 2)
        _ = try write(".hidden/hidden.png", megabytes: 2)
        _ = try write("Pictures/library.photoslibrary/original.png", megabytes: 2)
        _ = try write("Code/node_modules/asset.png", megabytes: 2)
        let outside = fixture.appendingPathComponent("outside.png")
        try Data(repeating: 7, count: 2 << 20).write(to: outside)
        try fm.createSymbolicLink(at: home.appendingPathComponent("Pictures/link.png"), withDestinationURL: outside)

        let cacheDirectory = fixture.appendingPathComponent("cache")
        let cache = AnalysisInventoryCache(directory: cacheDirectory, home: home.path)
        func scan(_ kind: AnalysisInventoryKind, full: Bool = false,
                  roots: [String]? = nil, control: CleanupScanControl? = nil) -> AnalysisInventoryScanResult {
            cache.scan(kind, forceFull: full, roots: roots ?? [home.path],
                       control: control ?? CleanupScanControl(mode: .deep))
        }
        let images = scan(.images)
        expect(images.canReuse, "readable first scan must produce a reusable inventory")
        expect(images.report.media?.map(\.path) == [sharedLargeImage.path],
               "image scan must reject video, packages, Library, hidden locations, and symlinks")
        expect(images.snapshot.files[small.path] != nil, "small files must remain indexed for later growth")
        expect(images.snapshot.files[video.path] == nil, "each section must inspect only its own file category")
        expect(images.statistics.listedDirectories > 0 && images.statistics.reusedDirectories == 0,
               "first scan must enumerate fresh directory memberships")
        expect(cache.restore()[.videos] == nil, "scanning images must not mark videos as scanned")
        let originalImageDate = images.snapshot.scannedAt

        let unchanged = scan(.images)
        expect(unchanged.statistics.listedDirectories == 0,
               "unchanged incremental scan must skip every directory listing")
        expect(unchanged.statistics.reusedDirectories == images.snapshot.directories.count,
               "incremental scan must reuse directory membership index")
        expect(unchanged.statistics.changedFiles == 0 && unchanged.statistics.reusedFiles == 2,
               "unchanged relevant file fingerprints must be reused")
        let full = scan(.images, full: true)
        expect(full.statistics.listedDirectories == images.statistics.listedDirectories &&
               full.statistics.reusedFiles == 0, "explicit full scan must rebuild the index")

        // An edit can leave parent directory metadata and file size unchanged.
        // Preserve the old mtime too: ctime/nanosecond identity still invalidates.
        let fingerprint = AnalysisFileFingerprint.read(sharedLargeImage.path)!
        let parent = sharedLargeImage.deletingLastPathComponent()
        let parentFingerprint = AnalysisFileFingerprint.read(parent.path)!
        let handle = try FileHandle(forWritingTo: sharedLargeImage)
        try handle.write(contentsOf: Data([9]))
        try handle.close()
        let dates = [timespec(tv_sec: Int(fingerprint.modifiedSeconds), tv_nsec: Int(fingerprint.modifiedNanoseconds)),
                     timespec(tv_sec: Int(fingerprint.modifiedSeconds), tv_nsec: Int(fingerprint.modifiedNanoseconds))]
        _ = dates.withUnsafeBufferPointer { utimensat(AT_FDCWD, sharedLargeImage.path, $0.baseAddress!, 0) }
        expect(AnalysisFileFingerprint.read(parent.path) == parentFingerprint,
               "fixture edit must leave parent identity unchanged")
        let edited = scan(.images)
        expect(edited.statistics.listedDirectories == 0 && edited.statistics.changedFiles == 1,
               "same-size content edit must invalidate only its file fingerprint")

        _ = try write("Pictures/small.jpg", megabytes: 2)
        let grown = scan(.images)
        expect(grown.report.mediaSummary?.imageCount == 2,
               "previously small files must enter results after crossing the threshold")
        let added = try write("Pictures/new.jpg", megabytes: 2)
        let additions = scan(.images)
        expect(additions.statistics.listedDirectories == 1 && additions.report.mediaSummary?.imageCount == 3,
               "new names must enumerate only the changed parent directory")
        try fm.removeItem(at: added)
        let deletions = scan(.images)
        expect(deletions.snapshot.files[added.path] == nil && deletions.report.mediaSummary?.imageCount == 2,
               "deleted names must disappear from incremental results")

        let videos = scan(.videos)
        expect(videos.report.media?.map(\.path) == [video.path], "video section must have its own result")
        let large = scan(.largeFiles)
        expect(large.report.largeFiles?.map(\.path) == [sharedLargeImage.path],
               "large-file category must overlap image inventory without sharing scan lifecycle")
        let imagesBeforeFailedScan = cache.restore()[.images]!
        let cancelledControl = CleanupScanControl(mode: .deep)
        cancelledControl.cancel()
        let cancelled = scan(.images, control: cancelledControl)
        expect(!cancelled.canReuse && DiskAnalysisWorker.completion(for: cancelled.report) == .cancelled,
               "cancellation must be distinct from a completed empty inventory")
        expect(cache.restore()[.images]?.scannedAt == imagesBeforeFailedScan.scannedAt,
               "cancelled re-scan must retain previous usable results and scan date")
        let failed = scan(.images, roots: [fixture.appendingPathComponent("missing").path])
        expect(!failed.canReuse && DiskAnalysisWorker.completion(for: failed.report) == .failed,
               "unreadable roots must fail rather than complete empty")
        expect(cache.restore()[.images]?.files.count == imagesBeforeFailedScan.files.count,
               "failed re-scan must retain the previous inventory")

        try fm.removeItem(at: sharedLargeImage)
        let repaired = cache.refresh(removedPaths: [sharedLargeImage.path], changedPaths: [])
        expect(repaired[.largeFiles]?.report.largeFiles?.isEmpty == true &&
               repaired[.images]?.report.mediaSummary?.imageCount == 1,
               "confirmed deletion must repair every cached category without scanning")
        expect(repaired[.videos]?.report.media?.map(\.path) == [video.path],
               "unrelated section results must survive cleanup")
        _ = try write("Pictures/small.jpg", megabytes: 0)
        let compressionRepair = cache.refresh(removedPaths: [], changedPaths: [small.path])
        expect(compressionRepair[.images]?.report.media?.isEmpty == true &&
               compressionRepair[.images]?.report.mediaSummary?.imageBytes == 0,
               "compression repair must recalculate candidate threshold and totals")
        let output = try write("Pictures/compressed.jpg", megabytes: 2)
        let outputRepair = cache.refresh(removedPaths: [], changedPaths: [output.path])
        expect(outputRepair[.images]?.report.media?.map(\.path) == [output.path],
               "new compression output must join every applicable cached section")

        let restored = AnalysisInventoryCache(directory: cacheDirectory, home: home.path).restore()
        expect(restored.keys.count == 3 && restored[.images]?.report.media?.map(\.path) == [output.path],
               "persistent caches must restore independently after relaunch")
        expect(restored[.images]!.scannedAt >= originalImageDate &&
               restored[.images]!.scannedAt == outputRepair[.images]!.scannedAt,
               "mutation repair must retain the last actual scan date")
        let emptyRoot = home.appendingPathComponent("empty")
        try fm.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let empty = AnalysisInventoryWorker.scan(.images, roots: [emptyRoot.path], home: home.path,
            control: CleanupScanControl(mode: .deep))
        expect(empty.canReuse && empty.report.media?.isEmpty == true,
               "a successful empty scan must remain a reusable completed inventory")

        let linksRoot = home.appendingPathComponent("Hardlinks")
        let original = try write("Hardlinks/original.png", megabytes: 2)
        let linked = linksRoot.appendingPathComponent("zz-copy.png")
        try fm.linkItem(at: original, to: linked)
        let links = AnalysisInventoryWorker.scan(.images, roots: [linksRoot.path], home: home.path,
            control: CleanupScanControl(mode: .deep))
        expect(links.snapshot.files.count == 2 && links.report.mediaSummary?.imageCount == 1,
               "hardlinks must be indexed but allocated blocks counted once per device/inode")
        expect(links.report.mediaSummary?.imageBytes == AnalysisFileFingerprint.read(original.path)?.allocated,
               "hardlink summary must not double count allocated bytes")

        // Pause an earlier scan after it captures the cache revision. A cleanup
        // repair must remain authoritative when that traversal later completes.
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let concurrentCache = AnalysisInventoryCache(directory: cacheDirectory, home: home.path)
        DispatchQueue.global(qos: .utility).async {
            var paused = false
            let result = concurrentCache.scan(.images, roots: [home.path],
                control: CleanupScanControl(mode: .deep), progress: { _, _ in
                    guard !paused else { return }
                    paused = true
                    started.signal()
                    resume.wait()
                })
            expect(!result.canReuse, "scan predating a mutation revision must refuse commit")
            finished.signal()
        }
        expect(started.wait(timeout: .now() + 10) == .success, "concurrent scan must reach its read boundary")
        try fm.removeItem(at: output)
        let mutation = concurrentCache.refreshState(removedPaths: [output.path], changedPaths: [])
        resume.signal()
        expect(finished.wait(timeout: .now() + 10) == .success, "superseded scan must finish without deadlock")
        let repairedDisk = AnalysisInventoryCache(directory: cacheDirectory, home: home.path).restore()
        expect(repairedDisk[.images]?.files[output.path] == nil &&
               concurrentCache.currentRevision == mutation.revision,
               "late scan must never resurrect a deleted file in persisted results")
        // The disk browser inventories every physical home-tree location,
        // independently of the filtered deletion/media classifications.
        let gitObject = try write(".git/objects/object", megabytes: 2)
        let disk = scan(.disk)
        expect(disk.canReuse && disk.diskBrowser?.rootPath == AnalysisDiskScopes.overviewPath &&
               disk.diskBrowser?.homePath == home.path,
               "disk browser must wrap the reusable home inventory in a scope overview")
        let defaultScopes = AnalysisInventoryWorker.defaultRoots(home: "/Users/nori-fixture-home", kind: .disk)
        expect(Set(defaultScopes) == Set(["/Users/nori-fixture-home"] + AnalysisDiskScopes.systemRoots) &&
               !defaultScopes.contains("/"),
               "disk accounting must cover only explicit home/log/temp/swap/cache scopes, never the root disk")
        expect(disk.diskBrowser?.entriesByPath[AnalysisDiskScopes.overviewPath]?.map(\.path) == [home.path],
               "a legacy home-only cache must remain navigable through its overview without rescanning")
        expect(disk.report.media == nil && disk.report.largeFiles?.isEmpty == true,
               "disk reports must not become media or reuse the large-file category")
        for relative in ["Library/private.png", ".hidden/hidden.png", ".git/objects/object",
                         "Pictures/library.photoslibrary/original.png", "Code/node_modules/asset.png"] {
            expect(disk.snapshot.files[home.appendingPathComponent(relative).path] != nil,
                   "disk accounting must include hidden, Library, package and dependency files: " + relative)
        }
        expect(disk.snapshot.files[home.appendingPathComponent("Pictures/link.png").path] == nil &&
               disk.snapshot.files[outside.path] == nil,
               "disk inventory must never follow symbolic links outside its root")
        let rootEntries = disk.diskBrowser!.entriesByPath[home.path]!
        expect(rootEntries == rootEntries.sorted { $0.size == $1.size ? $0.path < $1.path : $0.size > $1.size },
               "prepared disk columns must be sorted by physical capacity")
        let library = home.appendingPathComponent("Library")
        expect(rootEntries.first(where: { $0.path == library.path })?.size ==
               disk.snapshot.files[library.appendingPathComponent("private.png").path]!.allocated +
               disk.snapshot.directories[library.path]!.fingerprint.allocated,
               "directory entries must account for their entire known subtree")
        let unchangedDisk = scan(.disk)
        expect(unchangedDisk.statistics.listedDirectories == 0 &&
               unchangedDisk.statistics.reusedFiles == disk.snapshot.files.count,
               "unchanged disk rescans must reuse memberships and fingerprints")
        let nested = try write("Code/New/nested/data.bin", megabytes: 2)
        let addedDirectory = scan(.disk)
        expect(addedDirectory.statistics.listedDirectories == 3 && addedDirectory.snapshot.files[nested.path] != nil,
               "a new disk subtree must list only its changed parent and new directories")

        let beforeCompression = addedDirectory.report.totalSize
        let oldObjectBytes = addedDirectory.snapshot.files[gitObject.path]!.allocated
        let moviesColumn = addedDirectory.diskBrowser!.entriesByPath[home.appendingPathComponent("Movies").path]
        _ = try write(".git/objects/object", megabytes: 0)
        let diskRepair = cache.refreshState(removedPaths: [], changedPaths: [gitObject.path])
        expect(diskRepair.reports[.disk]?.totalSize == beforeCompression - oldObjectBytes &&
               diskRepair.diskBrowser?.repairedDirectoryCount == 3,
               "compression repair must update only the file's three ancestor columns without scanning")
        expect(diskRepair.diskBrowser?.entriesByPath[home.appendingPathComponent("Movies").path] == moviesColumn,
               "a mutation must reuse unrelated directory columns")
        let repairedProjection = AnalysisDiskBrowserInventory(snapshot: diskRepair.snapshots[.disk]!)
        expect(repairedProjection.report(for: diskRepair.snapshots[.disk]!).totalSize == diskRepair.reports[.disk]?.totalSize,
               "incremental ancestor totals must match a rebuilt in-memory projection")
        let beforeLibraryRemoval = diskRepair.reports[.disk]!.totalSize
        let libraryBytes = diskRepair.diskBrowser!.entriesByPath[home.path]!.first(where: { $0.path == library.path })!.size
        try fm.removeItem(at: library)
        let directoryRepair = cache.refreshState(removedPaths: [library.path], changedPaths: [])
        expect(directoryRepair.reports[.disk]?.totalSize == beforeLibraryRemoval - libraryBytes &&
               directoryRepair.diskBrowser?.entriesByPath[library.path] == nil,
               "known directory removal must prune all descendants and repair ancestor capacity")
        let diskRestored = AnalysisInventoryCache(directory: cacheDirectory, home: home.path).restoreState()
        expect(diskRestored.snapshots.count == 4 && diskRestored.diskBrowser?.entriesByPath == directoryRepair.diskBrowser?.entriesByPath,
               "disk and large-file caches must persist and restore independently")

        // Exact-key mutation repair uses cached memberships, including roots
        // removed through an ancestor that was never part of this index.
        let known = diskRestored.snapshots[.disk]!
        var emptyRemoval = known
        expect(emptyRemoval.removeKnownPaths([]).isEmpty && emptyRemoval.files == known.files &&
               emptyRemoval.directories.count == known.directories.count,
               "compression-only repair must skip removal traversal")
        var oneRemoval = known
        let exactRemoved = oneRemoval.removeKnownPaths([nested.path])
        expect(exactRemoved == [nested.path] && oneRemoval.files.count == known.files.count - 1 &&
               oneRemoval.directories.count == known.directories.count &&
               oneRemoval.directories[nested.deletingLastPathComponent().path]?.files.contains(nested.path) == false,
               "known file deletion must remove only its exact key and parent reference")
        var subtreeRemoval = known
        let newTree = home.appendingPathComponent("Code/New")
        let subtreeKeys = subtreeRemoval.removeKnownPaths([newTree.path])
        expect(subtreeKeys == [newTree.path, nested.deletingLastPathComponent().path, nested.path] &&
               subtreeRemoval.directories[newTree.path] == nil && subtreeRemoval.files[nested.path] == nil,
               "known directory deletion must follow only its cached descendants")
        var ancestorRemoval = known
        _ = ancestorRemoval.removeKnownPaths([fixture.path])
        expect(ancestorRemoval.files.isEmpty && ancestorRemoval.directories.isEmpty,
               "removing an unindexed ancestor must remove every contained indexed root")

        let hardlinkTotal = directoryRepair.reports[.disk]!.totalSize
        try fm.removeItem(at: original)
        let hardlinkRemoval = cache.refreshState(removedPaths: [original.path], changedPaths: [])
        expect(hardlinkRemoval.reports[.disk]?.totalSize == hardlinkTotal &&
               hardlinkRemoval.diskBrowser?.entriesByPath[linksRoot.path]?.first(where: { $0.path == linked.path })?.size == AnalysisFileFingerprint.read(linked.path)?.allocated,
               "deleting the accounting owner must reassign hardlink blocks without changing tree totals")
        let hardlinkCopy = linksRoot.appendingPathComponent("00-owner.png")
        try fm.linkItem(at: linked, to: hardlinkCopy)
        let newLinkRepair = cache.refreshState(removedPaths: [], changedPaths: [hardlinkCopy.path])
        expect(newLinkRepair.reports[.disk]?.totalSize == hardlinkTotal,
               "a new hardlink must enter its column while allocated blocks remain counted once")
        let linkHandle = try FileHandle(forWritingTo: linked)
        try linkHandle.truncate(atOffset: 0)
        try linkHandle.close()
        let hardlinkChanged = cache.refreshState(removedPaths: [], changedPaths: [linked.path])
        let hardlinkRebuilt = AnalysisDiskBrowserInventory(snapshot: hardlinkChanged.snapshots[.disk]!)
        expect(hardlinkChanged.reports[.disk]?.totalSize == hardlinkRebuilt.report(for: hardlinkChanged.snapshots[.disk]!).totalSize &&
               hardlinkChanged.diskBrowser?.entriesByPath[linksRoot.path]?.allSatisfy({ $0.size == 0 }) == true,
               "in-place edits must update every indexed alias and repair the allocation owner")

        // Native permission failure is a real partial traversal, not a mocked
        // empty result. An unreadable saved subtree retains its size, is marked
        // untrusted, and is retried even while the directory metadata stays put.
        if getuid() != 0 {
            let protectedFile = try write("Protected/nested/file.bin", megabytes: 2)
            let protectedRoot = home.appendingPathComponent("Protected")
            let completeDisk = scan(.disk)
            let protectedBytes = completeDisk.diskBrowser!.entriesByPath[home.path]!.first(where: { $0.path == protectedRoot.path })!.size
            expect(chmod(protectedRoot.path, 0) == 0, "fixture must become unreadable")
            defer { _ = chmod(protectedRoot.path, 0o700) }
            let partialDisk = scan(.disk)
            expect(partialDisk.canReuse && partialDisk.report.isPartial == true &&
                   partialDisk.snapshot.files[protectedFile.path] != nil,
                   "partial disk inventory must retain and persist the previous known subtree")
            expect(partialDisk.diskBrowser!.entriesByPath[home.path]!.first(where: { $0.path == protectedRoot.path })?.size == protectedBytes &&
                   partialDisk.diskBrowser!.entriesByPath[protectedFile.deletingLastPathComponent().path]!.first?.isPartial == true,
                   "retained unreadable sizes and descendants must stay marked partial")
            let fullPartial = scan(.disk, full: true)
            expect(fullPartial.canReuse && fullPartial.snapshot.files[protectedFile.path] != nil &&
                   fullPartial.diskBrowser!.entriesByPath[home.path]!.first(where: { $0.path == protectedRoot.path })?.size == protectedBytes,
                   "an explicit full scan must preserve the known capacity of an unreadable subtree")
            let persistedPartial = AnalysisInventoryCache(directory: cacheDirectory, home: home.path).restoreState()
            expect(persistedPartial.reports[.disk]?.isPartial == true &&
                   persistedPartial.diskBrowser?.entriesByPath[home.path]?.first(where: { $0.path == protectedRoot.path })?.isPartial == true,
                   "partial warnings must survive restoring disk results")
            let retriedPartial = scan(.disk)
            expect(retriedPartial.report.scanIssueCount ?? 0 > 0 &&
                   retriedPartial.snapshot.unreadableDirectories?.contains(protectedRoot.path) == true,
                   "unchanged unreadable memberships must be retried instead of becoming complete")
            expect(chmod(protectedRoot.path, 0o700) == 0, "fixture permission must recover")
            let recovered = scan(.disk)
            expect(recovered.report.isPartial == false && recovered.snapshot.unreadableDirectories == nil &&
                   recovered.diskBrowser!.entriesByPath[protectedFile.deletingLastPathComponent().path]!.first?.isPartial == false,
                   "a successful retry must clear all partial markers")
        }

        // Expand a persisted home-only inventory using explicit new scopes.
        // All filesystem work remains inside this disposable fixture.
        let homeOnly = scan(.disk)
        let logsRoot = URL(fileURLWithPath: AnalysisDiskScopes.physicalPath(
            fixture.appendingPathComponent("system/logs").path))
        let temporaryRoot = URL(fileURLWithPath: AnalysisDiskScopes.physicalPath(
            fixture.appendingPathComponent("system/temporary").path))
        let archivedRoot = logsRoot.appendingPathComponent("archive")
        try fm.createDirectory(at: archivedRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let archivedLog = archivedRoot.appendingPathComponent("historical.log")
        let temporaryFile = temporaryRoot.appendingPathComponent("old.tmp")
        try Data(repeating: 5, count: 128 << 10).write(to: archivedLog)
        try Data(repeating: 6, count: 64 << 10).write(to: temporaryFile)
        let rootAlias = fixture.appendingPathComponent("system/log-alias")
        try fm.createSymbolicLink(at: rootAlias, withDestinationURL: logsRoot)
        let childAlias = logsRoot.appendingPathComponent("outside-link")
        try fm.createSymbolicLink(at: childAlias, withDestinationURL: home)
        let linkedVideo = logsRoot.appendingPathComponent("shared-video.mp4")
        try fm.linkItem(at: video, to: linkedVideo)
        let expandedRoots = [home.path, logsRoot.path, archivedRoot.path,
                             rootAlias.path, temporaryRoot.path, logsRoot.path]
        let expanded = scan(.disk, roots: expandedRoots)
        expect(Set(expanded.snapshot.roots) == Set([home.path, logsRoot.path, temporaryRoot.path]) &&
               expanded.statistics.listedDirectories == 3 &&
               expanded.statistics.reusedDirectories == homeOnly.snapshot.directories.count,
               "scope expansion must reuse all saved home memberships and list only new normalized roots")
        expect(expanded.snapshot.directories[childAlias.path] == nil &&
               expanded.snapshot.files[rootAlias.appendingPathComponent("archive/historical.log").path] == nil,
               "scope aliases and child symlinks must never duplicate physical tree accounting")
        let expandedOverview = expanded.diskBrowser!.entriesByPath[AnalysisDiskScopes.overviewPath]!
        expect(Set(expandedOverview.map(\.path)) == Set(expanded.snapshot.roots) &&
               expandedOverview.reduce(UInt64(0), { $0 &+ $1.size }) == expanded.report.totalSize,
               "overview must expose exactly the explicit scopes and their prepared capacities")
        var uniqueFiles = Set<String>()
        let uniqueBytes = expanded.snapshot.files.values.reduce(UInt64(0)) { bytes, fingerprint in
            let identity = "\(fingerprint.device):\(fingerprint.inode)"
            return uniqueFiles.insert(identity).inserted ? bytes &+ fingerprint.allocated : bytes
        }
        let directoryBytes = expanded.snapshot.directories.values.reduce(UInt64(0)) {
            $0 &+ $1.fingerprint.allocated
        }
        expect(expanded.report.totalSize == uniqueBytes &+ directoryBytes,
               "cross-scope hardlinks must allocate their bytes to only one physical object")
        let historicalOverlap = AnalysisInventorySnapshot(kind: .disk, home: home.path,
            roots: expanded.snapshot.roots + [archivedRoot.path, home.path],
            scannedAt: expanded.snapshot.scannedAt, directories: expanded.snapshot.directories,
            files: expanded.snapshot.files)
        let restoredOverlap = AnalysisDiskBrowserInventory(snapshot: historicalOverlap)
        expect(restoredOverlap.report(for: historicalOverlap).totalSize == expanded.report.totalSize &&
               restoredOverlap.entriesByPath[AnalysisDiskScopes.overviewPath]!.count == 3,
               "restored overlapping scopes must deduplicate using cached identities without filesystem reads")
        let unchangedScopes = scan(.disk, roots: expandedRoots)
        expect(unchangedScopes.statistics.listedDirectories == 0 &&
               unchangedScopes.statistics.reusedFiles == expanded.snapshot.files.count,
               "subsequent multi-scope scans must reuse every saved membership and file fingerprint")
        let datesBeforeRepair = cache.restore().mapValues(\.scannedAt)
        let unrelatedHomeColumns = unchangedScopes.diskBrowser!.entriesByPath[home.path]
        let beforeSystemEdit = unchangedScopes.report.totalSize
        let previousLogBytes = unchangedScopes.snapshot.files[archivedLog.path]!.allocated
        try Data().write(to: archivedLog)
        let systemEdit = cache.refreshState(removedPaths: [], changedPaths: [archivedLog.path])
        expect(systemEdit.reports[.disk]?.totalSize == beforeSystemEdit - previousLogBytes &&
               systemEdit.diskBrowser?.repairedDirectoryCount == 2 &&
               systemEdit.diskBrowser?.entriesByPath[home.path] == unrelatedHomeColumns,
               "system-file edits must repair only physical ancestors plus the overview, reusing home columns")
        expect(systemEdit.snapshots.mapValues(\.scannedAt) == datesBeforeRepair &&
               systemEdit.snapshots[.images]?.files[archivedLog.path] == nil,
               "targeted system refresh must preserve every category date and keep classifications isolated")
        let beforeSystemRemoval = systemEdit.reports[.disk]!.totalSize
        let temporaryBytes = systemEdit.snapshots[.disk]!.files[temporaryFile.path]!.allocated
        try fm.removeItem(at: temporaryFile)
        let systemRemoval = cache.refreshState(removedPaths: [temporaryFile.path], changedPaths: [])
        expect(systemRemoval.reports[.disk]?.totalSize == beforeSystemRemoval - temporaryBytes &&
               systemRemoval.diskBrowser?.repairedDirectoryCount == 1 &&
               systemRemoval.diskBrowser?.entriesByPath[temporaryRoot.path]?.isEmpty == true,
               "system-file removal must refresh only its parent and the overview")
        let rebuiltSystem = AnalysisDiskBrowserInventory(snapshot: systemRemoval.snapshots[.disk]!)
        expect(rebuiltSystem.entriesByPath == systemRemoval.diskBrowser?.entriesByPath,
               "multi-scope mutation repair must match a fresh in-memory projection")

        if getuid() != 0 {
            let savedScopes = scan(.disk, roots: expandedRoots)
            let savedLogSize = savedScopes.diskBrowser!.entriesByPath[AnalysisDiskScopes.overviewPath]!
                .first(where: { $0.path == logsRoot.path })!.size
            expect(chmod(logsRoot.path, 0) == 0, "explicit fixture scope must become unreadable")
            defer { _ = chmod(logsRoot.path, 0o700) }
            let unreadableScope = scan(.disk, roots: expandedRoots)
            expect(unreadableScope.canReuse && unreadableScope.report.isPartial == true &&
                   unreadableScope.snapshot.files[archivedLog.path] != nil &&
                   unreadableScope.diskBrowser!.entriesByPath[AnalysisDiskScopes.overviewPath]!
                    .first(where: { $0.path == logsRoot.path })?.size == savedLogSize,
                   "unreadable explicit scopes must retain saved subtree capacity and remain partial")
            let restoredScopes = AnalysisInventoryCache(directory: cacheDirectory, home: home.path).restoreState()
            expect(restoredScopes.diskBrowser?.entriesByPath[AnalysisDiskScopes.overviewPath]?
                    .first(where: { $0.path == logsRoot.path })?.isPartial == true &&
                   restoredScopes.diskBrowser?.entriesByPath[archivedRoot.path]?.first?.isPartial == true,
                   "restored unreadable scopes must keep overview and descendant partial markers")
            let retry = scan(.disk, roots: expandedRoots)
            expect(retry.snapshot.unreadableDirectories?.contains(logsRoot.path) == true &&
                   retry.report.isPartial == true,
                   "permission failures at an explicit root must be retried even with unchanged metadata")
            expect(chmod(logsRoot.path, 0o700) == 0, "explicit fixture scope must recover access")
            let recoveredScope = scan(.disk, roots: expandedRoots)
            expect(recoveredScope.report.isPartial == false && recoveredScope.snapshot.unreadableDirectories == nil,
                   "recovered explicit scopes must clear cached partial state")
        }
        let missingScope = AnalysisDiskScopes.physicalPath(fixture.appendingPathComponent("system/missing").path)
        let withMissingScope = scan(.disk, roots: expandedRoots + [missingScope])
        expect(withMissingScope.canReuse && withMissingScope.report.isPartial == true &&
               withMissingScope.diskBrowser?.entriesByPath[missingScope]?.isEmpty == true &&
               withMissingScope.diskBrowser?.entriesByPath[AnalysisDiskScopes.overviewPath]?
                .first(where: { $0.path == missingScope })?.isPartial == true,
               "missing new scopes must show an explicitly partial navigable column without discarding useful results")
        print("PASS: independent analysis inventories, multi-scope accounting, alias deduplication, incremental reuse, partial retry, persistence, and local mutation repair")
    }
}
