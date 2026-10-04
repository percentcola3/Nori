import Foundation
import Darwin

/// Snapshots contain a validated manifest, never raw credential-bearing configuration.
/// Import ignores scripts and Brewfiles and reconstructs registered operations.
enum DeveloperSnapshotService {
    struct Item: Codable, Identifiable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case runtime, package, editorExtension }
        let kind: Kind
        let manager: String
        let name: String
        let version: String
        let isDefault: Bool
        var defaultOrder: Int? = nil
        var id: String { kind.rawValue + ":" + manager + ":" + name + ":" + version }

        func command(environment: [String: String]) -> DeveloperCommand? {
            if kind == .runtime, let manager = DeveloperManager(rawValue: manager) {
                return DeveloperToolchainService.command(manager: manager, operation: .install, version: version, candidate: name, environment: environment)
            }
            if kind == .editorExtension {
                guard ["code", "cursor"].contains(manager), DeveloperSnapshotService.validExtension(name, version: version),
                      let executable = DeveloperToolchainService.executable(manager, environment: environment) else { return nil }
                return .init(titleKey: "dev.snapshot.restore", executable: executable,
                             arguments: ["--install-extension", name + (version.isEmpty ? "" : "@" + version)],
                             environment: environment, timeout: 300, privilegedArguments: nil)
            }
            return DeveloperSnapshotService.packageInstall(manager: manager, name: name, environment: environment)
        }

        func commands(environment: [String: String], installed: [DeveloperManagedVersion] = []) -> [DeveloperCommand] {
            guard let install = command(environment: environment) else { return [] }
            let exists = kind == .runtime && installed.contains { $0.manager.rawValue == manager && $0.candidate == name && $0.version == version }
            var commands = exists ? [] : [install]
            if kind == .runtime, isDefault, let manager = DeveloperManager(rawValue: manager),
               let select = DeveloperToolchainService.command(manager: manager, operation: .setDefault, version: version, candidate: name, environment: environment) {
                commands.append(select)
            }
            let group = UUID()
            return commands.map { var command = $0; command.operationGroup = group; return command }
        }

        func preview(environment: [String: String], installed: [DeveloperManagedVersion] = []) -> String? {
            guard command(environment: environment) != nil else { return nil }
            let commands = commands(environment: environment, installed: installed)
            return commands.isEmpty ? L10n.shared.t("dev.snapshot.alreadyInstalled") : commands.map(\.display).joined(separator: "\n")
        }
    }
    struct Manifest: Codable, Sendable {
        let formatVersion: Int
        let createdAt: Date
        let architecture: String
        let items: [Item]
    }
    enum Failure: Error { case invalidManifest, unsafeDestination }

    static func read(from directory: URL) throws -> Manifest {
        let url = directory.appendingPathComponent("manifest.json")
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.invalidManifest }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 2_097_152,
              let data = try handle.read(upToCount: 2_097_153), data.count <= 2_097_152 else { throw Failure.invalidManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.formatVersion == 1, manifest.items.count <= 4096,
              Set(manifest.items.map(\.id)).count == manifest.items.count else { throw Failure.invalidManifest }
        for item in manifest.items {
            guard DeveloperPackageService.validName(item.name), item.version.utf8.count <= 128,
                  item.defaultOrder.map({ (0..<128).contains($0) }) ?? true else { throw Failure.invalidManifest }
            switch item.kind {
            case .runtime:
                guard DeveloperManager(rawValue: item.manager) != nil, DeveloperToolchainService.validIdentifier(item.version) else { throw Failure.invalidManifest }
            case .package:
                guard ["brew", "brew-cask", "npm", "pnpm", "pipx", "cargo", "dotnet"].contains(item.manager) else { throw Failure.invalidManifest }
            case .editorExtension:
                guard ["code", "cursor"].contains(item.manager), validExtension(item.name, version: item.version) else { throw Failure.invalidManifest }
            }
        }
        return manifest
    }

    static func export(to directory: URL, versions: [DeveloperManagedVersion], packages: [DeveloperPackage], environment: [String: String]) async throws -> URL {
        let fm = FileManager.default
        let destination = directory.appendingPathComponent("Nori-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(6))
        try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let validPackages = packages.filter { DeveloperPackageService.validName($0.name) && $0.version.utf8.count <= 128 && ["brew", "brew-cask", "npm", "pnpm", "pipx", "cargo", "dotnet"].contains($0.manager) }
        var items = versions.filter { DeveloperToolchainService.validIdentifier($0.version) && DeveloperPackageService.validName($0.candidate) }.map { version in
            let order = DeveloperToolchainService.defaultVersions(version.manager, candidate: version.candidate, environment: environment, home: environment["HOME"] ?? NSHomeDirectory()).firstIndex(of: version.version)
            return Item(kind: .runtime, manager: version.manager.rawValue, name: version.candidate, version: version.version, isDefault: version.isDefault, defaultOrder: order)
        } + validPackages.map {
            Item(kind: .package, manager: $0.manager, name: $0.name, version: $0.version, isDefault: false)
        }
        for tool in ["code", "cursor"] {
            if let executable = DeveloperToolchainService.executable(tool, environment: environment) {
                let result = await MoleEngine().run(executable: URL(fileURLWithPath: executable), arguments: ["--list-extensions", "--show-versions"], environment: environment, timeout: 10)
                if result.succeeded {
                    let extensions = parseExtensions(result.output, editor: tool)
                    items += extensions
                    let lines = extensions.map { $0.name + ($0.version.isEmpty ? "" : "@" + $0.version) }.joined(separator: "\n")
                    try write(Data(lines.utf8), to: destination.appendingPathComponent(tool + "-extensions.txt"))
                }
            }
        }
        var identifiers: Set<String> = []
        items = items.filter { identifiers.insert($0.id).inserted }
        guard items.count <= 4096 else { throw Failure.invalidManifest }
        let manifest = Manifest(formatVersion: 1, createdAt: Date(), architecture: ProcessInfo.processInfo.machineArchitecture, items: items)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(manifest), to: destination.appendingPathComponent("manifest.json"))
        let brewfile = validPackages.filter { $0.manager == "brew" || $0.manager == "brew-cask" }.map {
            ($0.manager == "brew" ? "brew" : "cask") + " \"" + $0.name + "\""
        }.joined(separator: "\n") + "\n"
        try write(Data(brewfile.utf8), to: destination.appendingPathComponent("Brewfile"))
        // This helper is provided for manual review. Nori never executes imported scripts.
        var restore = "#!/bin/bash\nset -euo pipefail\n# " + L10n.shared.t("dev.snapshot.script.review") + "\n"
        for item in items {
            if item.kind == .package {
                let command = packageInstall(manager: item.manager, name: item.name, environment: environment)
                if let command { restore += ([item.manager == "brew-cask" ? "brew" : item.manager] + command.arguments).map(DeveloperCLIService.shellQuote).joined(separator: " ") + "\n" }
            } else if item.kind == .editorExtension {
                restore += ([item.manager, "--install-extension", item.name + (item.version.isEmpty ? "" : "@" + item.version)]).map(DeveloperCLIService.shellQuote).joined(separator: " ") + "\n"
            } else {
                switch item.manager {
                case "nvm": restore += "[ -s \"${NVM_DIR:-$HOME/.nvm}/nvm.sh\" ] && source \"${NVM_DIR:-$HOME/.nvm}/nvm.sh\" --no-use\nnvm install " + DeveloperCLIService.shellQuote(item.version) + "\n"
                case "sdkman": restore += "source \"${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh\"\nsdk install " + DeveloperCLIService.shellQuote(item.name) + " " + DeveloperCLIService.shellQuote(item.version) + "\n"
                case "rustup": restore += "rustup toolchain install " + DeveloperCLIService.shellQuote(item.version) + "\n"
                case "asdf": restore += "asdf install " + DeveloperCLIService.shellQuote(item.name) + " " + DeveloperCLIService.shellQuote(item.version) + "\n"
                default: restore += DeveloperCLIService.shellQuote(item.manager) + " install " + DeveloperCLIService.shellQuote(item.version) + "\n"
                }
            }
        }
        let defaultGroups = Dictionary(grouping: items.filter { $0.kind == .runtime && $0.isDefault }) { $0.manager + ":" + $0.name }
        for key in defaultGroups.keys.sorted() {
            guard let defaults = defaultGroups[key], let first = defaults.first, let manager = DeveloperManager(rawValue: first.manager),
                  let select = DeveloperToolchainService.defaultCommand(manager: manager, versions: orderedDefaults(defaults), candidate: first.name, environment: environment) else { continue }
            let args = manager == .nvm || manager == .sdkman ? Array(select.arguments.dropFirst(6)) : select.arguments
            restore += ([manager == .sdkman ? "sdk" : first.manager] + args).map(DeveloperCLIService.shellQuote).joined(separator: " ") + "\n"
        }
        try write(Data(restore.utf8), to: destination.appendingPathComponent("restore.sh"))
        try write(Data(L10n.shared.t("dev.snapshot.readme").utf8), to: destination.appendingPathComponent("README.txt"))
        return destination
    }

    static func validExtension(_ name: String, version: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil &&
        (version.isEmpty || version.range(of: #"^[A-Za-z0-9][A-Za-z0-9.+-]{0,127}$"#, options: .regularExpression) != nil)
    }

    static func parseExtensions(_ output: String, editor: String) -> [Item] {
        guard ["code", "cursor"].contains(editor) else { return [] }
        return output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(separator: "@", omittingEmptySubsequences: false)
            guard fields.count <= 2, let name = fields.first else { return nil }
            let version = fields.count == 2 ? String(fields[1]) : ""
            guard validExtension(String(name), version: version) else { return nil }
            return .init(kind: .editorExtension, manager: editor, name: String(name), version: version, isDefault: false)
        }
    }

    /// Keep all default selectors for one runtime together. In particular,
    /// pyenv and asdf allow several global versions in one official command.
    static func restoreCommands(_ items: [Item], environment: [String: String], installed: [DeveloperManagedVersion]) -> [DeveloperCommand] {
        var commands: [DeveloperCommand] = []
        let runtimes = Dictionary(grouping: items.filter { $0.kind == .runtime }) { $0.manager + ":" + $0.name }
        for key in runtimes.keys.sorted() {
            let groupItems = runtimes[key] ?? []
            guard let first = groupItems.first, let manager = DeveloperManager(rawValue: first.manager) else { continue }
            let group = UUID()
            for item in groupItems where !installed.contains(where: { $0.manager == manager && $0.candidate == item.name && $0.version == item.version }) {
                if var command = item.command(environment: environment) { command.operationGroup = group; commands.append(command) }
            }
            let defaults = orderedDefaults(groupItems)
            if !defaults.isEmpty, var select = DeveloperToolchainService.defaultCommand(manager: manager, versions: defaults, candidate: first.name, environment: environment) {
                select.operationGroup = group
                commands.append(select)
            }
        }
        for item in items where item.kind != .runtime {
            if var command = item.command(environment: environment) { command.operationGroup = UUID(); commands.append(command) }
        }
        return commands
    }

    private static func orderedDefaults(_ items: [Item]) -> [String] {
        items.enumerated().filter { $0.element.isDefault }.sorted {
            ($0.element.defaultOrder ?? $0.offset) < ($1.element.defaultOrder ?? $1.offset)
        }.map { $0.element.version }
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func packageInstall(manager: String, name: String, environment: [String: String]) -> DeveloperCommand? {
        guard DeveloperPackageService.validName(name) else { return nil }
        let tool = manager == "brew-cask" ? "brew" : manager
        guard let executable = DeveloperToolchainService.executable(tool, environment: environment) else { return nil }
        let arguments: [String]
        switch manager {
        case "brew": arguments = ["install", name]
        case "brew-cask": arguments = ["install", "--cask", name]
        case "npm", "pnpm": arguments = ["install", "-g", name]
        case "pipx", "cargo": arguments = ["install", name]
        case "dotnet": arguments = ["tool", "install", "--global", name]
        default: return nil
        }
        var env = environment; env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return .init(titleKey: "dev.snapshot.restore", executable: executable, arguments: arguments, environment: env, timeout: 1800, privilegedArguments: nil)
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
