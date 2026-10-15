import SwiftUI

/// Compact occupancy dial. The value and caption carry the meaning; the arc
/// adds a quick visual comparison without a second progress row.
struct IslandMetricGauge: View {
    let title: String
    let value: String
    let progress: Double
    let tint: Color
    var highlighted = false
    var busy = false
    var reveal: CGFloat = 1

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.hairline, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75 * min(1, max(0, progress)) * reveal)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(value)
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: 30)
                        .contentTransition(.numericText())
                }
            }
            .frame(width: 36, height: 36)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(highlighted ? Color.accentText : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}
