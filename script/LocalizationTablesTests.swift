import Foundation

@main
struct LocalizationTablesTests {
    static func main() {
        let tables = [L10nDeveloperExistingTables.table, L10nLocalizationAuditTables.table]
        let placeholder = try! NSRegularExpression(pattern: "%[0-9$]*[ld@f]+|%%")
        func formatArguments(_ value: String) -> [String] {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return placeholder.matches(in: value, range: range).compactMap { match in
                let token = (value as NSString).substring(with: match.range)
                return token == "%%" ? nil : token
            }
        }
        for table in tables {
            let english = table(.en)
            precondition(!english.isEmpty)
            for language in [AppLanguage.zhHans, .zhHant] {
                let translated = table(language)
                precondition(Set(translated.keys) == Set(english.keys), "Missing language keys")
                for (key, value) in english {
                    precondition(formatArguments(value) == formatArguments(translated[key]!),
                                 "Format arguments differ: \(key)")
                }
            }
        }
        L10n.shared.resolved = .zhHant
        precondition(L10n.shared.t("dev.cli.title") == "命令列工具")
        precondition(L10n.shared.t("dev.cleanup.sizeUnknown") == "大小未知")
        precondition(L10n.shared.tf("audit.auto.error.invalidRoot", "/tmp/User Project")
                     == "無法存取自動清理資料夾：/tmp/User Project")
        precondition(L10nLocalizationAuditTables.categoryName("npm Cache") == "npm 快取")
        precondition(L10nLocalizationAuditTables.categoryName("User Project") == "User Project")
        precondition(L10nLocalizationAuditTables.categoryName("Example App leftovers", isAppLeftover: true)
                     == "Example App 殘留")
        L10n.shared.resolved = .ja
        precondition(L10n.shared.t("dev.cli.title") == "Command-line tools", "English fallback failed")
        let preview = LocalizationPreviewFixture.Preview(
            need: .needed, summaryKey: "audit.maintenance.downloads",
            summaryArguments: [.integer(3)])
        L10n.shared.resolved = .en
        precondition(preview.summary == "3 download records.")
        L10n.shared.resolved = .zhHant
        precondition(preview.summary == "3 筆下載記錄。", "A scanned summary did not follow the UI language")
        let userSummary = LocalizationPreviewFixture.Preview(need: .needed, summary: "User Project")
        precondition(userSummary.summary == "User Project")
        print("Localization tables: language coverage, formats, Traditional Chinese and user values passed")
    }
}
