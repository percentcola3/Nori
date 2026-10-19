import AppKit
import Foundation

/// 菜单快捷键按键盘字符保存，菜单显示、触发与设置中的文案共用同一份值。
struct PageKeyboardShortcut: Codable, Equatable {
    let keyEquivalent: String
    let modifierRawValue: UInt

    init(keyEquivalent: String, modifiers: NSEvent.ModifierFlags = .command) {
        self.keyEquivalent = keyEquivalent.lowercased()
        modifierRawValue = modifiers.intersection(Self.supportedModifiers).rawValue
    }

    init?(event: NSEvent) {
        guard let key = event.characters(byApplyingModifiers: []), !key.isEmpty else { return nil }
        self.init(keyEquivalent: key, modifiers: event.modifierFlags)
        guard isValid else { return nil }
    }

    static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRawValue) }

    var isValid: Bool {
        keyEquivalent.count == 1 && keyEquivalent == keyEquivalent.lowercased()
            && (keyEquivalent.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
                || ["\r", "\t", "\u{7f}"].contains(keyEquivalent))
            && modifierRawValue == modifiers.intersection(Self.supportedModifiers).rawValue
            && !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    var displayLabel: String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        let symbols = [" ": "Space", "\r": "↩", "\t": "⇥", "\u{7f}": "⌫",
                       "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→"]
        if let symbol = symbols[keyEquivalent] { return label + symbol }
        if let scalar = keyEquivalent.unicodeScalars.first, (0xf704...0xf717).contains(scalar.value) {
            return label + "F\(scalar.value - 0xf704 + 1)"
        }
        return label + keyEquivalent.uppercased()
    }

    /// 保留应用菜单、目录页与系统窗口操作所需的组合。
    var isReserved: Bool {
        if modifiers == .command {
            return ["q", "z", "x", "c", "v", "a", "h", "m", "w", "f", "[", "]", " ",
                    "\t", "\u{7f}", "\u{f700}"].contains(keyEquivalent)
        }
        if modifiers == [.command, .shift] { return ["z", "g", "3", "4", "5", "6", "\t"].contains(keyEquivalent) }
        if modifiers == [.command, .option] { return ["h", "w", "m", "d", " ", "\u{1b}"].contains(keyEquivalent) }
        if modifiers == [.command, .control] { return ["q", " "].contains(keyEquivalent) }
        return false
    }
}

struct PageShortcutPreferences: Codable, Equatable {
    /// Entry 的 nil 是明确清除；没有 Entry 才使用默认值。
    struct Entry: Codable, Equatable {
        let shortcut: PageKeyboardShortcut?
    }

    private(set) var overrides: [String: Entry] = [:]
    private static let storageKey = "SMPageKeyboardShortcuts"

    func shortcut(for page: String, defaultKey: String) -> PageKeyboardShortcut? {
        if let entry = overrides[page] { return entry.shortcut }
        return PageKeyboardShortcut(keyEquivalent: defaultKey)
    }

    mutating func set(_ shortcut: PageKeyboardShortcut?, for page: String) {
        overrides[page] = Entry(shortcut: shortcut)
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              var saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        saved.overrides = saved.overrides.filter { _, entry in
            entry.shortcut.map { $0.isValid && !$0.isReserved } ?? true
        }
        return saved
    }

    func store(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
