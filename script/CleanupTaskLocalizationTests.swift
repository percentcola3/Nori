import Foundation

enum AppLanguage: String, CaseIterable {
    case auto, en, zhHans, zhHant, ja, ko, de, fr, es, pt, it, ru, tr
}

@main
struct CleanupTaskLocalizationTests {
    static func main() {
        let english = L10nCleanupTaskTables.table(for: .en)
        let expectedKeys = Set(L10nCleanupTaskTables.keys + L10nCleanupTaskTables.adminKeys + L10nCleanupTaskTables.scanKeys)
        for language in AppLanguage.allCases where language != .auto {
            let table = L10nCleanupTaskTables.table(for: language)
            expect(Set(table.keys) == expectedKeys,
                   "Cleanup stage covers every key in \(language.rawValue)")
            expect(table.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                   "Cleanup stage has no empty text in \(language.rawValue)")
            expect(table["cleanup.task.progress"]!.components(separatedBy: "%d").count == 3,
                   "Handled-target progress has two integer placeholders in \(language.rawValue)")
            expect(table["cleanup.task.completed"]!.components(separatedBy: "%d").count == 2,
                   "Completed cleanup has one integer placeholder in \(language.rawValue)")
            expect(table["cleanup.task.reclaimed"]!.components(separatedBy: "%@").count == 2,
                   "Cleanup result has one byte-size placeholder in \(language.rawValue)")
            expect(table["cleanup.task.closeApps"]!.components(separatedBy: "%@").count == 2,
                   "Close-app guidance preserves the app names in \(language.rawValue)")
            expect(String(format: table["cleanup.admin.message"]!, 6).contains("6"),
                   "Administrator disclosure includes its selected item count")
            let progress = String(format: table["cleanup.task.progress"]!, 3, 8)
            let apps = String(format: table["cleanup.task.closeApps"]!, "Cursor, Codex")
            let reclaimed = String(format: table["cleanup.task.reclaimed"]!, "1.5 GB")
            expect(progress.contains("3") && progress.contains("8") && apps.contains("Cursor, Codex")
                   && reclaimed.contains("1.5 GB"),
                   "Runtime values appear in the localized stage text in \(language.rawValue)")
            if language != .en {
                expect(L10nCleanupTaskTables.keys.allSatisfy { english[$0] != table[$0] },
                       "Cleanup stage text does not fall back to English in \(language.rawValue)")
            }
        }
        expect(L10nCleanupTaskTables.table(for: .auto).isEmpty,
               "Automatic language is resolved by the app localizer")
        print("Cleanup task localization tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: " + message) }
        print("PASS: " + message)
    }
}
