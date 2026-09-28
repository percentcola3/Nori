import AppKit
import Foundation

@main
struct ScreenshotPresetTests {
    static func main() {
        testBuiltInPresets()
        testPlainLayoutIsIdentity()
        testWindowLayoutAddsChromeAndPadding()
        testPhoneShellLayout()
        testPhoneShellWithoutPaddingKeepsButtons()
        testAspectNeverCropsContent()
        testChromeScalesWithResolution()
        testCompositionSelectionResetsOverrides()
        testPreferencesRoundTrip()
        testEncoderFormats()
        print("screenshot preset tests ok")
    }

    static func testBuiltInPresets() {
        let presets = ScreenshotPreset.builtIn
        precondition(presets.count == 11, "expected 11 built-in presets, got \(presets.count)")
        precondition(presets.first?.id == "plain", "plain must be the first preset")
        precondition(Set(presets.map(\.id)).count == presets.count, "preset ids must be unique")
        precondition(ScreenshotPreset.builtIn(id: ScreenshotPreset.defaultID) != nil,
                     "default preset must exist")
        precondition(presets.contains { $0.frame == .iphone },
                     "an iPhone shell preset must exist")
        for preset in presets {
            if case .mesh(let colors) = preset.background {
                precondition(colors.count == 9, "mesh preset \(preset.id) needs 9 colors")
            }
        }
    }

