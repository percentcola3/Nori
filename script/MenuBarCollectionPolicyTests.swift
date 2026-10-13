import Foundation

@main
struct MenuBarCollectionPolicyTests {
    static func main() {
        precondition(MenuBarCollectionPolicy.backend(majorVersion: 12) == .unavailable)
        for version in 13...26 { precondition(MenuBarCollectionPolicy.backend(majorVersion: version) == .separator) }
        precondition(MenuBarCollectionPolicy.backend(majorVersion: 27) == .nativeExperimental)
        precondition(MenuBarCollectionPolicy.backend(majorVersion: 28) == .unavailable)
        let running: Set<String> = ["a", "b", "new", "com.apple.controlcenter", "nori"]
        let allowed = MenuBarCollectionPolicy.allowedApps(running: running,
            selected: ["a", "com.apple.controlcenter", "nori", "stale"], candidates: ["a", "b", "com.apple.controlcenter", "nori"], own: "nori")
        precondition(Set(allowed) == running.subtracting(["a"]))
        precondition(MenuBarCollectionPolicy.allowedApps(running: running, selected: ["stale"], candidates: ["a"], own: "nori") == running.sorted())
        precondition(MenuBarCollectionPolicy.separatorLength(screenWidths: [1920, 3840]) == 7680)
        precondition(MenuBarCollectionPolicy.separatorLength(screenWidths: []) == nil)
        precondition(MenuBarCollectionPolicy.separatorLength(screenWidths: [6000]) == nil)
        precondition(MenuBarCollectionPolicy.separatorLength(screenWidths: [.infinity]) == nil)
        print("PASS: OS gating, selected-only allow list, own/system/new/unselected apps retained, stale selections ignored, multi-display bounds")
    }
}
