import Foundation

/// 工具自定义缓存位置解析。只读取用户配置文件与环境变量，不执行任何
/// 工具命令；同一次进程内复用一份结果。发现层与风险策略共用它，保证
/// “规则认可”和“扫描得到”永远指向同一批路径。
struct DeveloperCacheLocations: Equatable {
    var npmCache: String?
    var yarnCache: String?
    var pipCache: String?
    var gradleUserHome: String?
    var cargoHome: String?
    var goModCache: String?
    var goBuildCache: String?
    var xdgCacheHome: String?
    var poetryCache: String?

    static func resolve(home: String,
                        environment: [String: String],
                        readText: (String) -> String? = DeveloperCacheLocations.defaultReadText)
        -> DeveloperCacheLocations {
        func expand(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            var value = raw
            if value == "~" || value.hasPrefix("~/") { value = home + String(value.dropFirst()) }
            guard value.hasPrefix("/") else {
                // 相对路径相对当前用户 home 解释（npm/pip 配置的常见写法）。
                value = home + "/" + value
                return URL(fileURLWithPath: value).standardizedFileURL.path
            }
            return URL(fileURLWithPath: value).standardizedFileURL.path
        }
        func firstExisting(_ candidates: [String?]) -> String? {
            candidates.compactMap { $0 }.first
        }

        // npm：npmrc 的 cache= 优先，其次 NPM_CONFIG_CACHE / npm_config_cache。
        var npmCache = expand(environment["NPM_CONFIG_CACHE"] ?? environment["npm_config_cache"])
        if npmCache == nil {
            for configPath in [home + "/.npmrc", "/etc/npmrc"] {
                guard let text = readText(configPath) else { continue }
                if let value = Self.configValue(in: text, key: "cache") {
                    npmCache = expand(value)
                    break
                }
            }
        }

        // Yarn：.yarnrc.yml 的 cacheFolder 或 YARN_CACHE_FOLDER。
        var yarnCache = expand(environment["YARN_CACHE_FOLDER"])
        if yarnCache == nil {
            for configPath in [home + "/.yarnrc.yml", home + "/.yarnrc"] {
                guard let text = readText(configPath) else { continue }
                if let value = Self.configValue(in: text, key: "cacheFolder")
                    ?? Self.configValue(in: text, key: "cache-folder") {
                    yarnCache = expand(value)
                    break
                }
            }
        }

        // pip：PIP_CACHE_DIR 或 pip.conf [global] cache-dir。
        var pipCache = expand(environment["PIP_CACHE_DIR"])
        if pipCache == nil {
            for configPath in [home + "/Library/Application Support/pip/pip.conf",
                               home + "/.config/pip/pip.conf", home + "/.pip/pip.conf"] {
                guard let text = readText(configPath) else { continue }
                if let value = Self.configValue(in: text, key: "cache-dir") {
                    pipCache = expand(value)
                    break
                }
            }
        }

        return DeveloperCacheLocations(
            npmCache: firstExisting([npmCache]),
            yarnCache: firstExisting([yarnCache]),
            pipCache: firstExisting([pipCache]),
            gradleUserHome: expand(environment["GRADLE_USER_HOME"]),
            cargoHome: expand(environment["CARGO_HOME"]),
            goModCache: expand(environment["GOMODCACHE"]),
            goBuildCache: expand(environment["GOCACHE"]),
            xdgCacheHome: expand(environment["XDG_CACHE_HOME"]),
            poetryCache: expand(environment["POETRY_CACHE_DIR"]))
    }

    /// 进程级缓存。环境变量与用户配置在进程生命周期内视为稳定；测试用
    /// `override` 注入受控值。
    private static let lock = NSLock()
    private static var cachedValue: DeveloperCacheLocations?
    private static var overrideValue: DeveloperCacheLocations?

    static var override: DeveloperCacheLocations? {
        get { lock.lock(); defer { lock.unlock() }; return overrideValue }
        set { lock.lock(); overrideValue = newValue; lock.unlock() }
    }

    static func current(home: String = NSHomeDirectory()) -> DeveloperCacheLocations {
        lock.lock()
        if let overrideValue { lock.unlock(); return overrideValue }
        if let cachedValue { lock.unlock(); return cachedValue }
        lock.unlock()
        let resolved = resolve(home: home,
                               environment: ProcessInfo.processInfo.environment)
        lock.lock()
        if cachedValue == nil { cachedValue = resolved }
        let value = cachedValue ?? resolved
        lock.unlock()
        return value
    }

    /// 简单 ini/yaml 行解析：`key = value` / `key: value`（够用且无依赖）。
    static func configValue(in text: String, key: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix(";"), !line.hasPrefix("[") else { continue }
            let separators = CharacterSet(charactersIn: "=:")
            guard let separator = line.firstIndex(where: { separators.contains($0.unicodeScalars.first ?? " ") }) else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func defaultReadText(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}
