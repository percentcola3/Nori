import AppKit

@main
struct NoriBrandTests {
    static func main() throws {
        // Accessibility always produces a stable, open-eyed pose, including mid-celebration.
        for mood in NoriMood.allCases {
            for time in [0.0, 0.3, 0.7, 1.4, 4.6, 8.0, 180.0, Double.infinity, Double.nan] {
                precondition(NoriMotion.pose(for: mood, elapsed: time, reduceMotion: true) == NoriPose())
            }
            for frame in 0..<2400 {
                let p = NoriMotion.pose(for: mood, elapsed: Double(frame) / 60)
                precondition((0.87...1.13).contains(p.scaleX) && (0.87...1.13).contains(p.scaleY))
                precondition((-22.01...0.01).contains(p.offsetY))
                precondition((-5.01...5.01).contains(p.rotation))
                precondition((0.079...1.001).contains(p.eyeOpen))
                precondition((0...1).contains(p.confetti))
                // No deformations may move the mascot beyond its own 256px canvas.
                let transform = CGAffineTransform(translationX: 132, y: 218 + p.offsetY)
                    .rotated(by: p.rotation * .pi / 180).scaledBy(x: p.scaleX, y: p.scaleY)
                    .translatedBy(x: -132, y: -218)
                var matrix = transform
                let bounds = NoriGeometry.bodyPath().copy(using: &matrix)!.boundingBoxOfPath
                precondition(CGRect(x: 0, y: 0, width: 256, height: 256).contains(bounds), "clipped \(mood) at \(frame): \(bounds)")
            }
        }
        for time in [1.4, 2.0, 20.0] {
            precondition(NoriMotion.pose(for: .success, elapsed: time) == NoriPose(), "success must settle once")
            precondition(NoriMotion.pose(for: .attention, elapsed: time) == NoriPose(), "attention must settle once")
        }
        precondition(NoriMotion.pose(for: .working, elapsed: 0.74) != NoriPose())
        precondition(NoriMotion.pose(for: .blink, elapsed: 3.8 * 0.46).eyeOpen < 0.1)
        precondition(NoriMotion.pose(for: .success, elapsed: 0.7).confetti > 0)
        var feedback = NoriScanFeedback()
        precondition(!feedback.update(scanning: false, succeeded: true))
        precondition(!feedback.update(scanning: true, succeeded: true))
        precondition(!feedback.update(scanning: false, succeeded: true), "stale completion must not celebrate")
        precondition(!feedback.update(scanning: true, succeeded: false))
        precondition(!feedback.update(scanning: false, succeeded: false), "failed/cancelled scan must not celebrate")
        precondition(!feedback.update(scanning: true, succeeded: false))
        precondition(feedback.update(scanning: false, succeeded: true), "successful scan must celebrate")
        precondition(!feedback.update(scanning: false, succeeded: true), "success must not replay on re-render")
        precondition(NoriCleanupFeedback.mood(removed: 4, skipped: 0, failed: 0) == .success)
        precondition(NoriCleanupFeedback.mood(removed: 0, skipped: 0, failed: 0) == .idle)
        precondition(NoriCleanupFeedback.mood(removed: 4, skipped: 1, failed: 0) == .attention)
        precondition(NoriCleanupFeedback.mood(removed: 4, skipped: 0, failed: 1) == .attention)
        let support = URL(fileURLWithPath: CommandLine.arguments[1])
        for (name, dimension) in [("AppIcon-1024.png",1024), ("HeaderBrandIcon.png",256),
                                  ("MenuBarIconTemplate.png",18), ("MenuBarIconTemplate@2x.png",36)] {
            let data = try Data(contentsOf: support.appendingPathComponent(name))
            let image = NSBitmapImageRep(data: data)!
            precondition(image.pixelsWide == dimension && image.pixelsHigh == dimension)
            precondition(image.colorAt(x: 0, y: 0)!.alphaComponent == 0, "transparent padding missing")
            if name.hasPrefix("MenuBar") {
                var opaque = 0
                for y in 0..<dimension { for x in 0..<dimension {
                    let c = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    if c.alphaComponent > 0 {
                        precondition(c.redComponent == 0 && c.greenComponent == 0 && c.blueComponent == 0, "template must contain only black and alpha")
                        opaque += 1
                    }
                }}
                precondition(opaque > dimension * dimension / 3)
                for eye in NoriGeometry.eyes {
                    precondition(image.colorAt(x: Int(eye.x / 256 * Double(dimension)),
                                               y: Int(eye.y / 256 * Double(dimension)))!.alphaComponent < 0.5,
                                 "template eye cutout missing")
                }
            }
        }
        let info = NSDictionary(contentsOf: support.appendingPathComponent("Info.plist"))!
        precondition(info["CFBundleIdentifier"] as? String == "com.forgesweep.app", "permission identity changed")
        precondition(info["CFBundleExecutable"] as? String == "ForgeSweep", "legacy executable contract changed")
        print("Nori: bounded motion, single-shot feedback, reduced motion, vector bounds, raster sizes, template alpha and stable identity passed")
    }
}