    static func testPlainLayoutIsIdentity() {
        let plain = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "plain")!)
        precondition(plain.isPlain, "plain preset must be recognised as plain")
        let layout = PresetLayout.compute(contentSize: CGSize(width: 800, height: 500), composition: plain)
        precondition(layout.canvasSize == CGSize(width: 800, height: 500), "plain layout must not add padding")
        precondition(layout.contentRect == CGRect(x: 0, y: 0, width: 800, height: 500), "plain content must fill the canvas")
        precondition(layout.titleBarHeight == 0 && layout.cornerRadius == 0, "plain layout has no chrome")
    }

    static func testWindowLayoutAddsChromeAndPadding() {
        let aurora = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "aurora")!)
        let layout = PresetLayout.compute(contentSize: CGSize(width: 1000, height: 600), composition: aurora)
        precondition(layout.padding == 60, "6% padding of 1000 must be 60, got \(layout.padding)")
        precondition(layout.titleBarHeight == 30, "title bar at 1000pt must be 30, got \(layout.titleBarHeight)")
        precondition(layout.canvasSize == CGSize(width: 1120, height: 750),
                     "canvas must be content + title bar + padding, got \(layout.canvasSize)")
        precondition(layout.cardRect == CGRect(x: 60, y: 60, width: 1000, height: 630), "card rect mismatch \(layout.cardRect)")
        precondition(layout.contentRect == CGRect(x: 60, y: 90, width: 1000, height: 600), "content rect mismatch \(layout.contentRect)")
    }

    static func testPhoneShellLayout() {
        let composition = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "iphone")!)
        precondition(composition.preset.frame == .iphone && composition.frame == .iphone,
                     "iphone preset must default to the iphone frame")
        let layout = PresetLayout.compute(contentSize: CGSize(width: 600, height: 1200),
                                          composition: composition)
        // chromeScale = 600/1000 = 0.6
        precondition(layout.bezelSide == 33 && layout.bezelTop == 66 && layout.bezelBottom == 33,
                     "bezel must scale with content width, got \(layout.bezelSide)/\(layout.bezelTop)")
        precondition(layout.cardRect.size == CGSize(width: 666, height: 1299),
                     "body must be content plus bezels, got \(layout.cardRect.size)")
        precondition(layout.contentRect == CGRect(x: layout.cardRect.minX + 33,
                                                  y: layout.cardRect.minY + 66,
                                                  width: 600, height: 1200),
                     "content rect must sit inside the bezels, got \(layout.contentRect)")
        precondition(layout.padding == 30, "5% padding of 600 must be 30, got \(layout.padding)")
        precondition(layout.canvasSize == CGSize(width: 726, height: 1359),
                     "canvas must be body + padding, got \(layout.canvasSize)")
        precondition(layout.islandRect.midX == layout.cardRect.midX
                     && layout.islandRect.maxY <= layout.contentRect.minY,
                     "island must be centred inside the top bezel without covering content")
        precondition(layout.bodyCornerRadius > layout.screenCornerRadius && layout.screenCornerRadius > 0,
                     "screen corners must be tighter than the body corners")
        precondition(layout.titleBarHeight == 0, "phone shell has no title bar")
    }

    static func testPhoneShellWithoutPaddingKeepsButtons() {
        var composition = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "plain")!)
        composition.frame = .iphone
        let layout = PresetLayout.compute(contentSize: CGSize(width: 500, height: 1000),
                                          composition: composition)
        precondition(layout.buttonProtrusion > 0, "phone shell must have side buttons")
        precondition(layout.padding == layout.buttonProtrusion,
                     "zero-ratio padding must still cover the button protrusion, got \(layout.padding)")
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        precondition(canvas.contains(layout.cardRect), "body must stay inside the canvas")
        precondition(canvas.minX + layout.buttonProtrusion <= layout.cardRect.minX
                     && layout.cardRect.maxX + layout.buttonProtrusion <= canvas.maxX,
                     "canvas must leave room for the protruding buttons on both sides")
    }

    static func testAspectNeverCropsContent() {
        let content = CGSize(width: 1000, height: 600)
        for frame in PresetFrameStyle.allCases {
            for aspect in PresetAspect.allCases {
                let composition = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "ocean")!,
                                                        frame: frame, aspect: aspect)
                let layout = PresetLayout.compute(contentSize: content, composition: composition)
                let canvas = CGRect(origin: .zero, size: layout.canvasSize)
                precondition(canvas.contains(layout.cardRect), "\(frame)/\(aspect) must keep the card inside the canvas")
                precondition(layout.contentRect.size == content, "\(frame)/\(aspect) must never resize the content")
                if let ratio = aspect.ratio {
                    let actual = layout.canvasSize.width / layout.canvasSize.height
                    precondition(abs(actual - ratio) < 0.01, "\(frame)/\(aspect) ratio \(actual) != \(ratio)")
                }
                // centred
                precondition(abs(layout.cardRect.midX - layout.canvasSize.width / 2) <= 1, "\(frame)/\(aspect) card not centred horizontally")
                precondition(abs(layout.cardRect.midY - layout.canvasSize.height / 2) <= 1, "\(frame)/\(aspect) card not centred vertically")
            }
        }
    }

    static func testChromeScalesWithResolution() {
        let composition = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "graphite")!)
        let small = PresetLayout.compute(contentSize: CGSize(width: 500, height: 300), composition: composition)
        let large = PresetLayout.compute(contentSize: CGSize(width: 2000, height: 1200), composition: composition)
        precondition(small.chromeScale == 0.5 && large.chromeScale == 2, "chrome scale must follow width")
        precondition(large.titleBarHeight == 4 * small.titleBarHeight, "title bar must scale with resolution")
        precondition(large.padding == 4 * small.padding, "padding must scale with resolution")
    }

    static func testCompositionSelectionResetsOverrides() {
        var composition = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "aurora")!)
        composition.frame = .roundedCard
        composition.aspect = .square
        composition.select(ScreenshotPreset.builtIn(id: "paper")!)
        precondition(composition.frame == .roundedCard && composition.aspect == .free,
                     "selecting a preset must restore its default frame and aspect")
        composition.select(ScreenshotPreset.builtIn(id: "plain")!)
        precondition(composition.isPlain, "plain selection must be plain again")
        composition.frame = .macWindow
        precondition(!composition.isPlain, "plain + window frame is no longer plain")
    }

    static func testPreferencesRoundTrip() {
        let suite = "com.forgesweep.screenshot-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("no defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = ScreenshotPreferences(defaults: defaults)
        precondition(prefs.loadComposition().preset.id == ScreenshotPreset.defaultID, "first launch uses the default preset")
        precondition(prefs.loadExportOptions() == ScreenshotExportOptions(), "first launch uses default export options")

        let composition = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "midnight")!,
                                                frame: .roundedCard, aspect: .story9x16)
        prefs.save(composition)
        precondition(prefs.loadComposition() == composition, "composition must round-trip")

        var options = ScreenshotExportOptions()
        options.format = .jpeg
        options.scale = .retina
        prefs.save(options)
        let loaded = prefs.loadExportOptions()
        precondition(loaded.format == .jpeg && loaded.scale == .retina, "export options must round-trip")

        defaults.set("does-not-exist", forKey: "screenshot.preset")
        precondition(prefs.loadComposition().preset.id == ScreenshotPreset.defaultID, "unknown preset falls back to default")
    }

    static func testEncoderFormats() {
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            NSColor.systemBlue.setFill()
            NSRect(x: 10, y: 5, width: 20, height: 20).fill()
            return true
        }
        guard let png = ScreenshotExporter.encode(image, options: ScreenshotExportOptions(format: .png)) else {
            fatalError("png encode failed")
        }
        precondition(png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "png signature missing")
        guard let jpeg = ScreenshotExporter.encode(image, options: ScreenshotExportOptions(format: .jpeg)) else {
            fatalError("jpeg encode failed")
        }
        precondition(jpeg.starts(with: [0xFF, 0xD8]), "jpeg signature missing")
        guard let decoded = NSBitmapImageRep(data: jpeg) else { fatalError("jpeg not decodable") }
        precondition(!decoded.hasAlpha, "jpeg must be flattened without alpha")
        let corner = decoded.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)
        precondition((corner?.redComponent ?? 0) > 0.9 && (corner?.blueComponent ?? 0) > 0.9,
                     "transparent areas must be flattened onto white for JPEG")

        let name = ScreenshotExporter.defaultFileName(format: .jpeg, date: Date(timeIntervalSince1970: 0))
        precondition(name.hasPrefix("Screenshot-") && name.hasSuffix(".jpeg"), "unexpected file name \(name)")
    }
}
