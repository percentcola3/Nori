import Foundation

/// One-time migrations between product identities (Simple Mole → ForgeSweep →
/// Nori). Internal engine names remain unchanged; only user preferences and
/// app-owned storage move to the current product namespace.
///
/// Auto-cleanup rules are deliberately NOT migrated: each rule carries a
/// per-directory "regenerable only" authorization bound to the install that
/// recorded it, and a fresh install must not silently inherit automatic
/// deletion rules from a previous brand.
enum BrandMigration {
    private static let migrationKey = "SMNoriBrandMigrationV1"
    private static let legacyBundleIdentifiers = ["com.forgesweep.app", "com.simplemole.app"]

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        for legacyIdentifier in legacyBundleIdentifiers {
            guard let legacy = defaults.persistentDomain(forName: legacyIdentifier) else { continue }
            for (key, value) in legacy
            where key.hasPrefix("SM") && key != AutoCleanupRuleStore.storageKey {
                if defaults.object(forKey: key) == nil {
                    defaults.set(value, forKey: key)
                }
            }
        }

        migrateDirectory(in: "Library/Application Support")
        migrateDirectory(in: "Library/Caches")
        migrateDirectory(in: "Library/Logs")
        defaults.set(true, forKey: migrationKey)
    }

    private static func migrateDirectory(in relativeParent: String) {
        let parent = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(relativeParent, isDirectory: true)
        let fileManager = FileManager.default
        let current = parent.appendingPathComponent("Nori", isDirectory: true)
        // ForgeSweep data is the immediate predecessor; only fall back to the
        // pre-release SimpleMole directory when ForgeSweep never existed.
        for legacyName in ["ForgeSweep", "SimpleMole"] {
            let legacy = parent.appendingPathComponent(legacyName, isDirectory: true)
            guard fileManager.fileExists(atPath: legacy.path),
                  !fileManager.fileExists(atPath: current.path) else { continue }
            try? fileManager.moveItem(at: legacy, to: current)
        }
    }
}
