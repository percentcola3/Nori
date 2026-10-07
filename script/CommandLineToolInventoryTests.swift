import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

@main
struct CommandLineToolInventoryTests {
    static func main() throws {
        let fm = FileManager.default
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        try fm.createDirectory(at: input, withIntermediateDirectories: true)
        let fixture = input.resolvingSymlinksInPath().standardizedFileURL
        let home = fixture.appendingPathComponent("home")
        func write(_ relative: String, _ text: String = "x", executable: Bool = false) throws {
            let url = fixture.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        let control = CleanupScanControl(mode: .deep)

        // Homebrew: receipts decide dependents and on-request state without running brew.
        try write("Cellar/libx/1.0/INSTALL_RECEIPT.json",
                  #"{"installed_on_request": false, "runtime_dependencies": []}"#)
        try write("Cellar/libx/1.0/lib/libx.dylib", String(repeating: "a", count: 8192))
        try write("Cellar/tool/2.3/INSTALL_RECEIPT.json",
                  #"{"installed_on_request": true, "runtime_dependencies": [{"full_name": "libx"}]}"#)
        try write("Cellar/tool/2.3/bin/tool", "b", executable: true)
        setenv("HOMEBREW_CELLAR", fixture.appendingPathComponent("Cellar").path, 1)
        let brew = CommandLineToolInventory.homebrewFormulae(home: home.path, searchPath: [], control: control, cellars: [fixture.path + "/Cellar"])
        let libx = brew.first { $0.name == "libx" }, tool = brew.first { $0.name == "tool" }
        expect(libx?.dependents == ["tool"] && libx?.canUninstall == false && libx?.installedOnRequest == false
               && libx!.bytes >= 8192, "a formula required by another one must not be uninstallable")
        expect(tool?.dependents == [] && tool?.canUninstall == true && tool?.version == "2.3",
               "a leaf formula is uninstallable and keeps its version")
        let expired = CleanupScanControl(mode: .deep, totalBudget: 0)
        let afterDeadline = CommandLineToolInventory.homebrewFormulae(home: home.path, searchPath: [], control: expired, cellars: [fixture.path + "/Cellar"])
        expect(Set(afterDeadline.map(\.name)) == ["libx", "tool"] && afterDeadline.allSatisfy { !$0.sizeIsKnown },
               "A sizing deadline must not hide installed packages or claim their unknown sizes are zero")

        // cargo: .crates.toml lists binaries per crate.
        try write("cargo/.crates.toml", """
        [v1]
        "ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)" = ["rg"]
        "cargo-edit 0.12.2 (registry+https://github.com/rust-lang/crates.io-index)" = ["cargo-add", "cargo-rm"]
        """)
        for binary in ["rg", "cargo-add", "cargo-rm"] { try write("cargo/bin/" + binary, String(repeating: "c", count: 4096), executable: true) }
        setenv("CARGO_HOME", fixture.appendingPathComponent("cargo").path, 1)
        let cargo = CommandLineToolInventory.cargoTools(home: home.path, control: control)
        let edit = cargo.first { $0.name == "cargo-edit" }
        expect(cargo.count == 2 && edit?.version == "0.12.2" && edit!.bytes >= 8192
               && cargo.first { $0.name == "ripgrep" }?.path.hasSuffix("/bin/rg") == true,
               "cargo crates must map to their binaries: \(cargo)")

        try write("home/.cargo/.crates.toml", "[v1]\n\"ripgrep 15.0.0 (registry+https://index.crates.io/)\" = [\"rg\"]\n")
        try write("home/.cargo/bin/rg", "fixture", executable: true)
        let cargoRoots = CommandLineToolInventory.cargoTools(home: home.path, control: expired,
            searchPath: [fixture.path + "/cargo/bin"])
        expect(cargoRoots.filter { $0.name == "ripgrep" }.count == 2 && Set(cargoRoots.map(\.id)).count == 3,
               "Cargo retains both custom and default roots, including same-name crates")
        var ownedCrate = cargoRoots.first { $0.version == "15.0.0" }!
        ownedCrate.managerExecutable = fixture.path + "/manager"
        expect(CommandLineToolInventory.uninstallCommand(ownedCrate, home: home.path, searchPath: [])?.arguments
               == ["uninstall", "ripgrep", "--root", home.path + "/.cargo"], "Cargo uninstall targets its selected install root")

        // go: only executable regular files in GOBIN are tools.
        try write("gobin/gopls", "g", executable: true)
        try write("gobin/notes.txt", "n")
        setenv("GOBIN", fixture.appendingPathComponent("gobin").path, 1)
        let go = CommandLineToolInventory.goBinaries(home: home.path)
        expect(go.map(\.name) == ["gopls"] && go[0].manager == .go, "go binaries must be executables only")

        try write("go-first/bin/formatter", "first", executable: true)
        try write("go-second/bin/formatter", "second", executable: true)
        setenv("GOPATH", fixture.path + "/go-first:" + fixture.path + "/go-second", 1)
        expect(CommandLineToolInventory.goBinaries(home: home.path).filter { $0.name == "formatter" }.count == 2,
               "All GOPATH entries are discovered alongside GOBIN without collapsing same names")

        // Uninstall guards: dependents and running processes block before any command runs.
        let blocked = CommandLineToolInventory.uninstall(libx!, home: home.path, running: RunningApplicationSnapshot())
        expect(!blocked.succeeded && blocked.messages.first?.contains("depend") == true, "dependents must block uninstall")
        let running = CommandLineToolInventory.uninstall(go[0], home: home.path,
            running: RunningApplicationSnapshot(processNames: ["gopls"]))
        expect(!running.succeeded && fm.fileExists(atPath: go[0].path), "a running tool must not be removed")
        let unknown = CommandLineToolInventory.uninstall(go[0], home: home.path, running: .unavailable)
        expect(!unknown.succeeded && fm.fileExists(atPath: go[0].path), "unknown process state must block uninstall")
        let outsideHome = CommandLineToolInventory.uninstall(go[0], home: fixture.appendingPathComponent("elsewhere").path,
            running: RunningApplicationSnapshot())
        expect(!outsideHome.succeeded && fm.fileExists(atPath: go[0].path), "go binaries outside home are never trashed")
        // Non-Node runtimes and shells appear even without a package receipt.
        for (name, version) in [("bash", "Bash 5.2"), ("zsh", "zsh 5.9"),
                                ("rustc", "rustc 1.90.0"), ("python3", "Python 3.13.0")] {
            try write("home/bin/" + name, "#!/bin/sh\nprintf '%s\\n' '\(version)'\n", executable: true)
        }
        let jdk = "home/Library/Java/JavaVirtualMachines/fixture.jdk/Contents/Home"
        try write(jdk + "/bin/java", "#!/bin/sh\nexit 99\n", executable: true)
        try write(jdk + "/release", "JAVA_VERSION=\"21.0.8\"\n")
        let snapshot = DeveloperCLIService.discover(environment: ["PATH": home.appendingPathComponent("bin").path],
            homePath: home.path, includeSystemDirectories: false)
        let managedPython = CommandLineTool(manager: .homebrew, name: "python", version: "3.13.0",
            path: home.appendingPathComponent("bin/python3").path, bytes: 1, dependents: [], installedOnRequest: true)
        let local = CommandLineToolInventory.localTools(home: home.path, managed: [managedPython], snapshot: snapshot)
        expect(Set(local.map(\.name)).isSuperset(of: ["bash", "zsh", "rustc", "java"])
               && !local.contains { $0.name == "python3" }
               && local.first { $0.name == "java" }?.version == "21.0.8"
               && local.allSatisfy { !$0.canUninstall }, "Discover shells, Rust and JDK metadata, deduplicate managed runtimes and preserve read-only boundaries")
        let localRemoval = CommandLineToolInventory.uninstall(local[0], home: home.path, running: RunningApplicationSnapshot())
        expect(!localRemoval.succeeded && fm.fileExists(atPath: local[0].path), "Externally managed runtimes cannot be removed by a guessed command")

        // A version budget controls optional information, never the inventory.
        let unversioned = CommandLineToolInventory.localTools(home: home.path, managed: [], snapshot: snapshot, versionBudget: 0)
        expect(Set(unversioned.map(\.id)) == Set(CommandLineToolInventory.localTools(home: home.path, managed: [], snapshot: snapshot).map(\.id)),
               "An exhausted version budget must preserve every runtime and shell")
        let manyLocations = (0..<140).map { index in
            DeveloperCLILocation(path: home.path + "/runtimes/\(index)/python3", resolvedPath: home.path + "/runtimes/\(index)/python3", source: "fixture", isInPATH: false)
        }
        var many = snapshot
        many.entries = [.init(tool: DeveloperCLIService.tools.first { $0.id == "python3" }!, locations: manyLocations, version: .pending)]
        expect(CommandLineToolInventory.localTools(home: home.path, managed: [], snapshot: many, versionBudget: 0).count == 140,
               "The old 128-item cap must not discard discovered installations")

        // Ordinary packages, including scoped/private packages, in inactive Node
        // prefixes must be found without successful npm commands or Agent hints.
        for (prefix, version) in [("home/custom-prefix", "1.2.0"), ("home/.nvm/versions/node/v20.0.0", "2.1.0")] {
            try write(prefix + "/lib/node_modules/typescript/package.json", "{\"name\":\"typescript\",\"version\":\"\(version)\"}")
            try write(prefix + "/lib/node_modules/@fixture/linter/package.json", #"{"name":"@fixture/linter","version":"3.0.0","private":true}"#)
            try write(prefix + "/bin/npm", "#!/bin/sh\nexit 1\n", executable: true)
        }
        try write("home/.npmrc", "prefix=${HOME}/custom-prefix\n")
        let npmTools = CommandLineToolInventory.nodeGlobals(.npm, home: home.path,
            searchPath: AgentCatalog.executableSearchPath(home: home.path), control: expired)
        expect(npmTools.filter { $0.name == "typescript" }.count == 2
               && Set(npmTools.map(\.id)).count == npmTools.count
               && npmTools.filter { $0.name == "@fixture/linter" }.allSatisfy { !$0.supportsPublicRegistryUpdates }
               && npmTools.allSatisfy { !$0.sizeIsKnown }, "Metadata discovery must survive manager failure and preserve distinct non-Agent packages")
        try write("home/.npmrc", "prefix=~/custom-prefix\n")
        expect(CommandLineToolInventory.nodeGlobals(.npm, home: home.path, searchPath: [], control: expired).contains { $0.name == "typescript" },
               "Tilde prefixes in npmrc are expanded without running shell configuration")
        let alias = fixture.path + "/npm-alias"
        let customRoot = home.path + "/custom-prefix/lib/node_modules"
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: customRoot)
        let aliasTools = CommandLineToolInventory.nodeGlobals(.npm, home: home.path, searchPath: [], control: expired,
            roots: [customRoot, alias])
        expect(aliasTools.count == 2, "Filesystem aliases must not duplicate a physical package installation")
        let npmRemoval = CommandLineToolInventory.uninstallCommand(npmTools.first { $0.name == "@fixture/linter" }!, home: home.path, searchPath: [])!
        expect(npmRemoval.executable.hasSuffix("/bin/npm") && npmRemoval.environment["NPM_CONFIG_PREFIX"] != nil
               && npmRemoval.expectedRoot?.hasSuffix("/lib/node_modules") == true,
               "Scoped uninstall must bind the discovered manager and exact prefix")

        let guardManager = "home/guard-manager"
        let mutationMarker = home.path + "/unexpected-mutation"
        try write(guardManager, "#!/bin/sh\nif [ \"$1\" = root ]; then printf '/wrong/root\\n'; exit 0; fi\nprintf 'mutated' > '\(mutationMarker)'\n", executable: true)
        var guardedNpm = npmTools.first { $0.name == "typescript" }!
        guardedNpm.managerExecutable = fixture.path + "/" + guardManager
        let guardResult = CommandLineToolInventory.uninstall(guardedNpm, home: home.path, running: RunningApplicationSnapshot())
        expect(!guardResult.succeeded && !fm.fileExists(atPath: mutationMarker) && fm.fileExists(atPath: guardedNpm.path),
               "Manager root mismatch blocks a generic package uninstall before any mutation command")

        try write("home/Library/pnpm/global/5/node_modules/fixture-cli/package.json", #"{"name":"fixture-cli","version":"5.0"}"#)
        let pnpmTools = CommandLineToolInventory.nodeGlobals(.pnpm, home: home.path, searchPath: [], control: expired)
        expect(pnpmTools.contains { $0.name == "fixture-cli" }, "pnpm receipt discovery works without a runnable pnpm")
        var pnpmTool = pnpmTools[0]
        pnpmTool.managerExecutable = home.path + "/fixture-pnpm"
        expect(CommandLineToolInventory.uninstallCommand(pnpmTool, home: home.path, searchPath: [])?.arguments.suffix(2)
               == ["--global-dir", home.path + "/Library/pnpm/global/5"], "pnpm uninstall must target its discovered global directory")

        try write("second/Cellar/libx/9.0/INSTALL_RECEIPT.json", #"{"runtime_dependencies":[]}"#)
        let twoBrews = CommandLineToolInventory.homebrewFormulae(home: home.path, searchPath: [], control: expired,
            cellars: [fixture.path + "/Cellar", fixture.path + "/second/Cellar"])
        expect(twoBrews.filter { $0.name == "libx" }.count == 2
               && twoBrews.first { $0.version == "9.0" }?.dependents == []
               && twoBrews.first { $0.version == "9.0" }?.managerExecutable == fixture.path + "/second/bin/brew",
               "Multiple Cellars preserve independent dependencies and manager ownership")

        // Python environments come from receipts, even if their manager fails
        // or is missing. Both legacy and current pipx roots are retained.
        for base in ["home/.local/pipx", "home/.local/share/pipx"] {
            try write(base + "/venvs/black/pipx_metadata.json", #"{"main_package":{"package":"black","package_version":"25.1.0","package_or_url":"black"}}"#)
        }
        let pythonTools = CommandLineToolInventory.pipxTools(home: home.path, searchPath: [], control: expired)
        expect(pythonTools.count == 2 && pythonTools.allSatisfy { $0.version == "25.1.0" && !$0.sizeIsKnown },
               "pipx metadata survives unavailable managers and multiple installation homes")
        let uvRoot = "home/.local/share/uv/tools/ruff"
        try write(uvRoot + "/uv-receipt.toml", "[tool]\nrequirements = [{name = \"ruff\"}]\n")
        try write(uvRoot + "/lib/python3.13/site-packages/ruff-0.13.0.dist-info/METADATA", "Name: ruff\nVersion: 0.13.0\n")
        let uvTools = CommandLineToolInventory.uvTools(home: home.path, searchPath: [], control: expired)
        expect(uvTools.count == 1 && uvTools[0].version == "0.13.0", "uv discovers tool receipts and installed versions without invoking a tool")

        let allDiscovered = twoBrews + npmTools + pnpmTools + pythonTools + uvTools + cargo + go + unversioned
        var measurements = 0
        let unsized = CommandLineToolInventory.sizeTools(allDiscovered, control: expired) { _, _ in
            measurements += 1
            return .init(bytes: 999)
        }
        expect(unsized.map(\.id) == allDiscovered.map(\.id) && measurements == 0
               && unsized.first { $0.name == "cargo-edit" }?.bytes == edit?.bytes,
               "A shared sizing deadline cannot drop any provider or overwrite multi-binary Cargo sizes")
        let interrupted = CleanupScanControl(mode: .deep)
        let partiallySized = CommandLineToolInventory.sizeTools(npmTools, control: interrupted) { _, control in
            control.cancel()
            return .init(bytes: 123, complete: false)
        }
        expect(partiallySized.count == npmTools.count && partiallySized.allSatisfy { !$0.sizeIsKnown },
               "Partial measurements retain all later metadata records")
        let parent = CleanupScanControl(mode: .deep)
        let child = CleanupScanControl(mode: .deep, totalBudget: 0, cancellationSource: parent)
        parent.cancel()
        expect(child.isCancelled && CommandLineToolInventory.nodeGlobals(.npm, home: home.path, searchPath: [], control: child, roots: [customRoot]).isEmpty,
               "Discovery ignores sizing deadlines but respects explicit cancellation")

        // Agent discovery sees other global prefixes even if npm's active list
        // omits them. Merge the exact installations, never package names alone.
        let codex = AgentCatalog.definitions.first { $0.id == "codex" }!
        for (prefix, version) in [("home/.npm-global", "0.116.0"), ("home/other-prefix", "0.115.0")] {
            let package = prefix + "/lib/node_modules/@openai/codex"
            try write(package + "/package.json", "{\"name\":\"@openai/codex\",\"version\":\"\(version)\"}")
            try write(package + "/bin/codex.js", "#!/bin/sh\nexit 0\n", executable: true)
            try write(prefix + "/bin/npm", "#!/bin/sh\nexit 0\n", executable: true)
            try fm.createSymbolicLink(atPath: fixture.appendingPathComponent(prefix + "/bin/codex").path,
                withDestinationPath: fixture.appendingPathComponent(package + "/bin/codex.js").path)
        }
        let presence = AgentPresenceContext(applicationDirs: [], searchPath: [home.path + "/.npm-global/bin", home.path + "/other-prefix/bin"])
        let installations = AgentCLIService.installations(for: codex, home: home.path, presence: presence)
        expect(installations.count == 2, "Agent fixture must contain two distinct Codex installations")
        let missing = CommandLineToolInventory.mergingAgents([], installations: installations, control: expired)
        expect(missing.count == 2 && Set(missing.map(\.version)) == ["0.116.0", "0.115.0"]
               && Set(missing.map(\.id)).count == 2 && missing.allSatisfy { $0.agentInstallation != nil && !$0.sizeIsKnown },
               "Missing Agent CLIs must remain visible beyond the sizing deadline with stable distinct IDs")
        let existing = CommandLineTool(manager: .npm, name: "@openai/codex", version: "0.116.0",
            path: home.path + "/.npm-global/lib/node_modules/@openai/codex", bytes: 1, dependents: [], installedOnRequest: true)
        let merged = CommandLineToolInventory.mergingAgents([existing], installations: installations, control: expired)
        expect(merged.count == 2 && merged.first?.agentInstallation != nil,
               "An existing record is attached once without hiding another installation of the same package")
        try write("home/.local/bin/codex", "#!/bin/sh\nexit 0\n", executable: true)
        let native = AgentCLIService.installations(for: codex, home: home.path,
            presence: .init(applicationDirs: [], searchPath: [home.path + "/.local/bin"]))
        let nativeRows = CommandLineToolInventory.mergingAgents([], installations: native, control: expired)
        expect(nativeRows.contains { $0.manager == .local && $0.canUninstall && $0.agentInstallation?.manager == .native },
               "Verified native Agent commands stay visible and retain their captured uninstall route")
        if let nativeRow = nativeRows.first(where: { $0.agentInstallation?.manager == .native }) {
            var measuredNative = 0
            let nativeSized = CommandLineToolInventory.sizeTools([nativeRow], control: CleanupScanControl(mode: .deep)) { _, _ in
                measuredNative += 1
                return .init(bytes: 512)
            }
            expect(measuredNative > 0 && nativeSized[0].sizeIsKnown && nativeSized[0].bytes > 0,
                   "Native Agent installations still receive optional sizing after metadata-only discovery")
        }
        print("Command-line tools: multi-prefix Homebrew/npm/pnpm/pipx/uv/Cargo/Go, Python/Rust/Java/shell discovery, metadata versions, deduplication and uninstall guards passed")
    }
}
