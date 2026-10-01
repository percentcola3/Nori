import Darwin
import Foundation

private func expectHostPresence(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

@main
struct AgentHostPresenceTests {
    static func main() throws {
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home").path
        let applications = home + "/Applications"
        let bin = home + "/bin"
        try fm.createDirectory(atPath: applications, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let context = AgentPresenceContext(applicationDirs: [applications], searchPath: [bin])
        let copilotIDs = ["github.copilot", "github.copilot-chat"]
        let manifestPath = home + "/.vscode/extensions/arbitrary-folder/package.json"
        let obsoletePath = home + "/.vscode/extensions/.obsolete"
        let codeApp = applications + "/Visual Studio Code.app"

        func write(_ path: String, data: Data) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path))
        }
        func json(_ path: String, _ object: Any) throws {
            try write(path, data: JSONSerialization.data(withJSONObject: object))
        }
        func executable(_ path: String, permissions: Int = 0o755) throws {
            try write(path, data: Data("fixture executable; never run\n".utf8))
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
        func app(_ path: String, bundleID: String, executableName: String = "Code") throws {
            let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL",
                                        "CFBundleExecutable": executableName]
            try write(path + "/Contents/Info.plist", data: PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0))
            try executable(path + "/Contents/MacOS/" + executableName)
        }
        func has(_ ids: [String] = ["anthropic.claude-code"]) -> Bool {
            AgentHostPresence.hasExtension(ids: ids, home: home, context: context)
        }
        func owners(_ ids: [String] = ["anthropic.claude-code"]) -> [String] {
            AgentHostPresence.owners(ids: ids, home: home, context: context)
        }

        // 宿主存在不能替代扩展存在；仅空app目录也不是宿主。
        try fm.createDirectory(atPath: codeApp, withIntermediateDirectories: true)
        expectHostPresence(!has(), "an empty host app directory was treated as an installed extension")
        try app(codeApp, bundleID: "com.microsoft.VSCode")
        expectHostPresence(!has(), "a real host with no extension was sufficient for presence")
        expectHostPresence(owners().isEmpty, "a host with no matching extension gained activity owners")
        try json(manifestPath, ["publisher": "anthropic", "name": "claude-code", "version": "1.0.0"])
        expectHostPresence(has(), "a matching physical manifest under an installed host was missed")
        expectHostPresence(owners() == ["Code", "com.microsoft.VSCode"],
                           "VSCode extension did not add its exact process and bundle owners")
        expectHostPresence(owners(["anthropic.claude-code", "ANTHROPIC.CLAUDE-CODE"]).count == 2,
                           "duplicate extension IDs duplicated activity owners")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: codeApp + "/Contents/MacOS/Code")
        expectHostPresence(!has(), "a host app with no executable binary was accepted")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codeApp + "/Contents/MacOS/Code")
        expectHostPresence(!has(copilotIDs), "directory names or another extension matched Copilot")
        expectHostPresence(!has([]), "empty extension IDs were accepted")
        expectHostPresence(has(["ANTHROPIC.CLAUDE-CODE"]), "extension ID normalization was inconsistent")

        // 真正卸载宿主后保留扩展目录，不代表扩展仍在运行。
        try fm.removeItem(atPath: codeApp)
        expectHostPresence(!has(), "an uninstalled IDE host retained extension presence")
        try app(codeApp, bundleID: "invalid.publisher")
        expectHostPresence(!has(), "a fake host bundle identifier was accepted")
        try fm.removeItem(atPath: codeApp)
        try app(codeApp, bundleID: "com.microsoft.VSCode")
        let savedApp = home + "/saved-code.app"
        try fm.moveItem(atPath: codeApp, toPath: savedApp)
        try fm.createSymbolicLink(atPath: codeApp, withDestinationPath: savedApp)
        expectHostPresence(!has(), "a symlinked host app was followed")
        try fm.removeItem(atPath: codeApp)
        try fm.moveItem(atPath: savedApp, toPath: codeApp)
        try fm.removeItem(atPath: manifestPath)
        expectHostPresence(!has(), "an uninstalled extension retained presence")
        try json(manifestPath, ["publisher": "fake-anthropic", "name": "claude-code"])
        expectHostPresence(!has(), "a lookalike publisher manifest was accepted")
        try json(manifestPath, ["publisher": "anthropic", "name": "claude-code-fake"])
        expectHostPresence(!has(), "a lookalike extension name was accepted")
        try json(manifestPath, ["publisher": "anthropic", "name": "claude-code"])

        // VS Code 已标记待删的旧包不应保活Agent；false和数字不能冒充boolean。
        try json(obsoletePath, ["arbitrary-folder": true])
        expectHostPresence(!has(), "an obsolete extension directory retained presence")
        expectHostPresence(owners().isEmpty, "an obsolete extension retained host activity owners")
        try json(obsoletePath, ["arbitrary-folder": false])
        expectHostPresence(has(), "a false obsolete marker hid a live extension")
        try json(obsoletePath, ["arbitrary-folder": 1])
        expectHostPresence(has(), "a numeric obsolete value was treated as JSON boolean")
        try write(obsoletePath, data: Data("invalid JSON".utf8))
        expectHostPresence(!has(), "a malformed obsolete index was trusted")
        try write(obsoletePath, data: Data(repeating: 32, count: 1_048_577))
        expectHostPresence(!has(), "an oversized obsolete index was trusted")
        let obsoleteCopy = home + "/obsolete-copy.json"
        try json(obsoleteCopy, [:] as [String: Bool])
        try fm.removeItem(atPath: obsoletePath)
        try fm.createSymbolicLink(atPath: obsoletePath, withDestinationPath: obsoleteCopy)
        expectHostPresence(!has(), "a symlinked obsolete index was followed")
        try fm.removeItem(atPath: obsoletePath)

        // 非对象/坏/超大manifest、symlink叶子均不跟随。
        try json(manifestPath, ["anthropic.claude-code"])
        expectHostPresence(!has(), "a non-object package manifest was accepted")
        try write(manifestPath, data: Data("invalid JSON".utf8))
        expectHostPresence(!has(), "a malformed package manifest was accepted")
        try write(manifestPath, data: Data(repeating: 32, count: 2_097_153))
        expectHostPresence(!has(), "an oversized package manifest was accepted")
        let alternate = home + "/external-manifest.json"
        try json(alternate, ["publisher": "anthropic", "name": "claude-code"])
        try fm.removeItem(atPath: manifestPath)
        try fm.createSymbolicLink(atPath: manifestPath, withDestinationPath: alternate)
        expectHostPresence(!has(), "a symlinked package manifest was followed")
        try fm.removeItem(atPath: manifestPath)
        try fm.createDirectory(atPath: manifestPath, withIntermediateDirectories: true)
        expectHostPresence(!has(), "a directory named package.json was accepted")
        try fm.removeItem(atPath: manifestPath)
        try json(manifestPath, ["publisher": "anthropic", "name": "claude-code"])
        let packageDirectory = (manifestPath as NSString).deletingLastPathComponent
        let packageCopy = home + "/package-copy"
        try fm.moveItem(atPath: packageDirectory, toPath: packageCopy)
        try fm.createSymbolicLink(atPath: packageDirectory, withDestinationPath: packageCopy)
        expectHostPresence(!has(), "a symlinked extension package directory was followed")
        try fm.removeItem(atPath: packageDirectory)
        try fm.moveItem(atPath: packageCopy, toPath: packageDirectory)

        // CLI宿主替代只接受普通可执行文件，不接受目录/不可执行文件/链接。
        try fm.removeItem(atPath: codeApp)
        try executable(bin + "/code", permissions: 0o644)
        expectHostPresence(!has(), "a nonexecutable CLI host was accepted")
        try executable(bin + "/code")
        expectHostPresence(has(), "a physical executable code host did not establish presence")
        try fm.removeItem(atPath: bin + "/code")
        try fm.createDirectory(atPath: bin + "/code", withIntermediateDirectories: true)
        expectHostPresence(!has(), "an executable directory named code was accepted")
        try fm.removeItem(atPath: bin + "/code")
        try executable(bin + "/actual-code")
        try fm.createSymbolicLink(atPath: bin + "/code", withDestinationPath: bin + "/actual-code")
        expectHostPresence(!has(), "a symlink CLI host was followed")
        try fm.removeItem(atPath: bin + "/code")

        // 各宿主只使用各自根；Insiders不能拿普通VSCode包保活，Cursor同理。
        try app(applications + "/Visual Studio Code - Insiders.app", bundleID: "com.microsoft.VSCodeInsiders")
        expectHostPresence(!has(), "Insiders was matched to the standard VSCode extension root")
        let insiders = home + "/.vscode-insiders/extensions/github.copilot-chat-1/package.json"
        try json(insiders, ["publisher": "github", "name": "copilot-chat"])
        expectHostPresence(has(copilotIDs), "a real Insiders Copilot extension was missed")
        expectHostPresence(owners(copilotIDs) == ["Code - Insiders", "com.microsoft.VSCodeInsiders"],
                           "Insiders Copilot did not return its own process and bundle owners")
        try fm.removeItem(atPath: applications + "/Visual Studio Code - Insiders.app")
        try app(applications + "/Cursor.app", bundleID: "com.todesktop.230313mzl4w4u92", executableName: "Cursor")
        let cursorRoot = home + "/.cursor/extensions"
        try json(cursorRoot + "/copilot/package.json", ["publisher": "github", "name": "copilot"])
        expectHostPresence(has(copilotIDs), "a real Cursor Copilot extension was missed")
        expectHostPresence(owners(copilotIDs) == ["Cursor", "com.todesktop.230313mzl4w4u92"],
                           "Cursor Copilot did not return its exact process and bundle owners")
        try app(codeApp, bundleID: "com.microsoft.VSCode")
        try json(manifestPath, ["publisher": "github", "name": "copilot-chat"])
        expectHostPresence(Set(owners(copilotIDs)) == Set([
            "Code", "com.microsoft.VSCode", "Cursor", "com.todesktop.230313mzl4w4u92"
        ]), "matching extensions in multiple IDEs lost a host's activity owners")
        try fm.removeItem(atPath: codeApp)
        let savedCursorRoot = home + "/cursor-extensions"
        try fm.moveItem(atPath: cursorRoot, toPath: savedCursorRoot)
        try fm.createSymbolicLink(atPath: cursorRoot, withDestinationPath: savedCursorRoot)
        expectHostPresence(!has(copilotIDs), "a symlinked extensions root was followed")
        print("AgentHostPresenceTests: passed")
    }
}
