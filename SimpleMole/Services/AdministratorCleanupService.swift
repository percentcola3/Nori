import Darwin
import Foundation
import os

enum AdministratorCleanupService {
    private static let logger = Logger(subsystem: "com.nori.app", category: "cleanup")
    static func apply(items: [DeletionPlan.Item],
                      onProgress: ((Int, Int, String) -> Void)? = nil) async -> CleanupExecutionResult {
        guard !items.isEmpty else { return .init() }
        let request = AdministratorCleanupPlan.Request(records: items.map {
            .init(path: $0.record, identity: $0.identity, metadata: $0.metadata ?? DeletionPlan.Metadata.read($0.record))
        })
        guard let data = try? JSONEncoder().encode(request),
              data.count <= AdministratorCleanupPlan.maximumPlanBytes else {
            return .init(failed: items.count, messages: ["Invalid administrator cleanup plan."])
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nori-admin-cleanup-" + UUID().uuidString, isDirectory: true)
        let manifest = directory.appendingPathComponent("plan.json")
        let progress = directory.appendingPathComponent("plan.json.progress")
        // Only clean up a directory this operation created exclusively.
        guard mkdir(directory.path, 0o700) == 0 else {
            return .init(failed: items.count, messages: [String(cString: strerror(errno))])
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try Data().write(to: progress, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: progress.path)
            try data.write(to: manifest, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        } catch {
            return .init(failed: items.count, messages: [error.localizedDescription])
        }
        // The worker publishes only its latest real path, in the private request directory.
        let progressTask = Task {
            var previous: AdministratorCleanupPlan.Progress?
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: progress), data.count <= 16_384,
                   let update = try? JSONDecoder().decode(AdministratorCleanupPlan.Progress.self, from: data),
                   update != previous {
                    previous = update
                    onProgress?(update.completed, update.total, update.path)
                }
                do { try await Task.sleep(nanoseconds: 120_000_000) } catch { break }
            }
        }
        defer { progressTask.cancel() }
        let privilegedStarted = ProcessInfo.processInfo.systemUptime
        let result = await MoleEngine.shared.runPrivilegedBridge(
            "bin/app_cleanup_admin.sh", arguments: [String(getuid()), manifest.path], timeout: 900)
        let privilegedSeconds = ProcessInfo.processInfo.systemUptime - privilegedStarted
        logger.notice("Administrator authorization and worker finished in \(privilegedSeconds, privacy: .public)s; targets=\(items.count, privacy: .public)")
        let reports = result.output.components(separatedBy: .newlines).filter {
            $0.hasPrefix(AdministratorCleanupPlan.reportPrefix)
        }
        guard reports.count == 1,
              let data = reports[0].dropFirst(AdministratorCleanupPlan.reportPrefix.count).data(using: .utf8),
              let report = try? JSONDecoder().decode(AdministratorCleanupPlan.Report.self, from: data),
              report.removed >= 0, report.skipped >= 0, report.failed >= 0 else {
            return .init(failed: items.count, messages: [result.diagnosticOutput], executionFailed: true)
        }
        let roots = Set(items.map(\.record))
        let confirmedPaths = Set(report.removedPaths)
        guard (report.removed > 0 || report.skipped > 0 || report.failed > 0),
              confirmedPaths.allSatisfy({ path in
                  DeletionPlan.isLexicallySafePath(path)
                      && CleanupRiskPolicy.normalizedPathLiteral(path) == path
                      && DeletionPlan.isPathCovered(path, by: roots)
              }), confirmedPaths.count <= report.removed,
              report.removed == 0 || !confirmedPaths.isEmpty else {
            return .init(failed: items.count, messages: ["Invalid administrator cleanup report."],
                         executionFailed: true)
        }
        return .init(removed: report.removed, skipped: report.skipped, failed: report.failed,
                     messages: report.messages, executionFailed: !result.succeeded,
                     removedPaths: confirmedPaths, reclaimedBytes: report.reclaimedBytes)
    }
}
