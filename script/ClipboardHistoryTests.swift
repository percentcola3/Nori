import Foundation
import AppKit

@main
@MainActor
struct ClipboardHistoryTests {
    static func main() {
        let suite = "com.simplemole.clipboard-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simple-mole-clipboard-\(UUID().uuidString)",
                                    isDirectory: true)
        let historyURL = testDirectory.appendingPathComponent("history.plist")
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let manager = ClipboardHistoryManager(defaults: defaults, historyURL: historyURL)
        precondition(manager.capacity == 50, "default capacity must be 50")
        manager.updateCapacity(10)
        precondition(manager.capacity == 10, "capacity update failed")

        for index in 0..<12 {
            manager.record(.init(kind: .text, text: "item-\(index)",
                                 date: Date(timeIntervalSince1970: Double(index))))
        }
        precondition(manager.entries.count == 10, "oldest unpinned entries were not trimmed")
        precondition(manager.entries.last?.text == "item-2", "trim order is not oldest first")

        guard let pinnedID = manager.entries.last?.id else { fatalError("missing test entry") }
        manager.togglePinned(pinnedID)
        for index in 12..<15 {
            manager.record(.init(kind: .url, text: "https://example.com/\(index)",
                                 date: Date(timeIntervalSince1970: Double(index))))
        }
        precondition(manager.pinnedCount == 1, "pinned entry was lost")
        precondition(manager.unpinnedCount == 10, "capacity must apply only to unpinned entries")
        precondition(manager.entries.first?.id == pinnedID, "pinned entry is not kept first")

        let duplicate = ClipboardHistoryManager.Entry(kind: .text, text: "item-2")
        manager.record(duplicate)
        precondition(manager.entries.first?.id == pinnedID,
                     "re-copying pinned content must preserve pin identity")

        manager.clearUnpinned()
        precondition(manager.entries.count == 1 && manager.entries[0].isPinned,
                     "clear unpinned removed a pinned entry")

        let sourceURL = testDirectory.appendingPathComponent("large-source.bin")
        let sourceData = Data(repeating: 0x5a, count: 1024 * 1024)
        try! FileManager.default.createDirectory(at: testDirectory,
                                                 withIntermediateDirectories: true)
        try! sourceData.write(to: sourceURL)
        manager.record(.init(kind: .file, filePaths: [sourceURL.path]))

        let archiveAttributes = try! FileManager.default.attributesOfItem(
            atPath: historyURL.path)
        let archiveSize = (archiveAttributes[.size] as! NSNumber).intValue
        precondition(archiveSize < sourceData.count,
                     "file clipboard entry copied source contents into history storage")

        try! FileManager.default.removeItem(at: sourceURL)
        let restored = ClipboardHistoryManager(defaults: defaults, historyURL: historyURL)
        precondition(restored.entries.count == 2, "persisted entries were not restored")
        precondition(restored.pinnedCount == 1, "pinned state was not restored")
        precondition(restored.entries.contains {
            $0.kind == .file && $0.filePaths == [sourceURL.path] && $0.imageData == nil
        }, "file history must persist only its path index")
        let originalImage = Data(repeating: 0x23, count: 8 * 1024 * 1024)
        manager.record(.init(kind: .image, imageData: originalImage))
        precondition(manager.entries.filter { $0.kind == .image }.allSatisfy { $0.imageData == nil },
                     "Image history must keep metadata only, not full image payloads in memory")
        let image = manager.entries.first { $0.kind == .image }!
        precondition(image.byteCount == originalImage.count && manager.imageData(for: image) == originalImage,
                     "On-demand images must preserve original bytes and storage accounting")
        let smallArchive = try! Data(contentsOf: historyURL)
        precondition(smallArchive.count < 4096, "The metadata archive must not embed image payloads")
        manager.togglePinned(image.id)
        manager.record(.init(kind: .image, imageData: originalImage))
        precondition(manager.entries.filter { $0.kind == .image }.count == 1
                     && manager.entries.first { $0.kind == .image }?.id == image.id
                     && manager.entries.first { $0.kind == .image }?.isPinned == true,
                     "Content-addressed images must preserve duplicate and pin identity")
        let imageRestored = ClipboardHistoryManager(defaults: defaults, historyURL: historyURL)
        let storedImage = imageRestored.entries.first { $0.kind == .image }!
        precondition(storedImage.imageData == nil && imageRestored.imageData(for: storedImage) == originalImage,
                     "A restored image must read from disk without retaining its payload")
        let clipboard = NSPasteboard(name: .init("NoriMemoryFixture." + UUID().uuidString))
        let copied = imageRestored.copyToPasteboard(storedImage, to: clipboard)
        precondition(copied
                     && clipboard.data(forType: .tiff) == originalImage,
                     "Copying history must restore the exact original image: write=\(copied), readBytes=\(clipboard.data(forType: .tiff)?.count ?? -1)")
        clipboard.releaseGlobally()

