import AppKit
import SwiftUI

@main
struct ScreenshotEditorWindowTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        testWindowBounds()
        testPreviewFitsControls()
        testRepeatedEditorSessions()
        print("Screenshot editor: repeated sessions, retained geometry, minimum size and screen bounds passed")
    }

    static func testWindowBounds() {
        let desktop = CGRect(x: 1440, y: 24, width: 1440, height: 876)
        let repaired = ScreenshotEditorSizing.windowFrame(visibleFrame: desktop,
                                                          preferredSize: CGSize(width: 170, height: 210),
                                                          preferredOrigin: CGPoint(x: 0, y: 0))
        precondition(repaired.size == ScreenshotEditorSizing.minimumWindowSize,
                     "An inherited collapsed host must recover the editor's minimum size")
        precondition(desktop.contains(repaired), "A moved display must retain the whole editor")
        let smallDisplay = CGRect(x: -400, y: 200, width: 400, height: 300)
        let constrained = ScreenshotEditorSizing.windowFrame(visibleFrame: smallDisplay)
        precondition(smallDisplay.contains(constrained),
                     "A screen smaller than the editor minimum must still contain the window")
        precondition(constrained.width < ScreenshotEditorSizing.minimumWindowSize.width)
    }

    static func testPreviewFitsControls() {
        let images = [CGSize(width: 1600, height: 900), CGSize(width: 600, height: 1400)]
        let viewports = [CGSize(width: 876, height: 470), CGSize(width: 496, height: 180)]
        for image in images {
            for available in viewports {
                for preset in ScreenshotPreset.builtIn {
                    let composition = ScreenshotComposition(preset: preset)
                    let content = ScreenshotEditorSizing.previewContentSize(imageSize: image,
                                                                            available: available,
                                                                            composition: composition)
                    let canvas = PresetLayout.compute(contentSize: content, composition: composition).canvasSize
                    precondition(canvas.width <= available.width && canvas.height <= available.height,
                                 "\(preset.id) preview must leave space for editing controls")
                }
            }
        }
    }

    @MainActor static func testRepeatedEditorSessions() {
        let suite = "com.nori.screenshot-window-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ScreenshotPreferences(defaults: defaults)
        preferences.save(ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "plain")!))
        let display = CGRect(x: 0, y: 24, width: 1440, height: 876)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 900, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); MosaicCache.shared.clear() }

        for session in 0..<6 {
            let imageSize = session.isMultiple(of: 2)
                ? CGSize(width: 1600, height: 900) : CGSize(width: 600, height: 1400)
            let image = NSImage(size: imageSize)
            image.addRepresentation(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(imageSize.width), pixelsHigh: Int(imageSize.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!)
            let editor = ScreenshotEditorView(image: image,
                                              preferences: preferences, onClose: {})
            let previousFrame = window.frame
            ScreenshotEditorSizing.replaceContent(editor, in: window, visibleFrame: display,
                                                   center: session == 0)
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            precondition(window.frame.width >= 520 && window.frame.height >= 360,
                         "Editor session \(session) collapsed after hosting/layout")
            if session > 0 {
                precondition(window.frame == previousFrame,
                             "Replacing the editor must preserve the user-sized window")
            }
            let host = window.contentViewController as! NSHostingController<ScreenshotEditorView>
            precondition(host.sizingOptions.isEmpty,
                         "The resizable AppKit window must own its size")
            if session == 0 {
                window.setFrame(CGRect(x: 200, y: 200, width: 760, height: 520), display: false)
            }
            window.close()
            window.contentViewController = nil
        }

        // Recover windows collapsed by earlier versions, then clamp retained
        // geometry after moving to a smaller display.
        window.minSize = .zero
        window.setFrame(CGRect(x: 10, y: 10, width: 170, height: 210), display: false)
        ScreenshotEditorSizing.replaceContent(Text("New capture"), in: window,
                                               visibleFrame: display, center: false)
        precondition(window.frame.size == ScreenshotEditorSizing.minimumWindowSize)
        let smallDisplay = CGRect(x: -500, y: 0, width: 500, height: 340)
        ScreenshotEditorSizing.replaceContent(Text("Smaller screen"), in: window,
                                               visibleFrame: smallDisplay, center: false)
        precondition(smallDisplay.contains(window.frame),
                     "Reopening on a smaller display must fit its visible area")
    }
}
