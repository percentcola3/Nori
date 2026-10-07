import Foundation

@main
struct DeveloperCLIServiceTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first bin", isDirectory: true)
        let second = root.appendingPathComponent("second bin", isDirectory: true)
        let alias = root.appendingPathComponent("alias bin", isDirectory: true)
        let home = root.appendingPathComponent("home with 'quote $value", isDirectory: true)
        let nodeA = try executable(first.appendingPathComponent("node"), body: "printf 'v20.1.0\\n'\n")
        _ = try executable(second.appendingPathComponent("node"), body: "printf 'v22.0.0\\n'\n")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias.appendingPathComponent("node"), withDestinationURL: nodeA)
        let nvm = home.appendingPathComponent(".nvm/versions/node/v18.0.0/bin", isDirectory: true)
        _ = try executable(nvm.appendingPathComponent("node"), body: "printf 'v18.0.0\\n'\n")
        let local = home.appendingPathComponent(".local/bin", isDirectory: true)
        _ = try executable(local.appendingPathComponent("uv"), body: "printf 'uv 0.8.0\\n'\n")
        let snapshot = DeveloperCLIService.discover(environment: ["PATH": first.path + ":" + alias.path + ":" + second.path + ":" + first.path + ":.:"], homePath: home.path, includeSystemDirectories: false)
        let node = entry("node", in: snapshot)
        expect(node.locations.count == 4, "Find PATH locations and nvm installations")
        expect(node.preferredLocation?.path == nodeA.path, "Preserve the first PATH source")
        expect(node.hasPATHShadowing, "Detect distinct executables shadowed by PATH ordering")
        expect(node.installationCount == 3, "Do not count a symlink to the same executable as another installation")
        expect(snapshot.duplicatePATHDirectories == [first.path], "Deduplicate repeated PATH directories without losing their diagnosis")
        expect(snapshot.hasRelativePATHEntry, "Report relative and empty PATH entries without searching the current directory")
        let uv = entry("uv", in: snapshot)
        expect(uv.isFound && !uv.isInPATH && !uv.hasPATHShadowing, "An extra installation is not a PATH conflict")
        expect(uv.preferredLocation?.source == "PATH / local", "A user bin directory is not a macOS system directory")
        expect(!entry("flutter", in: snapshot).isFound, "Represent tools outside the bounded discovery scope as not found")
        expect(DeveloperCLIService.inspectVersion(of: node, snapshot: snapshot) == .value("v20.1.0"), "Run the exact preferred executable with fixed version arguments")
        expect(DeveloperCLIService.inspectVersion(of: uv, snapshot: snapshot) == .value("uv 0.8.0"), "Read a version from a discovered extra installation")

        let onlyAliases = DeveloperCLIService.discover(environment: ["PATH": first.path + ":" + alias.path], homePath: root.appendingPathComponent("unused-home").path, includeSystemDirectories: false)
        expect(!entry("node", in: onlyAliases).hasPATHShadowing, "Aliases of the same executable do not create false PATH conflicts")

        let marker = root.appendingPathComponent("unexpected-launch")
        _ = try executable(local.appendingPathComponent("flutter"), body: "/usr/bin/touch " + DeveloperCLIService.shellQuote(marker.path) + "\n")
        let shim = home.appendingPathComponent(".asdf/shims", isDirectory: true)
        _ = try executable(shim.appendingPathComponent("python3"), body: "/usr/bin/touch " + DeveloperCLIService.shellQuote(marker.path) + "\n")
        let bootstrap = DeveloperCLIService.discover(environment: ["PATH": shim.path], homePath: home.path, includeSystemDirectories: false)
        expect(DeveloperCLIService.inspectVersion(of: entry("flutter", in: bootstrap), snapshot: bootstrap) == .deferred, "Do not launch Flutter's SDK bootstrapper")
        expect(DeveloperCLIService.inspectVersion(of: entry("python3", in: bootstrap), snapshot: bootstrap) == .deferred, "Do not launch version-manager shims")
        expect(!FileManager.default.fileExists(atPath: marker.path), "Source detection does not execute SDK/bootstrap shims")

        _ = try executable(first.appendingPathComponent("bun"), body: "trap '' TERM\nwhile :; do :; done\n")
        _ = try executable(first.appendingPathComponent("go"), body: "printf 'go version go1.24.0\\n'\ni=0\nwhile [ \"$i\" -lt 12000 ]; do printf 'large diagnostic output that must never fill a pipe\\n'; i=$((i + 1)); done\n")
        _ = try executable(first.appendingPathComponent("poetry"), body: "printf 'broken install\\n'\nexit 3\n")
        let timing = DeveloperCLIService.discover(environment: ["PATH": first.path], homePath: home.path, includeSystemDirectories: false)
        let started = Date()
        expect(DeveloperCLIService.inspectVersion(of: entry("bun", in: timing), snapshot: timing, timeout: 0.08) == .timedOut, "Kill a stalled version command even if SIGTERM is ignored")
        expect(Date().timeIntervalSince(started) < 0.8, "The timeout bounds the duration of a stalled probe")
        expect(DeveloperCLIService.inspectVersion(of: entry("go", in: timing), snapshot: timing, timeout: 1.0) == .value("go version go1.24.0"), "Drain large output without pipe back-pressure")
        expect(DeveloperCLIService.inspectVersion(of: entry("poetry", in: timing), snapshot: timing) == .unavailable, "Surface unsuccessful version commands")

        let forged = DeveloperCLITool(id: "node;touch " + marker.path, name: "Untrusted", category: .web, versionArguments: [], allowsVersionProbe: true)
        expect(DeveloperCLIService.diagnosticCommand(for: forged).isEmpty, "Reject commands outside the catalog")
        expect(DeveloperCLIService.terminalScript(for: forged) == nil, "Do not generate Terminal scripts from arbitrary user input")
        let diagnostic = DeveloperCLIService.diagnosticCommand(for: node.tool)
        expect(diagnostic.contains("/bin/zsh -f -c") && diagnostic.contains("whence -a"), "Diagnostic checks only command sources without shell initialization")
        expect(!diagnostic.contains("--version"), "Terminal diagnosis does not launch the detected tool")
        let quoted = "space 'quote `not executed` $(not executed)"
        let quoteProcess = Process()
        quoteProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        quoteProcess.arguments = ["-f", "-c", "printf %s " + DeveloperCLIService.shellQuote(quoted)]
        let pipe = Pipe()
        quoteProcess.standardOutput = pipe
        try quoteProcess.run()
        let quoteData = pipe.fileHandleForReading.readDataToEndOfFile()
        quoteProcess.waitUntilExit()
        expect(String(decoding: quoteData, as: UTF8.self) == quoted, "Quote paths and diagnostic arguments without command substitution")

        let inspected = await DeveloperCLIService.inspectVersions(in: snapshot)
        expect(entry("node", in: inspected).version == .value("v20.1.0"), "The bounded asynchronous version sweep preserves preferred versions")
        expect(inspected.entries.map(\.id) == snapshot.entries.map(\.id), "Version sweeps preserve stable tool identities and ordering")

        let asdfNode = home.appendingPathComponent(".asdf/installs/nodejs/24.0.0/bin", isDirectory: true)
        let macFNM = home.appendingPathComponent("Library/Application Support/fnm/node-versions/v22.0.0/installation/bin", isDirectory: true)
        _ = try executable(asdfNode.appendingPathComponent("node"), body: "printf 'v24.0.0\\n'\n")
        _ = try executable(macFNM.appendingPathComponent("node"), body: "printf 'v22.0.0\\n'\n")
        let noBootstrap = "/usr/bin/touch " + DeveloperCLIService.shellQuote(marker.path) + "\n"
        let userJDK = home.appendingPathComponent("Library/Java/JavaVirtualMachines/test.jdk/Contents/Home/bin", isDirectory: true)
        _ = try executable(userJDK.appendingPathComponent("java"), body: noBootstrap)
        _ = try executable(userJDK.appendingPathComponent("javac"), body: noBootstrap)
        _ = try executable(first.appendingPathComponent("java"), body: noBootstrap)
        _ = try executable(second.appendingPathComponent("java"), body: noBootstrap)
        let sdkmanMaven = home.appendingPathComponent(".sdkman/candidates/maven/3.9.0/bin", isDirectory: true)
        let sdkmanGradle = home.appendingPathComponent(".sdkman/candidates/gradle/8.0.0/bin", isDirectory: true)
        _ = try executable(sdkmanMaven.appendingPathComponent("mvn"), body: noBootstrap)
        _ = try executable(sdkmanGradle.appendingPathComponent("gradle"), body: noBootstrap)
        let extended = DeveloperCLIService.discover(environment: ["PATH": first.path + ":" + second.path], homePath: home.path, includeSystemDirectories: false)
        let extendedNode = entry("node", in: extended)
        expect(extendedNode.locations.contains { $0.path == asdfNode.appendingPathComponent("node").path && $0.source == "asdf" }, "Discover asdf Node installations without invoking shims")
        expect(extendedNode.locations.contains { $0.path == macFNM.appendingPathComponent("node").path && $0.source == "fnm" }, "Discover fnm's standard macOS Application Support location")
        let jvm = extended.entries.filter { $0.tool.category == .jvm }
        expect(jvm.count == 4 && jvm.allSatisfy(\.isFound), "Find Java, javac, Maven and Gradle under PATH, JDK and SDKMAN")
        expect(entry("java", in: extended).hasPATHShadowing, "Detect Java PATH priority conflicts")
        expect(entry("javac", in: extended).preferredLocation?.source == "JDK", "Identify an installed user JDK source")
        expect(entry("mvn", in: extended).preferredLocation?.source == "SDKMAN", "Identify Maven from SDKMAN")
        expect(jvm.allSatisfy { DeveloperCLIService.inspectVersion(of: $0, snapshot: extended) == .deferred }, "Do not execute Java launchers, Maven, or Gradle during automatic version checks")
        expect(!FileManager.default.fileExists(atPath: marker.path), "JVM source discovery never starts a toolchain or daemon")

        for (tool, body) in [("helm", "v3.17.0"), ("terraform", "Terraform v1.11.0"), ("gh", "gh version 2.70.0"), ("mise", "2026.10.0"), ("jq", "jq-1.7"), ("rg", "ripgrep 14.1.0"), ("fd", "fd 10.2.0")] {
            _ = try executable(first.appendingPathComponent(tool), body: "printf '%s\\n' " + DeveloperCLIService.shellQuote(body) + "\n")
        }
        let flutterBin = home.appendingPathComponent("flutter/bin", isDirectory: true)
        _ = try executable(flutterBin.appendingPathComponent("flutter"), body: noBootstrap)
        try FileManager.default.createDirectory(at: flutterBin.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try #"{"frameworkVersion":"3.35.1","channel":"stable"}"#.write(to: flutterBin.appendingPathComponent("cache/flutter.version.json"), atomically: true, encoding: .utf8)
        try "JAVA_VERSION=\"21.0.8\"\nIMPLEMENTOR=\"Eclipse Adoptium\"\n".write(to: userJDK.deletingLastPathComponent().appendingPathComponent("release"), atomically: true, encoding: .utf8)
        let metadata = DeveloperCLIService.discover(environment: ["PATH": flutterBin.path + ":" + userJDK.path + ":" + first.path], homePath: home.path, includeSystemDirectories: false)
        expect(DeveloperCLIService.inspectVersion(of: entry("java", in: metadata), snapshot: metadata) == .value("21.0.8"), "Read the preferred JDK release metadata without executing Java")
        expect(DeveloperCLIService.inspectVersion(of: entry("javac", in: metadata), snapshot: metadata) == .value("21.0.8"), "Read javac's JDK metadata without executing the compiler")
        expect(DeveloperCLIService.inspectVersion(of: entry("flutter", in: metadata), snapshot: metadata) == .value("3.35.1"), "Read Flutter cache version metadata without running its bootstrap script")
        for id in ["helm", "terraform", "gh", "mise", "jq", "rg", "fd"] {
            expect(entry(id, in: metadata).isFound, "Discover the extended " + id + " catalog entry")
            if case .value = DeveloperCLIService.inspectVersion(of: entry(id, in: metadata), snapshot: metadata) {} else { fatalError("No fixture version for " + id) }
        }
        try "999\\nUNTRUSTED".write(to: userJDK.deletingLastPathComponent().appendingPathComponent("release"), atomically: true, encoding: .utf8)
        try #"{"frameworkVersion":"$(touch unexpected)"}"#.write(to: flutterBin.appendingPathComponent("cache/flutter.version.json"), atomically: true, encoding: .utf8)
        expect(DeveloperCLIService.inspectVersion(of: entry("java", in: metadata), snapshot: metadata) == .deferred, "Malformed JDK metadata stays deferred")
        expect(DeveloperCLIService.inspectVersion(of: entry("flutter", in: metadata), snapshot: metadata) == .deferred, "Malformed Flutter metadata does not launch a fallback bootstrap")
        expect(!FileManager.default.fileExists(atPath: marker.path), "SDK metadata version reads never execute the fake launchers")
        print("Developer CLI tests passed")
    }

    private static func entry(_ id: String, in snapshot: DeveloperCLISnapshot) -> DeveloperCLIEntry {
        snapshot.entries.first { $0.id == id }!
    }

    @discardableResult
    private static func executable(_ url: URL, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: " + message) }
        print("PASS: " + message)
    }
}
