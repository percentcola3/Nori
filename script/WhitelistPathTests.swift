import Foundation

@main
struct WhitelistPathTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nori-whitelist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Folder With Spaces")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("notes.txt")
        try "fixture".write(to: file, atomically: true, encoding: .utf8)

        func expectPath(_ input: String, _ expected: String) throws {
            let actual = try WhitelistPath.validated(input, homeDirectory: root.path)
            precondition(actual == expected, "Path normalization mismatch")
        }
        func expectError(_ input: String, _ expected: WhitelistPath.ValidationError) {
            do {
                _ = try WhitelistPath.validated(input, homeDirectory: root.path)
                preconditionFailure("Invalid input was accepted")
            } catch let error as WhitelistPath.ValidationError {
                switch (error, expected) {
                case (.invalid, .invalid), (.missing, .missing): break
                default: preconditionFailure("Wrong validation failure")
                }
            } catch { preconditionFailure("Unexpected error") }
        }

        try expectPath(" \t\(directory.path) \r\n", directory.path)
        try expectPath("\"\(directory.path)\"", directory.path)
        try expectPath(file.path, file.path)
        try expectPath(directory.absoluteString, directory.path)
        try expectPath("~/Folder With Spaces/", directory.path)
        try expectPath("$HOME//Folder With Spaces", directory.path)
        try expectPath("${HOME}/Folder With Spaces", directory.path)
        try expectPath(root.path + "/future/*", root.path + "/future/*")
        expectError("", .invalid)
        expectError("relative/path", .invalid)
        expectError("~someone/Projects", .invalid)
        expectError(root.path + "/missing", .missing)
        expectError(directory.path + "\n" + file.path, .invalid)
        expectError(directory.path + "\u{0000}", .invalid)
        expectError(root.path + "/../etc", .invalid)
        expectError("file://remote.example/tmp", .invalid)
        expectError("file:///tmp?query=1", .invalid)
        expectError("file:///tmp/%0A", .invalid)
        expectError("file:///tmp/../etc", .invalid)
        print("Whitelist path tests passed")
    }
}
