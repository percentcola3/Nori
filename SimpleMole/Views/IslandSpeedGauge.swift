import SwiftUI
import Darwin

/// Log-scaled speedometer for the island network panel: 240° arc with the gap
/// at the bottom, hairline track, success-coloured progress and a needle.
struct IslandSpeedGauge: View, Animatable {
    /// Current throughput in Mbps.
    var value: Double
    let caption: String
    var detail: String? = nil

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    private static let startDegrees: Double = 150
    private static let sweepDegrees: Double = 240
    private static let maxMbps: Double = 1000
    private static let ticks: [Double] = [0, 1, 5, 10, 50, 100, 500, 1000]

    private var fraction: Double {
        Darwin.log10(1 + min(max(value, 0), Self.maxMbps)) / Darwin.log10(1 + Self.maxMbps)
    }

    private var formattedValue: String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private static func fraction(of v: Double) -> Double {
        Darwin.log10(1 + min(max(v, 0), maxMbps)) / Darwin.log10(1 + maxMbps)
    }

    private static func point(_ center: CGPoint, _ radius: CGFloat, _ degrees: Double) -> CGPoint {
        let rad = degrees * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(Darwin.cos(rad)),
                       y: center.y + radius * CGFloat(Darwin.sin(rad)))
    }

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width / 2 - 24, size.height - 60, 80)
            guard radius > 30 else { return }
            let center = CGPoint(x: size.width / 2, y: radius + 14)

            var track = Path()
            track.addArc(center: center, radius: radius,
                         startAngle: .degrees(Self.startDegrees),
                         endAngle: .degrees(Self.startDegrees + Self.sweepDegrees),
                         clockwise: false)
            context.stroke(track, with: .color(.hairline),
                           style: StrokeStyle(lineWidth: 7, lineCap: .round))

            if fraction > 0.001 {
                var progress = Path()
                progress.addArc(center: center, radius: radius,
                                startAngle: .degrees(Self.startDegrees),
                                endAngle: .degrees(Self.startDegrees + Self.sweepDegrees * fraction),
                                clockwise: false)
                context.stroke(progress, with: .color(.success),
                               style: StrokeStyle(lineWidth: 7, lineCap: .round))
            }

            for tick in Self.ticks {
                let angle = Self.startDegrees + Self.sweepDegrees * Self.fraction(of: tick)
                var mark = Path()
                mark.move(to: Self.point(center, radius - 6, angle))
                mark.addLine(to: Self.point(center, radius - 1, angle))
                context.stroke(mark, with: .color(.hairline), lineWidth: 1)
                let label = context.resolve(
                    Text(tick.truncatingRemainder(dividingBy: 1) == 0
                         ? String(format: "%.0f", tick) : String(format: "%g", tick))
                        .font(.system(size: 8)).foregroundColor(.secondary))
                context.draw(label, at: Self.point(center, radius + 14, angle), anchor: .center)
            }

            let needleAngle = Self.startDegrees + Self.sweepDegrees * fraction
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: Self.point(center, radius * 0.62, needleAngle))
            context.stroke(needle, with: .color(.primary),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5,
                                                width: 5, height: 5)), with: .color(.primary))

            let valueText = context.resolve(
                Text(formattedValue)
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()))
            context.draw(valueText, at: CGPoint(x: center.x, y: center.y + radius * 0.42), anchor: .center)
            let unitText = context.resolve(
                Text("Mbps").font(.system(size: 9)).foregroundColor(.secondary))
            context.draw(unitText, at: CGPoint(x: center.x, y: center.y + radius * 0.42 + 15), anchor: .center)
            let captionText = context.resolve(
                Text(caption).font(.system(size: 10)).foregroundColor(.secondary))
            context.draw(captionText, at: CGPoint(x: center.x, y: center.y + radius * 0.42 + 28), anchor: .center)
            if let detail {
                let detailText = context.resolve(
                    Text(detail).font(.system(size: 10)).foregroundColor(.secondary))
                context.draw(detailText, at: CGPoint(x: center.x, y: center.y + radius * 0.42 + 42), anchor: .center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue("\(formattedValue) Mbps")
    }
}
