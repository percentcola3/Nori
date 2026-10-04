import Foundation

enum DeveloperManager: String, CaseIterable, Identifiable, Sendable {
    case nvm, fnm, pyenv, rbenv, rustup, sdkman, asdf
    var id: String { rawValue }
    var displayName: String { self == .sdkman ? "SDKMAN" : rawValue }
}

struct DeveloperManagedVersion: Identifiable, Equatable, Sendable {
    let manager: DeveloperManager
    let candidate: String
    let version: String
    let path: String
    let isDefault: Bool
    let isActive: Bool
    var id: String { manager.rawValue + ":" + candidate + ":" + version }
}

enum DeveloperToolchainOperation: String, Sendable { case setDefault, install, uninstall, available, update }

enum DeveloperPrivilegedBridge: String, Sendable {
    case xcode = "bin/app_dev_xcode.sh"
    case proxy = "bin/app_net_fixproxy.sh"
}

struct DeveloperCommand: Identifiable, Sendable {
    let id = UUID()
    let titleKey: String
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let privilegedArguments: [String]?
    var privilegedBridge: DeveloperPrivilegedBridge = .xcode
    var operationGroup: UUID? = nil
    var toolchainRequest: DeveloperToolchainRequest? = nil
    var refreshAfterExecution = true
    var display: String {
        DeveloperSecretRedactor.redact(([executable] + arguments).map(DeveloperCLIService.shellQuote).joined(separator: " "))
    }
}

struct DeveloperToolchainRequest: Sendable {
    let manager: DeveloperManager
    let operation: DeveloperToolchainOperation
    let version: String
    let candidate: String
}

