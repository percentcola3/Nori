import AppKit
import SwiftUI

@main
struct ScreenshotEditorWindowTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        testWindowBounds()
        testPreviewFitsControls()
        testCanvasCursor()
        testShapeEditing()
        testAnnotationIndices()
        testRepeatedEditorSessions()
        print("Screenshot editor: annotation indices, shape resizing/moving, cursor tracking, event passthrough, repeated sessions and window bounds passed")
    }

    static func testAnnotationIndices() {
        let rect = Stroke(kind: .rect, colorIndex: 0, points: [.zero, CGPoint(x: 0.2, y: 0.3)])
        let ellipse = Stroke(kind: .ellipse, colorIndex: 1,
                             points: [CGPoint(x: 0.9, y: 0.8), CGPoint(x: 0.6, y: 0.4)])
        let arrow = Stroke(kind: .arrow, colorIndex: 2, points: rect.points)
        let draft = Stroke(kind: .rect, colorIndex: 0, points: [.zero])
        let shapes = AnnotationIndexing.numberedShapes(in: [arrow, rect, draft, arrow, ellipse])
        precondition(shapes.map(\.number) == [1, 2], "Only completed shape outlines consume indices")
        precondition(shapes.map { $0.stroke.id } == [rect.id, ellipse.id])
        let undone = AnnotationIndexing.numberedShapes(in: [arrow, rect, arrow])
        precondition(undone.map(\.number) == [1])
        var moved = rect
        moved.points = ellipse.points
        precondition(AnnotationIndexing.numberedShapes(in: [moved, ellipse]).map(\.number) == [1, 2],
                     "Changing shape geometry must preserve reference numbers")

        let size = CGSize(width: 400, height: 300)
        for number in [1, 12, 123] {
            for point in [CGPoint.zero, CGPoint(x: 399, y: 299), CGPoint(x: 100, y: 100)] {
                let bounds = CGRect(origin: point, size: CGSize(width: 1, height: 1))
                let badge = AnnotationIndexing.badgeRect(for: bounds, number: number,
                                                        canvasSize: size, drawingScale: 1)
                precondition(CGRect(origin: .zero, size: size).contains(badge),
                             "Corner indices must stay inside the exported image, even at its edges")
                precondition(badge.height == 16, "Indices must stay small in the editor")
                let exported = AnnotationIndexing.badgeRect(
                    for: CGRect(x: point.x * 2, y: point.y * 2, width: 2, height: 2), number: number,
                    canvasSize: CGSize(width: 800, height: 600), drawingScale: 2)
                precondition(exported == CGRect(x: badge.minX * 2, y: badge.minY * 2,
                                                width: badge.width * 2, height: badge.height * 2),
                             "Export must preserve the preview's index size and placement relative to the image")
            }
        }
    }

    static func testShapeEditing() {
        let size = CGSize(width: 1000, height: 500)
        for kind in [Stroke.Kind.rect, .ellipse] {
            // Include intermediate drag points and a drag drawn from bottom-right to top-left.
            let original = Stroke(kind: kind, colorIndex: 2,
                                  points: [CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.6, y: 0.6),
                                           CGPoint(x: 0.2, y: 0.2)])
            let bounds = CGRect(x: 200, y: 100, width: 600, height: 300)
            for handle in AnnotationShapeEditing.Handle.allCases {
                let start = handle.point(in: CGRect(points: original.points))
                let screenPoint = handle.point(in: bounds)
                let target = AnnotationShapeEditing.hit(at: screenPoint, size: size,
                                                        strokes: [original], selected: original.id)!
                precondition(target.id == original.id && target.handle == handle)
                let session = AnnotationShapeEditing.Session(target: target, original: original, start: start)
                let end = CGPoint(x: start.x - CGFloat(handle.horizontal) * 0.1,
                                  y: start.y - CGFloat(handle.vertical) * 0.1)
                let smaller = AnnotationShapeEditing.updated(session, to: end, size: size)
                let rect = CGRect(points: smaller.points)
                precondition(abs(rect.width - (handle.horizontal == 0 ? 0.6 : 0.5)) < 0.000001)
                precondition(abs(rect.height - (handle.vertical == 0 ? 0.6 : 0.5)) < 0.000001)
                if handle.horizontal <= 0 { precondition(abs(rect.maxX - 0.8) < 0.000001) }
                if handle.horizontal >= 0 { precondition(abs(rect.minX - 0.2) < 0.000001) }
                if handle.vertical <= 0 { precondition(abs(rect.maxY - 0.8) < 0.000001) }
                if handle.vertical >= 0 { precondition(abs(rect.minY - 0.2) < 0.000001) }
                precondition(smaller.id == original.id && smaller.kind == original.kind)
                precondition(smaller.colorIndex == original.colorIndex && smaller.points.count == 2)
                precondition(AnnotationShapeEditing.updated(session, to: end, size: size).points == smaller.points,
                             "Drag updates must always use the starting snapshot")
                let crossed = AnnotationShapeEditing.updated(session,
                    to: CGPoint(x: start.x - CGFloat(handle.horizontal) * 2,
                                y: start.y - CGFloat(handle.vertical) * 2), size: size)
                let crossedBounds = CGRect(points: crossed.points)
                precondition(crossedBounds.width >= 0.004 - 0.000001 && crossedBounds.height >= 0.008 - 0.000001,
                             "Dragging past the opposite edge must retain visible dimensions")
                precondition(CGRect(x: 0, y: 0, width: 1, height: 1).contains(crossedBounds))
            }
            let move = AnnotationShapeEditing.Session(target: .init(id: original.id, handle: nil),
                                                       original: original, start: CGPoint(x: 0.5, y: 0.5))
            let moved = CGRect(points: AnnotationShapeEditing.updated(move, to: CGPoint(x: 2, y: -2), size: size).points)
            precondition(abs(moved.maxX - 1) < 0.000001 && abs(moved.minY) < 0.000001)
            precondition(abs(moved.width - 0.6) < 0.000001 && abs(moved.height - 0.6) < 0.000001)
            let edge = CGPoint(x: 500, y: 100)
            precondition(AnnotationShapeEditing.hit(at: edge, size: size, strokes: [original], selected: nil)?.id == original.id)
            precondition(AnnotationShapeEditing.hit(at: CGPoint(x: 500, y: 250), size: size,
                                                    strokes: [original], selected: nil) == nil)
            precondition(AnnotationShapeEditing.hit(at: CGPoint(x: 500, y: 250), size: size,
                                                    strokes: [original], selected: original.id)?.handle == nil)
        }
        let pen = Stroke(kind: .pen, colorIndex: 0, points: [.zero, CGPoint(x: 1, y: 1)])
        precondition(AnnotationShapeEditing.hit(at: .zero, size: size, strokes: [pen], selected: pen.id) == nil)
    }

    @MainActor static func testCanvasCursor() {
        for tool in EditorTool.allCases {
            precondition(tool.cursor === (tool == .text ? NSCursor.iBeam : NSCursor.crosshair))
        }
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); NSCursor.arrow.set() }
        let view = EditorCursorRegion.CursorView(cursor: .crosshair)
        view.frame = CGRect(x: 20, y: 20, width: 200, height: 100)
        window.contentView!.addSubview(view)
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        precondition(view.trackingAreas.count == 1, "Layout must not accumulate tracking areas")
        let options = view.trackingAreas[0].options
        precondition(options.contains([.inVisibleRect, .activeInKeyWindow, .cursorUpdate,
                                       .mouseMoved, .mouseEnteredAndExited, .enabledDuringMouseDrag]))
        precondition(view.hitTest(NSPoint(x: 40, y: 40)) == nil,
                     "Cursor tracking must not intercept annotation or text input")
        let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: 40, y: 40),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        view.mouseEntered(with: enter)
        precondition(NSCursor.current === NSCursor.crosshair, "Entering the image must show a crosshair")
        NSCursor.arrow.set() // Simulate the hosting view overriding the cursor.
        view.cursorUpdate(with: enter)
        precondition(NSCursor.current === NSCursor.crosshair)
        NSCursor.arrow.set()
        view.mouseMoved(with: enter)
        precondition(NSCursor.current === NSCursor.crosshair, "Moving must retain the drawing cursor")
        view.cursor = .iBeam
        view.cursorUpdate(with: enter)
        precondition(NSCursor.current === NSCursor.iBeam, "Text placement must show an I-beam")
        view.mouseExited(with: enter)
        precondition(NSCursor.current === NSCursor.arrow, "Leaving the image must restore the arrow")
        view.frame.size = CGSize(width: 100, height: 50)
        view.updateTrackingAreas()
        precondition(view.trackingAreas.count == 1)
        view.cursor = .crosshair
        view.mouseEntered(with: enter)
        view.removeFromSuperview()
        precondition(NSCursor.current === NSCursor.arrow, "Closing the canvas must restore the arrow")
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
