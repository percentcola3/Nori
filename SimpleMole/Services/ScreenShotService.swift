import Foundation
import AppKit
import Carbon.HIToolbox

/// 全局快捷键（Carbon RegisterEventHotKey，无需辅助功能权限）。
/// 支持多个并行注册：每个热键一个 id，回调按 id 分发。
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var localMonitor: Any?
    private var combinations: [UInt32: HotKeyCombo] = [:]
    private var nextID: UInt32 = 0

    /// 注册一个热键；`id` 仅作调用方语义标识，变更热键组合时整体重注册。
    @discardableResult
    func register(id: String,
                  keyCode: UInt32,
                  modifiers: UInt32,
                  handler: @escaping () -> Void) -> Bool {
        guard installEventHandlerIfNeeded() else { return false }
        let slot = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x534D_484B), id: slot) // "SMHK"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeys[slot] = ref
        handlers[slot] = handler
        combinations[slot] = HotKeyCombo(keyCode: keyCode, modifiers: modifiers)
        installLocalMonitorIfNeeded()
        return true
    }

    func unregister() {
        for ref in hotKeys.values { UnregisterEventHotKey(ref) }
        hotKeys.removeAll()
        handlers.removeAll()
        combinations.removeAll()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        nextID = 0
    }

    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandlerRef == nil else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // 后台全局热键直接送到应用 target，不能依赖前台窗口的事件分发器。
        // 主窗口、编辑器和覆盖层共用同一入口。
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           UInt32(kEventParamDirectObject),
                                           UInt32(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr, hotKeyID.signature == OSType(0x534D_484B) else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().fire(slot: hotKeyID.id)
            return noErr
        }, 1, &eventType, selfPtr, &eventHandlerRef)
        if status != noErr { eventHandlerRef = nil }
        return status == noErr
    }

    private func installLocalMonitorIfNeeded() {
        guard localMonitor == nil else { return }
        // Carbon 已消费的热键不会成为 keyDown；只处理仍送到前台窗口的按键。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let combo = HotKeyCombo(keyCode: UInt32(event.keyCode), modifierFlags: event.modifierFlags)
            guard let slot = self.combinations.first(where: { $0.value == combo })?.key else {
                return event
            }
            if !event.isARepeat { self.fire(slot: slot) }
            return nil
        }
    }

    private func fire(slot: UInt32) {
        guard let handler = handlers[slot] else { return }
        Task { @MainActor in handler() }
    }
}

/// 用户可自定义的快捷键组合：Carbon 键码 + 修饰键掩码，持久化到
/// UserDefaults。默认 ⇧⌘S。
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_ANSI_S),
                                       modifiers: UInt32(cmdKey | shiftKey))
    /// 按比例截取：默认 ⇧⌘R。
    static let ratioDefault = HotKeyCombo(keyCode: UInt32(kVK_ANSI_R),
                                          modifiers: UInt32(cmdKey | shiftKey))

    static func load(defaults: UserDefaults = .standard) -> HotKeyCombo {
        load(defaults: defaults, codeKey: "SMShotHotKeyCode",
             modsKey: "SMShotHotKeyMods", fallback: .default)
    }

    static func loadRatio(defaults: UserDefaults = .standard) -> HotKeyCombo {
        load(defaults: defaults, codeKey: "SMShotRatioHotKeyCode",
             modsKey: "SMShotRatioHotKeyMods", fallback: .ratioDefault)
    }

    private static func load(defaults: UserDefaults, codeKey: String,
                             modsKey: String, fallback: HotKeyCombo) -> HotKeyCombo {
        guard let code = defaults.object(forKey: codeKey) as? Int,
              let mods = defaults.object(forKey: modsKey) as? Int else {
            return fallback
        }
        return HotKeyCombo(keyCode: UInt32(code), modifiers: UInt32(mods))
    }

    func store(defaults: UserDefaults = .standard) {
        store(defaults: defaults, codeKey: "SMShotHotKeyCode", modsKey: "SMShotHotKeyMods")
    }

    func storeRatio(defaults: UserDefaults = .standard) {
        store(defaults: defaults, codeKey: "SMShotRatioHotKeyCode", modsKey: "SMShotRatioHotKeyMods")
    }

    private func store(defaults: UserDefaults, codeKey: String, modsKey: String) {
        defaults.set(Int(keyCode), forKey: codeKey)
        defaults.set(Int(modifiers), forKey: modsKey)
    }

    /// 至少包含 ⌘/⌥/⌃ 之一：仅 ⇧ 或无修饰键的全局热键会在日常打字里误触发。
    var hasStrongModifier: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// Apple 惯用顺序 ⌃⌥⇧⌘ + 键名。
    var displayLabel: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keySymbol(for: keyCode))
        return parts.joined()
    }

    private static func keySymbol(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Keypad0: return "Num0"
        case kVK_ANSI_Keypad1: return "Num1"
        case kVK_ANSI_Keypad2: return "Num2"
        case kVK_ANSI_Keypad3: return "Num3"
        case kVK_ANSI_Keypad4: return "Num4"
        case kVK_ANSI_Keypad5: return "Num5"
        case kVK_ANSI_Keypad6: return "Num6"
        case kVK_ANSI_Keypad7: return "Num7"
        case kVK_ANSI_Keypad8: return "Num8"
        case kVK_ANSI_Keypad9: return "Num9"
        default: return "Key\(keyCode)"
        }
    }
}

extension HotKeyCombo {
    /// 从 NSEvent 修饰键掩码构造（设置页录制快捷键用）。
    init(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) {
        var mods: UInt32 = 0
        if modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        self.init(keyCode: keyCode, modifiers: mods)
    }
}

/// 交互式截图：调系统 screencapture -i（区域/窗口选择体验与系统一致），
/// 完成后读取为内存图片并立即清理私有临时目录。需要屏幕录制权限（首次系统会弹授权）。
enum ScreenShotService {
    @discardableResult
    static func captureInteractive(completion: @escaping (NSImage?) -> Void) -> Process? {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("com.nori.screenshot.\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            completion(nil)
            return nil
        }
        let url = directory.appendingPathComponent("capture.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        process.terminationHandler = { proc in
            let image = proc.terminationStatus == 0
                ? (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
                : nil
            try? fileManager.removeItem(at: directory)
            DispatchQueue.main.async {
                completion(image)
            }
        }
        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: directory)
            DispatchQueue.main.async { completion(nil) }
            return nil
        }
        return process
    }

    /// 定比例区域截取：`rect` 为全局屏幕坐标（点）。需要屏幕录制权限。
    @discardableResult
    static func captureRegion(_ rect: CGRect, completion: @escaping (NSImage?) -> Void) -> Process? {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("com.nori.screenshot.\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            completion(nil)
            return nil
        }
        let url = directory.appendingPathComponent("capture.png")
        let region = "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-R", region, "-x", url.path]
        process.terminationHandler = { proc in
            let image = proc.terminationStatus == 0
                ? (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
                : nil
            try? fileManager.removeItem(at: directory)
            DispatchQueue.main.async {
                completion(image)
            }
        }
        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: directory)
            DispatchQueue.main.async { completion(nil) }
            return nil
        }
        return process
    }
}