        struct LegacyEntry: Codable {
            let id: UUID
            let kind: String
            let text: String?
            let filePaths: [String]
            let imageData: Data?
            let date: Date
            let isPinned: Bool
        }
        let legacyURL = testDirectory.appendingPathComponent("legacy.plist")
        let legacy = LegacyEntry(id: UUID(), kind: "image", text: nil, filePaths: [], imageData: originalImage,
            date: Date(timeIntervalSince1970: 1), isPinned: true)
        try! PropertyListEncoder().encode([legacy]).write(to: legacyURL)
        let migrated = ClipboardHistoryManager(defaults: defaults, historyURL: legacyURL)
        precondition(migrated.entries[0].id == legacy.id && migrated.entries[0].isPinned
                     && migrated.entries[0].imageData == nil && migrated.imageData(for: migrated.entries[0]) == originalImage
                     && (try! Data(contentsOf: legacyURL)).count < 4096,
                     "Migration must preserve old image identity, pins and bytes while replacing the archive with metadata")
        let unsafe = ClipboardHistoryManager.Entry(kind: .image, imageFileName: "../secret.tiff", imageByteCount: 1)
        precondition(migrated.imageURL(for: unsafe) == nil, "Archive references must not escape the owned image directory")
        let unavailableBoard = NSPasteboard(name: .init("NoriMissingImageFixture." + UUID().uuidString))
        unavailableBoard.setString("keep", forType: .string)
        precondition(!migrated.copyToPasteboard(unsafe, to: unavailableBoard)
                     && unavailableBoard.string(forType: .string) == "keep",
                     "A missing original image must not clear the current clipboard or report a successful copy")
        unavailableBoard.releaseGlobally()
        let blockedURL = testDirectory.appendingPathComponent("blocked.plist")
        try! PropertyListEncoder().encode([legacy]).write(to: blockedURL)
        try! Data("not a directory".utf8).write(to: testDirectory.appendingPathComponent("blocked-images"))
        let failedMigration = ClipboardHistoryManager(defaults: defaults, historyURL: blockedURL)
        precondition(failedMigration.entries[0].imageData == originalImage
                     && failedMigration.imageData(for: failedMigration.entries[0]) == originalImage,
                     "An image-store I/O failure must preserve the old inline history instead of losing the image")
        let imageURL = manager.imageURL(for: image)!
        let unowned = imageURL.deletingLastPathComponent().appendingPathComponent("keep.txt")
        try! Data("keep".utf8).write(to: unowned)
        manager.clear()
        precondition(!FileManager.default.fileExists(atPath: imageURL.path)
                     && FileManager.default.fileExists(atPath: unowned.path),
                     "Deleting history must remove owned payloads and preserve unrelated neighbors")
        print("Image payload: \(originalImage.count) bytes → 0 retained bytes; metadata archive \(smallArchive.count) bytes")
        print("Clipboard history tests passed")
    }
}
