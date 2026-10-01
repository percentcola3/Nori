import Foundation
import Darwin

private struct PlannerTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
enum AutoCleanupPlannerTests {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw PlannerTestFailure(message: "expected one fixture-root argument")
            }
            let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                .standardizedFileURL
            guard fixtureRoot.lastPathComponent.hasPrefix(".auto-cleanup-planner-tests.") else {
                throw PlannerTestFailure(message: "refusing unsafe fixture root: \(fixtureRoot.path)")
            }
            try await run(fixtureRoot: fixtureRoot)
        } catch {
            let message = "AutoCleanupPlannerTests failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(1)
        }
    }

    private static func run(fixtureRoot: URL) async throws {
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let managedRoot = fixtureRoot
            .appendingPathComponent("managed", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
        let outsideRoot = fixtureRoot.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideRoot, withIntermediateDirectories: true)

        let now = Date()
        let oldest = managedRoot.appendingPathComponent("oldest.cache")
        let older = managedRoot.appendingPathComponent("older.cache")
        let recent = managedRoot.appendingPathComponent("recent.cache")
        // Keep the fixture above the public 0.1 GB lower bound so the real
        // capacity planner is exercised without weakening production validation.
        try writeFixtureData(count: 8 * 1_048_576, seed: 1, to: oldest)
        try writeFixtureData(count: 8 * 1_048_576, seed: 2, to: older)
        try writeFixtureData(count: 96 * 1_048_576, seed: 3, to: recent)
        try setModificationDate(now.addingTimeInterval(-10 * 86_400), at: oldest,
                                fileManager: fileManager)
        try setModificationDate(now.addingTimeInterval(-2 * 86_400), at: older,
                                fileManager: fileManager)
        try setModificationDate(now.addingTimeInterval(-10 * 60), at: recent,
                                fileManager: fileManager)

        let outsidePayload = outsideRoot.appendingPathComponent("must-not-be-counted.bin")
        try pseudoRandomData(count: 1_048_576, seed: 4).write(to: outsidePayload)
        let linkedOutside = managedRoot.appendingPathComponent("linked-outside")
        try fileManager.createSymbolicLink(at: linkedOutside, withDestinationURL: outsideRoot)

        let baselineRule = AutoCleanupRule(directory: managedRoot.path,
                                           policy: .sizeLimit,
                                           sizeLimitBytes: AutoCleanupRule.maximumSizeLimitBytes,
                                           retentionDays: 5,
                                           isRegenerable: true)
        let baseline = try await AutoCleanupPlanner.plan(for: baselineRule)
        try expect(baseline.candidates.isEmpty, "unlimited rule produced candidates")

        let oldestBytes = try allocatedBytes(at: oldest)
        let olderBytes = try allocatedBytes(at: older)
        let recentBytes = try allocatedBytes(at: recent)
        try expect(oldestBytes > 0 && olderBytes > 0 && recentBytes > 0,
                   "fixture files have no allocated blocks")
        try expect(baseline.totalBytes == oldestBytes + olderBytes + recentBytes,
                   "top-level symlink was followed or counted")

        // 超限后只取最旧项即可回到阈值时，不应继续选择更新的项。
        let exactLimit = baseline.totalBytes - oldestBytes
        let exactRule = AutoCleanupRule(directory: managedRoot.path,
                                        policy: .sizeLimit,
                                        sizeLimitBytes: exactLimit,
                                        retentionDays: 5,
                                        isRegenerable: true)
        let exactPlan = try await AutoCleanupPlanner.plan(for: exactRule)
        try expect(exactPlan.candidates.map(\.path) == [oldest.path],
                   "capacity rule did not select oldest item first")
        let plannedOldest = try requireCandidate(oldest.path, in: exactPlan)
        let oldestIdentity = try deletionIdentity(at: oldest)
        try expect(plannedOldest.identity == oldestIdentity,
                   "candidate was not bound to its scan-time identity")
        try expect(exactPlan.remainingBytes == exactLimit,
                   "capacity rule did not stop at its configured limit")

        // 最小合法阈值下也必须保护最近一小时有写入的顶层项。
        let protectedRule = AutoCleanupRule(directory: managedRoot.path,
                                            policy: .sizeLimit,
                                            sizeLimitBytes: AutoCleanupRule.minimumSizeLimitBytes,
                                            retentionDays: 5,
                                            isRegenerable: true)
        let protectedPlan = try await AutoCleanupPlanner.plan(for: protectedRule)
        try expect(protectedPlan.candidates.map(\.path) == [oldest.path, older.path],
                   "capacity rule ignored age order or recent-write protection")
        try expect(protectedPlan.remainingBytes == recentBytes,
                   "recent item was included in the reclaimable size")

        for invalidLimit in [UInt64(0), UInt64.max] {
            let invalidRule = AutoCleanupRule(directory: managedRoot.path,
                                              policy: .sizeLimit,
                                              sizeLimitBytes: invalidLimit,
                                              retentionDays: 5,
                                              isRegenerable: true)
            do {
                _ = try await AutoCleanupPlanner.plan(for: invalidRule)
                throw PlannerTestFailure(message: "invalid capacity limit was accepted")
            } catch AutoCleanupPlannerError.invalidSizeLimit(let rejected) {
                try expect(rejected == invalidLimit, "wrong capacity limit was rejected")
            }
        }

        let retentionRule = AutoCleanupRule(directory: managedRoot.path,
                                            policy: .retentionDays,
                                            sizeLimitBytes: 0,
                                            retentionDays: 5,
                                            isRegenerable: true)
        let retentionPlan = try await AutoCleanupPlanner.plan(for: retentionRule)
        try expect(retentionPlan.candidates.map(\.path) == [oldest.path],
                   "retention rule did not keep the configured number of days")
        try expect(!retentionPlan.candidates.contains { $0.path == linkedOutside.path },
                   "retention rule included a top-level symlink")

        let nestedContainer = managedRoot
            .appendingPathComponent("nested-managed", isDirectory: true)
        let nestedManagedRoot = nestedContainer
            .appendingPathComponent("cache", isDirectory: true)
        try fileManager.createDirectory(at: nestedManagedRoot, withIntermediateDirectories: true)
        let nestedPayload = nestedManagedRoot.appendingPathComponent("old.cache")
        try pseudoRandomData(count: 8_192, seed: 5).write(to: nestedPayload)
        try setModificationDate(now.addingTimeInterval(-10 * 86_400), at: nestedPayload,
                                fileManager: fileManager)
        try setModificationDate(now.addingTimeInterval(-10 * 86_400), at: nestedManagedRoot,
                                fileManager: fileManager)
        try setModificationDate(now.addingTimeInterval(-10 * 86_400), at: nestedContainer,
                                fileManager: fileManager)
        let unprotectedNestedPlan = try await AutoCleanupPlanner.plan(for: retentionRule)
        try expect(unprotectedNestedPlan.candidates.contains { $0.path == nestedContainer.path },
                   "nested fixture was not eligible before rule-root protection")
        let nestedProtectedPlan = try await AutoCleanupPlanner.plan(
            for: retentionRule, protecting: [nestedManagedRoot.path])
        try expect(!nestedProtectedPlan.candidates.contains { $0.path == nestedContainer.path },
                   "parent rule selected another managed rule root")

        let authorizedRoot = fixtureRoot
            .appendingPathComponent("authorized", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
        try fileManager.createDirectory(at: authorizedRoot, withIntermediateDirectories: true)
        let authorizedPayload = authorizedRoot.appendingPathComponent("generated.cache")
        try Data("generated".utf8).write(to: authorizedPayload)
        let authorizedRule = AutoCleanupRule(directory: authorizedRoot.path,
                                             policy: .retentionDays,
                                             sizeLimitBytes: 0,
                                             retentionDays: 5,
                                             isRegenerable: true)
        let stagedPayload = fixtureRoot.appendingPathComponent("generated.cache.staged")
        try fileManager.moveItem(at: authorizedPayload, to: stagedPayload)
        try fileManager.removeItem(at: authorizedRoot)
        try fileManager.createDirectory(at: authorizedRoot, withIntermediateDirectories: true)
        try fileManager.moveItem(at: stagedPayload, to: authorizedPayload)
        do {
            _ = try await AutoCleanupPlanner.plan(for: authorizedRule)
            throw PlannerTestFailure(message: "replacement root inherited authorization")
        } catch AutoCleanupPlannerError.rootAuthorizationChanged {
            // Expected.
        }

        // Model formats stay Protected even when the surrounding folder has a
        // generic cache name. Automation must never infer safety from location
        // authorization alone.
        for modelExtension in ["gguf", "safetensors", "ckpt", "mlmodel", "mlmodelc",
                               "pt", "pth", "onnx", "tflite"] {
            let modelRoot = fixtureRoot
                .appendingPathComponent("protected-\(modelExtension)", isDirectory: true)
                .appendingPathComponent("cache", isDirectory: true)
            try fileManager.createDirectory(at: modelRoot, withIntermediateDirectories: true)
            let model = modelRoot.appendingPathComponent("payload.\(modelExtension)")
            try Data("model".utf8).write(to: model)
            let modelRule = AutoCleanupRule(directory: modelRoot.path,
                                            policy: .retentionDays,
                                            sizeLimitBytes: 0,
                                            retentionDays: 5,
                                            isRegenerable: true)
            do {
                _ = try await AutoCleanupPlanner.plan(for: modelRule)
                throw PlannerTestFailure(
                    message: "model extension was accepted: \(modelExtension)")
            } catch AutoCleanupPlannerError.protectedContent {
                // Expected: no model format can be eligible for automation.
            }
        }

        for sessionPath in [".gemini/tmp", ".local/share/opencode/project", "sessions/current",
                            "conversations/current", "userdata", "user data",
                            ".codex/log", ".claude/projects", ".claude/todos",
                            ".claude/shell-snapshots", ".cache/torch",
                            ".cache/huggingface", ".ollama/models"] {
            let sessionRoot = fixtureRoot
                .appendingPathComponent("protected-session", isDirectory: true)
                .appendingPathComponent(sessionPath, isDirectory: true)
            try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
            try Data("session".utf8).write(
                to: sessionRoot.appendingPathComponent("history.jsonl"))
            let managedSessionParent = fixtureRoot
                .appendingPathComponent("protected-session", isDirectory: true)
            let sessionRule = AutoCleanupRule(directory: managedSessionParent.path,
                                              policy: .retentionDays,
                                              sizeLimitBytes: 0,
                                              retentionDays: 5,
                                              isRegenerable: true)
            do {
                _ = try await AutoCleanupPlanner.plan(for: sessionRule)
                throw PlannerTestFailure(message: "AI session root was accepted: \(sessionPath)")
            } catch AutoCleanupPlannerError.protectedContent {
                // Expected.
            }
            try fileManager.removeItem(at: managedSessionParent)
        }

        let suiteName = "SimpleMole.AutoCleanupPlannerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PlannerTestFailure(message: "could not create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var storedRule = retentionRule
        storedRule.isEnabled = false
        storedRule.lastRunAt = Date(timeIntervalSince1970: 1_700_000_000)
        storedRule.lastReclaimedBytes = 12_345
        let storedRules = [exactRule, storedRule]
        AutoCleanupRuleStore.save(storedRules, to: defaults)
        try expect(AutoCleanupRuleStore.load(from: defaults) == storedRules,
                   "UserDefaults JSON roundtrip changed the rules")

        var legacyObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode([retentionRule])) as? [[String: Any]] ?? []
        try expect(legacyObject.count == 1, "legacy auto-cleanup fixture was not encoded")
        legacyObject[0]["safetyVersion"] = 3
        legacyObject[0]["authorizedRootIdentity"] = "1:2"
        defaults.set(try JSONSerialization.data(withJSONObject: legacyObject),
                     forKey: AutoCleanupRuleStore.storageKey)
        let migratedLegacy = AutoCleanupRuleStore.load(from: defaults)
        try expect(migratedLegacy.count == 1 && !migratedLegacy[0].isEnabled
                   && !migratedLegacy[0].isRegenerable
                   && !migratedLegacy[0].isSafetyAuthorized,
                   "legacy inode-only authorization remained enabled")

        // —— 版本升级继承：安全版本过期的规则保持未确认（不可执行），
        // 但存储中的授权数据必须原样保留，且中途保存不销毁。 ——
        func persistedEntry(_ rule: AutoCleanupRule) throws -> [String: Any] {
            let array = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode([rule])) as? [[String: Any]] ?? []
            guard let first = array.first else {
                throw PlannerTestFailure(message: "rule was not encoded for persistence")
            }
            return first
        }

        var upgradedEntry = try persistedEntry(retentionRule)
        upgradedEntry["safetyVersion"] = 3
        upgradedEntry["authorizedRootIdentity"] = "1:2:3"
        upgradedEntry["isEnabled"] = true
        defaults.set(try JSONSerialization.data(withJSONObject: [upgradedEntry]),
                     forKey: AutoCleanupRuleStore.storageKey)
        let upgraded = AutoCleanupRuleStore.load(from: defaults)
        try expect(upgraded.count == 1 && !upgraded[0].isRegenerable && !upgraded[0].isEnabled
                   && !upgraded[0].isSafetyAuthorized,
                   "stale safety version stayed executable after an upgrade")
        try expect(upgraded[0].safetyVersion == 3 && upgraded[0].authorizedRootIdentity == "1:2:3",
                   "upgrade decode destroyed the stored authorization data")
        AutoCleanupRuleStore.save(upgraded, to: defaults)
        let repersisted = AutoCleanupRuleStore.load(from: defaults)
        try expect(repersisted.count == 1 && repersisted[0].safetyVersion == 3
                   && repersisted[0].authorizedRootIdentity == "1:2:3",
                   "saving an upgraded rule destroyed its stored authorization data")

        // —— 部分损坏：一条规则字段坏了，其余规则仍要能加载。 ——
        var brokenEntry = try persistedEntry(exactRule)
        brokenEntry["sizeLimitBytes"] = "not-a-number"
        defaults.set(try JSONSerialization.data(
            withJSONObject: [try persistedEntry(retentionRule), brokenEntry]),
            forKey: AutoCleanupRuleStore.storageKey)
        let salvaged = AutoCleanupRuleStore.load(from: defaults)
        try expect(salvaged.count == 1 && salvaged[0].directory == retentionRule.directory,
                   "one corrupted rule discarded the whole persisted set")

        // —— 整体损坏：覆盖前必须留下原始快照，便于恢复。 ——
        let corruptedBlob = Data("definitely not json".utf8)
        defaults.set(corruptedBlob, forKey: AutoCleanupRuleStore.storageKey)
        AutoCleanupRuleStore.save([retentionRule], to: defaults)
        try expect(defaults.data(forKey: AutoCleanupRuleStore.backupKey) == corruptedBlob,
                   "overwriting an undecodable store kept no backup snapshot")
        try expect(AutoCleanupRuleStore.load(from: defaults) == [retentionRule],
                   "save after corruption did not restore a readable store")
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        guard condition() else { throw PlannerTestFailure(message: message) }
    }

    private static func setModificationDate(_ date: Date,
                                            at url: URL,
                                            fileManager: FileManager) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private static func allocatedBytes(at url: URL) throws -> UInt64 {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0, value.st_blocks >= 0 else {
            throw PlannerTestFailure(message: "could not stat fixture: \(url.path)")
        }
        return UInt64(value.st_blocks) * 512
    }

    private static func deletionIdentity(at url: URL) throws -> String {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            throw PlannerTestFailure(message: "could not identify fixture: \(url.path)")
        }
        return "\(value.st_dev):\(value.st_ino):\(value.st_mtimespec.tv_sec)"
    }

    private static func requireCandidate(_ path: String,
                                         in plan: AutoCleanupPlan) throws -> AutoCleanupCandidate {
        guard let candidate = plan.candidates.first(where: { $0.path == path }) else {
            // Unlimited plans intentionally have no deletion candidates; synthesize a
            // zero-limit plan at the call site when identity inspection is needed.
            throw PlannerTestFailure(message: "missing planned candidate: \(path)")
        }
        return candidate
    }

    private static func pseudoRandomData(count: Int, seed: UInt64) -> Data {
        var state = seed
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            bytes.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        return Data(bytes)
    }

    private static func writeFixtureData(count: Int, seed: UInt64, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw PlannerTestFailure(message: "could not create fixture: \(url.path)")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = pseudoRandomData(count: min(count, 1_048_576), seed: seed)
        var remaining = count
        while remaining > 0 {
            let length = min(remaining, chunk.count)
            try handle.write(contentsOf: length == chunk.count ? chunk : chunk.prefix(length))
            remaining -= length
        }
    }
}
