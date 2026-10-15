import Foundation

@main
struct MenuBarCollectionPreferencesTests {
    static func main() {
        let phase = CommandLine.arguments[1]
        let suite = CommandLine.arguments[2]
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = MenuBarCollectionPreferences(defaults: defaults)
        let apps: Set<String> = ["app.nori.fixture.one", "app.nori.fixture.two"]
        switch phase {
        case "write":
            precondition(!preferences.enabled && !preferences.collapsed)
            // Existing versions already saved these keys. Keep those choices.
            defaults.set(Array(apps), forKey: "SMMenuBarCollectionApps")
            defaults.set(true, forKey: "SMMenuBarCollectionTray")
            precondition(preferences.selected == apps && preferences.trayIconVisible)
            preferences.enabled = true
            preferences.collapsed = true
        case "relaunch":
            precondition(preferences.enabled && preferences.collapsed)
            precondition(preferences.selected == apps && preferences.trayIconVisible)
            preferences.collapsed = false
        case "expanded":
            precondition(preferences.enabled && !preferences.collapsed)
            precondition(preferences.selected == apps && preferences.trayIconVisible)
            preferences.enabled = false
        case "disabled":
            precondition(!preferences.enabled && !preferences.collapsed)
            precondition(preferences.selected == apps && preferences.trayIconVisible)
        default: fatalError("Unknown test phase")
        }
        precondition(defaults.synchronize(), "The isolated test preferences must reach the next process")
        print("PASS: menu bar preferences \(phase)")
    }
}
