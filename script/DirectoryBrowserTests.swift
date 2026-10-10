import AppKit
import Combine
import Foundation

@main
@MainActor
struct DirectoryBrowserTests {
    static func settle(_ condition: @escaping @MainActor () -> Bool,
                       file: StaticString = #fileID, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            precondition(Date() < deadline, "Directory model did not settle at \(file):\(line)")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    static func main() async throws {
        let english = L10nDirectoryTables.table(for: .en)
        for language in [AppLanguage.zhHans, .zhHant] {
            let table = L10nDirectoryTables.table(for: language)
            precondition(Set(table.keys) == Set(english.keys), "Directory translations are missing keys")
            for (key, value) in english {
                precondition(value.components(separatedBy: "%@").count == table[key]!.components(separatedBy: "%@").count,
                             "Directory format placeholders differ: \(key)")
                precondition(value.components(separatedBy: "%d").count == table[key]!.components(separatedBy: "%d").count,
                             "Directory numeric placeholders differ: \(key)")
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nori-directory-model-\(UUID())")
        let suite = "nori-directory-model-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let clipboard = NSPasteboard.withUniqueName()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
            clipboard.releaseGlobally()
        }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: first.appendingPathComponent(".secret"))
        try Data("alpha".utf8).write(to: first.appendingPathComponent("Alpha.txt"))
        try Data("beta".utf8).write(to: first.appendingPathComponent("Beta.txt"))
        try Data("nested".utf8).write(to: second.appendingPathComponent(".nested"))
        let model = DirectoryBrowserModel(defaults: defaults, homeDirectory: root, initialDirectory: first,
            indexDatabaseURL: root.appendingPathComponent("index.sqlite"), pasteboard: clipboard,
            sizeCacheURL: root.appendingPathComponent("cache/sizes.json"))
        defer { model.suspend(); model.stopSizeBackgroundWork() }
        model.start()
        try await settle { !model.isLoading && model.entries.count == 3 }
        precondition(model.showHidden && model.entries.contains { $0.name == ".secret" })
        model.showHidden = false
        precondition(model.entries.count == 2, "Hidden toggle did not filter current directory")
        model.navigate(to: second)
        precondition(model.entries.isEmpty, "New breadcrumb retained the previous directory's actionable rows")
        try await settle { !model.isLoading && model.entries.count == 1 }
        precondition(model.showHidden, "Every unvisited directory must show hidden files by default")
        model.goBack()
        try await settle { !model.isLoading && model.entries.count == 2 }
        precondition(!model.showHidden, "Per-directory visibility was not restored")
        precondition(model.canGoForward)
        model.goForward()
        try await settle { !model.isLoading }
        model.navigate(to: first)
        try await settle { !model.isLoading && model.entries.count == 2 }
        precondition(!model.canGoForward, "New navigation retained abandoned forward history")

        let exactPath = first.appendingPathComponent("Alpha.txt")
        let pathQuery = DirectoryPathQuery(exactPath.path)!
        precondition(pathQuery.score(exactPath) == 100)
        precondition(DirectoryPathQuery("Alpha.txt") == nil, "Plain filenames should keep filename filtering")
        precondition(DirectoryPathQuery("~/first", home: root)!.text == first.path)
        precondition(DirectoryPathQuery(exactPath.absoluteString)!.text == exactPath.path)
        let typoPath = DirectoryPathQuery(first.appendingPathComponent("Alhpa.txt").path)!
        let candidates = try typoPath.localCandidates(currentDirectory: first, showHidden: true)
        precondition(candidates.contains(exactPath), "Adjacent-letter typo did not resolve")
        precondition(typoPath.score(exactPath) > typoPath.score(first.appendingPathComponent("Beta.txt")))
        var revealURL = URLComponents()
        revealURL.scheme = "nori"; revealURL.host = "reveal"
        revealURL.queryItems = [URLQueryItem(name: "path", value: exactPath.path)]
        precondition(DirectoryRevealRequest.fileURL(from: revealURL.url!) == exactPath)
        precondition(DirectoryRevealRequest.fileURL(from: URL(string: "nori://other?path=/tmp")!) == nil)
        precondition(DirectoryRevealRequest.fileURL(from: URL(string: "https://example.com/tmp")!) == nil)
        model.query = exactPath.path
        try await settle { !model.isSearching && model.entries.contains { $0.id == exactPath.path } }
        precondition(model.entries.first?.id == exactPath.path && model.pathMatchScores[exactPath.path] == 100,
                     "Exact path must appear before fuzzy candidates")
        model.query = ""
        model.reveal([exactPath])
        try await settle { !model.isLoading && model.selectedIDs.contains(exactPath.path) }
        precondition(model.currentDirectory.path == first.path, "Reveal launched the file instead of selecting its containing folder")
        model.showHidden = false

        model.query = "ALPHA"
        precondition(model.entries.map(\.name) == ["Alpha.txt"], "Local filter is not case insensitive")
        model.query = ""
        model.selectAll()
        precondition(model.selectedIDs.count == 2)
        let alpha = model.entries.first { $0.name == "Alpha.txt" }!
        model.select(entry: alpha, extending: false)
        model.copySelection()
        model.navigate(to: second)
        try await settle { !model.isLoading }
        model.paste()
        try await settle { !model.isWorking && !model.isLoading && model.entries.contains { $0.name == "Alpha.txt" } }
        precondition(FileManager.default.fileExists(atPath: first.appendingPathComponent("Alpha.txt").path),
                     "Copy removed the original file")
        model.paste()
        try await settle { !model.isWorking && !model.isLoading && model.entries.contains { $0.name == "Alpha 2.txt" } }
        let copy = model.entries.first { $0.name == "Alpha 2.txt" }!
        model.select(entry: copy, extending: false)
        model.cutSelection()
        model.navigate(to: first)
        try await settle { !model.isLoading }
        model.paste()
        try await settle { !model.isWorking && !model.isLoading && model.entries.contains { $0.name == "Alpha 2.txt" } }
        precondition(!FileManager.default.fileExists(atPath: second.appendingPathComponent("Alpha 2.txt").path),
                     "Cut/paste did not move the source")
        model.copyBreadcrumbPath()
        precondition(clipboard.string(forType: .string) == first.path, "Breadcrumb copy did not preserve absolute path")
        precondition(model.isBreadcrumbPathCopied, "Copy feedback was not published")
        try await settle { !model.isBreadcrumbPathCopied }
        model.go(to: "relative/path")
        precondition(model.errorMessage != nil && model.currentDirectory.path == first.path)
        model.clearError()
        model.createFolder(name: "new folder")
        try await settle { !model.isWorking && !model.isLoading && model.entries.contains { $0.name == "new folder" } }
        let folder = model.entries.first { $0.name == "new folder" }!
        model.select(entry: folder, extending: false)
        model.renameSelected(to: "renamed")
        try await settle { !model.isWorking && !model.isLoading && model.entries.contains { $0.name == "renamed" } }

        let moveAlpha = model.entries.first { $0.name == "Alpha.txt" }!
        let moveBeta = model.entries.first { $0.name == "Beta.txt" }!
        model.select(entry: moveAlpha, extending: false)
        model.select(entry: moveBeta, extending: true)
        model.cutSelection()
        try FileManager.default.removeItem(at: moveBeta.url)
        model.navigate(to: second)
        try await settle { !model.isLoading }
        model.paste()
        try await settle { !model.isWorking && model.errorMessage != nil }
        let remaining = (clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        precondition(remaining == [moveBeta.url], "Partial move retry retained already moved sources")
        try Data("restored beta".utf8).write(to: moveBeta.url)
        model.paste()
        try await settle { !model.isWorking && !model.isLoading && model.entries.contains { $0.name == "Beta.txt" } }
        let movedClipboard = (clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        precondition(movedClipboard == [second.appendingPathComponent("Beta.txt")], "Completed cut retained nonexistent clipboard sources")
        model.navigate(to: first)
        try await settle { !model.isLoading }
        model.suspend()
        model.start()
        try await settle { !model.isLoading }
        precondition(model.currentDirectory.path == first.path && !model.showHidden)
        model.createFile(name: "offscreen.txt")
        model.suspend()
        try await settle { !model.isWorking }
        precondition(!model.isLoading, "Completed operation restarted navigation on a suspended tab")
        try await settle { !model.isCalculatingSizes }
        try await testUnifiedSearch(in: root, defaults: defaults, clipboard: clipboard)
        try await testTargetedPaste(in: root, defaults: defaults, clipboard: clipboard)
        try await testBackgroundSizes(in: root, defaults: defaults, clipboard: clipboard)
        try await testIdleSizeRelease(in: root, defaults: defaults, clipboard: clipboard)
        try await testVisibleSizeCacheCapacity(in: root, defaults: defaults, clipboard: clipboard)
        try await testGitOperationLifecycle(in: root, defaults: defaults, clipboard: clipboard)
        print("Directory model: history, hidden preferences, filtering, isolated clipboard copy/move and partial retry, mutation refresh and lifecycle passed")
    }

    static func testGitOperationLifecycle(in root: URL, defaults: UserDefaults, clipboard: NSPasteboard) async throws {
        let parent = root.appendingPathComponent("git-model")
        let repository = parent.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"),
                                               withIntermediateDirectories: true)
        let model = DirectoryBrowserModel(defaults: defaults, homeDirectory: parent, initialDirectory: parent,
            indexDatabaseURL: root.appendingPathComponent("git-model-index.sqlite"), pasteboard: clipboard,
            sizeCacheURL: root.appendingPathComponent("git-model-cache/sizes.json"))
        defer { model.suspend(); model.stopSizeBackgroundWork() }
        model.start()
        try await settle { !model.isLoading && model.entries.contains { $0.isGitRepository } }
        precondition(!model.currentDirectoryIsGitRepository, "The parent of a repository was marked as a Git root")
        model.navigate(to: repository)
        try await settle { !model.isLoading && model.currentDirectoryIsGitRepository }
        precondition(model.beginGitOperation() && !model.beginGitOperation(), "Git operations must be serialized")
        model.createFile(name: "blocked.txt")
        precondition(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("blocked.txt").path),
                     "File mutations must not race a Git checkout")
        let changedFile = repository.appendingPathComponent("from-git.txt")
        try Data("Git operation result".utf8).write(to: changedFile)
        model.finishGitOperation(at: repository, error: nil)
        try await settle { !model.isWorking && !model.isLoading && model.entries.contains { $0.url == changedFile } }
        model.goUp()
        try await settle { !model.isLoading && !model.currentDirectoryIsGitRepository }
        precondition(model.beginGitOperation())
        model.suspend()
        model.finishGitOperation(at: repository, error: "fixture failure")
        precondition(!model.isLoading && !model.isWorking && model.errorMessage == "fixture failure",
                     "Completing a Git action offscreen must release the lock and preserve its error without reopening navigation")
        print("Directory Git integration: repository display, mutation locking, refresh and offscreen completion passed")
    }

