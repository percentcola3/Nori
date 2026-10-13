import AppKit

@main
struct MenuBarCollectionStatusFixture {
    static var items: [NSStatusItem] = []
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let selected = Bundle.main.bundleIdentifier == "app.nori.fixture.selected"
        for title in selected ? ["NX", "NY"] : ["NV"] {
            let item = NSStatusBar.system.statusItem(withLength: 28)
            item.button?.title = title
            let menu = NSMenu()
            menu.addItem(withTitle: "Original fixture menu " + title, action: nil, keyEquivalent: "")
            item.menu = menu
            items.append(item)
        }
        app.run()
    }
}
