import Darwin
import Foundation

/// Does not launch tools or read account configuration. All payloads, aliases
/// and saved snapshots live under the new caller-provided .build fixture.
@main struct CleanupDeveloperBoundaryTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        precondition(root.path.contains("/.build/") && !fm.fileExists(atPath: root.path))
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home")
        var failures = 0
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL " + message) }
        }
        let aliases = [(".gradle", "gradle-default", ["caches/modules-2/dependency.jar"]),
                       ("custom-gradle", "gradle-custom", ["caches/modules-2/dependency.jar"]),
                       (".cargo", "cargo-default", ["registry/src/pkg/source.rs", "git/checkouts/pkg/source.rs"]),
                       ("custom-cargo", "cargo-custom", ["registry/src/pkg/source.rs", "git/checkouts/pkg/source.rs"])]
        var leaves: [String] = []
        for (alias, target, payloads) in aliases {
            let physical = home.appendingPathComponent("Library/Caches/" + target)
            for payload in payloads {
                let url = physical.appendingPathComponent(payload)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: url)
                leaves.append(url.path)
            }
            try fm.createSymbolicLink(at: home.appendingPathComponent(alias), withDestinationURL: physical)
        }
        DeveloperCacheLocations.override = .resolve(home: home.path, environment: [
            "GRADLE_USER_HOME": home.path + "/custom-gradle", "CARGO_HOME": home.path + "/custom-cargo"
        ], readText: { _ in nil })
        defer { DeveloperCacheLocations.override = nil }
        for leaf in leaves {
            check(CleanupRiskPolicy.isProtectedCleanupPath(leaf, homeDirectory: home.path), "physical dependency protection: " + leaf)
            check(CleanupRiskPolicy.core(section: "Cache", path: leaf, homeDirectory: home.path).risk != .safe,
                  "physical dependency classification: " + leaf)
        }
        for target in ["gradle-default", "gradle-custom"] {
            let build = home.path + "/Library/Caches/" + target + "/caches/build-cache-1/output"
            check(!DeveloperCleanupCatalog.isDependencyStoreContent(build, home: home.path), "Gradle build-cache exception retained")
            check(CleanupRiskPolicy.core(section: "Cache", path: build, homeDirectory: home.path).risk == .safe,
                  "physical Gradle build cache classification")
        }
        let first = leaves[0], second = leaves[1]
        let category = CleanupCategory(name: "Fixture", paths: [first, second], bytes: 14,
            pathBytes: [first: 7, second: 7], selected: true, source: .developerCache,
            risk: .safe, disposal: .permanentDelete, applyRoute: .developerCacheTrash,
            activityGuard: .openFile, retention: CleanupAgePolicy.developerRetention,
            reasonKey: "cleanup.risk.recentlyActive").selectingPaths([first])
        let snapshot = root.appendingPathComponent("snapshot.json")
        CleanupCache.save([category], to: snapshot)
        let restored = CleanupCache.restore(from: snapshot)?.categories.first
        check(restored?.selectedPaths == [first], "partial selection round trip")
        check(restored?.retention == CleanupAgePolicy.developerRetention, "retention round trip")
        check(restored?.safeCleanupCandidate?.selectedPaths == [first], "partial selection presentation")
        CleanupCache.save([category.clearingSelection()], to: snapshot)
        let empty = CleanupCache.restore(from: snapshot)?.categories.first
        check(empty?.selectedPaths.isEmpty == true, "empty selection round trip")
        check(empty?.safeCleanupCandidate?.selectedPaths.isEmpty == true, "empty selection presentation")
        for broad in [home.path, home.path + "/Documents", home.path + "/Library/Caches", home.path + "/.cache"] {
            check(!DeveloperCleanupCatalog.isNarrowCacheRoot(broad, home: home.path), "broad cache rejected")
        }
        let config = DeveloperCacheLocations.resolve(home: home.path, environment: ["HOME": "/wrong", "UV_CACHE_DIR": "${HOME}/.cache/custom-uv"], readText: {
            $0 == home.path + "/.npmrc" ? "cache=${HOME}/custom-npm\nstore-dir=${HOME}/custom-pnpm\n" : nil
        })
        check(config.npmCache == home.path + "/custom-npm", "npm config cache resolution")
        check(config.pnpmStore == home.path + "/custom-pnpm", "pnpm config store resolution")
        check(config.uvCache == home.path + "/.cache/custom-uv", "environment HOME resolution")
        let benchmark = Date()
        var protectedCount = 0
        for index in 0..<20_000 {
            if CleanupRiskPolicy.isProtectedCleanupPath(leaves[index % leaves.count], homeDirectory: home.path) { protectedCount += 1 }
        }
        check(protectedCount == 20_000, "repeated physical dependency guard")
        print(String(format: "Physical dependency guard: 20000 checks in %.3fs", Date().timeIntervalSince(benchmark)))
        let collisionHome = root.appendingPathComponent("collision-home")
        let gradle = collisionHome.appendingPathComponent("gradle/caches")
        let cargo = collisionHome.appendingPathComponent("cargo/registry")
        try fm.createDirectory(at: gradle.appendingPathComponent("build-cache-1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cargo, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: cargo.appendingPathComponent("src"), withDestinationURL: gradle)
        DeveloperCacheLocations.override = .resolve(home: collisionHome.path, environment: [
            "CARGO_HOME": collisionHome.path + "/cargo", "GRADLE_USER_HOME": collisionHome.path + "/gradle"
        ], readText: { _ in nil })
        let collidingSource = gradle.appendingPathComponent("build-cache-1/source.rs").path
        check(CleanupRiskPolicy.isProtectedCleanupPath(collidingSource, homeDirectory: collisionHome.path),
              "strict source owner wins physical equal-root collision")
        check(CleanupRiskPolicy.core(section: "Cache", path: collidingSource, homeDirectory: collisionHome.path).risk != .safe,
              "equal-root collision is never recommended")
        print("Developer boundary audit: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
