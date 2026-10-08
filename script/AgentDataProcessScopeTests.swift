import Darwin
import Foundation

@main
struct AgentDataProcessScopeTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: message, code: 1) }
    }

    @MainActor
    static func main() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        func sample(_ pid: Int32, _ path: String, start: UInt64 = 100) -> ProcessSample {
            .init(identity: .init(pid: pid, startTime: start, ppid: 1, uid: getuid()), name: "codex", path: path,
                  cpuPercent: 0, residentBytes: 0, isZombie: false, isExiting: false, elapsed: 0)
        }
        func app(_ name: String, bundleID: String) throws -> String {
            let path = root.appendingPathComponent(name + ".app")
            let executable = path.appendingPathComponent("Contents/MacOS/Agent")
            try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x61]).write(to: executable)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name,
                "CFBundlePackageType": "APPL", "CFBundleExecutable": "Agent", "CFBundleVersion": "1"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: path.appendingPathComponent("Contents/Info.plist"))
            return path.path
        }
        func cli(_ agentID: String, _ prefix: String) throws -> AgentCLIInstallation {
            let package = root.appendingPathComponent(prefix + "/lib/node_modules/@fixture/agent")
            let target = package.appendingPathComponent("bin/agent.js")
            let launcher = root.appendingPathComponent(prefix + "/bin/agent")
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x61]).write(to: target)
            try manager.createSymbolicLink(at: launcher, withDestinationURL: target)
            return .init(id: agentID + ":" + prefix, agentID: agentID, name: "Same Name",
                executablePaths: [launcher.path], managedPaths: [package.path], manager: .npm,
                managerExecutable: nil, packageName: "@fixture/agent",
                identities: [package.path: DeletionPlan.identity(at: package.path)!, launcher.path: DeletionPlan.identity(at: launcher.path)!],
                detail: "fixture")
        }

        let desktopPath = try app("Trusted Desktop", bundleID: "com.fixture.codex")
        let editorPath = try app("Trusted Editor", bundleID: "com.fixture.editor")
        let impersonatorPath = try app("Codex", bundleID: "org.fixture.unrelated")
        let desktop = sample(40001, "/private/fixture-signing-clone/Agent")
        let editor = sample(40002, editorPath + "/Contents/MacOS/Agent")
        let impersonator = sample(40003, impersonatorPath + "/Contents/MacOS/Agent")
        let mismatch = sample(40004, impersonatorPath + "/Contents/MacOS/Agent")
        let noBundle = sample(40005, root.appendingPathComponent("missing.app/Contents/MacOS/Agent").path)
        let relative = sample(40006, "/private/fixture-relative/Agent")
        let firstCLI = try cli("codex", "prefix-one")
        let secondCLI = try cli("codex", "prefix-two")
        let otherCLI = try cli("gemini", "other-prefix")
        let allCLI = [firstCLI, otherCLI, secondCLI]
        var environment = AgentDataProcessScope.Environment()
        environment.resolvedOwnerIDs = { ids, _ in
            var owners = Set<String>()
            if ids.contains("codex") { owners.formUnion(["codex", "Codex", "com.fixture.codex"]) }
            if ids.contains("gemini") { owners.formUnion(["Code", "com.fixture.editor"]) }
            return owners
        }
        environment.applications = {
            [.init(bundleID: "com.fixture.codex", name: "Different Display Name", bundlePath: desktopPath, identity: desktop.identity),
             .init(bundleID: "com.fixture.editor", name: "Codex", bundlePath: editorPath, identity: editor.identity),
             .init(bundleID: "org.fixture.unrelated", name: "Codex", bundlePath: impersonatorPath, identity: impersonator.identity),
             .init(bundleID: "com.fixture.codex", name: "Codex", bundlePath: impersonatorPath, identity: mismatch.identity),
             .init(bundleID: "com.fixture.codex", name: "Codex", bundlePath: root.appendingPathComponent("missing.app").path, identity: noBundle.identity),
             .init(bundleID: "com.fixture.codex", name: "Codex", bundlePath: "relative/Trusted.app", identity: relative.identity)]
        }
        let samples = Dictionary([desktop, editor, impersonator, mismatch, noBundle, relative].map { ($0.identity, $0) },
                                 uniquingKeysWith: { first, _ in first })
        environment.current = { samples[$0] }
        let scope = AgentDataProcessScope.make(agentIDs: ["codex"], cli: allCLI, home: root.path, environment: environment)
        try expect(scope.roots.contains(desktopPath) && scope.applicationIdentities == [desktop.identity],
                   "A verified Workspace application's stable signing-clone identity was lost")
        try expect(!scope.roots.contains(editorPath) && !scope.roots.contains(impersonatorPath),
                   "Application names or mismatched bundle metadata expanded the data close scope")
        try expect((firstCLI.managedPaths + firstCLI.executablePaths + secondCLI.managedPaths + secondCLI.executablePaths)
            .allSatisfy(scope.contains) && !scope.contains(otherCLI.managedPaths[0]),
                   "Independent CLI prefixes were omitted or another Agent's installation was added")
        let unrelated = sample(40010, root.appendingPathComponent("arbitrary/codex").path)
        let selected = SoftwareUpdateProcesses.probe(scope, samples: [desktop, editor, impersonator, unrelated])
        try expect(selected.processes == [desktop], "A same-name executable was treated as a verified data consumer")
        let reused = sample(desktop.pid, unrelated.path, start: desktop.identity.startTime + 1)
        try expect(SoftwareUpdateProcesses.probe(scope, samples: [reused]).processes.isEmpty,
                   "A reused PID inherited the old Workspace application's close authority")
        var stale = environment
        stale.current = { _ in reused }
        let staleScope = AgentDataProcessScope.make(agentIDs: ["codex"], cli: [], home: root.path, environment: stale)
        try expect(staleScope.roots.isEmpty && staleScope.applicationIdentities.isEmpty,
                   "An already-stale Workspace identity authorized its old bundle root")

        let hostScope = AgentDataProcessScope.make(agentIDs: ["gemini"], cli: allCLI, home: root.path, environment: environment)
        try expect(hostScope.roots.contains(editorPath) && hostScope.applicationIdentities == [editor.identity]
                   && !hostScope.contains(firstCLI.managedPaths[0]) && hostScope.contains(otherCLI.managedPaths[0]),
                   "Extension host bundle IDs were not isolated to the selected Agent's runtime owners")
        var namesOnly = environment
        namesOnly.resolvedOwnerIDs = { _, _ in ["Codex", "codex", "Code"] }
        let noNameAuthority = AgentDataProcessScope.make(agentIDs: ["codex"], cli: [], home: root.path, environment: namesOnly)
        try expect(noNameAuthority.roots.isEmpty && noNameAuthority.applicationIdentities.isEmpty,
                   "A plain owner name authorized stopping an application")

        let scriptOne = sample(40011, "/usr/local/bin/node")
        let scriptTwo = sample(40012, "/usr/local/bin/node")
        let scriptOther = sample(40013, "/usr/local/bin/node")
        let arguments: [Int32: [String]] = [scriptOne.pid: ["node", firstCLI.managedPaths[0] + "/bin/agent.js"],
            scriptTwo.pid: ["node", secondCLI.managedPaths[0] + "/bin/agent.js"],
            scriptOther.pid: ["node", otherCLI.managedPaths[0] + "/bin/agent.js"]]
        let scripts = SoftwareUpdateProcesses.probe(scope, samples: [scriptOne, scriptTwo, scriptOther],
            arguments: { arguments[$0] }, workingDirectory: { _ in nil })
        try expect(scripts.processes == [scriptOne, scriptTwo], "CLI script ownership did not honor every independent prefix")

        let unknownTarget = root.appendingPathComponent("unknown-target")
        let unknownLink = root.appendingPathComponent("unknown-link")
        try Data([0x61]).write(to: unknownTarget)
        try manager.createSymbolicLink(at: unknownLink, withDestinationURL: unknownTarget)
        let linkOnly = AgentCLIInstallation(id: "unknown", agentID: "codex", name: "Codex",
            executablePaths: [unknownLink.path], managedPaths: [unknownLink.path], manager: .native,
            managerExecutable: nil, packageName: nil,
            identities: [unknownLink.path: DeletionPlan.identity(at: unknownLink.path)!], detail: "link only")
        let unknownScope = AgentDataProcessScope.make(agentIDs: ["codex"], cli: [linkOnly], home: root.path, environment: namesOnly)
        try expect(!unknownScope.contains(unknownTarget.path) && unknownScope.roots.isEmpty,
                   "A link-only installation authorized closing unrelated programs at its unknown target")
        try manager.removeItem(atPath: firstCLI.executablePaths[0])
        try manager.createSymbolicLink(atPath: firstCLI.executablePaths[0], withDestinationPath: unknownTarget.path)
        let changedLauncherScope = AgentDataProcessScope.make(agentIDs: ["codex"], cli: [firstCLI], home: root.path, environment: namesOnly)
        try expect(changedLauncherScope.contains(firstCLI.managedPaths[0]) && !changedLauncherScope.contains(unknownTarget.path),
                   "A replaced launcher widened the captured package's process scope")

        var empty = environment
        empty.applications = { fatalError("Empty selection inspected Workspace") }
        empty.resolvedOwnerIDs = { _, _ in fatalError("Empty selection resolved owners") }
        try expect(AgentDataProcessScope.make(agentIDs: [], cli: allCLI, home: root.path, environment: empty).roots.isEmpty,
                   "An empty selection acquired process authority")
        print("Agent data process scopes: verified bundle roots, stable identities, all CLI prefixes, extension hosts, names and replaced-launcher isolation passed")
    }
}
