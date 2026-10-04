import Foundation

// Fixture language state lives only in memory; no app preferences are changed.
enum AppLanguage: String, CaseIterable {
    case auto, zhHans = "zh-Hans", zhHant = "zh-Hant", en, ja, ko, de, fr, es, pt, it, ru, tr
}
final class L10n {
    static let shared = L10n()
    var resolved: AppLanguage = .en
    func t(_ key: String) -> String {
        let selected = L10nDeveloperExistingTables.table(for: resolved).merging(
            L10nLocalizationAuditTables.table(for: resolved)) { _, feature in feature }
        let english = L10nDeveloperExistingTables.table(for: .en).merging(
            L10nLocalizationAuditTables.table(for: .en)) { _, feature in feature }
        return selected[key] ?? english[key] ?? key
    }
    func tf(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: Locale(identifier: "en_US_POSIX"), arguments: arguments)
    }
}
