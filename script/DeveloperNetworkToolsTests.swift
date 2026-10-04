import Foundation
import Darwin

@main struct DeveloperNetworkToolsTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    @MainActor static func main() throws {
        typealias Tools = DeveloperNetworkToolsService
        expect(Tools.validProxyURL("http://127.0.0.1:7897"), "manual HTTP endpoint rejected")
        expect(Tools.validProxyURL("socks5h://[::1]:1080"), "IPv6 SOCKS endpoint rejected")
        for value in ["http://user:password@proxy.test", "http://proxy.test?token=secret", "http://proxy.test\n", "file:///tmp/proxy", "--proxy"] {
            expect(!Tools.validProxyURL(value), "unsafe endpoint accepted: \(value)")
        }
        expect(Tools.validMirror("https://proxy.test,direct", tool: .go), "Go fallback rejected")
        expect(Tools.validMirror("https://proxy.test|https://fallback.test,direct", tool: .go), "Go pipe fallback rejected")
        expect(!Tools.validMirror("http://proxy.test,direct", tool: .go), "insecure Go mirror accepted")
        expect(Tools.validMirror("sparse+https://index.test/", tool: .cargo), "sparse Cargo index rejected")
        expect(!Tools.validMirror("https://user:password@index.test", tool: .cargo), "Cargo secret accepted")
        let docker = Tools.ProxyRow(layer: .docker, values: ["httpProxy": "https://user:secret@proxy.test:7890"], available: true)
        expect(!docker.display.contains("secret") && !docker.display.contains("user:"), "Docker proxy credential leaked")
        _ = try DeveloperNetworkTOMLValidator.validate("title = \"sample\"\narray = [1, true, \"value\"]\n[build]\njobs = 4\n[env]\nTEST = { value = \"x\", force = true }\n")
        for invalid in ["[build\njobs=4", "[build]\njobs = nope\n", "x=1\nx=2", "x=\"unterminated", "x = [1 2]"] {
            do { _ = try DeveloperNetworkTOMLValidator.validate(invalid); expect(false, "invalid TOML accepted") } catch {}
        }
        let quotedSource = try DeveloperNetworkTOMLValidator.validate("[ \"source\" . \"crates-io\" ]\nreplace-with = \"company\"\n")
        expect(quotedSource.sourceConfigured, "quoted source routing was missed")
        let config = "[build]\njobs = 4\n"
        let mirror = try DeveloperNetworkConfigStore.replacingCargoSource(config, target: "sparse+https://mirror.test/")
        expect(mirror.hasPrefix(config) && mirror.contains("replace-with = \"nori-registry\""), "Cargo unrelated configuration lost")
        let back = try DeveloperNetworkConfigStore.replacingCargoSource(mirror, target: Tools.MirrorTool.cargo.official)
        expect(!back.contains("nori-registry") && back.contains("jobs = 4"), "Cargo official restore lost existing config")
        do {
            _ = try DeveloperNetworkConfigStore.replacingCargoSource("[source.crates-io]\nreplace-with = \"company\"\n", target: "sparse+https://mirror.test/")
            expect(false, "Cargo existing source silently overwritten")
        } catch {}
        let root = URL(fileURLWithPath: "/private/var/tmp").appendingPathComponent("nori-network-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["git", "npm", "pip", "yarn", "pnpm", "go"] {
            try Data("fixture".utf8).write(to: bin.appendingPathComponent(name))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.appendingPathComponent(name).path)
        }
        let env = ["PATH": bin.path]
        let commands = try Tools.proxyCommand(layer: .npm, target: "http://localhost:7897", environment: env)
        expect(commands.count == 2 && commands[0].arguments == ["config", "set", "proxy", "http://localhost:7897", "--location=user"], "npm user scope incorrect")
        let modern = try Tools.mirrorCommand(tool: .yarn, target: "https://registry.test", environment: env, yarnModern: true)
        expect(modern.arguments.contains("npmRegistryServer") && modern.arguments.contains("--home"), "modern Yarn adapter incorrect")
        let classic = try Tools.mirrorCommand(tool: .yarn, target: "https://registry.test", environment: env)
        expect(classic.arguments == ["config", "set", "registry", "https://registry.test"], "classic Yarn adapter incorrect")
        let cargoDir = root.appendingPathComponent(".cargo")
        try FileManager.default.createDirectory(at: cargoDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let cargoPath = cargoDir.appendingPathComponent("config.toml")
        try Data(config.utf8).write(to: cargoPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cargoPath.path)
        let draft = try DeveloperNetworkConfigStore.cargoDraft(target: "sparse+https://mirror.test/", home: root.path)
        try DeveloperNetworkConfigStore.save(draft, home: root.path)
        let savedCargo = try String(contentsOf: cargoPath, encoding: .utf8)
        expect(savedCargo == draft.text, "Cargo atomic save failed")
        do { try DeveloperNetworkConfigStore.save(draft, home: root.path); expect(false, "Cargo stale draft overwrote saved file") } catch {}
        let linkRoot = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linkRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: linkRoot.appendingPathComponent(".cargo"), withDestinationURL: cargoDir)
        do { _ = try DeveloperNetworkConfigStore.cargoDraft(target: "https://mirror.test", home: linkRoot.path); expect(false, "Cargo symlink followed") } catch {}
        let terminal = DeveloperTerminalSnapshot(environment: ["ZDOTDIR": root.path], shell: "/bin/zsh", sampledAt: nil, duration: nil, failed: false)
        let shell = try DeveloperNetworkToolsModel.shellDraft(values: ["http_proxy": "http://localhost:7897", "all_proxy": nil], block: "proxy", terminal: terminal)
        expect(shell.text.contains("export http_proxy='http://localhost:7897'") && shell.text.contains("unset all_proxy"), "Shell block did not encode intended operations")
        do { _ = try DeveloperNetworkToolsModel.shellDraft(values: ["BAD;id": "x"], block: "proxy", terminal: terminal); expect(false, "arbitrary shell key accepted") } catch {}
        print("Network tools: typed adapters, HTTPS validation, redaction, Cargo identity/atomic backup/symlink checks and Shell blocks passed")
    }
}
