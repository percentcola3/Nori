import Foundation
import Darwin

enum DeveloperCLICategory: String, CaseIterable, Identifiable, Sendable {
    case web, python, jvm, mobile, systems, utilities
    var id: String { rawValue }
}

struct DeveloperCLITool: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let category: DeveloperCLICategory
    let versionArguments: [String]
    /// Some launchers bootstrap SDKs or install their configured runtime even for --version.
    let allowsVersionProbe: Bool
}

struct DeveloperCLILocation: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let resolvedPath: String
    let source: String
    let isInPATH: Bool
}

enum DeveloperCLIVersion: Equatable, Sendable {
    case pending, value(String), unavailable, timedOut, deferred
}

struct DeveloperCLIEntry: Identifiable, Equatable, Sendable {
    var id: String { tool.id }
    let tool: DeveloperCLITool
    let locations: [DeveloperCLILocation]
    var version: DeveloperCLIVersion
    var preferredLocation: DeveloperCLILocation? { locations.first }
    var isFound: Bool { !locations.isEmpty }
    var isInPATH: Bool { locations.contains(where: \.isInPATH) }
    var hasPATHShadowing: Bool {
        Set(locations.filter(\.isInPATH).map(\.resolvedPath)).count > 1
    }
    var installationCount: Int { Set(locations.map(\.resolvedPath)).count }
}

struct DeveloperCLISnapshot: Equatable, Sendable {
    var entries: [DeveloperCLIEntry]
    let pathDirectories: [String]
    let duplicatePATHDirectories: [String]
    let hasRelativePATHEntry: Bool
    let homePath: String
}

/// A bounded, read-only inventory. This deliberately does not invoke a login shell,
/// source configuration files, install tools, or treat a GUI application's PATH as
/// the PATH of an interactive terminal.
enum DeveloperCLIService {
    static let tools: [DeveloperCLITool] = [
        .init(id: "node", name: "Node.js", category: .web, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "npm", name: "npm", category: .web, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "pnpm", name: "pnpm", category: .web, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "yarn", name: "Yarn", category: .web, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "bun", name: "Bun", category: .web, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "deno", name: "Deno", category: .web, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "python3", name: "Python 3", category: .python, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "pip3", name: "pip", category: .python, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "uv", name: "uv", category: .python, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "poetry", name: "Poetry", category: .python, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "java", name: "Java", category: .jvm, versionArguments: ["-version"], allowsVersionProbe: false),
        .init(id: "javac", name: "Java compiler", category: .jvm, versionArguments: ["-version"], allowsVersionProbe: false),
        .init(id: "mvn", name: "Maven", category: .jvm, versionArguments: ["--version"], allowsVersionProbe: false),
        .init(id: "gradle", name: "Gradle", category: .jvm, versionArguments: ["--version"], allowsVersionProbe: false),
        .init(id: "swift", name: "Swift", category: .mobile, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "xcodebuild", name: "Xcode", category: .mobile, versionArguments: ["-version"], allowsVersionProbe: true),
        .init(id: "adb", name: "Android Debug Bridge", category: .mobile, versionArguments: ["version"], allowsVersionProbe: true),
        .init(id: "flutter", name: "Flutter", category: .mobile, versionArguments: ["--version"], allowsVersionProbe: false),
        .init(id: "dart", name: "Dart", category: .mobile, versionArguments: ["--version"], allowsVersionProbe: false),
        .init(id: "rustc", name: "Rust", category: .systems, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "cargo", name: "Cargo", category: .systems, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "go", name: "Go", category: .systems, versionArguments: ["version"], allowsVersionProbe: true),
        .init(id: "git", name: "Git", category: .utilities, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "brew", name: "Homebrew", category: .utilities, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "docker", name: "Docker CLI", category: .utilities, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "kubectl", name: "kubectl", category: .utilities, versionArguments: ["version", "--client=true"], allowsVersionProbe: true),
        .init(id: "helm", name: "Helm", category: .utilities, versionArguments: ["version", "--short"], allowsVersionProbe: true),
        .init(id: "terraform", name: "Terraform", category: .utilities, versionArguments: ["version"], allowsVersionProbe: true),
        .init(id: "gh", name: "GitHub CLI", category: .utilities, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "mise", name: "mise", category: .utilities, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "jq", name: "jq", category: .utilities, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "rg", name: "ripgrep", category: .utilities, versionArguments: ["--version"], allowsVersionProbe: true),
        .init(id: "fd", name: "fd", category: .utilities, versionArguments: ["--version"], allowsVersionProbe: true),
    ]

