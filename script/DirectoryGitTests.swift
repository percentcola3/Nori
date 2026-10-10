import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct DirectoryGitTests {
    static var checks = 0
    static let engine = MoleEngine()
    static var environment: [String: String] = [:]

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(description: message) }
        checks += 1
    }

    @discardableResult
    static func git(_ arguments: [String], at root: URL) async throws -> String {
        let result = await engine.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
                                      environment: environment, currentDirectory: root, timeout: 15, captureLimit: 256 * 1024)
        guard result.succeeded, !result.outputTruncated else {
            throw TestFailure(description: "Fixture git failed: \(arguments): \(result.diagnosticOutput)")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func configure(_ root: URL) async throws {
        try await git(["config", "user.name", "Nori Test"], at: root)
        try await git(["config", "user.email", "nori-test@example.invalid"], at: root)
        try await git(["config", "commit.gpgsign", "false"], at: root)
        try await git(["config", "core.hooksPath", "/dev/null"], at: root)
    }

    static func fail(_ expected: DirectoryGitService.Failure,
                     _ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            throw TestFailure(description: "Expected \(expected)")
        } catch let failure as DirectoryGitService.Failure {
            try expect(failure == expected, "Expected \(expected), received \(failure)")
        }
    }

    static func write(_ name: String, _ text: String, at root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }

    static func commit(_ name: String, _ text: String, at root: URL) async throws {
        try write(name, text, at: root)
        try await git(["add", "--", name], at: root)
        try await git(["commit", "-m", "Update " + name], at: root)
    }

    static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let fm = FileManager.default
        let home = fixture.appendingPathComponent("home")
        let repository = fixture.appendingPathComponent("repository with spaces")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: repository, withIntermediateDirectories: true)
        environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path,
                       "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                       "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        try await git(["init", "--initial-branch=main"], at: repository)
        try await configure(repository)
        try await commit("seed.txt", "seed\n", at: repository)
        try await git(["branch", "feature"], at: repository)

        let missingGit = DirectoryGitService(executable: fixture.appendingPathComponent("missing-git").path,
                                             environment: environment)
        try await fail(.unavailable) { _ = try await missingGit.snapshot(at: repository) }
        try await fail(.unavailable) { try await missingGit.switchBranch("feature", at: repository) }
        try await fail(.unavailable) { try await missingGit.pull(at: repository) }
        let directoryGit = DirectoryGitService(executable: home.path, environment: environment)
        try await fail(.unavailable) { _ = try await directoryGit.snapshot(at: repository) }
        var missingToolsEnvironment = environment
        missingToolsEnvironment["DEVELOPER_DIR"] = fixture.appendingPathComponent("missing-developer-tools").path
        let missingTools = DirectoryGitService(executable: "/usr/bin/git", environment: missingToolsEnvironment)
        try await fail(.unavailable) { _ = try await missingTools.snapshot(at: repository) }
        let globalConfiguration = "[user]\n\tname = Existing User\n"
        try write(".gitconfig", globalConfiguration, at: home)
        let repositoryConfiguration = try Data(contentsOf: repository.appendingPathComponent(".git/config"))

        var sampled = environment
        sampled["GIT_DIR"] = "/nonexistent/nori-test"
        sampled["GIT_WORK_TREE"] = "/"
        let service = DirectoryGitService(executable: "/usr/bin/git", environment: sampled)
        let initial = try await service.snapshot(at: repository)
        try expect(initial.root.path == repository.path && initial.branch == "main", "Root and current branch")
        try expect(initial.branches == ["feature", "main"] && !initial.isDirty, "Clean local branches")
        try expect(initial.upstream == nil && !initial.operationInProgress, "No inferred upstream")
        try await fail(.notRepository) { _ = try await service.snapshot(at: fixture) }
        let subdirectory = repository.appendingPathComponent("subdirectory")
        try fm.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try await fail(.notRepository) { _ = try await service.snapshot(at: subdirectory) }

        try await service.switchBranch("feature", at: repository)
        try expect(try await service.snapshot(at: repository).branch == "feature", "Switch local branch")
        try await service.switchBranch("main", at: repository)
        try await fail(.branchUnavailable) { try await service.switchBranch("--force", at: repository) }
        try await fail(.branchUnavailable) { try await service.switchBranch("@{-1}", at: repository) }
        try await fail(.noUpstream) { try await service.pull(at: repository) }
        try expect(try Data(contentsOf: repository.appendingPathComponent(".git/config")) == repositoryConfiguration,
                   "Directory Git operations never configure the repository")
        try expect(try String(contentsOf: home.appendingPathComponent(".gitconfig"), encoding: .utf8) == globalConfiguration,
                   "Directory Git operations preserve the user's global configuration")

        try write("untracked.txt", "keep\n", at: repository)
        try await fail(.dirty) { try await service.switchBranch("feature", at: repository) }
        try await fail(.dirty) { try await service.pull(at: repository) }
        try expect(try await git(["branch", "--show-current"], at: repository) == "main", "Dirty refusal preserves branch")
        try fm.removeItem(at: repository.appendingPathComponent("untracked.txt"))
        try write("seed.txt", "local edits\n", at: repository)
        try await fail(.dirty) { try await service.switchBranch("feature", at: repository) }
        try expect(try String(contentsOf: repository.appendingPathComponent("seed.txt"), encoding: .utf8) == "local edits\n", "Dirty contents unchanged")
        try write("seed.txt", "seed\n", at: repository)

        try await commit(".gitignore", ".env\n", at: repository)
        try await git(["switch", "-c", "ignored-target"], at: repository)
        try write(".env", "tracked target value\n", at: repository)
        try await git(["add", "-f", "--", ".env"], at: repository)
        try await git(["commit", "-m", "Track target environment"], at: repository)
        try await git(["switch", "main"], at: repository)
        try write(".env", "local ignored secret\n", at: repository)
        try expect(!(try await service.snapshot(at: repository)).isDirty, "Ignored file is not reported as a local edit")
        do {
            try await service.switchBranch("ignored-target", at: repository)
            throw TestFailure(description: "Ignored switch collision must refuse")
        } catch DirectoryGitService.Failure.command { checks += 1 }
        try expect(try String(contentsOf: repository.appendingPathComponent(".env"), encoding: .utf8) == "local ignored secret\n", "Switch preserves ignored file")
        try expect(try await git(["branch", "--show-current"], at: repository) == "main", "Ignored conflict preserves branch")

        try await commit("# branch.head false-branch", "rename source\n", at: repository)
        try await git(["mv", "# branch.head false-branch", "renamed.txt"], at: repository)
        let renamed = try await service.snapshot(at: repository)
        try expect(renamed.branch == "main" && renamed.isDirty, "Rename source cannot become status metadata")
        try await git(["mv", "renamed.txt", "# branch.head false-branch"], at: repository)

        let linked = fixture.appendingPathComponent("linked worktree")
        try await git(["worktree", "add", "-b", "occupied", linked.path], at: repository)
        let ordinary = try await service.snapshot(at: repository)
        let worktree = try await service.snapshot(at: linked)
        try expect(ordinary.occupiedBranches.contains("occupied"), "Detect occupied branch")
        try expect(worktree.root.path == linked.path && worktree.branch == "occupied", "Read .git file worktree")
        try await fail(.branchOccupied) { try await service.switchBranch("occupied", at: repository) }

        let gitDirectory = repository.appendingPathComponent(".git")
        try write("MERGE_HEAD", initial.head + "\n", at: gitDirectory)
        try expect(try await service.snapshot(at: repository).operationInProgress, "Detect merge state")
        try await fail(.operationInProgress) { try await service.switchBranch("feature", at: repository) }
        try fm.removeItem(at: gitDirectory.appendingPathComponent("MERGE_HEAD"))
        try fm.createDirectory(at: gitDirectory.appendingPathComponent("rebase-merge"), withIntermediateDirectories: true)
        try await fail(.operationInProgress) { try await service.pull(at: repository) }
        try fm.removeItem(at: gitDirectory.appendingPathComponent("rebase-merge"))
        try await git(["switch", "--detach"], at: repository)
        try expect(try await service.snapshot(at: repository).branch == nil, "Detect detached HEAD")
        try await fail(.detached) { try await service.pull(at: repository) }
        try await service.switchBranch("main", at: repository)

        let remote = fixture.appendingPathComponent("remote.git")
        try await git(["init", "--bare", "--initial-branch=main", remote.path], at: fixture)
        try await git(["remote", "add", "origin", remote.path], at: repository)
        try await git(["push", "-u", "origin", "main"], at: repository)
        let writer = fixture.appendingPathComponent("writer")
        try await git(["clone", remote.path, writer.path], at: fixture)
        try await configure(writer)
        try await commit("remote.txt", "remote update\n", at: writer)
        try await git(["push"], at: writer)
        try await git(["config", "pull.rebase", "true"], at: repository)
        try await git(["config", "rebase.autoStash", "true"], at: repository)
        try await git(["config", "merge.autoStash", "true"], at: repository)
        try await git(["config", "--", "branch.main.mergeOptions", "--squash"], at: repository)
        try await service.pull(at: repository)
        let fastForward = try await service.snapshot(at: repository)
        try expect(fastForward.upstream == "origin/main" && !fastForward.isDirty, "Fast-forward follows upstream")
        try expect(fastForward.head == (try await git(["rev-parse", "HEAD"], at: writer)), "Fast-forward receives remote commit")
        try expect(try await git(["diff", "--cached", "--name-only"], at: repository) == "", "Squash configuration cannot leave staged changes instead of advancing HEAD")
        try expect(try await git(["stash", "list"], at: repository) == "", "No automatic stash")

        try await git(["push", "origin", "HEAD:refs/heads/to-delete"], at: writer)
        try await git(["fetch", "origin"], at: repository)
        try await git(["branch", "--set-upstream-to=origin/to-delete", "main"], at: repository)
        try await git(["update-ref", "-d", "refs/heads/to-delete"], at: remote)
        let beforeMissingUpstream = try await git(["rev-parse", "HEAD"], at: repository)
        try expect(try await service.snapshot(at: repository).upstream == "origin/to-delete", "Fixture retains stale tracking branch after remote deletion")
        do {
            try await service.pull(at: repository)
            throw TestFailure(description: "Deleted remote branch must refuse instead of merging stale tracking")
        } catch DirectoryGitService.Failure.command { checks += 1 }
        try expect(try await git(["rev-parse", "HEAD"], at: repository) == beforeMissingUpstream, "Missing remote branch preserves HEAD")
        try expect(try await git(["status", "--porcelain"], at: repository) == "", "Missing remote branch leaves worktree clean")
        try await git(["branch", "--set-upstream-to=origin/main", "main"], at: repository)

        try write(".env", "new remote value\n", at: writer)
        try await git(["add", "-f", "--", ".env"], at: writer)
        try await git(["commit", "-m", "Track remote environment"], at: writer)
        try await git(["push"], at: writer)
        let beforeIgnoredPull = try await git(["rev-parse", "HEAD"], at: repository)
        do {
            try await service.pull(at: repository)
            throw TestFailure(description: "Ignored pull collision must refuse")
        } catch DirectoryGitService.Failure.command { checks += 1 }
        try expect(try await git(["rev-parse", "HEAD"], at: repository) == beforeIgnoredPull, "Ignored pull conflict preserves HEAD")
        try expect(try String(contentsOf: repository.appendingPathComponent(".env"), encoding: .utf8) == "local ignored secret\n", "Pull preserves ignored file")
        try fm.removeItem(at: repository.appendingPathComponent(".env"))
        try await service.pull(at: repository)
        try expect(try String(contentsOf: repository.appendingPathComponent(".env"), encoding: .utf8) == "new remote value\n", "Pull resumes after resolving local collision")

        let changedUpstream = fixture.appendingPathComponent("changed-upstream")
        let quotedRepository = "'" + repository.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try Data(("#!/bin/sh\n/usr/bin/git -C " + quotedRepository
                  + " config branch.main.merge refs/heads/feature\nexec /usr/bin/git upload-pack \"$@\"\n").utf8).write(to: changedUpstream)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: changedUpstream.path)
        try await git(["config", "remote.origin.uploadpack", changedUpstream.path], at: repository)
        try await fail(.repositoryChanged) { try await service.pull(at: repository) }
        try await git(["config", "--unset", "remote.origin.uploadpack"], at: repository)
        try await git(["config", "branch.main.merge", "refs/heads/main"], at: repository)

        try await commit("local.txt", "local commit\n", at: repository)
        let beforeDivergence = try await git(["rev-parse", "HEAD"], at: repository)
        try await commit("remote.txt", "another remote commit\n", at: writer)
        try await git(["push"], at: writer)
        do {
            try await service.pull(at: repository)
            throw TestFailure(description: "Divergent pull must refuse")
        } catch DirectoryGitService.Failure.command { checks += 1 }
        try expect(try await git(["rev-parse", "HEAD"], at: repository) == beforeDivergence, "Divergence preserves local commit")
        try expect(try String(contentsOf: repository.appendingPathComponent("remote.txt"), encoding: .utf8) == "remote update\n", "Divergence preserves files")
        try expect(try await git(["status", "--porcelain"], at: repository) == "", "Divergence leaves worktree clean")
        try expect(!fm.fileExists(atPath: gitDirectory.appendingPathComponent("MERGE_HEAD").path), "Divergence starts no merge")

        let hooks = fixture.appendingPathComponent("hooks")
        try fm.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("post-checkout")
        try Data("#!/bin/sh\n/usr/bin/head -c 300000 /dev/zero\n".utf8).write(to: hook)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        try await git(["config", "core.hooksPath", hooks.path], at: repository)
        try await service.switchBranch("feature", at: repository)
        try expect(try await service.snapshot(at: repository).branch == "feature", "Successful switch is not failed by truncated hook output")
        try await service.switchBranch("main", at: repository)
        try await git(["config", "core.hooksPath", "/dev/null"], at: repository)

        let truncated = DirectoryGitService(executable: "/usr/bin/git", environment: environment, captureLimit: 8)
        try await fail(.outputTooLarge) { _ = try await truncated.snapshot(at: repository) }
        for index in 0..<100 { try write("untracked-\(index).txt", "local\n", at: repository) }
        let truncatedStatus = DirectoryGitService(executable: "/usr/bin/git", environment: environment, captureLimit: 512)
        try await fail(.outputTooLarge) { _ = try await truncatedStatus.snapshot(at: repository) }
        try await fail(.outputTooLarge) { try await truncatedStatus.switchBranch("feature", at: repository) }
        for index in 0..<100 { try fm.removeItem(at: repository.appendingPathComponent("untracked-\(index).txt")) }
        let bounded = await engine.run(executable: URL(fileURLWithPath: "/usr/bin/head"),
                                       arguments: ["-c", "1048576", "/dev/zero"], environment: environment,
                                       timeout: 3, onLine: { _ in }, captureLimit: 1024)
        try expect(bounded.succeeded && bounded.outputTruncated && bounded.output.utf8.count == 1024, "Bound stdout and unterminated lines while draining")
        let stderr = await engine.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                      arguments: ["-c", "/usr/bin/head -c 1048576 /dev/zero >&2"], environment: environment,
                                      timeout: 3, captureLimit: 1024)
        try expect(stderr.succeeded && stderr.outputTruncated && stderr.errorOutput.utf8.count == 1024, "Bound stderr")
        let lines = LineReceipt()
        let unlimited = await engine.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                         arguments: ["-c", "printf 'first\\nlast'; printf 'warning\\nend' >&2"],
                                         environment: environment, timeout: 3, onLine: lines.append)
        try expect(unlimited.succeeded && !unlimited.outputTruncated, "Existing unlimited calls remain successful")
        try expect(unlimited.output == "first\nlast" && unlimited.errorOutput == "warning\nend", "Existing stdout and stderr remain complete")
        try expect(Set(lines.values) == ["first", "last", "[stderr] warning", "[stderr] end"], "Existing line callback retains tails and stderr prefix")
        let timedOut = await engine.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
                                        environment: environment, timeout: 0.05, captureLimit: 1024)
        try expect(timedOut.timedOut && !timedOut.succeeded, "Timeout stops subprocess")

        let sleeper = fixture.appendingPathComponent("slow-git")
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: sleeper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sleeper.path)
        let cancellable = DirectoryGitService(executable: sleeper.path, environment: environment)
        let task = Task { try await cancellable.snapshot(at: repository) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        try await fail(.cancelled) { _ = try await task.value }

        let childSource = fixture.appendingPathComponent("child-source")
        let parentRepository = fixture.appendingPathComponent("parent-repository")
        try fm.createDirectory(at: childSource, withIntermediateDirectories: true)
        try fm.createDirectory(at: parentRepository, withIntermediateDirectories: true)
        try await git(["init", "--initial-branch=main"], at: childSource)
        try await configure(childSource)
        try await commit("version.txt", "one\n", at: childSource)
        let firstChild = try await git(["rev-parse", "HEAD"], at: childSource)
        try await commit("version.txt", "two\n", at: childSource)
        try await git(["init", "--initial-branch=main"], at: parentRepository)
        try await configure(parentRepository)
        try await git(["-c", "protocol.file.allow=always", "submodule", "add", childSource.path, "dependency"], at: parentRepository)
        try await git(["commit", "-m", "Add current dependency"], at: parentRepository)
        try await git(["switch", "-c", "old"], at: parentRepository)
        let dependency = parentRepository.appendingPathComponent("dependency")
        try await git(["checkout", firstChild], at: dependency)
        try await git(["add", "dependency"], at: parentRepository)
        try await git(["commit", "-m", "Use old dependency"], at: parentRepository)
        try await git(["config", "submodule.recurse", "true"], at: parentRepository)
        try await git(["config", "submodule.dependency.ignore", "all"], at: parentRepository)
        try write("version.txt", "local submodule edit\n", at: dependency)
        try expect(try await service.snapshot(at: parentRepository).isDirty, "Explicit submodule status detects ignored local edits")
        try await fail(.dirty) { try await service.switchBranch("main", at: parentRepository) }
        try write("version.txt", "one\n", at: dependency)
        try await service.switchBranch("main", at: parentRepository)
        try expect(try await git(["rev-parse", "HEAD"], at: dependency) == firstChild, "Switch does not recursively modify a submodule")
        try expect(try await service.snapshot(at: parentRepository).isDirty, "Changed gitlink remains visible despite ignore configuration")

        print("Directory Git tests passed: \(checks) checks")
    }

    private final class LineReceipt: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }
        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
