import Darwin
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
    var uvCache: String? = nil
    var bunCache: String? = nil
    var denoCache: String? = nil
    var homebrewCache: String? = nil
    var pnpmStore: String? = nil
    var retainedPhysicalRoots: [String] = []
    var homebrewPhysicalRoots: [String] = []
    var goModPhysicalRoots: [String] = []
    var dependencyPhysicalRoots: [String] = []
    var gradlePhysicalCacheRoots: [String] = []
    var cargoPhysicalCacheRoots: [String] = []
    var npmPhysicalRoots: [String] = []

    static func resolve(home: String,
                        environment: [String: String],
                        readText: (String) -> String? = DeveloperCacheLocations.defaultReadText)
        -> DeveloperCacheLocations {
        func expand(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            var value = raw
            // Tool configs commonly use ${HOME}/${XDG_CACHE_HOME}. Expand
            // declared environment values without invoking a shell.
            for (name, replacement) in environment.merging(["HOME": home], uniquingKeysWith: { _, supplied in supplied }) {
                value = value.replacingOccurrences(of: "${" + name + "}", with: replacement)
            }
            guard !value.contains("${"), !value.contains("\n"), !value.contains("\r") else { return nil }
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

        // npm：环境变量优先，其次用户配置和系统配置。
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

        // pnpm's content-addressed store is separate from its dlx cache.
        // Honor its npmrc/rc store-dir before falling back to macOS's store.
        var pnpmStore = expand(environment["PNPM_STORE_DIR"]
            ?? environment["npm_config_store_dir"] ?? environment["NPM_CONFIG_STORE_DIR"])
        if pnpmStore == nil {
            for configPath in [home + "/.npmrc", home + "/.config/pnpm/rc",
                               home + "/Library/Preferences/pnpm/rc"] {
                guard let text = readText(configPath),
                      let value = Self.configValue(in: text, key: "store-dir") else { continue }
                pnpmStore = expand(value)
                break
            }
        }
        if pnpmStore == nil {
            pnpmStore = home + "/Library/pnpm/store"
        }

        let gradleHomes = [home + "/.gradle"] + [expand(environment["GRADLE_USER_HOME"])].compactMap { $0 }
        let cargoHomes = [home + "/.cargo"] + [expand(environment["CARGO_HOME"])].compactMap { $0 }
        let dependencyRoots = [home + "/.m2/repository", home + "/.ivy2/cache",
            home + "/.nuget/packages", home + "/.pub-cache", home + "/.cabal/packages",
            home + "/.cpan/sources", home + "/.sbt/boot", home + "/.sbt/launchers"]
            + cargoHomes.flatMap { [$0 + "/registry/src", $0 + "/git"] }
        // Preserve the physical spelling required by the no-follow walker.
        // Foundation may shorten /private/var to the /var symlink alias.
        func physicalPath(_ path: String) -> String {
            if let pointer = realpath(path, nil) {
                defer { free(pointer) }
                return String(cString: pointer)
            }
            let resolved = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path
            if resolved == "/var" || resolved.hasPrefix("/var/")
                || resolved == "/tmp" || resolved.hasPrefix("/tmp/")
                || resolved == "/etc" || resolved.hasPrefix("/etc/") {
                return "/private" + resolved
            }
            return resolved
        }
        func physicalRoots(_ paths: [String]) -> [String] {
            Array(Set(paths.map(physicalPath))).sorted()
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
            poetryCache: expand(environment["POETRY_CACHE_DIR"]),
            uvCache: expand(environment["UV_CACHE_DIR"]),
            bunCache: expand(environment["BUN_INSTALL_CACHE_DIR"]),
            denoCache: expand(environment["DENO_DIR"]),
            homebrewCache: expand(environment["HOMEBREW_CACHE"]),
            pnpmStore: pnpmStore,
            retainedPhysicalRoots: ([home + "/Library/Caches/deno", home + "/.cache/deno", home + "/.deno",
                                     home + "/Library/Caches/pypoetry/virtualenvs", home + "/.cache/poetry/virtualenvs",
                                     home + "/Library/Caches/org.R-project.R/R/renv",
                                     home + "/.aws/cli/cache", home + "/.jupyter/runtime"]
                + [expand(environment["DENO_DIR"]),
                   expand(environment["POETRY_CACHE_DIR"]).map { $0 + "/virtualenvs" }].compactMap { $0 }).map(physicalPath),
            homebrewPhysicalRoots: ([home + "/Library/Caches/Homebrew"]
                + [expand(environment["HOMEBREW_CACHE"])].compactMap { $0 }).map(physicalPath),
            goModPhysicalRoots: ([home + "/go/pkg/mod"]
                + [expand(environment["GOMODCACHE"])].compactMap { $0 }).map(physicalPath),
            dependencyPhysicalRoots: physicalRoots(dependencyRoots),
            gradlePhysicalCacheRoots: physicalRoots(gradleHomes.map { $0 + "/caches" }),
            cargoPhysicalCacheRoots: physicalRoots(cargoHomes.map { $0 + "/registry/cache" }),
            npmPhysicalRoots: physicalRoots([home + "/.npm"] + [npmCache].compactMap { $0 }))
    }

    /// 进程级缓存。环境变量与用户配置在进程生命周期内视为稳定；测试用
    /// `override` 注入受控值。
    private static let processEnvironment = ProcessInfo.processInfo.environment
    private static let lock = NSLock()
    private static var cachedValue: DeveloperCacheLocations?
    private static var cachedEnvironment: [String: String]?
    private static var cachedHome: String?
    private static var overrideValue: DeveloperCacheLocations?

    static var override: DeveloperCacheLocations? {
        get { lock.lock(); defer { lock.unlock() }; return overrideValue }
        set { lock.lock(); overrideValue = newValue; lock.unlock() }
    }

    static func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cachedValue = nil
        cachedEnvironment = nil
        cachedHome = nil
    }

    static func current(home: String = NSHomeDirectory(), environment: [String: String]? = nil) -> DeveloperCacheLocations {
        let environment = environment ?? processEnvironment
        lock.lock()
        if let overrideValue { lock.unlock(); return overrideValue }
        if cachedEnvironment == environment, cachedHome == home, let cachedValue { lock.unlock(); return cachedValue }
        lock.unlock()
        let resolved = resolve(home: home, environment: environment)
        lock.lock()
        cachedValue = resolved
        cachedEnvironment = environment
        cachedHome = home
        let value = resolved
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

/// Shared discovery and classification catalog. All entries still pass physical,
/// content, activity and final deletion guards before becoming actionable.
enum DeveloperCleanupCatalog {
    struct Entry: Equatable {
        let path: String
        let label: String
    }

    private static let defaults: [(String, String)] = [
        (".npm/_cacache", "npm Cache"),
        (".npm/_logs", "npm Logs"),
        (".swiftpm/cache", "SwiftPM Cache"),
        (".cache/node/corepack", "Corepack Cache"),
        ("Library/Caches/org.carthage.CarthageKit", "Carthage Cache"),
        (".bun/install/cache", "Bun Cache"),
        ("Library/Caches/pnpm", "pnpm Cache"),
        ("Library/pnpm/store", "pnpm Store"),
        (".pnpm-store", "pnpm Store"),
        (".local/share/pnpm/store", "pnpm Store"),
        (".yarn/cache", "Yarn Cache"),
        ("Library/Caches/Yarn", "Yarn Cache"),
        (".gradle/daemon", "Gradle Cache"),
        (".gradle/workers", "Gradle Cache"),
        (".gradle/notifications", "Gradle Cache"),
        ("Library/Caches/go-build", "Go Build Cache"),
        ("go/pkg/mod/cache", "Go Download Cache"),
        (".cargo/registry/cache", "Cargo Cache"),
        ("Library/Caches/NuGet", "NuGet Cache"),
        ("Library/Caches/pip", "pip Cache"),
        (".cache/pip", "pip Cache"),
        ("Library/Caches/pypoetry/cache", "Poetry Cache"),
        ("Library/Caches/pypoetry/artifacts", "Poetry Artifacts"),
        (".cache/uv", "uv Cache"),
        (".composer/cache", "Composer Cache"),
        ("Library/Caches/composer", "Composer Cache"),
        (".cache/bazel", "Bazel Cache"),
        (".cache/zig", "Zig Cache"),
        ("Library/Caches/org.swift.swiftpm", "SwiftPM Cache"),
        ("Library/Caches/Homebrew/downloads", "Homebrew Cache"),
        ("Library/Caches/node-gyp", "node-gyp Cache"),
        ("Library/Caches/typescript", "TypeScript Cache"),
        (".hex/cache", "Hex Cache"),
        (".tnpm/_cacache", "tnpm Cache"),
        (".tnpm/_logs", "tnpm Logs"),
        (".cache/poetry/cache", "Poetry Cache"),
        (".cache/poetry/artifacts", "Poetry Artifacts"),
        (".cache/ruff", "Ruff Cache"),
        (".cache/mypy", "mypy Cache"),
        (".pytest_cache", "pytest Cache"),
        (".rbenv/cache", "Ruby Cache"),
        (".gem/specs", "RubyGems Metadata"),
        (".bundle/cache", "Bundler Cache"),
        (".cpan/build", "CPAN Build Cache"),
        (".kube/cache", "Kubernetes Cache"),
        (".config/gcloud/logs", "gcloud Logs"),
        (".azure/logs", "Azure Logs"),
        (".cache/typescript", "TypeScript Cache"),
        (".cache/electron", "Electron Cache"),
        (".cache/node-gyp", "node-gyp Cache"),
        (".node-gyp", "node-gyp Cache"),
        (".turbo/cache", "Turborepo Cache"),
        (".vite/cache", "Vite Cache"),
        (".cache/vite", "Vite Cache"),
        (".cache/webpack", "Webpack Cache"),
        (".parcel-cache", "Parcel Cache"),
        (".cache/eslint", "ESLint Cache"),
        (".cache/prettier", "Prettier Cache"),
        (".android/build-cache", "Android Build Cache"),
        (".android/cache", "Android Cache"),
        (".cache/swift-package-manager", "SwiftPM Cache"),
        (".expo/expo-go", "Expo Cache"),
        (".expo/android-apk-cache", "Expo Cache"),
        (".expo/ios-simulator-app-cache", "Expo Cache"),
        (".expo/native-modules-cache", "Expo Cache"),
        (".expo/schema-cache", "Expo Cache"),
        (".expo/template-cache", "Expo Cache"),
        (".expo/versions-cache", "Expo Cache"),
        ("Library/Logs/JetBrains", "JetBrains Logs"),
    ]

    static func entries(home: String) -> [Entry] {
        let locations = DeveloperCacheLocations.current(home: home)
        var result = defaults.map { Entry(path: home + "/" + $0.0, label: $0.1) }
        func add(_ path: String?, _ label: String) {
            guard let path, isNarrowCacheRoot(path, home: home) else { return }
            result.append(Entry(path: path, label: label))
        }
        add(locations.npmCache, "npm Cache")
        add(locations.yarnCache, "Yarn Cache")
        add(locations.pipCache, "pip Cache")
        add(locations.uvCache, "uv Cache")
        add(locations.bunCache, "Bun Cache")
        add(locations.goBuildCache, "Go Build Cache")
        add(locations.pnpmStore, "pnpm Store")
        if let poetry = locations.poetryCache {
            add(poetry + "/cache", "Poetry Cache")
            add(poetry + "/artifacts", "Poetry Artifacts")
        }
        if let brew = locations.homebrewCache { add(brew + "/downloads", "Homebrew Cache") }
        if let go = locations.goModCache { add(go + "/cache", "Go Download Cache") }
        if let cargo = locations.cargoHome { add(cargo + "/registry/cache", "Cargo Cache") }
        for cache in locations.cargoPhysicalCacheRoots { add(cache, "Cargo Cache") }
        if let gradle = locations.gradleUserHome {
            for leaf in ["daemon", "workers", "notifications"] { add(gradle + "/" + leaf, "Gradle Cache") }
        }
        var seen = Set<String>()
        return result.filter { isNarrowCacheRoot($0.path, home: home) && seen.insert($0.path).inserted }
    }

    /// A configured cache must never authorize a whole user or document root.
    static func isNarrowCacheRoot(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              path == URL(fileURLWithPath: path).standardizedFileURL.path else { return false }
        let components = path.split(separator: "/")
        guard !components.contains(".."), !components.contains(".") else { return false }
        let broad = ["Library", "Library/Caches", "Library/Application Support", "Documents", "Desktop",
                     "Downloads", "Pictures", "Music", "Movies", "Projects", "Code", ".cache", ".config", ".local"]
        return !broad.contains { path == home + "/" + $0 }
    }

    static func goDownloadRoots(home: String) -> [String] {
        toolStateBoundary(home: home).goRoots.map { $0 + "/cache" }
    }

    private struct ToolStateBoundary {
        let locations: DeveloperCacheLocations
        let retained: [String]
        let brewRoots: [String]
        let goRoots: [String]
        let dependencyRoots: [String]
        let strictDependencyRoots: Set<String>
        let gradleCacheRoots: [String]
    }
    private static let boundaryLock = NSLock()
    private static var boundaryCache: [String: ToolStateBoundary] = [:]

    /// Reuse immutable boundaries during a traversal; do no filesystem work per
    /// payload. Native scans refresh the location snapshot and shell guards
    /// resolve aliases again immediately before deletion.
    private static func toolStateBoundary(home: String) -> ToolStateBoundary {
        let locations = DeveloperCacheLocations.current(home: home)
        boundaryLock.lock()
        defer { boundaryLock.unlock() }
        if let cached = boundaryCache[home], cached.locations == locations { return cached }
        var retained = [home + "/Library/Caches/deno", home + "/.cache/deno", home + "/.deno",
                        home + "/.aws/cli/cache", home + "/.jupyter/runtime",
                        home + "/Library/Caches/org.R-project.R/R/renv",
                        home + "/Library/Caches/pypoetry/virtualenvs", home + "/.cache/poetry/virtualenvs"]
        retained += locations.retainedPhysicalRoots
        if let deno = locations.denoCache { retained.append(deno) }
        if let poetry = locations.poetryCache { retained.append(poetry + "/virtualenvs") }
        let brewRoots = [home + "/Library/Caches/Homebrew"] + locations.homebrewPhysicalRoots
            + (locations.homebrewCache.map { [$0] } ?? [])
        let goRoots = [home + "/go/pkg/mod"] + locations.goModPhysicalRoots
            + (locations.goModCache.map { [$0] } ?? [])
        var strictRoots = [home + "/.m2/repository", home + "/.ivy2/cache",
                           home + "/.nuget/packages", home + "/.pub-cache", home + "/.cargo/git",
                           home + "/.cargo/registry/src", home + "/.cabal/packages", home + "/.cpan/sources",
                           home + "/.sbt/boot", home + "/.sbt/launchers"] + locations.dependencyPhysicalRoots
        let gradleCacheRoots = [home + "/.gradle/caches"]
            + (locations.gradleUserHome.map { [$0 + "/caches"] } ?? []) + locations.gradlePhysicalCacheRoots
        if let cargo = locations.cargoHome { strictRoots += [cargo + "/registry/src", cargo + "/git"] }
        let boundary = ToolStateBoundary(locations: locations, retained: Array(Set(retained)),
                                         brewRoots: Array(Set(brewRoots)), goRoots: Array(Set(goRoots)),
                                         dependencyRoots: Array(Set(strictRoots + goRoots + gradleCacheRoots)),
                                         strictDependencyRoots: Set(strictRoots), gradleCacheRoots: gradleCacheRoots)
        boundaryCache[home] = boundary
        return boundary
    }

    static func dependencyStoreRoots(home: String) -> [String] {
        toolStateBoundary(home: home).dependencyRoots
    }

    static func isDependencyStoreContent(_ path: String, home: String) -> Bool {
        let boundary = toolStateBoundary(home: home)
        guard let owner = boundary.dependencyRoots.filter({ path == $0 || path.hasPrefix($0 + "/") })
            .max(by: { $0.count < $1.count }) else { return false }
        // The most specific owner wins when a configured store is nested in
        // another tool's cache. A strict owner wins an equal-root collision.
        if boundary.strictDependencyRoots.contains(owner) { return true }
        if boundary.goRoots.contains(owner) {
            return path != owner + "/cache" && !path.hasPrefix(owner + "/cache/")
        }
        if boundary.gradleCacheRoots.contains(owner) {
            let prefix = owner + "/"
            if path.hasPrefix(prefix),
               String(path.dropFirst(prefix.count)).split(separator: "/").first?.hasPrefix("build-cache-") == true { return false }
        }
        return true
    }

    /// Cache-looking paths that contain live runtime/origin state or credentials.
    static func isRetainedToolState(_ path: String, home: String) -> Bool {
        let boundary = toolStateBoundary(home: home)
        if boundary.retained.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        return boundary.brewRoots.contains { root in
            (path == root || path.hasPrefix(root + "/"))
                && path != root + "/downloads" && !path.hasPrefix(root + "/downloads/")
        }
    }
}
