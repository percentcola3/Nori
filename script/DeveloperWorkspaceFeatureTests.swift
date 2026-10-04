import Foundation
import Darwin

@main
struct DeveloperWorkspaceFeatureTests {
    private static var failures: [String] = []
    static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try terminalFixtures()
        availableVersionFixtures()
        let environment = try toolchainFixtures(root: root)
        try await packageFixtures(environment: environment, root: root)
        try await snapshotFixtures(environment: environment, root: root)
        if !failures.isEmpty {
            print("Developer workspace fixtures failed: " + failures.joined(separator: "; "))
            exit(1)
        }
        print("Developer workspace: terminal framing, redaction, toolchain protection, package formats and snapshot safety passed")
    }

    private static func availableVersionFixtures() {
        let nvm = DeveloperAvailableVersions.parse("\u{1b}[32m v20.19.0 (LTS: Iron)\u{1b}[0m\n-> v22.2.0 (Latest LTS: Jod)\n v20.19.0\n N/A\n v22.2.0;touch marker\n", manager: .nvm)
        expect(nvm.map(\.version) == ["v22.2.0", "v20.19.0"] && nvm.allSatisfy(\.isLTS), "Available nvm versions strip ANSI escapes, deduplicate and reject command fragments")
        let sdk = DeveloperAvailableVersions.parse("Vendor | Use | Version | Dist | Status | Identifier\nTemurin | >>> | 21.0.7 | tem | installed | 21.0.7-tem\nZulu | | 17.0.15 | zulu | local only | 17.0.15-zulu\nEvil | | 0.1 | x | | 1.0$(cmd)\n", manager: .sdkman)
        expect(sdk.map(\.version) == ["21.0.7-tem", "17.0.15-zulu"], "Available SDKMAN versions use registered table identifiers")
        let maven = DeveloperAvailableVersions.parse("Available Maven Versions\n 3.9.11 3.9.10 3.8.8\n 3.9.11\n", manager: .sdkman)
        expect(maven.map(\.version) == ["3.9.11", "3.9.10", "3.8.8"], "SDKMAN non-Java candidates support plain multi-column version lists")
        let pyenv = DeveloperAvailableVersions.parse("Available versions:\n  3.13.2\n  3.12.9\n  ../3.14\n  3.13.2\n", manager: .pyenv)
        expect(pyenv.map(\.version) == ["3.13.2", "3.12.9"], "Available plain runtime lists ignore prose and unsafe paths")
    }

    private static func terminalFixtures() throws {
        let marker = "NORI-ENV-fixture"
        let framed = "startup warning\nwith multiple lines\0" + marker + "\0PATH\0/fixture/bin:/usr/bin\0HOME\0/fixture/home with spaces\0no_proxy\0localhost\nexample.test\0" + marker + "-end\0trailing startup output"
        let decoded = DeveloperTerminalEnvironmentService.decode(framed, marker: marker)
        expect(decoded?["PATH"] == "/fixture/bin:/usr/bin", "Environment framing ignores startup output")
        expect(decoded?["no_proxy"] == "localhost\nexample.test", "Environment framing preserves multiline values")
        expect(DeveloperTerminalEnvironmentService.decode(marker + "\0PATH\0/bin\0TOKEN\0secret\0" + marker + "-end", marker: marker) == nil,
               "Environment samples reject unknown keys")
        expect(DeveloperTerminalEnvironmentService.decode(marker + "\0HOME\0/fixture\0" + marker + "-end", marker: marker) == nil,
               "Environment samples require PATH")
        expect(DeveloperTerminalEnvironmentService.decode(marker + "\0PATH\0/bin\0HOME\0" + marker + "-end", marker: marker) == nil,
               "Environment samples reject incomplete key-value framing")
        expect(DeveloperTerminalEnvironmentService.decode(marker + "\0PATH\0" + String(repeating: "x", count: 65_537) + "\0" + marker + "-end", marker: marker) == nil,
               "Environment values have a fixed size limit")
        let secret = "https://alice:password@example.test/path?token=query-secret&ok=1\n_authToken=registry-secret\nAuthorization: Bearer access-secret\napi_key=api-secret\nPATH=/fixture/bin"
        let redacted = DeveloperSecretRedactor.redact(secret)
        expect(!["alice", "password@", "query-secret", "registry-secret", "access-secret", "api-secret"].contains(where: redacted.contains),
               "Credential URLs, token fields and authorization lines are redacted")
        expect(redacted.contains("example.test") && redacted.contains("PATH=/fixture/bin"), "Redaction preserves diagnostic hostnames and paths")
    }

    private static func toolchainFixtures(root: URL) throws -> [String: String] {
        let home = root.appendingPathComponent("home 'quoted $literal")
        let bin = home.appendingPathComponent("fixture-bin")
        for name in ["fnm", "pyenv", "rbenv", "asdf", "rustup", "brew", "npm", "pnpm", "pipx", "cargo", "dotnet", "code", "cursor"] {
            try inertExecutable(bin.appendingPathComponent(name))
        }
        try write("# inert fixture only\n", to: home.appendingPathComponent(".nvm/nvm.sh"))
        try write("# inert fixture only\n", to: home.appendingPathComponent(".sdkman/bin/sdkman-init.sh"))
        var env = ["HOME": home.path, "PATH": bin.path, "NVM_DIR": home.appendingPathComponent(".nvm").path,
                   "PYENV_ROOT": home.appendingPathComponent(".pyenv").path,
                   "RBENV_ROOT": home.appendingPathComponent(".rbenv").path,
                   "ASDF_DATA_DIR": home.appendingPathComponent(".asdf").path,
                   "SDKMAN_DIR": home.appendingPathComponent(".sdkman").path,
                   "RUSTUP_HOME": home.appendingPathComponent(".rustup").path,
                   "FNM_DIR": home.appendingPathComponent("fnm").path]
        for version in ["3.11.9", "3.12.5", "3.13.2"] { try inertExecutable(home.appendingPathComponent(".pyenv/versions/" + version + "/bin/python3")) }
        try write("3.11.9\n", to: home.appendingPathComponent(".pyenv/version"))
        let activePython = home.appendingPathComponent(".pyenv/versions/3.12.5/bin")
        env["PATH"] = activePython.path + ":" + bin.path
        let inventory = DeveloperToolchainService.inventory(environment: env, home: home.path)
        expect(inventory.contains { $0.manager == .pyenv && $0.version == "3.11.9" && $0.isDefault }, "Read pyenv's default without executing it")
        expect(inventory.contains { $0.manager == .pyenv && $0.version == "3.12.5" && $0.isActive }, "Resolve the actual active runtime path")
        expect(DeveloperToolchainService.command(manager: .pyenv, operation: .uninstall, version: "3.11.9", environment: env, home: home.path) == nil, "Protect the default runtime")
        expect(DeveloperToolchainService.command(manager: .pyenv, operation: .uninstall, version: "3.12.5", environment: env, home: home.path) == nil, "Protect the active runtime")
        expect(DeveloperToolchainService.command(manager: .pyenv, operation: .uninstall, version: "3.13.2", environment: env, home: home.path)?.arguments == ["uninstall", "-f", "3.13.2"], "Allow a known inactive runtime uninstall proposal")
        let malicious = ["--help", "3.13; touch marker", "$(touch marker)", "../3.13", "3.13\ninstall", ""]
        for version in malicious {
            expect(DeveloperToolchainService.command(manager: .pyenv, operation: .install, version: version, environment: env, home: home.path) == nil,
                   "Reject an unsafe version identifier: " + version.debugDescription)
        }
        expect(DeveloperToolchainService.command(manager: .asdf, operation: .install, version: "22.1.0", candidate: "nodejs;touch marker", environment: env, home: home.path) == nil, "Reject unsafe candidate identifiers")
        let nvm = DeveloperToolchainService.command(manager: .nvm, operation: .install, version: "v22.1.0", environment: env, home: home.path)
        expect(nvm?.arguments.suffix(2) == ["install", "v22.1.0"], "Nvm operands remain separate positional arguments")
        expect(nvm?.arguments.contains(home.appendingPathComponent(".nvm/nvm.sh").path) == true && nvm?.arguments.contains(where: { $0.contains("source \"$1\"") }) == true,
               "Source a validated manager file through a positional argument")
        try write("3.11.9 3.13.2\n", to: home.appendingPathComponent(".pyenv/version"))
        expect(DeveloperToolchainService.command(manager: .pyenv, operation: .uninstall, version: "3.13.2", environment: env, home: home.path) == nil,
               "Protect every version selected by a multi-version pyenv global")
        try write("3.11.9\n", to: home.appendingPathComponent(".pyenv/version"))
        let shims = home.appendingPathComponent(".pyenv/shims")
        try inertExecutable(shims.appendingPathComponent("python3"))
        var unknownActive = env; unknownActive["PATH"] = shims.path + ":" + bin.path
        expect(DeveloperToolchainService.command(manager: .pyenv, operation: .uninstall, version: "3.13.2", environment: unknownActive, home: home.path) == nil,
               "Refuse deletion when a manager shim leaves the active version unknown")
        for version in ["v20.1.0", "v22.2.0", "v23.1.0"] { try inertExecutable(home.appendingPathComponent(".nvm/versions/node/" + version + "/bin/node")) }
        try write("production\n", to: home.appendingPathComponent(".nvm/alias/default"))
        try write("release/team\n", to: home.appendingPathComponent(".nvm/alias/production"))
        try write("lts/*\n", to: home.appendingPathComponent(".nvm/alias/release/team"))
        try write("lts/jod\n", to: home.appendingPathComponent(".nvm/alias/lts/*"))
        try write("v22.2.0\n", to: home.appendingPathComponent(".nvm/alias/lts/jod"))
        expect(DeveloperToolchainService.defaultVersion(.nvm, candidate: "node", environment: env, home: home.path) == "v22.2.0", "Resolve nested nvm aliases through actual LTS metadata")
        expect(DeveloperToolchainService.command(manager: .nvm, operation: .uninstall, version: "v22.2.0", environment: env, home: home.path) == nil, "Protect the real LTS default rather than the newest non-LTS runtime")
        try write("missing-custom-alias\n", to: home.appendingPathComponent(".nvm/alias/default"))
        expect(DeveloperToolchainService.command(manager: .nvm, operation: .uninstall, version: "v20.1.0", environment: env, home: home.path) == nil, "Unknown nvm defaults refuse runtime deletion")
        try write("loop\n", to: home.appendingPathComponent(".nvm/alias/default"))
        try write("default\n", to: home.appendingPathComponent(".nvm/alias/loop"))
        expect(DeveloperToolchainService.defaultVersion(.nvm, candidate: "node", environment: env, home: home.path) == nil, "Bound cyclic nvm alias resolution")
        for version in ["20.1.0", "22.2.0", "23.1.0"] { try inertExecutable(home.appendingPathComponent(".asdf/installs/nodejs/" + version + "/bin/node")) }
        try write("nodejs 20.1.0 22.2.0 # both global defaults\n", to: home.appendingPathComponent(".tool-versions"))
        expect(DeveloperToolchainService.command(manager: .asdf, operation: .uninstall, version: "22.2.0", candidate: "nodejs", environment: env, home: home.path) == nil, "Protect every asdf global version")
        let modernAsdf = bin.appendingPathComponent("asdf")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]).write(to: modernAsdf)
        expect(DeveloperToolchainService.command(manager: .asdf, operation: .setDefault, version: "23.1.0", candidate: "nodejs", environment: env, home: home.path)?.arguments == ["set", "-u", "nodejs", "23.1.0"], "Modern native asdf uses set -u")
        try write("#!/usr/bin/env bash\n# legacy fixture\n", to: modernAsdf)
        expect(DeveloperToolchainService.command(manager: .asdf, operation: .setDefault, version: "23.1.0", candidate: "nodejs", environment: env, home: home.path)?.arguments == ["global", "nodejs", "23.1.0"], "Legacy Shell asdf uses global without a location heuristic")
        try write("unknown executable format\n", to: modernAsdf)
        expect(DeveloperToolchainService.command(manager: .asdf, operation: .setDefault, version: "23.1.0", candidate: "nodejs", environment: env, home: home.path) == nil, "Unknown asdf implementation refuses a default mutation")
        for version in ["stable-aarch64-apple-darwin", "nightly-aarch64-apple-darwin", "1.82.0-aarch64-apple-darwin"] { try inertExecutable(home.appendingPathComponent(".rustup/toolchains/" + version + "/bin/rustc")) }
        try write("default_toolchain = \"stable-aarch64-apple-darwin\"\n[overrides]\n\"/fixture/project\" = \"1.82.0-aarch64-apple-darwin\"\n", to: home.appendingPathComponent(".rustup/settings.toml"))
        var rustEnvironment = env; rustEnvironment["RUSTUP_TOOLCHAIN"] = "nightly"
        expect(DeveloperToolchainService.command(manager: .rustup, operation: .uninstall, version: "nightly-aarch64-apple-darwin", environment: rustEnvironment, home: home.path) == nil, "Protect a Rustup environment-selected alias")
        expect(DeveloperToolchainService.command(manager: .rustup, operation: .uninstall, version: "1.82.0-aarch64-apple-darwin", environment: env, home: home.path) == nil, "Protect Rustup project override toolchains")
        expect(DeveloperToolchainService.command(manager: .pyenv, operation: .available, environment: env, home: home.path)?.refreshAfterExecution == false, "Read-only available queries do not resample Shell startup")
        expect(DeveloperToolchainService.defaultCommand(manager: .pyenv, versions: ["3.11.9", "3.13.2"], environment: env, home: home.path)?.arguments == ["global", "3.11.9", "3.13.2"], "Multi-version pyenv defaults use one validated selection operation")
        expect(DeveloperToolchainService.defaultCommand(manager: .pyenv, versions: ["3.11.9", "3.13.2;cmd"], environment: env, home: home.path) == nil, "Every default selection operand is validated")
        expect(DeveloperToolchainService.defaultCommand(manager: .nvm, versions: ["v20.1.0", "v22.2.0"], environment: env, home: home.path) == nil, "Single-default managers reject ambiguous multi-version selections")
        let outsidePATH = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: outsidePATH, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: outsidePATH.appendingPathComponent("python3"), withDestinationURL: home.appendingPathComponent(".pyenv/versions/3.13.2/bin/python3"))
        var noRuntimePATH = env; noRuntimePATH["PATH"] = bin.path
        expect(DeveloperToolchainService.inventory(environment: noRuntimePATH, home: home.path).filter { $0.manager == .pyenv }.allSatisfy { !$0.isActive },
               "Discovery outside the sampled PATH does not mark an installation active")
        expect(DeveloperToolchainService.isHomebrewInstallation("/opt/homebrew/Cellar/fnm/1.0/bin/fnm", manager: .fnm)
               && DeveloperToolchainService.isHomebrewInstallation("/usr/local/opt/pyenv/libexec/pyenv", manager: .pyenv), "Recognize verified Homebrew Cellar and opt ownership")
        expect(!DeveloperToolchainService.isHomebrewInstallation("/usr/local/bin/pyenv", manager: .pyenv)
               && !DeveloperToolchainService.isHomebrewInstallation("/opt/homebrew/Cellar/custom/1.0/bin/pyenv", manager: .pyenv), "Custom local executables and other formulae do not acquire Homebrew ownership")
        expect(DeveloperToolchainService.command(manager: .pyenv, operation: .update, environment: env, home: home.path) == nil,
               "A custom manager installation does not propose a Homebrew upgrade")
        expect(DeveloperToolchainService.command(manager: .nvm, operation: .update, environment: env, home: home.path) == nil,
               "An actual local nvm.sh takes precedence over unrelated Homebrew installations")
        return env
    }

    private static func packageFixtures(environment: [String: String], root: URL) async throws {
        let npm = DeveloperPackageService.parsePackages(manager: "npm", output: #"{"dependencies":{"@scope/tool":{"version":"2.1.0"},"safe":{"version":"1.0.0"},"bad;name":{"version":"0.1"}}}"#)
        expect(npm.map(\.name) == ["@scope/tool", "safe"], "Parse npm objects and reject unsafe package names")
        let pnpm = DeveloperPackageService.parsePackages(manager: "pnpm", output: #"[{"dependencies":{"first":{"version":"1"}}},{"dependencies":{"second":{"version":"2"}}}]"#)
        expect(Set(pnpm.map(\.name)) == ["first", "second"], "Parse every pnpm array inventory entry")
        let pipx = DeveloperPackageService.parsePackages(manager: "pipx", output: #"{"venvs":{"ruff":{"metadata":{"main_package":{"package_version":"0.8.0"}}}}}"#)
        expect(pipx.first?.version == "0.8.0", "Parse pipx's nested venv metadata")
        expect(DeveloperPackageService.parsePackages(manager: "cargo", output: "ripgrep v14.1.0:\n    rg\nfd-find v10.2.0:\n    fd\n").map(\.name) == ["ripgrep", "fd-find"], "Cargo command names are not packages")
        expect(DeveloperPackageService.parsePackages(manager: "dotnet", output: "Package Id      Version     Commands\n----------------------------------\ndotnet-ef       9.0.0       dotnet-ef\n").map(\.name) == ["dotnet-ef"], "Skip dotnet table headers")
        expect(DeveloperPackageService.parsePackages(manager: "npm", output: "{ invalid").isEmpty, "Malformed package JSON produces no forged packages")
        for name in ["--force", "valid;rm", "@scope/x$(cmd)", "../bad", "bad\nname"] {
            expect(DeveloperPackageService.command("uninstall", manager: "npm", name: name, environment: environment) == nil, "Reject unsafe package operands: " + name.debugDescription)
        }
        expect(DeveloperPackageService.command("start", name: "", environment: environment) == nil, "Service actions require an explicit name")
        expect(DeveloperPackageService.command("unknown", name: "safe", environment: environment) == nil, "Package actions use a fixed operation catalog")
        expect(DeveloperPackageService.command("uninstall", manager: "brew-cask", name: "safe", environment: environment)?.arguments == ["uninstall", "--cask", "safe"], "Cask deletion uses a fixed cask operation")
        var responses: [String: RunResult] = [:]
        func result(_ name: String, _ args: [String], _ output: String, exit: Int32 = 0) { responses[MoleEngine.key(name, args)] = .init(output: output, exitCode: exit, timedOut: false) }
        result("brew", ["list", "--versions"], "jq 1.7\n")
        result("brew", ["list", "--cask", "--versions"], "visual-studio-code 1.90\n")
        result("npm", ["ls", "-g", "--depth=0", "--json"], #"{"dependencies":{"typescript":{"version":"5.6"}}}"#)
        result("pnpm", ["ls", "-g", "--depth=0", "--json"], #"[{"dependencies":{"eslint":{"version":"9.0"}}}]"#)
        result("pipx", ["list", "--json"], #"{"venvs":{}}"#)
        result("cargo", ["install", "--list"], "")
        result("dotnet", ["tool", "list", "--global"], "")
        result("brew", ["services", "info", "--all", "--json"], "unsupported info fixture", exit: 2)
        result("brew", ["services", "list", "--json"], #"[{"name":"postgresql","status":"started","file":"/fixture/service.plist"}]"#)
        result("brew", ["outdated", "--json=v2"], #"{"formulae":[{"name":"jq","current_version":"1.8"}],"casks":[]}"#)
        result("npm", ["outdated", "-g", "--json"], #"{"typescript":{"latest":"5.8"}}"#, exit: 1)
        result("pnpm", ["outdated", "-g", "--json"], #"{"eslint":{"latest":"9.2"}}"#, exit: 1)
        MoleEngine.reset(root: root.path, responses: responses)
        let scan = await DeveloperPackageService.scan(environment: environment, checkUpdates: true)
        expect(scan.packages.first { $0.name == "typescript" }?.available == "5.8", "Parse an outdated inventory even when the manager uses exit 1")
        expect(scan.packages.first { $0.name == "eslint" }?.available == "9.2", "Associate pnpm update information with the correct manager")
        expect(scan.services.first?.name == "postgresql", "Read structured service inventory")
        expect(MoleEngine.invocations.contains { $0.arguments == ["services", "info", "--all", "--json"] }
               && MoleEngine.invocations.contains { $0.arguments == ["services", "list", "--json"] }, "Older Homebrew service inventories fall back to services list")
        expect(MoleEngine.invocations.allSatisfy { $0.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1" }, "Inventory commands suppress automatic Homebrew updates")
        expect(!MoleEngine.invocations.contains { ($0.arguments.first == "install" && $0.arguments != ["install", "--list"]) || $0.arguments.first == "uninstall" || $0.arguments == ["upgrade"] }, "Package inventory does not run mutation commands")
    }

    private static func snapshotFixtures(environment: [String: String], root: URL) async throws {
        let directory = root.appendingPathComponent("snapshot-input")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func save(_ items: [DeveloperSnapshotService.Item], format: Int = 1) throws {
            let manifest = DeveloperSnapshotService.Manifest(formatVersion: format, createdAt: Date(timeIntervalSince1970: 0), architecture: "fixture", items: items)
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        }
        let safe = DeveloperSnapshotService.Item(kind: .package, manager: "npm", name: "@scope/tool", version: "1.0.0", isDefault: false)
        try save([safe])
        try write("touch injected-script-marker\n", to: directory.appendingPathComponent("restore.sh"))
        try write("system 'touch injected-brewfile-marker'\n", to: directory.appendingPathComponent("Brewfile"))
        MoleEngine.reset(root: root.path)
        let manifest = try DeveloperSnapshotService.read(from: directory)
        expect(manifest.items == [safe] && MoleEngine.invocations.isEmpty, "Snapshot import reads the manifest and ignores executable helpers")
        expect(safe.command(environment: environment)?.arguments == ["install", "-g", "@scope/tool"], "Restore reconstructs registered argument arrays")
        let runtime = DeveloperSnapshotService.Item(kind: .runtime, manager: "pyenv", name: "python", version: "3.13.2", isDefault: true)
        let runtimeCommands = runtime.commands(environment: environment)
        expect(runtimeCommands.map(\.arguments) == [["install", "3.13.2"], ["global", "3.13.2"]], "Runtime restoration installs before selecting the default")
        expect(runtimeCommands.count == 2 && runtimeCommands[0].operationGroup != nil && runtimeCommands[0].operationGroup == runtimeCommands[1].operationGroup, "Runtime install and default selection share a failure group")
        let existingRuntime = DeveloperManagedVersion(manager: .pyenv, candidate: "python", version: "3.13.2", path: "/fixture/python", isDefault: false, isActive: false)
        expect(runtime.commands(environment: environment, installed: [existingRuntime]).map(\.arguments) == [["global", "3.13.2"]], "Existing runtimes skip reinstall while restoring their default selection")
        let retained = DeveloperSnapshotService.Item(kind: .runtime, manager: "pyenv", name: "python", version: "3.13.2", isDefault: false)
        expect(retained.commands(environment: environment, installed: [existingRuntime]).isEmpty, "Already-installed non-default runtimes need no restore mutation")
        let extensionItem = DeveloperSnapshotService.Item(kind: .editorExtension, manager: "code", name: "publisher.extension", version: "1.2.3", isDefault: false)
        expect(extensionItem.command(environment: environment)?.arguments == ["--install-extension", "publisher.extension@1.2.3"], "Extension restoration uses a validated extension identifier and version")
        let firstDefault = DeveloperSnapshotService.Item(kind: .runtime, manager: "pyenv", name: "python", version: "3.11.9", isDefault: true, defaultOrder: 1)
        let priorityDefault = DeveloperSnapshotService.Item(kind: .runtime, manager: "pyenv", name: "python", version: "3.13.2", isDefault: true, defaultOrder: 0)
        let aggregate = DeveloperSnapshotService.restoreCommands([firstDefault, priorityDefault, safe, extensionItem], environment: environment, installed: [existingRuntime])
        expect(aggregate.prefix(2).map(\.arguments) == [["install", "3.11.9"], ["global", "3.13.2", "3.11.9"]], "Aggregate restore installs missing runtimes before one ordered multi-default selection")
        expect(aggregate.count == 4 && aggregate[0].operationGroup != nil && aggregate[0].operationGroup == aggregate[1].operationGroup
               && aggregate[1].operationGroup != aggregate[2].operationGroup && aggregate[2].operationGroup != aggregate[3].operationGroup,
               "Runtime restoration shares one failure group and unrelated package or extension work keeps separate groups")
        for order in [-1, 128] {
            var invalidOrder = firstDefault; invalidOrder.defaultOrder = order
            try save([invalidOrder]); expectThrows("Reject out-of-range default ordering") { _ = try DeveloperSnapshotService.read(from: directory) }
        }
        var maximumOrder = firstDefault; maximumOrder.defaultOrder = 127
        try save([maximumOrder])
        let boundaryManifest = try DeveloperSnapshotService.read(from: directory)
        expect(boundaryManifest.items.first?.defaultOrder == 127, "Accept supported default ordering boundaries")
        for item in [DeveloperSnapshotService.Item(kind: .package, manager: "npm", name: "safe;touch marker", version: "1", isDefault: false),
                     .init(kind: .runtime, manager: "pyenv", name: "python", version: "3.13$(cmd)", isDefault: false),
                     .init(kind: .runtime, manager: "brew", name: "java", version: "21", isDefault: false),
                     .init(kind: .package, manager: "unknown", name: "safe", version: "1", isDefault: false),
                     .init(kind: .editorExtension, manager: "code", name: "publisher.extension", version: "1.0$(cmd)", isDefault: false),
                     .init(kind: .editorExtension, manager: "unknown", name: "publisher.extension", version: "1", isDefault: false),
                     .init(kind: .editorExtension, manager: "cursor", name: "https://untrusted.vsix", version: "", isDefault: false)] {
            try save([item]); expectThrows("Reject injected snapshot fields") { _ = try DeveloperSnapshotService.read(from: directory) }
        }
        try save([safe, safe]); expectThrows("Reject duplicate snapshot identities") { _ = try DeveloperSnapshotService.read(from: directory) }
        try save([safe], format: 2); expectThrows("Reject unknown manifest versions") { _ = try DeveloperSnapshotService.read(from: directory) }
        let linkDirectory = root.appendingPathComponent("snapshot-link")
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkDirectory.appendingPathComponent("manifest.json"), withDestinationURL: directory.appendingPathComponent("manifest.json"))
        expectThrows("Reject a symbolic-link manifest") { _ = try DeveloperSnapshotService.read(from: linkDirectory) }
        let responses = [MoleEngine.key("code", ["--list-extensions", "--show-versions"]): RunResult(output: "publisher.extension@1.2.3\npassword=should-not-export\n", exitCode: 0, timedOut: false),
                         MoleEngine.key("cursor", ["--list-extensions", "--show-versions"]): RunResult(output: "", exitCode: 0, timedOut: false)]
        MoleEngine.reset(root: root.path, responses: responses)
        let packages = [DeveloperPackage(manager: "brew", name: "jq", version: "1.7", available: nil),
                        DeveloperPackage(manager: "brew", name: "bad\"\nsystem 'injection'", version: "1", available: nil)]
        let home = URL(fileURLWithPath: environment["HOME"]!)
        try write("3.13.2 3.11.9\n", to: home.appendingPathComponent(".pyenv/version"))
        let runtimeVersions = [DeveloperManagedVersion(manager: .pyenv, candidate: "python", version: "3.11.9", path: "/fixture/3.11.9", isDefault: true, isActive: false),
                               .init(manager: .pyenv, candidate: "python", version: "3.13.2", path: "/fixture/3.13.2", isDefault: true, isActive: false)]
        let output = try await DeveloperSnapshotService.export(to: root, versions: runtimeVersions, packages: packages, environment: environment)
        let exported = try DeveloperSnapshotService.read(from: output)
        expect(exported.items.filter { $0.kind == .package }.map(\.name) == ["jq"], "Export omits invalid package identifiers")
        expect(exported.items.filter { $0.kind == .editorExtension } == [extensionItem], "Export records extensions as validated restoration items")
        expect(exported.items.first { $0.kind == .runtime && $0.version == "3.13.2" }?.defaultOrder == 0
               && exported.items.first { $0.kind == .runtime && $0.version == "3.11.9" }?.defaultOrder == 1, "Export preserves multi-default priority independently of inventory order")
        let brewfile = try String(contentsOf: output.appendingPathComponent("Brewfile"), encoding: .utf8)
        expect(brewfile == "brew \"jq\"\n", "Exported Brewfile rejects injected package content")
        let extensions = try String(contentsOf: output.appendingPathComponent("code-extensions.txt"), encoding: .utf8)
        expect(extensions == "publisher.extension@1.2.3", "Export includes extension identifiers and excludes secret-bearing output")
        let helperValues = try output.appendingPathComponent("restore.sh").resourceValues(forKeys: [.isRegularFileKey])
        let permissions = (try FileManager.default.attributesOfItem(atPath: output.appendingPathComponent("restore.sh").path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        expect(helperValues.isRegularFile == true && permissions & 0o111 == 0, "Exported restore helpers remain files for manual review")
        let restore = try String(contentsOf: output.appendingPathComponent("restore.sh"), encoding: .utf8)
        expect(restore.contains("'pyenv' 'global' '3.13.2' '3.11.9'") && restore.components(separatedBy: "'pyenv' 'global'").count == 2, "Manual restore helper selects every global version once in its original priority order")
        expect(MoleEngine.invocations.allSatisfy { $0.arguments == ["--list-extensions", "--show-versions"] }, "Snapshot export only probes the read-only extension catalog")
    }

    private static func inertExecutable(_ url: URL) throws {
        try write("inert fixture; this file must never execute\n", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private static func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() { print("PASS: " + message) } else { failures.append(message); print("FAIL: " + message) }
    }
    private static func expectThrows(_ message: String, _ body: () throws -> Void) {
        do { try body(); expect(false, message) } catch { expect(true, message) }
    }
}
