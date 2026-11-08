import Darwin
import Foundation

enum AdministratorCleanupService {
    /// The injected transport is used by the dedicated nonce-only regression.
    /// Live retries are bound to the first operation's exact session identifier.
    struct Transport {
        let first: (URL) async -> PrivilegedSessionClient.Execution
        let reuse: (URL, UUID) async -> RunResult
        static var live: Transport {
            .init(first: { manifest in
                await MoleEngine.shared.runPrivilegedBridgeWithSession("bin/app_cleanup_admin.sh",
                    arguments: [String(getuid()), manifest.path], timeout: 900)
            }, reuse: { manifest, sessionID in
                await MoleEngine.shared.runPrivilegedBridgeIfAuthorized("bin/app_cleanup_admin.sh",
                    arguments: [String(getuid()), manifest.path], timeout: 900, sessionID: sessionID)
            })
        }
    }

    static func apply(items: [DeletionPlan.Item],
                      onProgress: ((Int, Int, String) -> Void)? = nil,
                      retryBudget: CleanupRetryPolicy.Budget? = nil,
                      requestID: UUID? = nil) async -> CleanupExecutionResult {
        await apply(items: items, onProgress: onProgress, retryBudget: retryBudget,
                    requestID: requestID, transport: .live)
    }

    static func apply(items: [DeletionPlan.Item],
                      onProgress: ((Int, Int, String) -> Void)? = nil,
                      retryBudget: CleanupRetryPolicy.Budget? = nil,
                      requestID: UUID? = nil, transport: Transport) async -> CleanupExecutionResult {
        guard !items.isEmpty else { return .init() }
        let budget = retryBudget ?? CleanupRetryPolicy.Budget()
        // Freeze missing metadata once, before the first operation. A retry
        // never refreshes a submitted object's identity or authorization scope.
        var pending = await Task.detached(priority: .utility) {
            items.map { DeletionPlan.Item(record: $0.record, identity: $0.identity,
                metadata: $0.metadata ?? DeletionPlan.Metadata.read($0.record)) }
        }.value
        var combined = CleanupExecutionResult()
        var sessionID: UUID?
        var firstUnclaimed = 0
        for attempt in 1...CleanupRetryPolicy.maximumAttempts {
            guard !Task.isCancelled else { combined.executionFailed = true; break }
            let candidates = pending
            let claimed = await Task.detached(priority: .utility) { budget.claim(items: candidates) }.value
            guard attempt == 1 || claimed.count == candidates.count else {
                CleanupTrace.record("admin.retry.stopped", requestID: requestID, fields: [
                    "reason": "partial_budget_exhausted", "attempt": String(attempt)
                ])
                break // Keep the last complete remaining-pass terminal counts.
            }
            guard !claimed.isEmpty else {
                CleanupTrace.record("admin.retry.stopped", requestID: requestID,
                    fields: ["reason": "budget_exhausted", "attempt": String(attempt)])
                if attempt == 1 { combined.failed = items.count }
                break
            }
            if attempt == 1 { firstUnclaimed = max(0, pending.count - claimed.count) }
            CleanupTrace.record("admin.attempt.started", requestID: requestID, fields: [
                "attempt": String(attempt), "targets": String(claimed.count),
                "may_authorize": String(attempt == 1), "session_bound": String(sessionID != nil)
            ])
            let preparation = await Task.detached(priority: .utility) { prepare(claimed) }.value
            guard case .ready(let files) = preparation else {
                if case .failed(let detail) = preparation {
                    combined = await merge(combined, .init(failed: claimed.count,
                        messages: [detail], executionFailed: true))
                }
                CleanupTrace.record("admin.retry.stopped", requestID: requestID, fields: ["reason": "plan_io_failed"])
                break
            }
            let progressTask = Task.detached(priority: .utility) {
                var previous: AdministratorCleanupPlan.Progress?
                while !Task.isCancelled {
                    if let data = try? Data(contentsOf: files.progress), data.count <= 16_384,
                       let update = try? JSONDecoder().decode(AdministratorCleanupPlan.Progress.self, from: data),
                       update != previous, update.completed >= 0, update.total >= update.completed {
                        previous = update
                        await MainActor.run { onProgress?(update.completed, update.total, update.path) }
                    }
                    do { try await Task.sleep(nanoseconds: 120_000_000) } catch { break }
                }
            }
            let run: RunResult
            if attempt == 1 {
                let execution = await transport.first(files.manifest)
                sessionID = execution.sessionID
                run = execution.result
            } else if let sessionID {
                run = await transport.reuse(files.manifest, sessionID)
            } else {
                run = .init(output: "Administrator session is not available.", exitCode: 77, timedOut: false)
            }
            progressTask.cancel()
            await progressTask.value
            await Task.detached(priority: .utility) { remove(files) }.value
            let decoded = await Task.detached(priority: .utility) { decode(run, items: claimed) }.value
            var fields = ["attempt": String(attempt), "exit_code": String(run.exitCode),
                "timed_out": String(run.timedOut), "output_truncated": String(run.outputTruncated),
                "report_valid": String(decoded.valid), "retry_safe": String(decoded.retrySafe),
                "removed": String(decoded.result.removed), "failed": String(decoded.result.failed),
                "skipped": String(decoded.result.skipped)]
            for (index, chunk) in decoded.diagnostics.enumerated() { fields["diagnostic_\(index)"] = chunk }
            CleanupTrace.record("admin.attempt.finished", requestID: requestID, fields: fields)
            combined = await merge(combined, decoded.result)
            guard decoded.retrySafe, sessionID != nil, !Task.isCancelled else { break }
            let remaining = await Task.detached(priority: .utility) {
                CleanupRetryPolicy.remainingItems(claimed, after: decoded.result)
            }.value
            guard !remaining.isEmpty else { break }
            guard decoded.result.failed > 0 || decoded.result.skipped > decoded.result.quietSkipped
                    || decoded.result.executionFailed else {
                combined.executionFailed = true
                CleanupTrace.record("admin.retry.stopped", requestID: requestID, fields: ["reason": "unconfirmed_remaining"])
                break
            }
            pending = remaining
        }
        combined.failed += firstUnclaimed
        return combined
    }