    static func testUnifiedSearch(in root: URL, defaults: UserDefaults, clipboard: NSPasteboard) async throws {
        let manager = FileManager.default
        let workspace = root.appendingPathComponent("unified-search").resolvingSymlinksInPath()
        let current = workspace.appendingPathComponent("current", isDirectory: true)
        let nested = current.appendingPathComponent("nested", isDirectory: true)
        let elsewhere = workspace.appendingPathComponent("elsewhere", isDirectory: true)
        for folder in [nested, elsewhere] { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        let token = "nori-unified-\(UUID().uuidString)"
        let local = current.appendingPathComponent("z-" + token + ".txt")
        let descendant = nested.appendingPathComponent("b-" + token + ".txt")
        let global = elsewhere.appendingPathComponent(token)
        let hidden = elsewhere.appendingPathComponent("." + token)
        for file in [local, descendant, global, hidden] { try Data("search fixture".utf8).write(to: file) }
        let indexURL = root.appendingPathComponent("unified-index/files.sqlite")
        let fixtureIndex = try DirectorySearchIndex(databaseURL: indexURL)
        _ = try await fixtureIndex.rebuild(roots: [workspace])
        let model = DirectoryBrowserModel(defaults: defaults, homeDirectory: workspace, initialDirectory: current,
            indexDatabaseURL: indexURL, pasteboard: clipboard,
            sizeCacheURL: root.appendingPathComponent("unified-cache/state.json"))
        defer { model.suspend(); model.stopSizeBackgroundWork() }
        model.start()
        try await settle { !model.isLoading && model.entries.contains { $0.url == local } }
        model.showHidden = false
        model.query = token
        precondition(model.entries.map(\.url) == [local], "Current-folder matches must appear before asynchronous index results")
        try await settle { !model.isSearching }
        precondition(model.entries.map(\.url) == [local, descendant, global],
                     "Unified search must keep current folder and descendants ahead of a global exact-name match")
        precondition(Set(model.entries.map(\.id)).count == 3, "Current and indexed results were not deduplicated")
        model.select(entry: model.entries[0], extending: false)
        model.showHidden = true
        try await settle { !model.isSearching && model.entries.contains { $0.url == hidden } }
        precondition(model.entries.prefix(2).map(\.url) == [local, descendant], "Hidden global results displaced current matches")
        model.query = token + "-missing"
        model.query = ""
        precondition(!model.isSearching && model.entries.count == 2, "Clearing search did not restore normal folder browsing")
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(model.entries.count == 2 && model.pathMatchScores.isEmpty, "Cancelled global search overwrote folder browsing")
        let limitToken = token + "-limit"
        for number in 0..<301 {
            try Data().write(to: elsewhere.appendingPathComponent("\(limitToken)-\(number).txt"))
        }
        _ = try await fixtureIndex.rebuild(roots: [workspace])
        model.query = limitToken
        try await settle { !model.isSearching }
        precondition(model.entries.count == 300 && model.statusMessage != nil, "Search limit was not reported")
        model.query = ""
        precondition(model.entries.count == 2 && model.statusMessage == nil, "Clearing search retained the previous result-limit message")
        print("Unified search: immediate current results, global merge, proximity before exact name, deduplication, hidden files and cancellation passed")
    }

    static func testTargetedPaste(in root: URL, defaults: UserDefaults, clipboard: NSPasteboard) async throws {
        let manager = FileManager.default
        let workspace = root.appendingPathComponent("targeted-paste-workspace")
        let parent = workspace.appendingPathComponent("parent")
        let child = parent.appendingPathComponent("child-folder")
        let otherParent = workspace.appendingPathComponent("other-parent")
        let payload = parent.appendingPathComponent("targeted-payload.txt")
        let anchor = otherParent.appendingPathComponent("unique-global-paste-anchor.txt")
        try manager.createDirectory(at: child, withIntermediateDirectories: true)
        try manager.createDirectory(at: otherParent, withIntermediateDirectories: true)
        try Data("targeted clipboard payload".utf8).write(to: payload)
        try Data("global selection".utf8).write(to: anchor)
        let indexURL = root.appendingPathComponent("targeted-paste-index/files.sqlite")
        let fixtureIndex = try DirectorySearchIndex(databaseURL: indexURL)
        _ = try await fixtureIndex.rebuild(roots: [workspace])
        let seededAnchor = try await fixtureIndex.search(query: "unique-global-paste-anchor")
        precondition(seededAnchor.contains { $0.url.lastPathComponent == anchor.lastPathComponent },
                     "Targeted-paste fixture did not seed its local global-search anchor")

        let model = DirectoryBrowserModel(defaults: defaults, homeDirectory: workspace, initialDirectory: parent,
            indexDatabaseURL: indexURL, pasteboard: clipboard,
            sizeCacheURL: root.appendingPathComponent("targeted-paste-cache/state.json"))
        defer { model.suspend(); model.stopSizeBackgroundWork() }
        model.start()
        try await settle { !model.isLoading && model.entries.count == 2 }
        let source = model.entries.first { $0.name == payload.lastPathComponent }!
        let targetFolder = model.entries.first { $0.name == child.lastPathComponent }!
        model.select(entry: source, extending: false)
        model.copySelection()
        model.select(entry: targetFolder, extending: false)
        let initialDirectory = model.currentDirectory.path
        let initialHistory = model.history.map(\.path)
        let initialPosition = model.historyPosition
        let initialBack = model.canGoBack
        let initialForward = model.canGoForward
        model.paste(into: targetFolder.url)
        try await settle { !model.isWorking && !model.isLoading }
        let firstCopy = child.appendingPathComponent(payload.lastPathComponent)
        precondition(manager.fileExists(atPath: firstCopy.path), "Explicit folder paste did not write inside the selected child folder")
        let firstContents = try Data(contentsOf: firstCopy)
        precondition(firstContents == Data("targeted clipboard payload".utf8),
                     "Explicit folder paste changed the copied file contents")
        precondition(manager.fileExists(atPath: payload.path), "Explicit copy/paste removed its source")
        precondition(model.currentDirectory.path == initialDirectory && model.history.map(\.path) == initialHistory
            && model.historyPosition == initialPosition && model.canGoBack == initialBack && model.canGoForward == initialForward,
            "Pasting into a row's child folder navigated away from its parent or changed history")

        model.query = "unique-global-paste-anchor"
        try await settle { !model.isSearching && model.entries.contains { $0.name == anchor.lastPathComponent } }
        let globalSelection = model.entries.first { $0.name == anchor.lastPathComponent }!
        model.select(entry: globalSelection, extending: false)
        precondition(model.breadcrumbDirectory.path == globalSelection.url.deletingLastPathComponent().path
            && model.breadcrumbDirectory.path != initialDirectory,
            "Global fixture did not point the breadcrumb at another parent")
        model.paste(into: targetFolder.url)
        try await settle { !model.isWorking && !model.isLoading }
        let secondCopy = child.appendingPathComponent("targeted-payload 2.txt")
        precondition(manager.fileExists(atPath: secondCopy.path), "Global selection overrode the explicit folder paste target")
        precondition(!manager.fileExists(atPath: otherParent.appendingPathComponent(payload.lastPathComponent).path),
                     "Explicit folder paste incorrectly wrote into the selected search result's parent")
        precondition(model.currentDirectory.path == initialDirectory && model.history.map(\.path) == initialHistory
            && model.historyPosition == initialPosition && model.query == "unique-global-paste-anchor",
            "Targeted paste altered global search navigation or history")
        print("Directory targeted paste: selected child destination, unchanged navigation/history and explicit target over global breadcrumb passed")
    }

    static func testBackgroundSizes(in root: URL, defaults: UserDefaults, clipboard: NSPasteboard) async throws {
        let parent = root.appendingPathComponent("size-workspace")
        let folder = parent.appendingPathComponent("folder")
        let nested = folder.appendingPathComponent(".nested")
        let payload = nested.appendingPathComponent("payload.bin")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x71, count: 32_768).write(to: payload)
        let cacheURL = root.appendingPathComponent("background-cache/sizes.json")
        let model = DirectoryBrowserModel(defaults: defaults, homeDirectory: parent, initialDirectory: parent,
            indexDatabaseURL: root.appendingPathComponent("background-index.sqlite"), pasteboard: clipboard,
            sizeCacheURL: cacheURL)
        defer { model.suspend(); model.stopSizeBackgroundWork() }
        var suspendedDuringCalculation = false
        let sizeSubscription = model.$isCalculatingSizes.dropFirst().sink { calculating in
            if calculating, !suspendedDuringCalculation {
                suspendedDuringCalculation = true
                model.suspend()
            }
        }
        model.start()
        try await settle { model.sizeStates[folder.path] == .complete && !model.isCalculatingSizes }
        precondition(suspendedDuringCalculation, "Fixture did not suspend queued size work")
        sizeSubscription.cancel()
        model.start()
        try await settle { !model.isLoading }
        let initial = DirectoryFileService.allocatedSize(of: folder)
        precondition(model.entries.first?.allocatedBytes == initial.bytes)
        let initialUpdated = model.sizeUpdatedAt[folder.path]!
        model.query = "fold"
        model.query = ""
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(model.sizeUpdatedAt[folder.path] == initialUpdated,
                     "Filtering recalculated a fresh cached folder")

        // Real recursive events must work while the tab's navigation watcher is stopped.
        model.suspend()
        try Data(repeating: 0x72, count: 131_072).write(to: payload)
        let changed = DirectoryFileService.allocatedSize(of: folder)
        try await settle {
            model.entries.first?.allocatedBytes == changed.bytes
                && model.sizeStates[folder.path] == .complete && !model.isCalculatingSizes
        }
        precondition(!model.isLoading, "Background size updates resumed suspended navigation")

        // The periodic reconciliation explicitly rechecks nested file fingerprints.
        try Data(repeating: 0x73, count: 262_144).write(to: payload)
        let calibrated = DirectoryFileService.allocatedSize(of: folder)
        let beforeCalibration = model.sizeUpdatedAt[folder.path]!
        await model.runScheduledSizeRefresh(now: Date().addingTimeInterval(6 * 3600 + 60))
        try await settle {
            model.entries.first?.allocatedBytes == calibrated.bytes
                && model.sizeUpdatedAt[folder.path]! > beforeCalibration && !model.isCalculatingSizes
        }

        model.start()
        try await settle { !model.isLoading }
        model.navigate(to: folder)
        try await settle { model.sizeStates[nested.path] == .complete && !model.isCalculatingSizes }
        model.createFile(name: "created.txt")
        try await settle { !model.isWorking && !model.isLoading }
        model.goBack()
        try await settle {
            model.sizeStates[folder.path] == .complete
                && model.sizeUpdatedAt[folder.path]! > beforeCalibration && !model.isCalculatingSizes
        }
        precondition(model.entries.first?.allocatedBytes == DirectoryFileService.allocatedSize(of: folder).bytes,
                     "Mutation failed to update the observed parent total")
        print("Directory background sizes: cached filtering, recursive hidden edits offscreen, six-hour calibration and ancestor mutation passed")
    }

