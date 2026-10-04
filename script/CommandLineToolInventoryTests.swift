import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

@main
struct CommandLineToolInventoryTests {
    static func main() throws {
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
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
        let brew = CommandLineToolInventory.homebrewFormulae(home: home.path, searchPath: [], control: control)
        let libx = brew.first { $0.name == "libx" }, tool = brew.first { $0.name == "tool" }
        expect(libx?.dependents == ["tool"] && libx?.canUninstall == false && libx?.installedOnRequest == false
               && libx!.bytes >= 8192, "a formula required by another one must not be uninstallable")
        expect(tool?.dependents == [] && tool?.canUninstall == true && tool?.version == "2.3",
               "a leaf formula is uninstallable and keeps its version")

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

        // go: only executable regular files in GOBIN are tools.
        try write("gobin/gopls", "g", executable: true)
        try write("gobin/notes.txt", "n")
        setenv("GOBIN", fixture.appendingPathComponent("gobin").path, 1)
        let go = CommandLineToolInventory.goBinaries(home: home.path)
        expect(go.map(\.name) == ["gopls"] && go[0].manager == .go, "go binaries must be executables only")

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
        print("Command-line tools: Homebrew receipts, cargo crates, go binaries and uninstall guards passed")
    }
}
