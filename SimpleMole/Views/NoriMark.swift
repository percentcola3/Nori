import SwiftUI

/// 标题栏与进度位共用的四种语境。
/// 静态、无聊、眨眼、旧庆祝和旧提醒都收进待机；成功和失败用独立角标，不再换一张看起来一样的脸。
enum NoriMood: Equatable, Hashable {
    case idle
    case working
    case success
    case failure
}

enum NoriResult: Equatable {
    case quiet
    case success
    case failure
}

/// 工作中的道具。同一套轻动作，换道具即可对应不同页面。
enum NoriWork: String, CaseIterable, Equatable {
    case sweep
    case search
    case box
    case wrench
    case gauge
    case terminal
    case pulse
    case plug
    case wave
    case photo
    case clip

    var tint: Color {
        switch self {
        case .sweep: return Color(red: 0.08, green: 0.62, blue: 0.55)
        case .search: return Color(red: 0.18, green: 0.55, blue: 0.86)
        case .box: return Color(red: 0.90, green: 0.52, blue: 0.16)
        case .wrench: return Color(red: 0.36, green: 0.48, blue: 0.92)
        case .gauge: return Color(red: 0.16, green: 0.62, blue: 0.42)
        case .terminal: return Color(red: 0.22, green: 0.58, blue: 0.32)
        case .pulse: return Color(red: 0.86, green: 0.32, blue: 0.38)
        case .plug: return Color(red: 0.48, green: 0.36, blue: 0.86)
        case .wave: return Color(red: 0.16, green: 0.58, blue: 0.82)
        case .photo: return Color(red: 0.86, green: 0.40, blue: 0.58)
        case .clip: return Color(red: 0.78, green: 0.58, blue: 0.12)
        }
    }
}

struct NoriWorkBadge: View {
    let work: NoriWork
    let size: CGFloat
    var animated: Bool

    var body: some View {
        let badge = size * 0.48
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    mark(badge: badge)
                        .offset(y: CGFloat(sin(time * 5.2)) * badge * 0.14)
                        .rotationEffect(.degrees(sin(time * 2.6) * 8))
                }
            } else {
                mark(badge: badge)
            }
        }
        .accessibilityHidden(true)
    }

    private func mark(badge: CGFloat) -> some View {
        ZStack {
            Circle().fill(work.tint)
            NoriWorkGlyph(work: work)
                .stroke(Color.white,
                        style: StrokeStyle(lineWidth: max(1.15, badge * 0.13),
                                           lineCap: .round,
                                           lineJoin: .round))
                .padding(badge * 0.24)
        }
        .frame(width: badge, height: badge)
        .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)
    }
}

struct NoriResultBadge: View {
    let mood: NoriMood
    let size: CGFloat
    var animated: Bool

    private var tint: Color {
        mood == .failure ? Color.danger : Color.success
    }

    var body: some View {
        let badge = size * 0.46
        Group {
            if animated, mood == .failure {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    let pulse = 1 + 0.08 * CGFloat(sin(time * 7.5))
                    mark(badge: badge).scaleEffect(pulse)
                }
            } else {
                mark(badge: badge)
            }
        }
        .accessibilityHidden(true)
    }

    private func mark(badge: CGFloat) -> some View {
        ZStack {
            Circle().fill(tint)
            NoriResultGlyph(failure: mood == .failure)
                .stroke(Color.white,
                        style: StrokeStyle(lineWidth: max(1.2, badge * 0.14),
                                           lineCap: .round,
                                           lineJoin: .round))
                .padding(badge * 0.26)
        }
        .frame(width: badge, height: badge)
        .shadow(color: tint.opacity(0.45), radius: animated && mood == .failure ? 3 : 1, y: 0.5)
    }
}

