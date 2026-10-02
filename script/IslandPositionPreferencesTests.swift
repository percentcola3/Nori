import Foundation

enum AppLanguage: String, CaseIterable {
    case auto, en, zhHans, zhHant, ja, ko, de, fr, es, pt, it, ru, tr
}

@main
struct IslandPositionPreferencesTests {
    static func main() {
        let suite = "app.nori.island-position-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let left = IslandPositionPreferences.leftKey
        let right = IslandPositionPreferences.rightKey

        expect(IslandPositionPreferences.restored(forKey: left, in: defaults) == 0.5
               && IslandPositionPreferences.restored(forKey: right, in: defaults) == 0.5,
               "New installs restore both sidebars to the center")
        defaults.set(0.18, forKey: left)
        defaults.set(0.79, forKey: right)
        let reopened = UserDefaults(suiteName: suite)!
        expect(IslandPositionPreferences.restored(forKey: left, in: reopened) == 0.18
               && IslandPositionPreferences.restored(forKey: right, in: reopened) == 0.79,
               "Reopening preferences restores independent left and right positions")
        defaults.set("invalid", forKey: left)
        expect(IslandPositionPreferences.restored(forKey: left, in: defaults) == 0.5
               && IslandPositionPreferences.restored(forKey: right, in: defaults) == 0.79,
               "Malformed preferences reset only the affected sidebar")
        defaults.set(-4.0, forKey: left)
        defaults.set(3.0, forKey: right)
        expect(IslandPositionPreferences.restored(forKey: left, in: defaults) == 0
               && IslandPositionPreferences.restored(forKey: right, in: defaults) == 1,
               "Out-of-range saved positions stay within the display")
        defaults.set(NSNumber(value: Double.nan), forKey: left)
        defaults.set(NSNumber(value: Double.infinity), forKey: right)
        expect(IslandPositionPreferences.restored(forKey: left, in: defaults) == 0.5
               && IslandPositionPreferences.restored(forKey: right, in: defaults) == 0.5,
               "Nonfinite preferences restore to the center")

        let keys = ["settings.island.edge", "settings.island.edge.top",
                    "settings.island.edge.left", "settings.island.edge.right",
                    "settings.island.hint", "island.drag.hint"]
        var dragHints = Set<String>()
        for language in AppLanguage.allCases where language != .auto {
            let table = L10nProductivityTables.table(for: language)
            expect(keys.allSatisfy { table[$0]?.isEmpty == false },
                   "Position and drag guidance are explicit in \(language.rawValue)")
            dragHints.insert(table["island.drag.hint"]!)
        }
        expect(dragHints.count == 12, "Drag guidance has a translation for every language")
        print("Island position preferences and localization tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        print("PASS: " + message)
    }
}
