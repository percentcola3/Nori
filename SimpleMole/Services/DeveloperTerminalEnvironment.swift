import Foundation
import Darwin

struct DeveloperTerminalSnapshot: Equatable, Sendable {
    let environment: [String: String]
    let shell: String
    let sampledAt: Date?
    let duration: TimeInterval?
    let failed: Bool
    var isSampled: Bool { sampledAt != nil && !failed }
}

/// A user-enabled sample, rather than a promise to reproduce an existing terminal.
/// Raw startup output is never displayed or persisted.
actor DeveloperTerminalEnvironmentService {
    static let shared = DeveloperTerminalEnvironmentService()
    static let enabledKey = "devTerminalSamplingEnabled"
    static let keys = ["PATH", "HOME", "JAVA_HOME", "NVM_DIR", "FNM_DIR", "PYENV_ROOT", "RBENV_ROOT",
                       "ASDF_DATA_DIR", "SDKMAN_DIR", "CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN", "ZDOTDIR", "PYENV_VERSION", "RBENV_VERSION", "SSH_AUTH_SOCK",
                       "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "GOPATH", "GOCACHE", "GOMODCACHE",
                       "http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY",
                       "ALL_PROXY", "NO_PROXY", "HOMEBREW_API_DOMAIN", "HOMEBREW_BOTTLE_DOMAIN",
                       "UV_DEFAULT_INDEX", "PIP_INDEX_URL", "PIP_EXTRA_INDEX_URL", "GOPROXY", "npm_config_registry",
                       "NPM_CONFIG_CACHE", "npm_config_cache", "PIP_CACHE_DIR", "UV_CACHE_DIR", "BUN_INSTALL_CACHE_DIR", "DENO_DIR",
                       "HOMEBREW_CACHE", "PNPM_STORE_DIR", "YARN_CACHE_FOLDER", "DOCKER_CONFIG", "YARN_NPM_REGISTRY_SERVER",
                       "npm_config_proxy", "npm_config_https_proxy", "NPM_CONFIG_PROXY", "NPM_CONFIG_HTTPS_PROXY", "PIP_PROXY"]
    private var cached: DeveloperTerminalSnapshot?
    private var pending: Task<DeveloperTerminalSnapshot, Never>?

    static func defaultShell() -> String {
        guard let entry = getpwuid(getuid()), let pointer = entry.pointee.pw_shell else { return "/bin/zsh" }
        let shell = String(cString: pointer)
        return shell.isEmpty ? "/bin/zsh" : shell
    }

    static func fallback() -> DeveloperTerminalSnapshot {
        let source = ProcessInfo.processInfo.environment
        var environment = source.filter { keys.contains($0.key) }
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        return .init(environment: environment, shell: defaultShell(), sampledAt: nil, duration: nil, failed: false)
    }

    func snapshot(force: Bool = false) async -> DeveloperTerminalSnapshot {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            cached = nil
            return Self.fallback()
        }
        if let pending { return await pending.value }
        if !force, let cached { return cached }
        let task = Task { await Self.sample() }
        pending = task
        let result = await task.value
        cached = result
        pending = nil
        return result
    }

    func invalidate() { cached = nil }

    static func decode(_ output: String, marker: String) -> [String: String]? {
        let fields = output.components(separatedBy: "\0")
        guard let start = fields.firstIndex(of: marker), let end = fields.lastIndex(of: marker + "-end"),
              end > start, (end - start - 1).isMultiple(of: 2) else { return nil }
        var environment: [String: String] = [:]
        var index = start + 1
        while index < end {
            let key = fields[index], value = fields[index + 1]
            guard keys.contains(key), value.utf8.count <= 65_536 else { return nil }
            if !value.isEmpty { environment[key] = value }
            index += 2
        }
        guard environment["PATH"] != nil else { return nil }
        return environment
    }

    private static func sample() async -> DeveloperTerminalSnapshot {
        let fallback = fallback()
        guard ["/bin/zsh", "/bin/bash"].contains(fallback.shell) else { return fallback }
        let marker = "NORI-ENV-" + UUID().uuidString
        // Indirection uses only the fixed key catalog, never a user-provided expression.
        let script = "printf '\\0%s\\0' '" + marker + "'; for key in " + keys.joined(separator: " ")
            + "; do eval 'value=${'\"$key\"'-}'; printf '%s\\0%s\\0' \"$key\" \"$value\"; done; printf '%s\\0' '" + marker + "-end'"
        let engine = MoleEngine()
        var environment = engine.standardEnvironment()
        environment["HOME"] = NSHomeDirectory()
        environment["DISABLE_AUTO_UPDATE"] = "true"
        environment["DISABLE_UPDATE_PROMPT"] = "true"
        environment["ZSH_DISABLE_COMPFIX"] = "true"
        environment["POWERLEVEL9K_INSTANT_PROMPT"] = "off"
        let start = Date()
        let result = await engine.run(executable: URL(fileURLWithPath: fallback.shell), arguments: ["-lic", script],
                                      environment: environment, currentDirectory: URL(fileURLWithPath: NSHomeDirectory()), timeout: 10)
        guard result.succeeded, let values = decode(result.output, marker: marker) else {
            return .init(environment: fallback.environment, shell: fallback.shell, sampledAt: Date(),
                         duration: Date().timeIntervalSince(start), failed: true)
        }
        return .init(environment: values, shell: fallback.shell, sampledAt: Date(),
                     duration: Date().timeIntervalSince(start), failed: false)
    }
}

enum DeveloperSecretRedactor {
    static func redact(_ text: String) -> String {
        var result = text
        let patterns = [
            (#"(?i)(https?|socks[45h]?)://[^/\s@]+@"#, "$1://[redacted]@"),
            (#"(?im)((?:token|password|passwd|secret|_auth(?:token)?|authorization|api[_-]?key)\s*[=:]\s*)[^\r\n]+"#, "$1[redacted]"),
            (#"(?i)([?&](?:token|key|password|secret|auth)=)[^&\s]+"#, "$1[redacted]")
        ]
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
            }
        }
        return result
    }
}
