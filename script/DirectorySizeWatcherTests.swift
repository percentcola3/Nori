import Foundation

@MainActor
private final class DirectoryWatcherRecorder {
    var changes: [URL] = []
    var rescans = 0
}

@main
struct DirectorySizeWatcherTests {
    @MainActor
    static func main() async {
        do { try await run() }
        catch {
            print("FAIL: \(error)")
            fflush(stdout)
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("nori-size-watch-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temporary) }
        let observed = temporary.appendingPathComponent("observed", isDirectory: true)
        let nested = observed.appendingPathComponent(".hidden/deep", isDirectory: true)
        let replacement = temporary.appendingPathComponent("replacement", isDirectory: true)
        let elsewhere = temporary.appendingPathComponent("elsewhere", isDirectory: true)
        for folder in [nested, replacement, elsewhere] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let recorder = DirectoryWatcherRecorder()
        let watcher = DirectorySizeWatcher(onChange: { recorder.changes += $0 }, onRescan: { recorder.rescans += 1 })
        defer { watcher.stop() }
        watcher.watch([observed, nested, URL(string: "https://example.com/")!])
        try await Task.sleep(nanoseconds: 250_000_000)

        let hiddenFile = nested.appendingPathComponent("hidden-change.bin")
        try Data(repeating: 7, count: 64).write(to: hiddenFile)
        // Rewatching the exact same set must preserve an already pending event.
        watcher.watch([nested, observed])
        try await wait("Nested hidden changes arrive using the caller's /var spelling") {
            recorder.changes.contains { $0.path == hiddenFile.standardizedFileURL.path }
        }
        expect(recorder.changes.allSatisfy { !$0.path.hasPrefix("/private/var/") }, "Physical /private paths map back to lexical cache keys")

        watcher.watch([replacement])
        recorder.changes = []
        let oldFile = nested.appendingPathComponent("old-stream.bin")
        let newFile = replacement.appendingPathComponent("new-stream.bin")
        try Data([1]).write(to: oldFile)
        try Data([2]).write(to: newFile)
        try await wait("A replacement stream receives its own folder changes") {
            recorder.changes.contains { $0.path == newFile.standardizedFileURL.path }
        }
        expect(!recorder.changes.contains { $0.path.hasPrefix(observed.path + "/") }, "Replaced stream callbacks cannot affect the current watcher")

        // A lexical descendant may point to a physically different observed subtree.
        // It must remain watched even when its lexical parent is already observed.
        let alias = observed.appendingPathComponent("linked-outside", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: elsewhere)
        let aliasedChild = alias.appendingPathComponent("child", isDirectory: true)
        let physicalChild = elsewhere.appendingPathComponent("child", isDirectory: true)
        try fm.createDirectory(at: physicalChild, withIntermediateDirectories: true)
        watcher.watch([observed, aliasedChild])
        recorder.changes = []
        let aliasFile = aliasedChild.appendingPathComponent("alias-change.bin")
        try Data([3]).write(to: aliasFile)
        try await wait("Explicit symlink-ancestor scopes receive events from their physical folder") {
            recorder.changes.contains { $0.path == aliasFile.standardizedFileURL.path }
        }

        let renameWatcher = DirectorySizeWatcher(onChange: { _ in }, onRescan: { recorder.rescans += 1 })
        renameWatcher.watch([replacement])
        try await Task.sleep(nanoseconds: 250_000_000)
        let previousRescans = recorder.rescans
        try fm.moveItem(at: replacement, to: temporary.appendingPathComponent("renamed-root", isDirectory: true))
        try await wait("Root rename requests filesystem calibration") { recorder.rescans > previousRescans }
        renameWatcher.stop()

        watcher.stop()
        recorder.changes = []
        let stopRescans = recorder.rescans
        try Data([4]).write(to: aliasFile)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        expect(recorder.changes.isEmpty && recorder.rescans == stopRescans, "Stopping drops both old callbacks and newly queued events")

        let gapFile = nested.appendingPathComponent("restart-gap.bin")
        try Data([6]).write(to: gapFile)
        // Let the system journal record the modification while no stream exists.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        watcher.watch([observed])
        try await wait("Restart replays journal events that occurred while the stream was stopped") {
            recorder.changes.contains { $0.path == gapFile.standardizedFileURL.path }
        }
        watcher.stop()

        let lifetimeRecorder = DirectoryWatcherRecorder()
        var ephemeral: DirectorySizeWatcher? = DirectorySizeWatcher(onChange: { lifetimeRecorder.changes += $0 }, onRescan: { lifetimeRecorder.rescans += 1 })
        weak var released = ephemeral
        ephemeral?.watch([observed])
        ephemeral = nil
        expect(released == nil, "The FSEvents context must not retain its watcher")
        released = nil
        try Data([5]).write(to: hiddenFile)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        expect(lifetimeRecorder.changes.isEmpty && lifetimeRecorder.rescans == 0, "Deallocated watchers cannot call their handlers")
        print("PASS: nested/hidden FSEvents, lexical and symlink-ancestor scope mapping, root-change calibration, stream replacement, journal replay across restart, stop and context lifetime")
    }

    @MainActor
    private static func wait(_ message: String, until condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        expect(condition(), message)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: " + message); fflush(stdout); exit(1) }
    }
}
