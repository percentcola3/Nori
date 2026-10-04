import AppKit
import Carbon.HIToolbox

@main
struct HotKeyCenterTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let center = HotKeyCenter()
        defer { center.unregister() }
        var calls: [String] = []
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        precondition(center.register(id: "first", keyCode: UInt32(kVK_F18),
                                     modifiers: modifiers) { calls.append("first") })
        precondition(center.register(id: "second", keyCode: UInt32(kVK_F19),
                                     modifiers: modifiers) { calls.append("second") })

        // Deliver exactly where Carbon sends a background application's hotkeys.
        // No keyDown or frontmost window exists to invoke the local monitor.
        precondition(send(slot: 0) == noErr, "The application target must handle global hotkeys")
        pump()
        precondition(calls == ["first"], "The background event must invoke its own callback once")
        precondition(send(slot: 1) == noErr)
        pump()
        precondition(calls == ["first", "second"], "Separate screenshot shortcuts must stay independent")

        let before = calls
        _ = send(slot: 99)
        _ = send(slot: 0, signature: OSType(0x5445_5354))
        pump()
        precondition(calls == before, "Unknown slots and another app's signature must not capture")
        center.unregister()
        _ = send(slot: 0)
        pump()
        precondition(calls == before, "Disabled hotkeys must not invoke a callback")

        precondition(center.register(id: "replacement", keyCode: UInt32(kVK_F18),
                                     modifiers: modifiers) { calls.append("replacement") })
        precondition(send(slot: 0) == noErr)
        pump()
        precondition(calls == before + ["replacement"], "Re-registration must route to the new callback")
        print("PASS: application-level hotkey routing, independent shortcuts, disable and re-registration")
    }

    private static func send(slot: UInt32, signature: OSType = OSType(0x534D_484B)) -> OSStatus {
        var event: EventRef?
        let result = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                 GetCurrentEventTime(), EventAttributes(0), &event)
        guard result == noErr, let event else { return result }
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: signature, id: slot)
        let parameter = SetEventParameter(event, UInt32(kEventParamDirectObject),
                                          UInt32(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
        guard parameter == noErr else { return parameter }
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    private static func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
