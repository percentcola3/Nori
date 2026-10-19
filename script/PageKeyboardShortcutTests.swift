import AppKit
import Foundation
import Carbon.HIToolbox

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

@main
struct PageKeyboardShortcutTests {
    static func main() {
        let suite = "NoriPageShortcutTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var preferences = PageShortcutPreferences.load(defaults: defaults)
        let initial = PageKeyboardShortcut(keyEquivalent: "1")
        expect(preferences.shortcut(for: "cleanup", defaultKey: "1") == initial,
               "fresh settings must preserve default shortcuts")
        let custom = PageKeyboardShortcut(keyEquivalent: "K", modifiers: [.command, .option])
        expect(custom.keyEquivalent == "k" && custom.displayLabel == "⌥⌘K",
               "letter shortcuts should normalize case and display modifiers consistently")
        preferences.set(custom, for: "cleanup")
        preferences.set(nil, for: "settings")
        preferences.store(defaults: defaults)

        let reloaded = PageShortcutPreferences.load(defaults: defaults)
        expect(reloaded.shortcut(for: "cleanup", defaultKey: "1") == custom,
               "custom keys and modifiers must survive a restart")
        expect(reloaded.shortcut(for: "settings", defaultKey: ",") == nil,
               "cleared shortcuts must stay cleared after a restart")
        expect(reloaded.shortcut(for: "agents", defaultKey: "2")?.displayLabel == "⌘2",
               "customizing one page must leave other defaults intact")
        PageShortcutPreferences().store(defaults: defaults)
        expect(PageShortcutPreferences.load(defaults: defaults).shortcut(for: "settings", defaultKey: ",")?.displayLabel == "⌘,",
               "restoring defaults must also re-enable cleared shortcuts")

        for flags: NSEvent.ModifierFlags in [[], .shift, .capsLock] {
            expect(!PageKeyboardShortcut(keyEquivalent: "k", modifiers: flags).isValid,
                   "unmodified typing shortcuts must be rejected")
        }
        expect(!PageKeyboardShortcut(keyEquivalent: "", modifiers: .command).isValid,
               "empty shortcuts must be rejected")
        expect(!PageKeyboardShortcut(keyEquivalent: "two", modifiers: .command).isValid,
               "multiple characters must be rejected")
        expect(!PageKeyboardShortcut(keyEquivalent: "\u{0}", modifiers: .command).isValid,
               "invalid control characters must be rejected")
        expect(PageKeyboardShortcut(keyEquivalent: "k", modifiers: [.control, .option, .shift]).isValid,
               "non-command modifier combinations must be supported")
        expect(PageKeyboardShortcut(keyEquivalent: "\u{f705}", modifiers: .command).displayLabel == "⌘F2",
               "function keys must have readable labels")
        for key in ["q", "c", "f", "[", " "] {
            expect(PageKeyboardShortcut(keyEquivalent: key).isReserved,
                   "existing application and system actions must stay reserved")
        }
        expect(PageKeyboardShortcut(keyEquivalent: "z", modifiers: [.command, .shift]).isReserved,
               "redo must stay reserved")
        expect(!custom.isReserved, "an unused combination must be available")

        let keyCodes = PageShortcutKeyCodeMap(codes: ["1": UInt32(kVK_ANSI_1),
            "k": UInt32(kVK_ANSI_K), "\u{f705}": UInt32(kVK_F2)])
        expect(initial.hotKeyCombo(using: keyCodes) == HotKeyCombo(
            keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey)),
            "existing default shortcuts must become global without being re-recorded")
        expect(custom.hotKeyCombo(using: keyCodes) == HotKeyCombo(
            keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey)),
            "saved custom keys must preserve modifiers when registered globally")
        let shifted = PageKeyboardShortcut(keyEquivalent: "k", modifiers: [.command, .control, .option, .shift])
        expect(shifted.hotKeyCombo(using: keyCodes)?.modifiers == UInt32(cmdKey | controlKey | optionKey | shiftKey),
            "all four modifiers must survive conversion to Carbon")
        expect(PageKeyboardShortcut(keyEquivalent: "j").hotKeyCombo(using: keyCodes) == nil,
            "unmapped keys must report a registration failure instead of binding the wrong key")
        let actualMap = PageShortcutKeyCodeMap.current()
        for key in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ",", "\u{f705}"] {
            expect(PageKeyboardShortcut(keyEquivalent: key).hotKeyCombo(using: actualMap) != nil,
                   "default page shortcuts and function keys must resolve on the active keyboard layout")
        }

        preferences.set(PageKeyboardShortcut(keyEquivalent: ""), for: "cleanup")
        preferences.set(PageKeyboardShortcut(keyEquivalent: "q"), for: "agents")
        preferences.store(defaults: defaults)
        let sanitized = PageShortcutPreferences.load(defaults: defaults)
        expect(sanitized.shortcut(for: "cleanup", defaultKey: "1") == initial,
               "invalid stored bindings must fall back to defaults")
        expect(sanitized.shortcut(for: "agents", defaultKey: "2")?.displayLabel == "⌘2",
               "reserved stored bindings must fall back to defaults")
        defaults.set(Data("invalid JSON".utf8), forKey: "SMPageKeyboardShortcuts")
        expect(PageShortcutPreferences.load(defaults: defaults).overrides.isEmpty,
               "corrupt settings must not prevent launching")
        print("Page shortcut persistence, clearing, defaults and validation passed")
    }
}
