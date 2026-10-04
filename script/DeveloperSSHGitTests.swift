import Foundation
import Darwin
@main struct DeveloperSSHGitTests {
    static func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    static func main() throws {
        typealias Service = DeveloperSSHGitService
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".ssh"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        func blob(_ bytes: Data) -> Data { var value = UInt32(bytes.count).bigEndian; return withUnsafeBytes(of: &value) { Data($0) } + bytes }
        let publicData = blob(Data("ssh-ed25519".utf8)) + blob(Data(repeating: 42, count: 32))
        let text = "ssh-ed25519 " + publicData.base64EncodedString() + " fixture-comment\n"
        let publicPath = root.appendingPathComponent(".ssh/id_test.pub")
        try text.write(to: publicPath, atomically: false, encoding: .utf8)
        let privatePath = root.appendingPathComponent(".ssh/id_test")
        try "PRIVATE DATA MUST NOT BE READ".write(to: privatePath, atomically: false, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: privatePath.path)
        let keys = Service.keys(home: root.path)
        expect(keys.count == 1 && keys[0].type == "ssh-ed25519" && keys[0].bits == 256 && keys[0].needsPermissionRepair, "public inventory must work while private key is unreadable")
        expect(!keys[0].privatePermissionsLoose, "unreadable private key is not falsely reported as too broad")
        expect(try Service.publicKeyText(keys[0], home: root.path) == text.trimmingCharacters(in: .whitespacesAndNewlines), "public-only copy")
        try Service.repairPermissions(keys[0], home: root.path)
        expect((try fm.attributesOfItem(atPath: privatePath.path)[.posixPermissions] as! NSNumber).intValue == 0o600, "private permission repaired")
        expect((try fm.attributesOfItem(atPath: root.appendingPathComponent(".ssh").path)[.posixPermissions] as! NSNumber).intValue == 0o700, "directory permission repaired")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: privatePath.path)
        expect(Service.keys(home: root.path).first?.privatePermissionsLoose == true, "group/world private access detected without reading contents")
        try fm.removeItem(at: privatePath)
        try fm.createSymbolicLink(at: privatePath, withDestinationURL: root.appendingPathComponent("unrelated"))
        expect(Service.keys(home: root.path).first?.privatePath == nil, "private symlinks not followed")
        try fm.removeItem(at: publicPath)
        try fm.createSymbolicLink(at: publicPath, withDestinationURL: root.appendingPathComponent("outside.pub"))
        expect(Service.keys(home: root.path).isEmpty, "public symlinks not followed")
        let configURL = root.appendingPathComponent(".ssh/config")
        let original = "# preamble\nHost *\n    User fallback\n\nHost old\n    HostName old.example.com\n    User git\n    ProxyCommand existing-custom-command\n"
        try original.write(to: configURL, atomically: false, encoding: .utf8)
        let snapshot = try Service.readConfig(home: root.path)
        expect(snapshot.blocks.count == 2 && snapshot.blocks.allSatisfy { !$0.isEditable }, "wildcards and unknown directives stay read-only")
        let added = try Service.settingHost(in: snapshot, block: nil, host: "github-work", hostname: "github.com", user: "git", port: "22", identityFile: "~/.ssh/id_work")
        expect(added.hasPrefix("# preamble\nHost github-work\n") && added.contains("Host *\n    User fallback"), "new specific host precedes wildcard without rewriting existing blocks")
        try Service.saveConfig(added, replacing: snapshot, home: root.path)
        expect(try String(contentsOf: configURL, encoding: .utf8) == added, "safe config replacement")
        expect(try DeveloperShellBackupStore.history(targetPath: configURL.path, home: root.path).count == 1, "SSH config backup saved")
        let stale = try Service.readConfig(home: root.path)
        try "# external\n".write(to: configURL, atomically: false, encoding: .utf8)
        do { try Service.saveConfig(added, replacing: stale, home: root.path); fatalError("must reject external changes") } catch Service.Failure.changed {}
        let complex = "Host demo\n    User git\nMatch exec \"touch NEVER\"\n    User other\nInclude /tmp/unknown\n"
        expect(Service.parseConfig(complex).allSatisfy { !$0.isEditable }, "Include and Match exec never passed to ssh-G")
        let global = "User earlier\nHost demo\n    HostName example.com\n    User git\n"
        let globalSnapshot = Service.SSHConfig(text: global, data: Data(global.utf8), path: configURL.path, identity: nil, blocks: Service.parseConfig(global))
        do { _ = try Service.settingHost(in: globalSnapshot, block: nil, host: "work", hostname: "github.com", user: "git", port: "22", identityFile: "~/.ssh/id_work"); fatalError("must refuse global fields that win before host") } catch Service.Failure.invalid {}
        let environment = ["PATH": "/fixture/bin"]
        let ssh = Service.connectionCommand(host: "github.com", environment: environment, home: root.path)!
        expect(ssh.arguments.contains("StrictHostKeyChecking=yes") && ssh.arguments.contains("UpdateHostKeys=no") && ssh.arguments.contains("BatchMode=yes") && ssh.arguments.contains("/dev/null"), "connection uses strict noninteractive trust and bypasses exec-bearing config")
        expect(Service.connectionCommand(host: "github.com;touch x", environment: environment) == nil, "host catalog rejects injected names")
        expect(Service.gitCommand(field: .email, value: "bad\nvalue", environment: environment) == nil, "git writes reject line breaks")
        let commands = Service.directoryIdentityCommands(directory: root.path + "/work", name: "Example", email: "example@example.com", environment: environment, home: root.path, identifier: "fixture")!
        expect(commands.count == 3 && commands.last!.arguments.contains("includeIf.gitdir:" + root.standardizedFileURL.path + "/work/.path"), "identity plan uses official git config includeIf")
        expect(Service.keyGenerationScript(name: "-bad", comment: "example") == nil, "key generation cannot inject options")
        expect(Service.connectionSucceeded(output: "Hi example! You've successfully authenticated, but GitHub does not provide shell access.", exitCode: 1), "GitHub exit 1 may be authentication success")
        expect(!Service.connectionSucceeded(output: "Permission denied", exitCode: 255), "auth failure remains failure")
        print("SSH/Git fixture tests passed: public metadata, symlinks, permissions, ordered config, backups, conflicts, strict trust, command validation.")
    }
}
