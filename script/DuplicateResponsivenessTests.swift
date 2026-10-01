import Darwin
import Foundation

/// Exercises the same worker boundary as the app without opening user folders.
@main
struct DuplicateResponsivenessTests {
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DuplicateScanProgress] = []
        private var mainThreadCallback = false

        func record(_ event: DuplicateScanProgress) {
            lock.lock()
            events.append(event)
            mainThreadCallback = mainThreadCallback || Thread.isMainThread
            lock.unlock()
        }

        var snapshot: (events: [DuplicateScanProgress], mainThreadCallback: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (events, mainThreadCallback)
        }
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
    }

    @MainActor
    static func main() async throws {
        let watchdog = Task.detached {
            do { try await Task.sleep(nanoseconds: 90_000_000_000) }
            catch { return }
            expect(false, "worker did not finish or honor cancellation within 90 seconds")
        }
        defer { watchdog.cancel() }

        let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardized
        let root = home.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let smallGroupCount = 512
        let largeGroupMembers = 2_048
        let fileBytes = 4_096
        let largeContent = Data(repeating: 42, count: fileBytes)
        for index in 0..<largeGroupMembers {
            try largeContent.write(to: root.appendingPathComponent("large-\(index).dat"))
        }
        for group in 0..<smallGroupCount {
            var content = Data(repeating: 7, count: fileBytes)
            for byte in 0..<8 { content[byte] = UInt8((UInt64(group) >> (byte * 8)) & 255) }
            for member in 0..<2 {
                try content.write(to: root.appendingPathComponent("group-\(group)-\(member).dat"))
            }
        }

        let reports = ProgressRecorder()
        let began = ProcessInfo.processInfo.systemUptime
        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000) }
                catch { return }
                heartbeats += 1
            }
        }
        let result = await Task.detached(priority: .utility) {
            DuplicateScanWorker.scan(mode: .exact, roots: [root.path],
                                     control: DuplicateScanControl(), home: home.path,
                                     progress: reports.record)
        }.value
        heartbeat.cancel()
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let progress = reports.snapshot
        let expectedFiles = largeGroupMembers + smallGroupCount * 2
        expect(!result.cancelled && !result.partial && result.error == nil,
               "the safe fixture must complete without partial results")
        expect(result.scanned == expectedFiles, "the worker must retain all scanned files")
        expect(result.groups.count == smallGroupCount + 1,
               "hundreds of distinct groups must survive the UI-model conversion")
        expect(result.groups.reduce(0) { $0 + $1.members.count } == expectedFiles,
               "no members may be dropped from the worker snapshot")
        expect(result.groups.contains { $0.members.count == largeGroupMembers },
               "a large single group must retain all members")
        expect(result.groups.allSatisfy { group in
            group.members.allSatisfy { $0.file.sha256.count == 64 }
                && Set(group.members.map { $0.file.sha256 }).count == 1
        }, "converted exact groups must retain their full content identities")
        expect(result.reclaimableBytes == UInt64((largeGroupMembers - 1 + smallGroupCount) * fileBytes),
               "the snapshot must count additional copies while retaining one per group")
        expect(result.exactCopiesSkipped == 0, "exact mode must retain copies rather than skip them")
        expect(heartbeats > 0, "MainActor must run while the detached worker scans and constructs the snapshot")
        expect(!progress.mainThreadCallback, "service progress must not execute on the main thread")
        expect(progress.events.first?.phase == "enumerating" && progress.events.last?.phase == "finished",
               "progress must include discovery and completion")
        expect(progress.events.count < expectedFiles / 10,
               "progress must be throttled rather than publish once per file")

        let cancellation = DuplicateScanControl()
        let cancelReports = ProgressRecorder()
        let cancelled = await Task.detached(priority: .utility) {
            DuplicateScanWorker.scan(mode: .exact, roots: [root.path], control: cancellation,
                                     home: home.path) { event in
                cancelReports.record(event)
                if event.phase == "hashing" { cancellation.cancel() }
            }
        }.value
        expect(cancelReports.snapshot.events.contains { $0.phase == "hashing" },
               "cancellation must happen after discovery and sampling, during an active scan")
        expect(cancelled.cancelled && cancelled.partial && cancelled.groups.isEmpty,
               "cancelled scans must finish without actionable incomplete groups")
        expect(!cancelReports.snapshot.mainThreadCallback, "cancel progress must also remain off the main thread")

        expect(!DuplicateSelectionPolicy.canSelect(isSelected: false, unselectedCount: 0),
               "an invalid group without a keeper must not allow another selection")
        expect(!DuplicateSelectionPolicy.canSelect(isSelected: false, unselectedCount: 1),
               "the last unselected member must remain as a keeper")
        expect(DuplicateSelectionPolicy.canSelect(isSelected: false, unselectedCount: 2),
               "one of two remaining copies may be selected")
        expect(DuplicateSelectionPolicy.canSelect(isSelected: true, unselectedCount: 0),
               "a selected member must always be deselectable to restore a keeper")
        expect(DuplicateSelectionPolicy.canSelect(isSelected: true, unselectedCount: 1),
               "deselecting a member must remain possible when a keeper exists")

        print("Duplicate worker: \(expectedFiles) files, \(result.groups.count) groups, "
              + "\(String(format: "%.3f", elapsed))s, \(progress.events.count) background progress events, "
              + "\(heartbeats) MainActor heartbeats; cancellation and keep-one policy passed")
    }
}
