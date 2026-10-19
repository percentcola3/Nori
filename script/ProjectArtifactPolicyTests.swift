import Darwin
import Foundation

private struct ProjectPolicyFailure: Error, CustomStringConvertible { let description: String }

@main
struct ProjectArtifactPolicyTests {
    private static let fm = FileManager.default
    private static var checks = 0

    static func main() throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        func write(_ path: String, _ value: String = "fixture") throws {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }
        func artifact(_ path: String, _ expected: Bool = true) throws {
            try expect(CleanupRiskPolicy.isProjectArtifact(home.appendingPathComponent(path).path,
                       homeDirectory: home.path) == expected, "wrong project-artifact verdict: " + path)
        }
        try expect(ProjectArtifactPolicy.markers.count == 34, "the audited project target inventory changed")

        let javascript = ["node_modules", ".next", ".nuxt", ".output", ".svelte-kit", ".astro",
                          ".turbo", ".parcel-cache", ".expo", "dist", "coverage", "build"]
        try write("Code/javascript/package.json", "{}")
        for name in javascript {
            try write("Code/javascript/\(name)/payload")
            try artifact("Code/javascript/" + name)
        }
        try write("Code/angular/angular.json", "{}")
        try write("Code/angular/.angular/payload")
        try artifact("Code/angular/.angular")

        try write("Code/python/pyproject.toml")
        for name in [".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox", "__pycache__", "dist"] {
            try write("Code/python/\(name)/payload")
            try artifact("Code/python/" + name)
        }
        try write("Code/python/src/package/__pycache__/module.pyc")
        try artifact("Code/python/src/package/__pycache__")
        for name in [".venv", "venv"] {
            try write("Code/virtualenv/\(name)/pyvenv.cfg")
            try artifact("Code/virtualenv/" + name)
        }
        for (project, marker, names) in [
            ("rust", "Cargo.toml", ["target"]), ("maven", "pom.xml", ["target"]),
            ("gradle", "build.gradle.kts", [".gradle", ".cxx", "build"]),
            ("dart", "pubspec.yaml", [".dart_tool"]), ("swift", "Package.swift", [".build"]),
            ("zig", "build.zig", [".zig-cache", "zig-out"]),
            ("php", "composer.json", ["vendor"]), ("ios", "Podfile", ["Pods"]),
            ("terragrunt", "terragrunt.hcl", [".terragrunt-cache"]),
            ("cmake", "CMakeLists.txt", ["build"])
        ] {
            try write("Code/\(project)/" + marker)
            for name in names {
                try write("Code/\(project)/\(name)/payload")
                try artifact("Code/\(project)/" + name)
            }
        }
        try write("Code/dotnet/Example.csproj")
        try write("Code/dotnet/bin/Debug/app.dll")
        try write("Code/dotnet/obj/project.assets.json")
        try artifact("Code/dotnet/bin")
        try artifact("Code/dotnet/obj")
        try write("Code/xcode/App.xcodeproj/project.pbxproj")
        try write("Code/xcode/DerivedData/output")
        try artifact("Code/xcode/DerivedData")

        // Names alone never make a project or a rebuild contract.
        for name in ProjectArtifactPolicy.markers.keys.sorted() {
            try write("Documents/no-marker/\(name)/payload")
            try artifact("Documents/no-marker/" + name, false)
        }
        try write("Code/not-dotnet/package.json")
        try write("Code/not-dotnet/bin/tool")
        try write("Code/not-dotnet/obj/source")
        try artifact("Code/not-dotnet/bin", false)
        try artifact("Code/not-dotnet/obj", false)
        try write("Code/php/go.mod")
        try artifact("Code/php/vendor", false)
        try write("Code/rails/Gemfile")
        try write("Code/rails/vendor/authored.rb")
        try artifact("Code/rails/vendor", false)

        // A dependency's internal build outputs must not become extra targets.
        try write("Code/javascript/node_modules/pkg/package.json", "{}")
        try write("Code/javascript/node_modules/pkg/dist/output.js")
        try artifact("Code/javascript/node_modules/pkg/dist", false)
        try write("Code/build/package.json", "{}")
        try write("Code/build/node_modules/pkg/index.js")
        try artifact("Code/build", false)
        try artifact("Code/build/node_modules")
        try expect(!ProjectArtifactPolicy.shouldPrune(home.path + "/Code/build", homeDirectory: home.path),
                   "a source project named build must remain traversable")