    static func discover(environment: [String: String] = ProcessInfo.processInfo.environment,
                         homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
                         includeSystemDirectories: Bool = true) -> DeveloperCLISnapshot {
        let fileManager = FileManager.default
        let components = (environment["PATH"] ?? "").components(separatedBy: ":")
        // Relative PATH components depend on a shell's current directory. Do not
        // guess that directory or execute a tool from Nori's working directory.
        let absoluteComponents = components.filter { $0.hasPrefix("/") }.map(standardize)
        var pathDirectories: [String] = []
        var repeated: [String] = []
        for path in absoluteComponents {
            if pathDirectories.contains(path) {
                if !repeated.contains(path) { repeated.append(path) }
            } else {
                pathDirectories.append(path)
            }
        }
        let standard = includeSystemDirectories ? ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] : []
        let homeDirectories = [".local/bin", ".cargo/bin", ".bun/bin", ".deno/bin", ".volta/bin", ".asdf/shims", ".local/share/mise/shims", ".pyenv/shims", ".nodenv/shims", "Library/Android/sdk/platform-tools"].map {
            URL(fileURLWithPath: homePath).appendingPathComponent($0).path
        }
        var managed: [String] = []
        for (root, suffix) in [(".nvm/versions/node", "bin"), (".nodenv/versions", "bin"),
                               (".pyenv/versions", "bin"), (".asdf/installs/nodejs", "bin"),
                               (".local/share/fnm/node-versions", "installation/bin"),
                               ("Library/Application Support/fnm/node-versions", "installation/bin"),
                               (".sdkman/candidates/java", "bin"), (".sdkman/candidates/maven", "bin"),
                               (".sdkman/candidates/gradle", "bin"), (".asdf/installs/java", "bin")] {
            let rootURL = URL(fileURLWithPath: homePath).appendingPathComponent(root)
            let versions = (try? fileManager.contentsOfDirectory(atPath: rootURL.path)) ?? []
            managed += versions.filter { !$0.hasPrefix(".") }.sorted().prefix(32).map {
                rootURL.appendingPathComponent($0).appendingPathComponent(suffix).path
            }
        }
        let jdkRoots = [URL(fileURLWithPath: homePath).appendingPathComponent("Library/Java/JavaVirtualMachines")]
            + (includeSystemDirectories ? [URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines")] : [])
        for rootURL in jdkRoots {
            let versions = (try? fileManager.contentsOfDirectory(atPath: rootURL.path)) ?? []
            managed += versions.filter { !$0.hasPrefix(".") }.sorted().prefix(32).map {
                rootURL.appendingPathComponent($0).appendingPathComponent("Contents/Home/bin").path
            }
        }
        var directories = pathDirectories
        for directory in standard + homeDirectories + managed where !directories.contains(directory) {
            directories.append(directory)
        }
        let entries = tools.map { tool in
            let locations = directories.compactMap { directory -> DeveloperCLILocation? in
                let path = URL(fileURLWithPath: directory).appendingPathComponent(tool.id).path
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                      !isDirectory.boolValue, fileManager.isExecutableFile(atPath: path) else { return nil }
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                return DeveloperCLILocation(path: path, resolvedPath: resolved,
                                            source: source(for: path), isInPATH: pathDirectories.contains(directory))
            }
            return DeveloperCLIEntry(tool: tool, locations: locations, version: locations.isEmpty ? .unavailable : .pending)
        }
        return DeveloperCLISnapshot(entries: entries, pathDirectories: pathDirectories,
                                    duplicatePATHDirectories: repeated,
                                    hasRelativePATHEntry: components.contains { !$0.hasPrefix("/") }, homePath: homePath)
    }

    static func inspectVersions(in snapshot: DeveloperCLISnapshot) async -> DeveloperCLISnapshot {
        var result = snapshot
        await withTaskGroup(of: (Int, DeveloperCLIVersion).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let entry = snapshot.entries[index]
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return (index, .unavailable) }
                    return (index, inspectVersion(of: entry, snapshot: snapshot))
                }
            }
            // Bound both launch concurrency and each launch duration.
            while next < min(4, snapshot.entries.count) { enqueue(next); next += 1 }
            while let (index, version) = await group.next() {
                result.entries[index].version = version
                if next < snapshot.entries.count, !Task.isCancelled { enqueue(next); next += 1 }
            }
        }
        return result
    }

    static func inspectVersion(of entry: DeveloperCLIEntry, snapshot: DeveloperCLISnapshot,
                               timeout: TimeInterval = 0.7) -> DeveloperCLIVersion {
        guard let location = entry.preferredLocation else { return .unavailable }
        if let version = metadataVersion(tool: entry.tool.id, location: location) { return .value(version) }
        guard canProbe(entry.tool, at: location) else { return .deferred }
        let result = runVersion(executablePath: location.path, arguments: entry.tool.versionArguments,
                                environment: probeEnvironment(snapshot), timeout: timeout)
        if result.timedOut { return .timedOut }
        guard result.status == 0, let line = result.output.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return .unavailable }
        let cleaned = line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return .value(String(String.UnicodeScalarView(cleaned)).prefix(160).description)
    }

    /// Fixed catalog names only. `whence` is a zsh builtin and does not execute
    /// the discovered tools, so even SDK/bootstrap shims can be diagnosed safely.
    static func diagnosticCommand(for tool: DeveloperCLITool) -> String {
        guard tools.contains(tool) else { return "" }
        return "/bin/zsh -f -c " + shellQuote("whence -a -- " + shellQuote(tool.id))
    }

    static func terminalScript(for tool: DeveloperCLITool) -> String? {
        let command = diagnosticCommand(for: tool)
        guard !command.isEmpty else { return nil }
        return "#!/bin/zsh -f\n# Nori: show sources visible in Terminal; do not execute or install the tool.\n" + command + "\n"
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func standardize(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    /// Read installed SDK metadata before considering a process launch. A JDK
    /// launcher or Flutter script can install components even for --version.
    private static func metadataVersion(tool: String, location: DeveloperCLILocation) -> String? {
        guard ["java", "javac", "flutter", "dart"].contains(tool) else { return nil }
        for path in [location.resolvedPath, location.path] {
            let bin = URL(fileURLWithPath: path).deletingLastPathComponent()
            guard bin.lastPathComponent == "bin" else { continue }
            let sdk = bin.deletingLastPathComponent()
            if tool == "java" || tool == "javac" {
                guard let data = metadata(at: sdk.appendingPathComponent("release")),
                      let release = String(data: data, encoding: .utf8),
                      let expression = try? NSRegularExpression(pattern: #"(?m)^JAVA_VERSION="([^"\r\n]{1,128})"\s*$"#),
                      let match = expression.firstMatch(in: release, range: NSRange(release.startIndex..., in: release)),
                      let range = Range(match.range(at: 1), in: release) else { continue }
                if let version = cleanMetadataVersion(String(release[range])) { return version }
            } else if tool == "flutter" {
                if let data = metadata(at: bin.appendingPathComponent("cache/flutter.version.json")),
                   let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let value = object["frameworkVersion"] as? String,
                   let version = cleanMetadataVersion(value) { return version }
                if let data = metadata(at: sdk.appendingPathComponent("version")),
                   let value = String(data: data, encoding: .utf8),
                   let version = cleanMetadataVersion(value.trimmingCharacters(in: .whitespacesAndNewlines)) { return version }
            } else if let data = metadata(at: sdk.appendingPathComponent("version")),
                      let value = String(data: data, encoding: .utf8),
                      let version = cleanMetadataVersion(value.trimmingCharacters(in: .whitespacesAndNewlines)) { return version }
        }
        return nil
    }

    private static func metadata(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= 65_536,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536 else { return nil }
        return data
    }

    private static func cleanMetadataVersion(_ value: String) -> String? {
        guard value.utf8.count <= 128,
              value.range(of: #"^[0-9][A-Za-z0-9._+-]*$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private static func source(for path: String) -> String {
        let names = [("/.nvm/", "nvm"), ("/fnm/", "fnm"), ("/.nodenv/", "nodenv"), ("/.pyenv/", "pyenv"), ("/.volta/", "Volta"), ("/.asdf/", "asdf"), ("/.sdkman/", "SDKMAN"), ("/Java/JavaVirtualMachines/", "JDK"), ("/mise/", "mise"), ("/.cargo/", "rustup / Cargo"), ("/.bun/", "Bun"), ("/.deno/", "Deno"), ("/Android/sdk/", "Android SDK"), ("/opt/homebrew/", "Homebrew (Apple Silicon)"), ("/usr/local/", "/usr/local"), ("/usr/bin/", "macOS"), ("/bin/", "macOS")]
        return names.first(where: { path.contains($0.0) })?.1 ?? "PATH / local"
    }

    private static func canProbe(_ tool: DeveloperCLITool, at location: DeveloperCLILocation) -> Bool {
        guard tools.contains(tool), tool.allowsVersionProbe else { return false }
        let bootstrapPaths = ["/corepack/", "/corepack/dist/", "/shims/", "/.volta/bin/", "/rustup"]
        guard !bootstrapPaths.contains(where: { location.path.contains($0) || location.resolvedPath.contains($0) }) else { return false }
        if ["git", "swift", "xcodebuild", "python3"].contains(tool.id), location.path.hasPrefix("/usr/bin/") {
            let fileManager = FileManager.default
            // Apple's /usr/bin developer stubs can prompt for toolchain installation.
            guard fileManager.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/" + tool.id)
                    || fileManager.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/" + tool.id) else { return false }
        }
        return true
    }

    private static func probeEnvironment(_ snapshot: DeveloperCLISnapshot) -> [String: String] {
        var directories = snapshot.pathDirectories
        for path in snapshot.entries.compactMap({ $0.preferredLocation.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path } }) where !directories.contains(path) {
            directories.append(path)
        }
        return ["PATH": directories.joined(separator: ":"), "HOME": snapshot.homePath,
                "LANG": "C", "LC_ALL": "C", "HOMEBREW_NO_AUTO_UPDATE": "1",
                "COREPACK_ENABLE_NETWORK": "0", "PYTHONNOUSERSITE": "1",
                "CHECKPOINT_DISABLE": "1", "GH_NO_UPDATE_NOTIFIER": "1",
                "NO_COLOR": "1", "TERM": "dumb"]
    }

    private struct ProbeResult { let output: String; let status: Int32; let timedOut: Bool }

    private static func runVersion(executablePath: String, arguments: [String],
                                   environment: [String: String], timeout: TimeInterval) -> ProbeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        // Keep draining the pipe even after its retained prefix is full. A broken
        // command cannot grow memory, write a large temporary file, or block on
        // pipe back-pressure while the timeout is waiting for it to terminate.
        let pipe = Pipe()
        let collector = OutputCollector()
        let reachedEOF = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                reachedEOF.signal()
            } else { collector.append(data) }
        }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        process.standardOutput = pipe
        process.standardError = pipe
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch { return .init(output: "", status: -1, timedOut: false) }
        try? pipe.fileHandleForWriting.close()
        let timedOut = completed.wait(timeout: .now() + max(0.05, timeout)) == .timedOut
        if timedOut, process.isRunning {
            process.terminate()
            if completed.wait(timeout: .now() + 0.1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 0.1)
            }
        }
        _ = reachedEOF.wait(timeout: .now() + 0.1)
        return .init(output: collector.output,
                     status: process.isRunning ? -1 : process.terminationStatus, timedOut: timedOut)
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ incoming: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(incoming.prefix(max(0, 4096 - data.count)))
        }
        var output: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