    private static func merge(_ prior: CleanupExecutionResult, _ current: CleanupExecutionResult) async -> CleanupExecutionResult {
        await Task.detached(priority: .utility) { CleanupRetryPolicy.combiningAttempts(prior, current) }.value
    }

    private struct PlanFiles {
        let directory: URL
        let manifest: URL
        let progress: URL
        let device: dev_t
        let inode: ino_t
    }
    private enum Preparation { case ready(PlanFiles), failed(String) }

    private static func prepare(_ items: [DeletionPlan.Item]) -> Preparation {
        let request = AdministratorCleanupPlan.Request(records: items.map {
            .init(path: $0.record, identity: $0.identity, metadata: $0.metadata)
        })
        guard let data = try? JSONEncoder().encode(request), data.count <= AdministratorCleanupPlan.maximumPlanBytes else {
            return .failed("Invalid administrator cleanup plan.")
        }
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = parent.appendingPathComponent("nori-admin-cleanup-" + UUID().uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { return .failed(String(cString: strerror(errno))) }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { return .failed("Administrator plan directory is unavailable.") }
        let files = PlanFiles(directory: directory, manifest: directory.appendingPathComponent("plan.json"),
            progress: directory.appendingPathComponent("plan.json.progress"), device: info.st_dev, inode: info.st_ino)
        do {
            try Data().write(to: files.progress, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.progress.path)
            try data.write(to: files.manifest, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.manifest.path)
            return .ready(files)
        } catch {
            remove(files)
            return .failed(String(DeveloperSecretRedactor.redact(error.localizedDescription).prefix(512)))
        }
    }

    private static func remove(_ files: PlanFiles) {
        var info = stat()
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard files.directory.isFileURL, files.directory.lastPathComponent.hasPrefix("nori-admin-cleanup-"),
              files.directory.deletingLastPathComponent() == parent,
              files.directory.resolvingSymlinksInPath() == files.directory,
              lstat(files.directory.path, &info) == 0, info.st_dev == files.device, info.st_ino == files.inode,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return }
        try? FileManager.default.removeItem(at: files.directory)
    }

    private struct Decoded {
        let result: CleanupExecutionResult
        let valid: Bool
        let retrySafe: Bool
        let diagnostics: [String]
    }

