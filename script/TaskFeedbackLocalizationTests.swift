import Foundation

// Build the feedback layer independently from SwiftUI so regressions run fast.
enum AppLanguage: String, CaseIterable {
    case auto, en, zhHans, zhHant, ja, ko, de, fr, es, pt, it, ru, tr
}

final class L10n {
    static let shared = L10n()
    func t(_ key: String) -> String { L10nTaskFeedbackTables.table(for: .en)[key] ?? key }
}

@main
struct TaskFeedbackLocalizationTests {
    static func main() {
        let required = Set([
            "task.failure.title", "task.failure.message", "task.failure.partial",
            "task.closeApps.title", "task.closeApps.message", "task.closeApps.changed",
            "task.closeApps.check", "task.details", "task.dismiss", "task.cancel",
            "task.failure.unknown", "task.failure.runtimeUnknown", "task.failure.skipped",
            "cleanup.execution.summary", "cleanup.execution.summary.permanent", "cleanup.execution.maintenance",
            "cleanup.execution.incomplete", "cleanup.execution.verificationIncomplete", "agents.status.incomplete",
            "agents.status.leftovers", "log.scanPartial",
            "task.closeApps.remaining", "task.failure.runtimeRemaining"
        ])
        let english = L10nTaskFeedbackTables.table(for: .en)
        for language in AppLanguage.allCases where language != .auto {
            let table = L10nTaskFeedbackTables.table(for: language)
            expect(required.isSubset(of: Set(table.keys)) && Set(table.keys) == Set(english.keys),
                   "All dialog and diagnostic keys are covered in \(language.rawValue)")
            expect(table.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                   "Every feedback value is nonempty in \(language.rawValue)")
            let status = table["task.reason.status"]!
            expect(status.components(separatedBy: "%@").count == 2,
                   "Exit status remains format-safe in \(language.rawValue)")
            for key in ["cleanup.execution.summary", "cleanup.execution.summary.permanent", "cleanup.execution.maintenance"] {
                expect(table[key]!.components(separatedBy: "%d").count == 4
                       && !table[key]!.contains("%@"),
                       "Cleanup counters preserve their three integer placeholders in \(language.rawValue): \(key)")
            }
            expect(table["agents.status.leftovers"]!.components(separatedBy: "%@").count == 2,
                   "Agent leftovers preserve their name placeholder in \(language.rawValue)")
            if language != .en {
                expect(table["task.failure.title"] != english["task.failure.title"]
                       && table["task.closeApps.message"] != english["task.closeApps.message"]
                       && table["task.failure.unknown"] != english["task.failure.unknown"],
                       "Primary failure feedback does not fall back to English in \(language.rawValue)")
            }
            let localize: (String) -> String = { table[$0] ?? $0 }
            let path = "/Users/fixture/a folder/技能: source"
            let messages = TaskFeedbackDiagnostic.localized([
                "Open-file check 0.03s; available=yes",
                "Kept Agent resource while its owner is running (Cursor, codex): " + path,
                "Failed secure removal of " + path + ": Permission denied",
                "Kept MCP installation because a registration configuration changed or could not be backed up: " + path,
                "CLI uninstall left installation paths in place: " + path + "\n/Users/fixture/bin/codex",
                "Package manager exited with status 23.\nUntranslated verbose package log",
                "Unsupported external tool error AUTH_TOKEN=do-not-display",
                "Another unsupported error AUTH_TOKEN=do-not-display"
            ], using: localize)
            expect(messages.count == 6 && messages[0].contains("Cursor, codex\n" + path),
                   "Preserve owner names and Unicode paths, omit probe logs, and deduplicate in \(language.rawValue)")
            expect(messages[1] == table["task.reason.remove"]! + "\n" + path,
                   "Keep the failing path while translating the removal reason in \(language.rawValue)")
            expect(TaskFeedbackDiagnostic.localized([
                "Skipped content that requires administrator access or cannot be deleted: " + path
            ], using: localize) == [table["task.reason.remove"]! + "\n" + path],
                   "Permission changes retain the path and a localized explanation in \(language.rawValue)")
            expect(messages[2].hasPrefix(table["task.reason.backup"]!)
                   && messages[3].contains("/Users/fixture/bin/codex")
                   && messages[4].contains("23")
                   && messages[5] == table["task.failure.unknown"],
                   "Translate backup, CLI, exit-code, and unknown failures in \(language.rawValue)")
            expect(!messages.joined().contains("AUTH_TOKEN")
                   && !messages.joined().contains("Untranslated verbose package log")
                   && !messages.joined().contains("Permission denied"),
                   "Technical English does not leak into primary feedback in \(language.rawValue)")
        }
        expect(TaskFeedbackDiagnostic.localized(["", "Open-file check 0.01s; available=no"]).isEmpty,
               "Informational logs alone do not produce a failure reason")
        expect(TaskFeedbackDiagnostic.localized(["Skipped because open-file state was unavailable: /fixture"])
            .first?.hasPrefix(english["task.reason.runtimeUnknown"]!) == true,
               "The default API uses the current app localizer")
        final class NoticeCapture: @unchecked Sendable {
            var events: [[AnyHashable: Any]] = []
        }
        let capture = NoticeCapture()
        let observer = NotificationCenter.default.addObserver(forName: .noriTaskFailure,
            object: nil, queue: nil) { notice in capture.events.append(notice.userInfo ?? [:]) }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<2 {
            TaskFeedbackNotice.reportFailure(messageKey: "task.reason.shellSyntax",
                details: ["~/.zshrc:7"], detailsAreLocalized: true)
        }
        expect(capture.events.count == 2 && capture.events.allSatisfy {
            $0["messageKey"] as? String == "task.reason.shellSyntax"
                && $0["details"] as? [String] == ["~/.zshrc:7"]
                && $0["detailsAreLocalized"] as? Bool == true
        }, "Repeated identical user-action failures each report a new localized notice")
        print("Task feedback localization tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: " + message) }
        print("PASS: " + message)
    }
}
