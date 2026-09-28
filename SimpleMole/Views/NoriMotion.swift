import Foundation

/// Semantic states shared by native callers and the distributable SVG names.
enum NoriMood: String, CaseIterable {
    case idle, blink, working, bored, success, attention
}

struct NoriPose: Equatable {
    var scaleX: Double = 1
    var scaleY: Double = 1
    var offsetY: Double = 0
    var rotation: Double = 0
    var eyeOpen: Double = 1
    var gazeX: Double = 0
    var gazeY: Double = 0
    var confetti: Double = 0
}

/// Pure, bounded motion: no timers, random states, perpetual success loops or I/O.
/// Dimensions use the same 256-point coordinate system as Nori.svg.
enum NoriMotion {
    static let celebrationDuration: TimeInterval = 1.4

    static func pose(for mood: NoriMood, elapsed: TimeInterval,
                     reduceMotion: Bool = false) -> NoriPose {
        guard !reduceMotion, elapsed.isFinite else { return NoriPose() }
        let t = max(0, elapsed)
        var pose = NoriPose()
        switch mood {
        case .idle:
            let breath = (1 - cos(t * .pi / 3)) / 2
            pose.scaleX += breath * 0.012
            pose.scaleY -= breath * 0.012
            pose.eyeOpen = blink(at: t, period: 6)
        case .blink:
            pose.eyeOpen = blink(at: t, period: 3.8)
        case .working:
            let phase = t.truncatingRemainder(dividingBy: 1.35) / 1.35
            let squash = interpolate(phase, [(0, 0), (0.25, 0.055), (0.55, -0.04), (0.8, 0.025), (1, 0)])
            pose.scaleX += squash
            pose.scaleY -= squash
            pose.offsetY = interpolate(phase, [(0, 0), (0.25, 0), (0.55, -3), (0.8, 0), (1, 0)])
            pose.gazeX = -4 * cos(t * .pi * 2 / 2.7)
            pose.eyeOpen = blink(at: t, period: 5.4)
        case .bored:
            let phase = t.truncatingRemainder(dividingBy: 8) / 8
            pose.rotation = interpolate(phase, [(0, 0), (0.2, 0), (0.4, -5), (0.6, -5), (0.8, 3), (1, 0)])
            let squash = interpolate(phase, [(0, 0), (0.2, 0), (0.4, 0.03), (0.6, 0.03), (0.8, -0.01), (1, 0)])
            pose.scaleX += squash
            pose.scaleY -= squash
            pose.gazeX = interpolate(phase, [(0, 0), (0.2, 0), (0.4, -7), (0.6, -7), (0.8, 5), (1, 0)])
            pose.gazeY = interpolate(phase, [(0, 0), (0.2, 0), (0.4, 2), (0.6, 2), (0.8, 0), (1, 0)])
            pose.eyeOpen = blink(at: t, period: 7)
        case .success:
            guard t < celebrationDuration else { return pose }
            let phase = t / celebrationDuration
            let squash = interpolate(phase, [(0, 0), (0.15, 0.12), (0.38, -0.035), (0.65, 0.07), (0.82, -0.02), (1, 0)])
            pose.scaleX += squash
            pose.scaleY -= squash
            pose.offsetY = interpolate(phase, [(0, 0), (0.15, 0), (0.38, -3), (0.65, 0), (1, 0)])
            pose.confetti = phase > 0.12 ? (phase - 0.12) / 0.88 : 0
        case .attention:
            guard t < 0.8 else { return pose }
            pose.rotation = interpolate(t / 0.8, [(0, 0), (0.25, -5), (0.6, 5), (1, 0)])
        }
        return pose
    }

    private static func blink(at time: Double, period: Double) -> Double {
        let phase = time.truncatingRemainder(dividingBy: period) / period
        return interpolate(phase, [(0, 1), (0.43, 1), (0.46, 0.08), (0.49, 1), (1, 1)])
    }

    private static func interpolate(_ t: Double, _ frames: [(Double, Double)]) -> Double {
        for i in 1..<frames.count where t <= frames[i].0 {
            let a = frames[i - 1], b = frames[i]
            let linear = min(1, max(0, (t - a.0) / (b.0 - a.0)))
            let smooth = linear * linear * (3 - 2 * linear)
            return a.1 + (b.1 - a.1) * smooth
        }
        return frames.last?.1 ?? 0
    }
}

/// A stale success flag from a previous scan must never celebrate another task's
/// cancellation/failure. Arm only after this scan reports its incomplete state.
struct NoriScanFeedback {
    private var wasScanning = false
    private var observedIncomplete = false

    mutating func update(scanning: Bool, succeeded: Bool) -> Bool {
        if scanning {
            if !wasScanning { observedIncomplete = false }
            if !succeeded { observedIncomplete = true }
        }
        let celebrate = wasScanning && !scanning && succeeded && observedIncomplete
        if !scanning { observedIncomplete = false }
        wasScanning = scanning
        return celebrate
    }
}

/// Celebrate confirmed work only; partial/failed operations get attention feedback.
enum NoriCleanupFeedback {
    static func mood(removed: Int, skipped: Int, failed: Int) -> NoriMood {
        if failed > 0 || skipped > 0 { return .attention }
        return removed > 0 ? .success : .idle
    }
}
