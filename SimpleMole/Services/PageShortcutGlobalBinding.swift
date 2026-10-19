import AppKit
import Carbon.HIToolbox

/// 将已有的字符绑定转换为 Carbon 虚拟键码，不要求用户重新录制。
struct PageShortcutKeyCodeMap {
    let codes: [String: UInt32]

    static func current() -> Self {
        var codes: [String: UInt32] = [:]
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        if let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            for code in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState, characters.count, &length, &characters)
                guard status == noErr, length > 0 else { continue }
                let key = String(utf16CodeUnits: characters, count: length).lowercased()
                if codes[key] == nil { codes[key] = UInt32(code) }
            }
        }
        // 导航、功能键和数字默认键不受输入法（含无布局数据的输入源）影响。
        let fixed: [String: Int] = [
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9, ",": kVK_ANSI_Comma,
            " ": kVK_Space, "\r": kVK_Return, "\t": kVK_Tab, "\u{7f}": kVK_Delete,
            "\u{f700}": kVK_UpArrow, "\u{f701}": kVK_DownArrow,
            "\u{f702}": kVK_LeftArrow, "\u{f703}": kVK_RightArrow,
            "\u{f729}": kVK_Home, "\u{f72b}": kVK_End,
            "\u{f72c}": kVK_PageUp, "\u{f72d}": kVK_PageDown, "\u{f728}": kVK_ForwardDelete
        ]
        for (key, code) in fixed where codes[key] == nil { codes[key] = UInt32(code) }
        let functionCodes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
            kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in functionCodes.enumerated() {
            codes[String(UnicodeScalar(0xf704 + index)!)] = UInt32(code)
        }
        return Self(codes: codes)
    }
}

extension PageKeyboardShortcut {
    func hotKeyCombo(using map: PageShortcutKeyCodeMap) -> HotKeyCombo? {
        guard isValid, let code = map.codes[keyEquivalent] else { return nil }
        return HotKeyCombo(keyCode: code, modifierFlags: modifiers)
    }
}
