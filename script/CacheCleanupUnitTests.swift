import Foundation

struct CacheFixtureCase {
    let name: String
    let root: String
    let aged: Bool
    static let all: [Self] = [
        .init(name: "ordinary", root: "Library/Caches/com.example.fixture", aged: false),
        .init(name: "diagnostics", root: "Library/DiagnosticReports/FixtureReports", aged: false),
        .init(name: "logs", root: "Library/Logs/com.example.fixture", aged: false),
        .init(name: "npm", root: ".npm/_cacache", aged: true),
        .init(name: "yarn", root: ".yarn/cache", aged: true),
        .init(name: "bun", root: ".bun/install/cache", aged: true),
        .init(name: "gradle-build", root: ".gradle/caches/build-cache-1", aged: true),
        .init(name: "cargo-downloads", root: ".cargo/registry/cache", aged: true),
        .init(name: "pip", root: ".cache/pip", aged: true),
        .init(name: "uv", root: ".cache/uv", aged: true),
        .init(name: "homebrew-downloads", root: "Library/Caches/Homebrew/downloads", aged: true),
        .init(name: "go-downloads", root: "go/pkg/mod/cache", aged: true),
        .init(name: "go-build", root: "Library/Caches/go-build", aged: true),
        .init(name: "pnpm-dlx", root: "Library/Caches/pnpm", aged: true),
        .init(name: "pnpm-store", root: "Library/pnpm/store/v10/files", aged: true),
        .init(name: "codex-web", root: "Library/Application Support/Codex/Cache", aged: true),
        .init(name: "cursor-code", root: "Library/Application Support/Cursor/Code Cache", aged: true),
        .init(name: "cursor-compile", root: "Library/Caches/cursor-compile-cache", aged: true),
        .init(name: "zed-npm", root: "Library/Application Support/Zed/node/cache/_cacache", aged: true),
        .init(name: "zed-node-version", root: "Library/Application Support/Zed/node/node-v22.0.0/cache", aged: true),
        .init(name: "zed-runtime", root: "Library/Application Support/Zed/languages/vtsls", aged: true),
        .init(name: "zed-work", root: "Library/Application Support/Zed/extensions/work", aged: true),
        .init(name: "blender", root: "Library/Caches/org.blenderfoundation.blender", aged: true),
        .init(name: "playwright", root: "Library/Caches/ms-playwright/chromium-1234/Chrome.app/Contents/MacOS", aged: true),
        .init(name: "poetry", root: "Library/Caches/pypoetry", aged: true),
        .init(name: "nuget-downloads", root: "Library/Caches/NuGet", aged: true),
        .init(name: "composer", root: "Library/Caches/composer", aged: true),
        .init(name: "node-gyp", root: "Library/Caches/node-gyp", aged: true),
        .init(name: "swiftpm", root: "Library/Caches/org.swift.swiftpm", aged: true),
        .init(name: "bazel", root: ".cache/bazel", aged: true),
        .init(name: "vite", root: ".cache/vite", aged: true),
        .init(name: "webpack", root: ".cache/webpack", aged: true),
        .init(name: "xcode-derived", root: "Library/Developer/Xcode/DerivedData/FixtureProject", aged: true),
        .init(name: "simulator-cache", root: "Library/Developer/CoreSimulator/Caches", aged: true),
        .init(name: "firmware", root: "Library/iTunes/iPhone Software Updates", aged: false),
        .init(name: "chrome", root: "Library/Application Support/Google/Chrome/Default/Cache", aged: false),
        .init(name: "edge", root: "Library/Application Support/Microsoft Edge/Default/Code Cache", aged: false),
        .init(name: "brave", root: "Library/Application Support/BraveSoftware/Brave-Browser/Default/GPUCache", aged: false),
        .init(name: "arc", root: "Library/Application Support/Arc/User Data/Default/Service Worker/ScriptCache", aged: false)
    ]
}
func cacheExpect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw NSError(domain: "CacheCleanupTest", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]) }
}
enum CacheCleanupUnitTests {
    static func run(home: String) throws {
        for item in CacheFixtureCase.all {
            let descriptor = CleanupRiskPolicy.core(section: "Cache", path: home + "/" + item.root, homeDirectory: home)
            try cacheExpect(descriptor.risk == .safe && descriptor.disposal == .permanentDelete,
                            "UNIT \(item.name): cache classification must be regenerable")
        }
        for relative in [".m2/repository", ".gradle/caches/modules-2", ".nuget/packages", "go/pkg/mod"] {
            let descriptor = CleanupRiskPolicy.developerCache(path: home + "/" + relative, homeDirectory: home)
            try cacheExpect(descriptor.risk == .warning, "UNIT dependency store was recommended: " + relative)
        }
        for (relative, expected) in [
            (".codex/auth.json", CleanupRisk.warning),
            (".codex/sessions/history.jsonl", .protected),
            (".cache/huggingface/models/weights", .protected),
            ("Library/Application Support/Google/Chrome/Default/Cookies", .protected),
            ("Library/Application Support/Google/Chrome/Default/Login Data", .protected)
        ] {
            try cacheExpect(CleanupRiskPolicy.core(section: "Cache", path: home + "/" + relative,
                homeDirectory: home).risk == expected, "UNIT sensitive content classification: " + relative)
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let retention = CleanupAgePolicy.developerRetention
        for (evidence, expected) in [(Optional<Date>.none, false), (now, false),
            (now.addingTimeInterval(-retention + 1), false), (now.addingTimeInterval(-retention), true),
            (now.addingTimeInterval(-retention - 1), true), (now.addingTimeInterval(121), false)] {
            try cacheExpect(CleanupAgePolicy.isStale(evidence, now: now, retention: retention) == expected,
                            "UNIT seven-day boundary or missing/future evidence")
        }
        try cacheExpect(CleanupAgePolicy.activityEvidence(modified: now.addingTimeInterval(-retention),
            accessed: now) == now, "UNIT recent reads must protect old writes")
        print("PASS UNIT: \(CacheFixtureCase.all.count) cache classifications, 4 dependency stores, 5 sensitive paths, 7 age/evidence checks")
    }
}
