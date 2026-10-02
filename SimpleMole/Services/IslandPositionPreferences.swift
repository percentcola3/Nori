import Foundation

/// Sidebars keep independent relative positions so they remain on-screen after
/// a display change. Missing or malformed preferences restore to the center.
enum IslandPositionPreferences {
    static let leftKey = "SMIslandLeftPosition"
    static let rightKey = "SMIslandRightPosition"

    static func normalized(_ position: Double) -> Double {
        guard position.isFinite else { return 0.5 }
        return min(1, max(0, position))
    }

    static func restored(forKey key: String, in defaults: UserDefaults = .standard) -> Double {
        guard let saved = defaults.object(forKey: key) as? NSNumber else { return 0.5 }
        return normalized(saved.doubleValue)
    }
}
