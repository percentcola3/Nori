import Foundation

/// User choices survive process shutdown and app replacement. Runtime visibility
/// assertions and cached icon coordinates are recreated for the current session.
final class MenuBarCollectionPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var enabled: Bool {
        get { defaults.bool(forKey: "SMMenuBarCollectionEnabled") }
        set { defaults.set(newValue, forKey: "SMMenuBarCollectionEnabled") }
    }

    var collapsed: Bool {
        get { defaults.bool(forKey: "SMMenuBarCollectionCollapsed") }
        set { defaults.set(newValue, forKey: "SMMenuBarCollectionCollapsed") }
    }

    var selected: Set<String> {
        get { Set(defaults.stringArray(forKey: "SMMenuBarCollectionApps") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "SMMenuBarCollectionApps") }
    }

    var trayIconVisible: Bool {
        get { defaults.bool(forKey: "SMMenuBarCollectionTray") }
        set { defaults.set(newValue, forKey: "SMMenuBarCollectionTray") }
    }
}