    static func testIdleSizeRelease(in root: URL, defaults: UserDefaults, clipboard: NSPasteboard) async throws {
        let parent = root.appendingPathComponent("idle-size-workspace")
        let folder = parent.appendingPathComponent("folder")
        let payload = folder.appendingPathComponent("payload.bin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 32_768).write(to: payload)
        let model = DirectoryBrowserModel(defaults: defaults, homeDirectory: parent, initialDirectory: parent,
            indexDatabaseURL: root.appendingPathComponent("idle-index.sqlite"), pasteboard: clipboard,
            sizeCacheURL: root.appendingPathComponent("idle-cache/sizes.json"), sizeIdleReleaseDelay: 0.15)
        defer { model.suspend(); model.stopSizeBackgroundWork() }
        model.start()
        try await settle { model.sizeStates[folder.path] == .complete && !model.isCalculatingSizes }
        let initialBytes = model.entries.first?.allocatedBytes
        let initialUpdated = model.sizeUpdatedAt[folder.path]

        model.suspend()
        try await settle { model.sizeStates[folder.path] == .stale }
        precondition(model.entries.first?.allocatedBytes == initialBytes,
                     "Idle release discarded the displayed size summary")
        try Data(repeating: 0x62, count: 131_072).write(to: payload)
        await model.runScheduledSizeRefresh(force: true)
        precondition(!model.isCalculatingSizes && model.sizeUpdatedAt[folder.path] == initialUpdated,
                     "Idle workspace restarted background measurement")

        model.start()
        precondition(model.entries.first?.allocatedBytes == initialBytes,
                     "Reopening lost the cached total before measurement completed")
        let changed = DirectoryFileService.allocatedSize(of: folder)
        try await settle {
            model.entries.first?.allocatedBytes == changed.bytes
                && model.sizeStates[folder.path] == .complete && !model.isCalculatingSizes
        }
        precondition(model.sizeUpdatedAt[folder.path] != initialUpdated,
                     "Reopening failed to calibrate changes made while the watcher was stopped")

        model.suspend()
        model.start()
        try await settle { !model.isLoading && !model.isCalculatingSizes }
        let resumedUpdated = model.sizeUpdatedAt[folder.path]
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(model.sizeStates[folder.path] == .complete
            && model.sizeUpdatedAt[folder.path] == resumedUpdated,
                     "Returning within the grace period did not cancel the idle release")
        try Data(repeating: 0x63, count: 262_144).write(to: payload)
        let watched = DirectoryFileService.allocatedSize(of: folder)
        try await settle {
            model.entries.first?.allocatedBytes == watched.bytes
                && model.sizeStates[folder.path] == .complete && !model.isCalculatingSizes
        }
        print("Directory idle release: preserved totals, paused I/O, offline changes and quick-return cancellation passed")
    }

    static func testVisibleSizeCacheCapacity(in root: URL, defaults: UserDefaults, clipboard: NSPasteboard) async throws {
        let parent = root.appendingPathComponent("many-folders")
        for number in 0..<129 {
            try FileManager.default.createDirectory(at: parent.appendingPathComponent("folder-\(number)"),
                                                    withIntermediateDirectories: true)
        }
        let model = DirectoryBrowserModel(defaults: defaults, homeDirectory: parent, initialDirectory: parent,
            indexDatabaseURL: root.appendingPathComponent("many-index.sqlite"), pasteboard: clipboard,
            sizeCacheURL: root.appendingPathComponent("many-cache/sizes.json"))
        defer { model.suspend(); model.stopSizeBackgroundWork() }
        model.start()
        try await settle { model.sizeUpdatedAt.count == 129 && !model.isCalculatingSizes }
        let timestamps = model.sizeUpdatedAt
        model.query = "folder"
        model.query = ""
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(!model.isCalculatingSizes && model.sizeUpdatedAt == timestamps,
                     "Visible folders churned the bounded persistent inventory on filter changes")
        print("Directory visible totals: filtering reuses all 129 results beyond the persistent inventory capacity")
    }
}
