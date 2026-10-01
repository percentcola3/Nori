import Darwin
import Foundation

private func expectProjectStorage(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

@main
struct AgentProjectStorageTests {
    static func main() throws {
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home").path
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)

        func write(_ path: String, text: String = "fixture") throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
        func registry(_ rows: [[String: String]]) throws {
            let path = AgentCatalog.absolute(".local/share/crush/projects.json", home: home)
            let data = try JSONSerialization.data(withJSONObject: ["projects": rows])
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path))
        }
        func entry(_ dataDirectory: String, project: String? = nil) -> [String: String] {
            ["path": project ?? (dataDirectory as NSString).deletingLastPathComponent,
             "data_dir": dataDirectory, "last_accessed": "2026-10-01T00:00:00Z"]
        }

        let dataRoot = home + "/Code/one/.crush"
        let secondRoot = home + "/Code/two/.crush"
        let customRoot = home + "/CrushData/custom"
        let family = ["crush.db", "crush.db-wal", "crush.db-shm", "crush.db-journal"]
        for name in family { try write(dataRoot + "/" + name) }
        try write(dataRoot + "/crush-other.db")
        try write(dataRoot + "/logs/crush.log")
        try write(dataRoot + "/logs/crush-2026-10-01T00-00-00.123.log")
        try write(dataRoot + "/logs/unrelated.log")
        try write(dataRoot + "/logs/crush-personal.log")
        try write(dataRoot + "/skills/custom/SKILL.md")
        try write(dataRoot + "/crush.json")
        try write(secondRoot + "/crush.db-wal")
        try write(customRoot + "/crush.db")
        try registry([entry(dataRoot), entry(dataRoot), entry(secondRoot),
                      entry(customRoot, project: home + "/Code/one")])

        let paths = AgentProjectStorage.residualPaths(for: "crush", home: home)
        let expected = Set(family.map { dataRoot + "/" + $0 } + [
            dataRoot + "/logs/crush.log", dataRoot + "/logs/crush-2026-10-01T00-00-00.123.log",
            secondRoot + "/crush.db-wal", customRoot + "/crush.db"
        ])
        expectProjectStorage(Set(paths) == expected && paths.count == expected.count,
                             "registered data must contain only exact regular DB/log leaves: \(paths)")
        let targets = AgentProjectStorage.targets(for: "crush", home: home)
        expectProjectStorage(targets.filter { $0.tier == .safe }.count == 1
                             && targets.filter { $0.tier == .review }.count == 3,
                             "database/history and regenerable logs lost their risk tiers")
        expectProjectStorage(targets.allSatisfy { $0.owners == ["crush"] }, "Crush targets lost process owners")
        expectProjectStorage(targets.allSatisfy {
            guard case .leaves(let root, _) = $0.kind else { return false }
            return (root as NSString).isAbsolutePath
        }, "registry data_dir must remain absolute to avoid Agent-prefix environment remapping")
        expectProjectStorage(AgentProjectStorage.targets(for: "pi", home: home).isEmpty,
                             "unregistered agents gained Crush data targets")

        // 不接受宽泛 data_dir、工作目录本身、相对目录或范围外目录。
        let outside = fixture.appendingPathComponent("outside").path
        let broadRoots = [home, home + "/Library", home + "/Library/Application Support",
                          home + "/.config", home + "/.local/share", home + "/Code"]
        for root in broadRoots { try write(root + "/crush.db") }
        try write(outside + "/crush.db")
        try registry(broadRoots.map { entry($0, project: home + "/other-project") }
                     + [entry(outside), entry(dataRoot, project: dataRoot), entry("relative/.crush")])
        expectProjectStorage(AgentProjectStorage.residualPaths(for: "crush", home: home).isEmpty,
                             "a broad, external, relative, or project root was accepted")

        // root、父级、数据库、日志和registry任一级链接都不跟随；同名目录也不是数据库。
        let linkedRoot = home + "/Code/linked/.crush"
        try fm.createDirectory(atPath: (linkedRoot as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linkedRoot, withDestinationPath: dataRoot)
        let linkedParent = home + "/Code/linked-parent"
        try fm.createSymbolicLink(atPath: linkedParent, withDestinationPath: home + "/Code/one")
        let fakeRoot = home + "/Code/fake/.crush"
        try fm.createDirectory(atPath: fakeRoot + "/crush.db", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: fakeRoot + "/crush.db-wal", withDestinationPath: dataRoot + "/crush.db-wal")
        try fm.createDirectory(atPath: fakeRoot + "/logs", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: fakeRoot + "/logs/crush.log", withDestinationPath: dataRoot + "/logs/crush.log")
        try registry([entry(linkedRoot), entry(linkedParent + "/.crush"), entry(fakeRoot)])
        expectProjectStorage(AgentProjectStorage.residualPaths(for: "crush", home: home).isEmpty,
                             "symlink storage or a nonregular leaf escaped the boundary")

        let registryPath = AgentCatalog.absolute(".local/share/crush/projects.json", home: home)
        let alternate = home + "/registry-copy.json"
        try write(alternate, text: "{\"projects\":[{\"path\":\"\(home)/Code/one\",\"data_dir\":\"\(dataRoot)\"}]}")
        try fm.removeItem(atPath: registryPath)
        try fm.createSymbolicLink(atPath: registryPath, withDestinationPath: alternate)
        expectProjectStorage(AgentProjectStorage.targets(for: "crush", home: home).isEmpty,
                             "a symlinked registry was read")
        try fm.removeItem(atPath: registryPath)
        try write(registryPath, text: "not JSON")
        expectProjectStorage(AgentProjectStorage.targets(for: "crush", home: home).isEmpty,
                             "invalid registry did not fail closed")
        try write(registryPath, text: String(repeating: " ", count: 1_048_577))
        expectProjectStorage(AgentProjectStorage.targets(for: "crush", home: home).isEmpty,
                             "oversized registry was accepted")
        print("AgentProjectStorageTests: passed")
    }
}
