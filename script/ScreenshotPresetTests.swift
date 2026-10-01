import AppKit
import Foundation

@main
struct ScreenshotPresetTests {
    static func main() {
        testBuiltInPresets()
        testCaptureRatios()
        testPlainLayoutIsIdentity()
        testWindowLayoutAddsChromeAndPadding()
        testPhoneShellLayout()
        testTabletShellLayout()
        testPhoneShellCropsLandscapeSource()
        testPhoneShellWithoutPaddingKeepsButtons()
        testAspectNeverCropsContent()
        testChromeScalesWithResolution()
        testCompositionSelectionResetsOverrides()
        testPreferencesRoundTrip()
        testEditorMigratesLegacyDevicePreset()
        testEditorPreservesBackgroundAndCaptureFrame()
        testEncoderFormats()
        print("screenshot preset tests ok")
    }

    /// 按比例截取的内置比例：互不相同，phone 与相框用的屏幕比例一致。
    static func testCaptureRatios() {
        precondition(CaptureRatio.allCases.count >= 5, "expected the built-in social ratios")
        precondition(Set(CaptureRatio.allCases.map { Int($0.ratio * 10_000) }).count
                     == CaptureRatio.allCases.count, "capture ratios must be distinct")
        precondition(abs(CaptureRatio.phone.ratio - PresetLayout.phoneScreenRatio) < 0.0001,
                     "phone capture ratio must match the phone shell screen ratio")
        precondition(abs(CaptureRatio.square.ratio - 1) < 0.0001
                     && abs(CaptureRatio.wide.ratio - 16.0 / 9.0) < 0.0001
                     && abs(CaptureRatio.post.ratio - 4.0 / 5.0) < 0.0001
                     && abs(CaptureRatio.story.ratio - 9.0 / 16.0) < 0.0001,
                     "social capture ratios are wrong")
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

    static func testTabletShellLayout() {
        precondition(CaptureRatio.tablet.frameStyle == .ipad)
        precondition(CaptureRatio.phone.frameStyle == .iphone)
        let composition = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "plain")!,
                                                frame: .ipad, aspect: .free)
        let layout = PresetLayout.compute(contentSize: CGSize(width: 900, height: 1200),
                                          composition: composition)
        precondition(layout.contentRect.size == CGSize(width: 900, height: 1200),
                     "iPad capture must retain the full selected image")
        precondition(layout.bezelTop == layout.bezelSide && layout.bezelBottom == layout.bezelSide)
        precondition(layout.islandRect == .zero, "iPad must not have a Dynamic Island")
        precondition(layout.cardRect.contains(layout.contentRect))
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
        // 屏幕固定为手机比例：600×1200 比屏幕更宽，宽度被居中剪裁为 554、高度完整保留。
        precondition(layout.contentSourceSize == CGSize(width: 600, height: 1200),
                     "source size must stay uncropped for cover rendering")
        precondition(layout.contentRect.size == CGSize(width: 554, height: 1200),
                     "screen must crop the wider source to the phone ratio, got \(layout.contentRect.size)")
        precondition(abs(layout.contentRect.width / layout.contentRect.height
                         - PresetLayout.phoneScreenRatio) < 0.001,
                     "screen aspect must match the phone ratio")
        // chromeScale = 554/1000 = 0.554；窄边框对齐真机（26/68/26 每 1000pt 宽）。
        precondition(layout.bezelSide == 14 && layout.bezelTop == 38 && layout.bezelBottom == 14,
                     "bezel must scale with the screen width, got \(layout.bezelSide)/\(layout.bezelTop)")
        precondition(layout.cardRect.size == CGSize(width: 582, height: 1252),
                     "body must be screen plus bezels, got \(layout.cardRect.size)")
        precondition(layout.contentRect == CGRect(x: layout.cardRect.minX + 14,
                                                  y: layout.cardRect.minY + 38,
                                                  width: 554, height: 1200),
                     "screen must sit inside the bezels, got \(layout.contentRect)")
        precondition(layout.padding == 28, "5% padding of 554 must be 28, got \(layout.padding)")
        precondition(layout.canvasSize == CGSize(width: 638, height: 1308),
                     "canvas must be body + padding, got \(layout.canvasSize)")
        precondition(layout.islandRect.midX == layout.cardRect.midX
                     && layout.islandRect.maxY <= layout.contentRect.minY,
                     "island must be centred inside the top bezel without covering content")
        precondition(layout.bodyCornerRadius > layout.screenCornerRadius && layout.screenCornerRadius > 0,
                     "screen corners must be tighter than the body corners")
        precondition(layout.titleBarHeight == 0, "phone shell has no title bar")
    }

    /// 横版截图套 iPhone 壳：屏幕保持手机比例，宽边被居中剪裁、内容不缩放不变形。
    static func testPhoneShellCropsLandscapeSource() {
        var composition = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "aurora")!)
        composition.frame = .iphone
        let layout = PresetLayout.compute(contentSize: CGSize(width: 1200, height: 800),
                                          composition: composition)
        precondition(layout.contentSourceSize == CGSize(width: 1200, height: 800),
                     "source size must stay uncropped")
        precondition(layout.contentRect.size == CGSize(width: 369, height: 800),
                     "landscape source must crop width to the phone ratio, got \(layout.contentRect.size)")
        precondition(abs(layout.contentRect.width / layout.contentRect.height
                         - PresetLayout.phoneScreenRatio) < 0.001,
                     "cropped screen must keep the phone ratio")
        // 比 9:19.5 更“瘦”的截图：宽度完整保留、高度被剪裁。
        let tall = PresetLayout.compute(contentSize: CGSize(width: 400, height: 1000),
                                        composition: composition)
        precondition(tall.contentRect.size == CGSize(width: 400, height: 867),
                     "skinny source must crop height instead, got \(tall.contentRect.size)")
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
                if frame == .iphone || frame == .ipad {
                    // iPhone 外壳：屏幕固定为手机比例，内容按 cover 居中剪裁，不缩放。
                    precondition(layout.contentSourceSize == content,
                                 "\(frame)/\(aspect) must keep the uncropped source size")
                    precondition(layout.contentRect.width <= content.width
                                 && layout.contentRect.height <= content.height,
                                 "\(frame)/\(aspect) screen must not exceed the source")
                    precondition(abs(layout.contentRect.width / layout.contentRect.height
                                     - (frame == .ipad ? PresetLayout.tabletScreenRatio : PresetLayout.phoneScreenRatio)) < 0.001,
                                 "\(frame)/\(aspect) screen ratio must stay a phone ratio")
                } else {
                    precondition(layout.contentRect.size == content, "\(frame)/\(aspect) must never resize the content")
                }
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
        let suite = "com.nori.screenshot-tests.\(UUID().uuidString)"
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

    static func testEditorMigratesLegacyDevicePreset() {
        let suite = "com.nori.screenshot-migration-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("no defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = ScreenshotPreferences(defaults: defaults)
        let legacy = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "iphone")!,
                                           frame: .iphone, aspect: .story9x16)
        let plain = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "plain")!)
        let captureFrames: [PresetFrameStyle?] = [nil, PresetFrameStyle.none, .iphone, .ipad]
        for captureFrame in captureFrames {
            prefs.save(legacy)
            let loaded = prefs.loadEditorComposition(captureFrame: captureFrame)
            precondition(loaded.preset.id == "plain" && loaded.aspect == .free,
                         "legacy device preset must migrate to the visible transparent preset")
            precondition(loaded.frame == (captureFrame ?? .none),
                         "migration must retain the frame chosen for this capture")
            precondition(ScreenshotPreset.editorPresets.contains { $0.id == loaded.preset.id },
                         "the migrated selection must appear in the editor")
            precondition(prefs.loadComposition() == plain,
                         "migration must persist the visible preset instead of the hidden device preset")
            precondition(prefs.loadEditorComposition(captureFrame: nil) == plain,
                         "the next ordinary capture must load the migrated selection")
        }
    }

    static func testEditorPreservesBackgroundAndCaptureFrame() {
        let suite = "com.nori.screenshot-editor-preferences-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("no defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = ScreenshotPreferences(defaults: defaults)
        let composition = ScreenshotComposition(preset: ScreenshotPreset.builtIn(id: "aurora")!,
                                                frame: .macWindow, aspect: .square)
        prefs.save(composition)
        precondition(prefs.loadEditorComposition(captureFrame: nil) == composition,
                     "ordinary capture must retain a visible saved composition")
        for frame in [PresetFrameStyle.none, .iphone, .ipad] {
            let loaded = prefs.loadEditorComposition(captureFrame: frame)
            precondition(loaded.preset == composition.preset && loaded.frame == frame && loaded.aspect == .free,
                         "aspect capture must retain the background and use the selected capture frame")
            precondition(prefs.loadComposition() == composition,
                         "a per-capture frame must not rewrite the saved background composition")
        }
        var previousDeviceCapture = composition
        previousDeviceCapture.frame = .ipad
        prefs.save(previousDeviceCapture)
        let ordinary = prefs.loadEditorComposition(captureFrame: nil)
        precondition(ordinary.preset == composition.preset && ordinary.frame == .none,
                     "ordinary capture must not inherit a device frame from an earlier aspect capture")
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