private struct NoriWorkGlyph: Shape {
    var work: NoriWork

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        switch work {
        case .sweep:
            path.move(to: point(0.30, 0.86))
            path.addLine(to: point(0.62, 0.18))
            path.move(to: point(0.46, 0.16))
            path.addLine(to: point(0.86, 0.34))
            path.move(to: point(0.40, 0.30))
            path.addLine(to: point(0.78, 0.46))
        case .search:
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.12,
                                       y: rect.minY + rect.height * 0.12,
                                       width: rect.width * 0.48,
                                       height: rect.height * 0.48))
            path.move(to: point(0.52, 0.52))
            path.addLine(to: point(0.86, 0.86))
        case .box:
            path.addRoundedRect(in: CGRect(x: rect.minX + rect.width * 0.18,
                                           y: rect.minY + rect.height * 0.32,
                                           width: rect.width * 0.64,
                                           height: rect.height * 0.48),
                                cornerSize: CGSize(width: rect.width * 0.08, height: rect.height * 0.08))
            path.move(to: point(0.18, 0.46))
            path.addLine(to: point(0.82, 0.46))
        case .wrench:
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.08,
                                       y: rect.minY + rect.height * 0.52,
                                       width: rect.width * 0.34,
                                       height: rect.height * 0.34))
            path.move(to: point(0.34, 0.62))
            path.addLine(to: point(0.84, 0.16))
        case .gauge:
            path.addArc(center: point(0.50, 0.62),
                        radius: rect.width * 0.34,
                        startAngle: .degrees(200),
                        endAngle: .degrees(340),
                        clockwise: false)
            path.move(to: point(0.50, 0.62))
            path.addLine(to: point(0.72, 0.34))
        case .terminal:
            path.addRoundedRect(in: CGRect(x: rect.minX + rect.width * 0.12,
                                           y: rect.minY + rect.height * 0.18,
                                           width: rect.width * 0.76,
                                           height: rect.height * 0.64),
                                cornerSize: CGSize(width: rect.width * 0.1, height: rect.height * 0.1))
            path.move(to: point(0.28, 0.62))
            path.addLine(to: point(0.48, 0.62))
        case .pulse:
            path.move(to: point(0.24, 0.72))
            path.addLine(to: point(0.24, 0.40))
            path.move(to: point(0.50, 0.78))
            path.addLine(to: point(0.50, 0.22))
            path.move(to: point(0.76, 0.70))
            path.addLine(to: point(0.76, 0.36))
        case .plug:
            path.addRoundedRect(in: CGRect(x: rect.minX + rect.width * 0.22,
                                           y: rect.minY + rect.height * 0.38,
                                           width: rect.width * 0.56,
                                           height: rect.height * 0.46),
                                cornerSize: CGSize(width: rect.width * 0.1, height: rect.height * 0.1))
            path.move(to: point(0.36, 0.38))
            path.addLine(to: point(0.36, 0.14))
            path.move(to: point(0.64, 0.38))
            path.addLine(to: point(0.64, 0.14))
        case .wave:
            path.move(to: point(0.08, 0.58))
            path.addQuadCurve(to: point(0.36, 0.58), control: point(0.22, 0.28))
            path.addQuadCurve(to: point(0.64, 0.58), control: point(0.50, 0.88))
            path.addQuadCurve(to: point(0.92, 0.58), control: point(0.78, 0.28))
        case .photo:
            path.addRoundedRect(in: CGRect(x: rect.minX + rect.width * 0.12,
                                           y: rect.minY + rect.height * 0.22,
                                           width: rect.width * 0.76,
                                           height: rect.height * 0.58),
                                cornerSize: CGSize(width: rect.width * 0.08, height: rect.height * 0.08))
            path.move(to: point(0.22, 0.66))
            path.addLine(to: point(0.42, 0.46))
            path.addLine(to: point(0.58, 0.60))
            path.addLine(to: point(0.78, 0.36))
        case .clip:
            path.addRoundedRect(in: CGRect(x: rect.minX + rect.width * 0.22,
                                           y: rect.minY + rect.height * 0.24,
                                           width: rect.width * 0.56,
                                           height: rect.height * 0.62),
                                cornerSize: CGSize(width: rect.width * 0.08, height: rect.height * 0.08))
            path.move(to: point(0.36, 0.24))
            path.addQuadCurve(to: point(0.64, 0.24), control: point(0.50, 0.06))
        }
        return path
    }
}

private struct NoriResultGlyph: Shape {
    var failure: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        if failure {
            path.move(to: point(0.50, 0.12))
            path.addLine(to: point(0.50, 0.62))
            path.move(to: point(0.50, 0.82))
            path.addLine(to: point(0.50, 0.84))
        } else {
            path.move(to: point(0.18, 0.52))
            path.addLine(to: point(0.40, 0.76))
            path.addLine(to: point(0.84, 0.24))
        }
        return path
    }
}
