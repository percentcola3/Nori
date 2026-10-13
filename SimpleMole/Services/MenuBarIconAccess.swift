import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Cached previews contain only selected menu bar regions, never a saved desktop
/// screenshot. Native elements are resolved again after restoring the bar.
struct CollectedMenuBarIcon: Identifiable {
    let id: String
    let bundleIdentifier: String
    let pid: pid_t
    let name: String
    let title: String
    let ordinal: Int
    let ownerCount: Int
    let nativeIdentifier: String?
    let frame: CGRect?
    var image: NSImage
    var isNativePreview = false
}

enum MenuBarIconAccess {
    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private static func elements(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let bar = value(app, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        return value(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite,
              dimensions.width > 0, dimensions.width <= 256,
              dimensions.height > 0, dimensions.height <= 64 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    @MainActor
    static func previews(for apps: [MenuBarCollectionController.Candidate]) async -> [CollectedMenuBarIcon] {
        guard AXIsProcessTrusted() else {
            return apps.map { app in
                CollectedMenuBarIcon(id: app.id, bundleIdentifier: app.id, pid: app.pid, name: app.name,
                    title: app.name, ordinal: 0, ownerCount: 0, nativeIdentifier: nil, frame: nil, image: app.icon)
            }
        }
        let descriptors = apps.map { ($0.id, $0.pid, $0.name) }
        let inventory = await Task.detached(priority: .userInitiated) {
            descriptors.flatMap { id, pid, name -> [(String, pid_t, String, String, Int, Int, String?, CGRect)] in
                let children = elements(pid: pid)
                return children.enumerated().compactMap { ordinal, element in
                    guard let bounds = frame(element) else { return nil }
                    let title = (value(element, kAXTitleAttribute) as? String)
                        ?? (value(element, kAXDescriptionAttribute) as? String) ?? name
                    let rawIdentifier = value(element, kAXIdentifierAttribute) as? String
                    let identifier = rawIdentifier.flatMap { $0.isEmpty ? nil : $0 }
                    return (id, pid, name, title, ordinal, children.count, identifier, bounds)
                }
            }
        }.value
        guard !Task.isCancelled else { return [] }
        let appIcons = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0.icon) })
        var icons = inventory.map { id, pid, name, title, ordinal, count, identifier, bounds in
            CollectedMenuBarIcon(id: "\(id):\(identifier ?? "item"):\(ordinal)", bundleIdentifier: id,
                pid: pid, name: name, title: title, ordinal: ordinal, ownerCount: count,
                nativeIdentifier: identifier, frame: bounds,
                image: appIcons[id] ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
        }
        if #available(macOS 14.0, *), CGPreflightScreenCaptureAccess(), !icons.isEmpty,
           let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
            for display in content.displays {
                let indices = icons.indices.filter { icons[$0].frame.map { display.frame.contains($0) } == true }
                guard !indices.isEmpty, !Task.isCancelled else { continue }
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.showsCursor = false
                let filter = SCContentFilter(display: display, excludingWindows: [])
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                      !Task.isCancelled else { continue }
                let scaleX = CGFloat(image.width) / display.frame.width
                let scaleY = CGFloat(image.height) / display.frame.height
                for index in indices {
                    guard let bounds = icons[index].frame else { continue }
                    let crop = CGRect(x: (bounds.minX - display.frame.minX) * scaleX,
                                      y: (bounds.minY - display.frame.minY) * scaleY,
                                      width: bounds.width * scaleX, height: bounds.height * scaleY).integral
                    if let thumbnail = image.cropping(to: crop),
                       let buffer = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        // Copy the crop so a thumbnail never retains the complete
                        // display image's backing pixel buffer.
                        buffer.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
                        if let copied = buffer.makeImage() {
                            icons[index].image = NSImage(cgImage: copied, size: bounds.size)
                            icons[index].isNativePreview = true
                        }
                    }
                }
            }
        }
        return icons
    }

    static func activate(_ icon: CollectedMenuBarIcon, secondary: Bool) -> Bool {
        guard AXIsProcessTrusted(),
              let owner = NSRunningApplication(processIdentifier: icon.pid), !owner.isTerminated,
              owner.bundleIdentifier == icon.bundleIdentifier else { return false }
        let children = elements(pid: icon.pid)
        let element: AXUIElement?
        if let identifier = icon.nativeIdentifier {
            let matching = children.filter { value($0, kAXIdentifierAttribute) as? String == identifier }
            if matching.count == 1 { element = matching.first }
            else if children.count == icon.ownerCount, children.indices.contains(icon.ordinal),
                    value(children[icon.ordinal], kAXIdentifierAttribute) as? String == identifier {
                element = children[icon.ordinal]
            } else { element = nil }
        } else if children.count == icon.ownerCount, children.indices.contains(icon.ordinal) {
            let candidate = children[icon.ordinal]
            let title = (value(candidate, kAXTitleAttribute) as? String)
                ?? (value(candidate, kAXDescriptionAttribute) as? String) ?? icon.name
            element = title == icon.title ? candidate : nil
        } else { element = nil }
        guard let element, let bounds = frame(element) else { return false }
        if !secondary {
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if result == .success { return true }
            guard result == .actionUnsupported else { return false }
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &displayCount) == .success,
              displays.prefix(Int(displayCount)).contains(where: { id in
                  let screen = CGDisplayBounds(id)
                  return screen.contains(bounds) && bounds.minY >= screen.minY && bounds.maxY <= screen.minY + 64
              }) else { return false }
        // AXShowMenu often aliases primary activation. Forward an actual right
        // click only after resolving the restored native item and its bounds.
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: secondary ? .rightMouseDown : .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: secondary ? .right : .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: secondary ? .rightMouseUp : .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: secondary ? .right : .left) else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