    private static func decode(_ run: RunResult, items: [DeletionPlan.Item]) -> Decoded {
        let diagnostics = diagnosticChunks(run)
        func invalid(_ message: String) -> Decoded {
            .init(result: .init(failed: items.count, messages: diagnostics.isEmpty ? [message] : diagnostics,
                executionFailed: true), valid: false, retrySafe: false, diagnostics: diagnostics)
        }
        guard run.output.utf8.count <= AdministratorCleanupPlan.maximumPlanBytes else { return invalid("Oversized administrator cleanup report.") }
        let reports = run.output.components(separatedBy: .newlines).filter { $0.hasPrefix(AdministratorCleanupPlan.reportPrefix) }
        guard reports.count == 1,
              let data = reports[0].dropFirst(AdministratorCleanupPlan.reportPrefix.count).data(using: .utf8),
              let report = try? JSONDecoder().decode(AdministratorCleanupPlan.Report.self, from: data),
              report.removed >= 0, report.skipped >= 0, report.failed >= 0 else {
            return invalid("Invalid administrator cleanup report.")
        }
        let roots = Set(items.map(\.record))
        let confirmed = Set(report.removedPaths)
        let retained = report.retainedTargets ?? []
        guard validateRetainedTargets(retained, items: items, skipped: report.skipped, removedPaths: confirmed),
              report.removed > 0 || report.skipped > 0 || report.failed > 0,
              confirmed.allSatisfy({ path in
                  DeletionPlan.isLexicallySafePath(path) && CleanupRiskPolicy.normalizedPathLiteral(path) == path
                      && DeletionPlan.isPathCovered(path, by: roots)
              }), confirmed.count <= report.removed, report.removed == 0 || !confirmed.isEmpty else {
            return invalid("Invalid administrator cleanup report.")
        }
        // A completed normal worker report is the only replay authority. A
        // timeout, truncated/lost reply, signal or protocol/signature failure
        // remains terminal even if a report-looking fragment was captured.
        let retrySafe = !run.timedOut && !run.outputTruncated && (run.exitCode == 0 || run.exitCode == 1)
        return .init(result: .init(removed: report.removed, skipped: report.skipped, failed: report.failed,
            messages: report.messages, executionFailed: !run.succeeded || !retrySafe,
            removedPaths: confirmed, reclaimedBytes: report.reclaimedBytes, retainedTargets: retained),
            valid: true, retrySafe: retrySafe, diagnostics: diagnostics)
    }

    /// Redact before clipping and splitting so a secret cannot straddle chunks.
    /// Never persist report JSON or a bootstrap command/script echoed by osascript.
    static func diagnosticChunks(_ run: RunResult) -> [String] {
        let raw = run.errorOutput.isEmpty ? run.output : run.errorOutput
        let bounded = String(decoding: raw.utf8.prefix(16_384), as: UTF8.self)
        let lines = DeveloperSecretRedactor.redact(bounded).components(separatedBy: .newlines).filter { line in
            !line.hasPrefix(AdministratorCleanupPlan.reportPrefix)
                && !["do shell script", "with administrator privileges", "stage_root=", "set -eu;", "worker_pid="].contains(where: line.contains)
        }
        let safe = lines.joined(separator: "\n")
        var chunks: [String] = []
        var current = ""
        var bytes = 0
        for character in safe {
            let size = String(character).utf8.count
            guard size <= 128 else { continue }
            if bytes + size > 128 {
                chunks.append(current)
                guard chunks.count < 4 else { return chunks }
                current = ""; bytes = 0
            }
            current.append(character); bytes += size
        }
        if !current.isEmpty && chunks.count < 4 { chunks.append(current) }
        return chunks
    }

    /// Each receipt attests only one exact submitted object. A root that cannot
    /// be removed may still contain independently removable submitted children.
    /// Retention never authorizes removal or converts a path to removed.
    static func validateRetainedTargets(_ targets: [DeletionPlan.RetainedTarget],
                                       items: [DeletionPlan.Item], skipped: Int,
                                       removedPaths: Set<String>) -> Bool {
        guard skipped >= 0 else { return false }
        if targets.isEmpty { return true }
        var identities: [String: String] = [:]
        for item in items {
            guard DeletionPlan.isLexicallySafePath(item.record),
                  DeletionPlan.normalizedPathLiteral(item.record) == item.record else { return false }
            if let prior = identities[item.record], prior != item.identity { return false }
            identities[item.record] = item.identity
        }
        var retainedRoots = Set<String>()
        for target in targets {
            guard target.record != "/", DeletionPlan.isLexicallySafePath(target.record),
                  DeletionPlan.normalizedPathLiteral(target.record) == target.record,
                  !target.identity.isEmpty, identities[target.record] == target.identity,
                  target.count == 1, retainedRoots.count < skipped,
                  retainedRoots.insert(target.record).inserted,
                  !DeletionPlan.isPathCovered(target.record, by: removedPaths) else { return false }
        }
        return true
    }
}
