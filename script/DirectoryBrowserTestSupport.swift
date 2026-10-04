import Foundation

enum AppLanguage { case auto, zhHans, zhHant, en }
final class L10n {
    static let shared = L10n()
    func t(_ key: String) -> String { L10nDirectoryTables.table(for: .en)[key] ?? key }
    func tf(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: Locale(identifier: "en_US_POSIX"), arguments: arguments)
    }
}