enum DeveloperToolchainService {
    static func javaHomes(environment: [String: String], home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        var homes: Set<String> = []
        if let current = environment["JAVA_HOME"], fm.fileExists(atPath: current + "/release") { homes.insert(current) }
        for root in ["/Library/Java/JavaVirtualMachines", home + "/Library/Java/JavaVirtualMachines"] {
            for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).prefix(128) {
                let path = root + "/" + name + "/Contents/Home"
                if fm.fileExists(atPath: path + "/release") { homes.insert(path) }
            }
        }
        for item in inventory(environment: environment, home: home) where item.candidate == "java" {
            if fm.fileExists(atPath: item.path + "/release") { homes.insert(item.path) }
        }
        for root in ["/opt/homebrew/opt", "/usr/local/opt"] {
            for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter({ $0.hasPrefix("openjdk") }).prefix(32) {
                let path = root + "/" + name + "/libexec/openjdk.jdk/Contents/Home"
                if fm.fileExists(atPath: path + "/release") { homes.insert(path) }
            }
        }
        return homes.sorted()
    }
    static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$"#, options: .regularExpression) != nil
    }

    static func executable(_ name: String, environment: [String: String]) -> String? {
        guard name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let path = String(directory) + "/" + name
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let directories = [home + "/.local/bin", home + "/.cargo/bin", home + "/.pyenv/bin", home + "/.rbenv/bin", home + "/.asdf/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories {
            let path = directory + "/" + name
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func activeExecutable(_ name: String, environment: [String: String]) -> String? {
        guard name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let path = String(directory) + "/" + name
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func inventory(environment: [String: String], home: String = NSHomeDirectory()) -> [DeveloperManagedVersion] {
        let fm = FileManager.default
        var result: [DeveloperManagedVersion] = []
        let roots: [(DeveloperManager, String, String)] = [
            (.nvm, (environment["NVM_DIR"] ?? home + "/.nvm") + "/versions/node", "node"),
            (.fnm, (environment["FNM_DIR"] ?? home + "/Library/Application Support/fnm") + "/node-versions", "node"),
            (.pyenv, (environment["PYENV_ROOT"] ?? home + "/.pyenv") + "/versions", "python"),
            (.rbenv, (environment["RBENV_ROOT"] ?? home + "/.rbenv") + "/versions", "ruby"),
            (.rustup, (environment["RUSTUP_HOME"] ?? home + "/.rustup") + "/toolchains", "rust")
        ]
        func versions(_ manager: DeveloperManager, _ root: String, _ candidate: String) {
            let defaults = defaultVersions(manager, candidate: candidate, environment: environment, home: home)
            let active = runtimeNames(manager, candidate: candidate).compactMap { activeExecutable($0, environment: environment) }
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted().prefix(128) where validIdentifier(name) && name != "current" {
                let path = root + "/" + name
                var directory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { continue }
                let selectedByEnvironment = activeSelectors(manager, candidate: candidate, environment: environment)
                    .contains { matchesSelector($0, version: name, manager: manager) }
                result.append(.init(manager: manager, candidate: candidate, version: name, path: path,
                                    isDefault: defaults.contains { matchesSelector($0, version: name, manager: manager) },
                                    isActive: selectedByEnvironment || active.contains { $0.hasPrefix(path + "/") }))
            }
        }
        for (manager, root, candidate) in roots { versions(manager, root, candidate) }
        let asdfRoot = (environment["ASDF_DATA_DIR"] ?? home + "/.asdf") + "/installs"
        for candidate in ((try? fm.contentsOfDirectory(atPath: asdfRoot)) ?? []).sorted().prefix(32) where validIdentifier(candidate) {
            versions(.asdf, asdfRoot + "/" + candidate, candidate)
        }
        let sdkRoot = (environment["SDKMAN_DIR"] ?? home + "/.sdkman") + "/candidates"
        for candidate in ((try? fm.contentsOfDirectory(atPath: sdkRoot)) ?? []).sorted().prefix(32) where validIdentifier(candidate) {
            versions(.sdkman, sdkRoot + "/" + candidate, candidate)
        }
        return result
    }

    static func defaultVersion(_ manager: DeveloperManager, candidate: String, environment: [String: String], home: String) -> String? {
        defaultVersions(manager, candidate: candidate, environment: environment, home: home).first
    }

    static func defaultVersions(_ manager: DeveloperManager, candidate: String, environment: [String: String], home: String) -> [String] {
        switch manager {
        case .nvm:
            let root = environment["NVM_DIR"] ?? home + "/.nvm"
            guard let alias = boundedText(root + "/alias/default") else { return [] }
            let installed = ((try? FileManager.default.contentsOfDirectory(atPath: root + "/versions/node")) ?? []).filter(validIdentifier)
            var visited: Set<String> = []
            func resolve(_ value: String) -> String? {
                guard visited.count < 16, visited.insert(value).inserted else { return nil }
                if installed.contains(value) { return value }
                if value == "node" || value == "stable" {
                    return installed.filter { !$0.contains("-") }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }.last
                }
                let components = value.split(separator: "/", omittingEmptySubsequences: false)
                let safeAlias = value == "lts/*" || (!components.isEmpty && components.count <= 8 && components.allSatisfy {
                    $0 != "." && $0 != ".." && $0.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
                })
                guard safeAlias else { return nil }
                if let target = boundedText(root + "/alias/" + value) { return resolve(target) }
                guard value.range(of: #"^v?[0-9]+(?:\.[0-9]+){0,2}(?:[-+][A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil else { return nil }
                let prefix = value.hasPrefix("v") ? value : "v" + value
                return installed.filter { $0 == prefix || $0.hasPrefix(prefix + ".") }.sorted {
                    $0.compare($1, options: .numeric) == .orderedAscending
                }.last ?? prefix
            }
            return resolve(alias).map { [$0] } ?? []
        case .pyenv: return selectors(boundedText((environment["PYENV_ROOT"] ?? home + "/.pyenv") + "/version"))
        case .rbenv: return selectors(boundedText((environment["RBENV_ROOT"] ?? home + "/.rbenv") + "/version"))
        case .fnm:
            let root = environment["FNM_DIR"] ?? home + "/Library/Application Support/fnm"
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/aliases/default"))
                .map { [URL(fileURLWithPath: $0).lastPathComponent == "installation" ? URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent : URL(fileURLWithPath: $0).lastPathComponent] } ?? []
        case .sdkman:
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: (environment["SDKMAN_DIR"] ?? home + "/.sdkman") + "/candidates/" + candidate + "/current"))
                .map { [URL(fileURLWithPath: $0).lastPathComponent] } ?? []
        case .asdf:
            return boundedText(home + "/.tool-versions")?.components(separatedBy: .newlines).compactMap { line -> [String]? in
                let pieces = line.components(separatedBy: "#")[0].split(whereSeparator: \.isWhitespace)
                return pieces.count >= 2 && pieces[0] == candidate ? pieces.dropFirst().map(String.init) : nil
            }.first ?? []
        case .rustup:
            guard let settings = boundedText((environment["RUSTUP_HOME"] ?? home + "/.rustup") + "/settings.toml"),
                  let version = quotedSetting("default_toolchain", in: settings), validIdentifier(version) else { return [] }
            return [version]
        }
    }

    private static func boundedText(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= 65_536,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func selectors(_ value: String?) -> [String] {
        value?.split(whereSeparator: { $0.isWhitespace || $0 == ":" }).map(String.init).filter(validIdentifier) ?? []
    }

    private static func runtimeNames(_ manager: DeveloperManager, candidate: String) -> [String] {
        if manager == .pyenv || candidate == "python" { return ["python3", "python"] }
        if manager == .rbenv { return ["ruby"] }
        if manager == .rustup { return ["rustc"] }
        if manager == .nvm || manager == .fnm || candidate == "nodejs" { return ["node"] }
        return [candidate == "maven" ? "mvn" : candidate == "golang" ? "go" : candidate]
    }

    private static func activeSelectors(_ manager: DeveloperManager, candidate: String, environment: [String: String]) -> [String] {
        switch manager {
        case .pyenv: return selectors(environment["PYENV_VERSION"])
        case .rbenv: return selectors(environment["RBENV_VERSION"])
        case .rustup: return selectors(environment["RUSTUP_TOOLCHAIN"])
        case .asdf: return selectors(environment["ASDF_" + candidate.uppercased().replacingOccurrences(of: "-", with: "_") + "_VERSION"])
        default: return []
        }
    }

    private static func matchesSelector(_ selector: String, version: String, manager: DeveloperManager) -> Bool {
        selector == version || (manager == .rustup && version.hasPrefix(selector + "-"))
    }

    private static func rustupOverrideVersions(environment: [String: String], home: String) -> [String] {
        guard let settings = boundedText((environment["RUSTUP_HOME"] ?? home + "/.rustup") + "/settings.toml") else { return [] }
        var inOverrides = false
        return settings.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inOverrides = trimmed == "[overrides]"; return nil }
            guard inOverrides, let regex = try? NSRegularExpression(pattern: #"^"[^"\r\n]*"\s*=\s*"([^"\r\n]+)"\s*(?:#.*)?$"#),
                  let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let range = Range(match.range(at: 1), in: trimmed), validIdentifier(String(trimmed[range])) else { return nil }
            return String(trimmed[range])
        }
    }

    private static func quotedSetting(_ name: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?m)^\\s*" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*"([^"\r\n]+)"\s*(?:#.*)?$"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// asdf 0.16 replaced the legacy Shell implementation with a native binary.
    /// Inspect the resolved file header; locations such as Homebrew libexec do
    /// not reliably indicate the command syntax.
    static func asdfIsModern(at path: String) -> Bool? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return nil }
        let bytes = [UInt8](data)
        if bytes[0] == 0x23 && bytes[1] == 0x21 { return false }
        let magic: Set<[UInt8]> = [[0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf],
                                  [0xce, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xce],
                                  [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
                                  [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
                                  [0x7f, 0x45, 0x4c, 0x46]]
        return magic.contains(bytes) ? true : nil
    }

    static func defaultCommand(manager: DeveloperManager, versions: [String], candidate: String = "java",
                               environment: [String: String], home: String = NSHomeDirectory()) -> DeveloperCommand? {
        guard !versions.isEmpty, versions.count <= 128, versions.allSatisfy(validIdentifier), validIdentifier(candidate),
              versions.count == 1 || [.pyenv, .rbenv, .asdf].contains(manager),
              let first = versions.first,
              let original = command(manager: manager, operation: .setDefault, version: first, candidate: candidate, environment: environment, home: home) else { return nil }
        if versions.count == 1 { return original }
        var seen: Set<String> = []
        let values = versions.filter { seen.insert($0).inserted }
        var result = DeveloperCommand(titleKey: original.titleKey, executable: original.executable,
                                      arguments: Array(original.arguments.dropLast()) + values,
                                      environment: original.environment, timeout: original.timeout,
                                      privilegedArguments: original.privilegedArguments)
        result.toolchainRequest = original.toolchainRequest
        return result
    }

    static func isHomebrewInstallation(_ resolvedPath: String, manager: DeveloperManager) -> Bool {
        let path = URL(fileURLWithPath: resolvedPath).standardizedFileURL.path
        return ["/opt/homebrew/Cellar/", "/opt/homebrew/opt/", "/usr/local/Cellar/", "/usr/local/opt/"].contains {
            path.hasPrefix($0 + manager.rawValue + "/")
        }
    }

    private static func nvmInitializationFile(environment: [String: String], home: String) -> String? {
        let preferred = (environment["NVM_DIR"] ?? home + "/.nvm") + "/nvm.sh"
        return [preferred, "/opt/homebrew/opt/nvm/nvm.sh", "/usr/local/opt/nvm/nvm.sh"].first {
            (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    static func command(manager: DeveloperManager, operation: DeveloperToolchainOperation, version: String = "",
                        candidate: String = "java", environment: [String: String], home: String = NSHomeDirectory()) -> DeveloperCommand? {
        guard validIdentifier(candidate), operation == .available || operation == .update || validIdentifier(version) else { return nil }
        if operation == .uninstall {
            guard let item = inventory(environment: environment, home: home).first(where: { $0.manager == manager && $0.version == version && (manager != .sdkman && manager != .asdf || $0.candidate == candidate) }),
                  !item.isActive, !item.isDefault else { return nil }
            if manager == .nvm, boundedText((environment["NVM_DIR"] ?? home + "/.nvm") + "/alias/default") != nil,
               defaultVersions(manager, candidate: candidate, environment: environment, home: home).isEmpty { return nil }
            let defaultFile: String?
            switch manager {
            case .nvm: defaultFile = (environment["NVM_DIR"] ?? home + "/.nvm") + "/alias/default"
            case .pyenv: defaultFile = (environment["PYENV_ROOT"] ?? home + "/.pyenv") + "/version"
            case .rbenv: defaultFile = (environment["RBENV_ROOT"] ?? home + "/.rbenv") + "/version"
            case .asdf: defaultFile = home + "/.tool-versions"
            case .rustup: defaultFile = (environment["RUSTUP_HOME"] ?? home + "/.rustup") + "/settings.toml"
            default: defaultFile = nil
            }
            if let defaultFile, FileManager.default.fileExists(atPath: defaultFile), boundedText(defaultFile) == nil { return nil }
            // A manager shim can choose a project or environment override. Refuse
            // deletion when the active runtime cannot be established from the sample.
            if manager == .pyenv || manager == .rbenv || manager == .asdf {
                let unresolvedShim = runtimeNames(manager, candidate: item.candidate).compactMap { executable($0, environment: environment) }.contains { $0.contains("/shims/") }
                if unresolvedShim {
                    let selected = activeSelectors(manager, candidate: candidate, environment: environment)
                    guard !selected.isEmpty, !selected.contains(version) else { return nil }
                }
            }
            if manager == .rustup,
               rustupOverrideVersions(environment: environment, home: home).contains(where: { matchesSelector($0, version: version, manager: manager) }) { return nil }
        }
        var args: [String]
        switch (manager, operation) {
        case (.nvm, .setDefault): args = ["alias", "default", version]
        case (.nvm, .install): args = ["install", version]
        case (.nvm, .uninstall): args = ["uninstall", version]
        case (.nvm, .available): args = ["ls-remote", "--lts"]
        case (.fnm, .setDefault): args = ["default", version]
        case (.fnm, .install): args = ["install", version]
        case (.fnm, .uninstall): args = ["uninstall", version]
        case (.fnm, .available): args = ["list-remote"]
        case (.pyenv, .setDefault), (.rbenv, .setDefault): args = ["global", version]
        case (.pyenv, .install), (.rbenv, .install): args = ["install", version]
        case (.pyenv, .uninstall), (.rbenv, .uninstall): args = ["uninstall", "-f", version]
        case (.pyenv, .available), (.rbenv, .available): args = ["install", "--list"]
        case (.rustup, .setDefault): args = ["default", version]
        case (.rustup, .install): args = ["toolchain", "install", version]
        case (.rustup, .uninstall): args = ["toolchain", "uninstall", version]
        case (.sdkman, .setDefault): args = ["default", candidate, version]
        case (.sdkman, .install): args = ["install", candidate, version]
        case (.sdkman, .uninstall): args = ["uninstall", candidate, version]
        case (.sdkman, .available): args = ["list", candidate]
        case (.sdkman, .update): args = ["selfupdate"]
        case (.rustup, .update): args = ["self", "update"]
        case (.fnm, .update), (.pyenv, .update), (.rbenv, .update), (.asdf, .update), (.nvm, .update):
            let managerFile = manager == .nvm ? nvmInitializationFile(environment: environment, home: home) : executable(manager.rawValue, environment: environment)
            guard let brew = executable("brew", environment: environment), let managerFile,
                  isHomebrewInstallation(URL(fileURLWithPath: managerFile).resolvingSymlinksInPath().path, manager: manager) else { return nil }
            var env = environment; env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            return .init(titleKey: "dev.action.update", executable: brew, arguments: ["upgrade", manager.rawValue], environment: env, timeout: 1800, privilegedArguments: nil)
        case (.asdf, .setDefault):
            guard let binary = executable("asdf", environment: environment), let isModern = asdfIsModern(at: binary) else { return nil }
            args = isModern ? ["set", "-u", candidate, version] : ["global", candidate, version]
        case (.asdf, .install): args = ["install", candidate, version]
        case (.asdf, .uninstall): args = ["uninstall", candidate, version]
        case (.asdf, .available): args = ["list", "all", candidate]
        default: return nil
        }
        var env = environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["NO_COLOR"] = "1"
        env["SDKMAN_NON_INTERACTIVE"] = "true"
        if manager == .nvm || manager == .sdkman {
            let file = manager == .nvm ? nvmInitializationFile(environment: env, home: home) : Optional((env["SDKMAN_DIR"] ?? home + "/.sdkman") + "/bin/sdkman-init.sh")
            guard let file, (try? URL(fileURLWithPath: file).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            let function = manager == .nvm ? "nvm" : "sdk"
            let script = manager == .nvm ? "source \"$1\" --no-use || exit; shift; nvm \"$@\"" : "source \"$1\" || exit; shift; sdk \"$@\""
            var command = DeveloperCommand(titleKey: "dev.action." + operation.rawValue, executable: "/bin/bash", arguments: ["--noprofile", "--norc", "-c", script, function, file] + args,
                         environment: env, timeout: 1800, privilegedArguments: nil)
            command.toolchainRequest = .init(manager: manager, operation: operation, version: version, candidate: candidate)
            command.refreshAfterExecution = operation != .available
            return command
        }
        guard let file = executable(manager.rawValue, environment: environment) else { return nil }
        var command = DeveloperCommand(titleKey: "dev.action." + operation.rawValue, executable: file, arguments: args,
                     environment: env, timeout: operation == .available ? 120 : 1800, privilegedArguments: nil)
        command.toolchainRequest = .init(manager: manager, operation: operation, version: version, candidate: candidate)
        command.refreshAfterExecution = operation != .available
        return command
    }

    static func xcodeCommand(_ operation: String, path: String = "") -> DeveloperCommand? {
        switch operation {
        case "install": return .init(titleKey: "dev.xcode.install", executable: "/usr/bin/xcode-select", arguments: ["--install"], environment: MoleEngine.shared.standardEnvironment(includeHomebrew: false), timeout: 30, privilegedArguments: nil)
        case "license": return .init(titleKey: "dev.xcode.license", executable: "/usr/bin/xcodebuild", arguments: ["-license", "accept"], environment: [:], timeout: 120, privilegedArguments: ["license"])
        case "select":
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
            guard canonical.hasPrefix("/Applications/"), canonical.hasSuffix(".app/Contents/Developer"),
                  FileManager.default.fileExists(atPath: canonical + "/usr/bin/xcodebuild") else { return nil }
            return .init(titleKey: "dev.xcode.select", executable: "/usr/bin/xcode-select", arguments: ["-s", canonical], environment: [:], timeout: 120, privilegedArguments: ["select", canonical])
        default: return nil
        }
    }
}