        let signature = "Signature: 8a477f597d28d172789f06886806bc55\n# Cache declaration\n"
        try write("Code/tagged/package.json", "{}")
        try write("Code/tagged/.custom-cache/CACHEDIR.TAG", signature)
        try write("Code/tagged/.custom-cache/payload")
        try artifact("Code/tagged/.custom-cache")
        try write("Code/tagged/bad-cache/CACHEDIR.TAG", "not a cache declaration")
        try artifact("Code/tagged/bad-cache", false)
        try write("Documents/unscoped/CACHEDIR.TAG", signature)
        try artifact("Documents/unscoped", false)
        try write("Code/tagged/tag-template", signature)
        try fm.createDirectory(at: home.appendingPathComponent("Code/tagged/link-tag"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home.path + "/Code/tagged/link-tag/CACHEDIR.TAG",
                                  withDestinationPath: home.path + "/Code/tagged/tag-template")
        try artifact("Code/tagged/link-tag", false)

        // Author content wins over both a directory name and a cache tag.
        try write("Code/rust/target/deploy/fixture-keypair.json", "[]")
        try artifact("Code/rust/target", false)
        try write("Code/javascript/dist/nested/.git/config")
        try artifact("Code/javascript/dist", false)
        try write("Code/tagged/.custom-cache/nested/.git", "gitdir: /unavailable")
        try artifact("Code/tagged/.custom-cache", false)
        try write("Code/physical/package.json", "{}")
        try fm.createSymbolicLink(atPath: home.path + "/Code/physical/node_modules",
                                  withDestinationPath: home.path + "/Code/javascript/node_modules")
        try artifact("Code/physical/node_modules", false)
        try fm.createSymbolicLink(atPath: home.path + "/Code/alias",
                                  withDestinationPath: home.path + "/Code/javascript")
        try artifact("Code/alias/node_modules", false)
        try write("Library/Tool/package.json", "{}")
        try write("Library/Tool/node_modules/payload")
        try artifact("Library/Tool/node_modules", false)
        try write("Code/unreadable/package.json", "{}")
        try write("Code/unreadable/node_modules/blocked/payload")
        let blocked = home.path + "/Code/unreadable/node_modules/blocked"
        try expect(chmod(blocked, 0) == 0, "could not prepare an unreadable subtree")
        defer { chmod(blocked, 0o700) }
        try artifact("Code/unreadable/node_modules", false)
        chmod(blocked, 0o700)
        try expect(!ProjectArtifactPolicy.isArtifact(home.path + "/Code/javascript/node_modules",
                   homeDirectory: home.path, inspectionBudget: 0), "an exhausted probe was treated as success")
        try expect(!ProjectArtifactPolicy.isArtifact(home.path + "/Code/javascript/node_modules",
                   homeDirectory: home.path, shouldStop: { true }), "cancellation was treated as success")
        try expect(!ProjectArtifactPolicy.isArtifact(home.path + "/Code/javascript/../javascript/node_modules",
                   homeDirectory: home.path), "lexical traversal was normalized into authorization")

        // Inspect the owning repository index, with exact/literal and icase
        // matching. Inherited Git routing must not substitute another index.
        let repository = home.appendingPathComponent("Code/git-project")
        try write("Code/git-project/package.json", "{}")
        try write("Code/git-project/dist/authored.js")
        try runGit(["init", "-q", repository.path])
        try runGit(["-C", repository.path, "add", "dist/authored.js"])
        try artifact("Code/git-project/dist", false)
        setenv("GIT_INDEX_FILE", "/nonexistent-nori-project-index", 1)
        defer { unsetenv("GIT_INDEX_FILE") }
        try artifact("Code/git-project/dist", false)
        unsetenv("GIT_INDEX_FILE")
        try write("Code/git-project/node_modules/pkg/index.js")
        try artifact("Code/git-project/node_modules")
        try write("Code/git-project/cache[1]/CACHEDIR.TAG", signature)
        try write("Code/git-project/cache1/authored.js")
        try runGit(["-C", repository.path, "add", "cache1/authored.js"])
        try artifact("Code/git-project/cache[1]")
        try write("Code/git-project/cache[1]/authored.js")
        try runGit(["-C", repository.path, "add", "cache[1]/authored.js"])
        try artifact("Code/git-project/cache[1]", false)

        // A newly tracked file invalidates the earlier selection at apply.
        try runGit(["-C", repository.path, "add", "node_modules/pkg/index.js"])
        try artifact("Code/git-project/node_modules", false)
        try Data("corrupted index".utf8).write(to: repository.appendingPathComponent(".git/index"))
        try artifact("Code/git-project/node_modules", false)

        let casing = home.appendingPathComponent("Code/casing-project")
        try write("Code/casing-project/package.json", "{}")
        try write("Code/casing-project/DIST/authored.js")
        try runGit(["init", "-q", casing.path])
        try runGit(["-C", casing.path, "add", "DIST/authored.js"])
        try fm.moveItem(at: casing.appendingPathComponent("DIST"), to: casing.appendingPathComponent("rename-stage"))
        try fm.moveItem(at: casing.appendingPathComponent("rename-stage"), to: casing.appendingPathComponent("dist"))
        try artifact("Code/casing-project/dist", false)

        let worktreeOwner = home.appendingPathComponent("Code/worktree-owner")
        try write("Code/worktree-owner/package.json", "{}")
        try runGit(["init", "-q", worktreeOwner.path])
        try runGit(["-C", worktreeOwner.path, "add", "package.json"])
        try runGit(["-C", worktreeOwner.path, "-c", "user.name=Nori Fixture",
                    "-c", "user.email=nori-fixture@example.invalid", "commit", "-qm", "fixture"])
        let worktree = home.appendingPathComponent("Code/worktree")
        try runGit(["-C", worktreeOwner.path, "worktree", "add", "--detach", worktree.path])
        try write("Code/worktree/node_modules/payload")
        try artifact("Code/worktree/node_modules")
        try runGit(["-C", worktree.path, "add", "node_modules/payload"])
        try artifact("Code/worktree/node_modules", false)

        // Gitfiles are common for worktrees; let Git resolve them, and fail
        // closed if their target cannot be resolved.
        try write("Code/gitfile/package.json", "{}")
        try write("Code/gitfile/node_modules/payload")
        try write("Code/gitfile/.git", "gitdir: /nonexistent-nori-git-directory\n")
        try artifact("Code/gitfile/node_modules", false)

        let descriptor = CleanupRiskPolicy.reviewDescriptor(.projectArtifact)
        try expect(descriptor.risk == .warning && descriptor.activityGuard == .appData,
                   "broader discovery must not promote project artifacts to automatic cleanup")
        print("ok - \(checks) project artifact eligibility and author-content checks")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        checks += 1
        if !condition { throw ProjectPolicyFailure(description: message) }
    }

    private static func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "could not prepare the Git fixture")
    }
}
