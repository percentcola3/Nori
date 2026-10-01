import AppKit
import SwiftUI

/// Reusable native counterpart of Support/Nori/Animations/*.svg.
/// Kept decorative: the surrounding UI provides the actual status text/progress.
struct NoriMascotView: View {
    var mood: NoriMood = .idle
    var size: CGFloat = 32
    var gaze: CGSize = .zero
    /// Extra drawing room on every side, as a fraction of `size`. Result props
    /// (confetti, the result badge) spill into it without changing layout.
    var bleed: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var startedAt = Date()
    @State private var appeared = false
    @State private var windowVisible = false
    @State private var appActive = NSApp.isActive
    @State private var settled = false

    private var canAnimate: Bool { appeared && windowVisible && appActive && !reduceMotion && !settled }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !canAnimate)) { timeline in
            let pose = NoriMotion.pose(for: mood,
                                       elapsed: timeline.date.timeIntervalSince(startedAt),
                                       reduceMotion: reduceMotion || !appActive || !windowVisible)
            Canvas { context, _ in
                context.translateBy(x: size * bleed, y: size * bleed)
                context.scaleBy(x: size / NoriGeometry.canvas, y: size / NoriGeometry.canvas)
                let showsProp = pose.prop > 0 && !reduceMotion
                context.drawLayer { character in
                    character.translateBy(x: NoriGeometry.anchor.x,
                                          y: NoriGeometry.anchor.y + pose.offsetY)
                    character.rotate(by: .degrees(pose.rotation))
                    character.scaleBy(x: pose.scaleX, y: pose.scaleY)
                    character.translateBy(x: -NoriGeometry.anchor.x, y: -NoriGeometry.anchor.y)
                    let body = Path(NoriGeometry.bodyPath())
                    character.fill(body, with: .color(noriColor(NoriGeometry.body)))
                    // Bare ice-blue artwork needs an outline on light glass; never on the Dock tile.
                    if colorScheme == .light {
                        character.stroke(body, with: .color(noriColor(NoriGeometry.ink).opacity(0.7)),
                                         lineWidth: 8)
                    }
                    for eye in NoriGeometry.eyes {
                        character.drawLayer { ink in
                            let hover = reduceMotion ? CGSize.zero : gaze
                            ink.translateBy(x: eye.x + pose.gazeX + hover.width * 5,
                                            y: eye.y + pose.gazeY + hover.height * 4)
                            ink.rotate(by: .radians(NoriGeometry.eyeTilt))
                            ink.scaleBy(x: 1, y: pose.eyeOpen)
                            let rect = CGRect(x: -NoriGeometry.eyeWidth / 2, y: -NoriGeometry.eyeHeight / 2,
                                              width: NoriGeometry.eyeWidth, height: NoriGeometry.eyeHeight)
                            ink.fill(Path(roundedRect: rect, cornerRadius: NoriGeometry.eyeWidth / 2),
                                     with: .color(noriColor(NoriGeometry.ink)))
                        }
                    }
                }
                if showsProp && mood == .success { drawConfetti(in: &context, progress: pose.prop) }
                if showsProp && (mood == .success || mood == .attention) {
                    drawBadge(in: &context, progress: pose.prop, succeeded: mood == .success)
                }
                if mood == .tidying && canAnimate {
                    drawActivityDots(in: &context, progress: pose.prop)
                }
            }
            .frame(width: size * (1 + 2 * bleed), height: size * (1 + 2 * bleed))
        }
        .frame(width: size, height: size)
        .background(NoriWindowVisibilityProbe { visible in windowVisible = visible })
        .onAppear { appeared = true; startedAt = Date() }
        .onDisappear { appeared = false }
        .onChange(of: mood) { _ in startedAt = Date(); settled = false }
        .onChange(of: reduceMotion) { _ in startedAt = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appActive = true
            startedAt = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appActive = false
        }
        .task(id: mood) {
            guard mood == .success || mood == .attention else { return }
            let duration = mood == .success ? NoriMotion.celebrationDuration : NoriMotion.failureDuration
            do { try await Task.sleep(nanoseconds: UInt64((duration + 0.1) * 1_000_000_000)) }
            catch { return }
            settled = true
        }
        .accessibilityHidden(true)
    }

    private func noriColor(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }

    /// Matches nori-success.svg: (dx, peak, fall, turn, color, round) per piece,
    /// scaled up because the SVG figure is drawn at 0.78.
    private static let confetti: [(Double, Double, Double, Double, UInt32, Bool)] = [
        (-100, -36, 70, -160, NoriGeometry.ribbonBlue, false), (-68, -50, 64, 120, NoriGeometry.ribbonGold, true),
        (-34, -58, 76, -90, NoriGeometry.ribbonLilac, false), (2, -62, 70, 140, NoriGeometry.ribbonBlue, true),
        (36, -58, 80, -130, NoriGeometry.ribbonGold, false), (70, -50, 66, 100, NoriGeometry.ribbonLilac, true),
        (102, -36, 74, -150, NoriGeometry.ribbonBlue, false), (-86, -18, 90, 80, NoriGeometry.ribbonLilac, true),
        (88, -20, 88, -70, NoriGeometry.ribbonGold, true)
    ]

    private func drawConfetti(in context: inout GraphicsContext, progress: Double) {
        let scale = 1.3
        let opacity = min(1, progress / 0.08) * (progress > 0.72 ? max(0, (1 - progress) / 0.28) : 1)
        for piece in Self.confetti {
            let (dx, peak, fall, turn) = (piece.0 * scale, piece.1 * scale, piece.2 * scale, piece.3)
            let x: Double, y: Double
            if progress < 0.45 {
                let s = 1 - pow(1 - progress / 0.45, 2)
                x = dx * 0.7 * s
                y = peak * s
            } else {
                let u = (progress - 0.45) / 0.55
                x = dx * (0.7 + 0.3 * u)
                y = peak + fall * u * u
            }
            context.drawLayer { layer in
                layer.opacity = opacity
                layer.translateBy(x: 132 + x, y: 40 + y)
                layer.rotate(by: .degrees(turn * progress))
                let color = GraphicsContext.Shading.color(noriColor(piece.4))
                if piece.5 {
                    layer.fill(Path(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18)), with: color)
                } else {
                    layer.fill(Path(roundedRect: CGRect(x: -6, y: -13, width: 12, height: 26), cornerRadius: 4),
                               with: color)
                }
            }
        }
    }

    /// A centered, quiet wave carries activity without a literal cleanup prop.
    private func drawActivityDots(in context: inout GraphicsContext, progress: Double) {
        for index in 0..<3 {
            let wave = max(0, sin((progress - Double(index) * 0.14) * 2 * .pi))
            context.drawLayer { dot in
                dot.opacity = 0.35 + wave * 0.65
                let circle = CGRect(x: 108 + Double(index) * 20, y: 240 - wave * 4,
                                    width: 8, height: 8)
                dot.fill(Path(ellipseIn: circle), with: .color(noriColor(NoriGeometry.ribbonBlue)))
            }
        }
    }

    /// Matches nori-success/attention.svg: one shared badge pops onto Nori's lower
    /// right, over the body; success shows a green check, failure a coral "!".
    private func drawBadge(in context: inout GraphicsContext, progress: Double, succeeded: Bool) {
        let pop: Double, tilt: Double
        switch progress {
        case ..<0.08: (pop, tilt) = (0, -20)
        case ..<0.22: let s = (progress - 0.08) / 0.14; (pop, tilt) = (1.18 * s, -20 + 26 * s)
        case ..<0.32: let s = (progress - 0.22) / 0.1; (pop, tilt) = (1.18 - 0.24 * s, 6 - 9 * s)
        case ..<0.42: let s = (progress - 0.32) / 0.1; (pop, tilt) = (0.94 + 0.06 * s, -3 + 3 * s)
        default: (pop, tilt) = (1, 0)
        }
        guard pop > 0 else { return }
        let ink = GraphicsContext.Shading.color(noriColor(NoriGeometry.ink))
        let ice = GraphicsContext.Shading.color(noriColor(NoriGeometry.body))
        context.drawLayer { badge in
            badge.opacity = progress > 0.9 ? (1 - progress) / 0.1 : 1
            badge.translateBy(x: 222, y: 204)
            badge.rotate(by: .degrees(tilt))
            badge.scaleBy(x: 1.3 * pop, y: 1.3 * pop)
            let disc = Path(ellipseIn: CGRect(x: -42, y: -42, width: 84, height: 84))
            badge.fill(disc, with: .color(noriColor(succeeded ? NoriGeometry.ribbonSuccess : NoriGeometry.ribbonFail)))
            badge.stroke(disc, with: ink, lineWidth: 4)
            if succeeded {
                let check = Path { path in
                    path.addLines([CGPoint(x: -17, y: -1), CGPoint(x: -5, y: 11), CGPoint(x: 17, y: -12)])
                }
                badge.stroke(check, with: ice, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
            } else {
                badge.fill(Path(roundedRect: CGRect(x: -5.5, y: -22, width: 11, height: 25), cornerRadius: 5.5), with: ice)
                badge.fill(Path(ellipseIn: CGRect(x: -6, y: 8, width: 12, height: 12)), with: ice)
            }
        }
    }
}

/// Suspend display-link work when the host window is hidden, minimized or occluded.
private struct NoriWindowVisibilityProbe: NSViewRepresentable {
    var onChange: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { Probe(onChange: onChange) }
    func updateNSView(_ view: Probe, context: Context) { view.onChange = onChange }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stopObserving() }

    final class Probe: NSView {
        var onChange: (Bool) -> Void
        private var token: NSObjectProtocol?
        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            reportVisibility()
            if let window {
                token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                object: window, queue: .main) { [weak self] _ in
                    self?.reportVisibility()
                }
            }
        }
        private func reportVisibility() {
            let visible = window?.occlusionState.contains(.visible) == true
            DispatchQueue.main.async { [weak self] in self?.onChange(visible) }
        }
        func stopObserving() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
        deinit { stopObserving() }
    }
}

/// Existing header/scanning call sites share the new vector mascot.
struct HeaderBrandIconView: View {
    var size: CGFloat
    var isSearching = false
    var searchSucceeded = false
    var isWorking = false
    var reactionID = 0
    var reactionMood: NoriMood = .success
    /// Cleaning and uninstalling share the tidying animation.
    var isTidying = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var gaze: CGSize = .zero
    @State private var playing = false
    @State private var playedMood: NoriMood = .success
    @State private var playID = 0

    private var mood: NoriMood {
        if playing { return playedMood }
        if isTidying { return .tidying }
        if isSearching || isWorking { return .working }
        return .idle
    }

    var body: some View {
        NoriMascotView(mood: mood, size: size, gaze: gaze, bleed: 0.7)
            .id(playing ? playID : 0)
            .contentShape(Rectangle())
            .allowsHitTesting(true)
            .onContinuousHover { phase in
                guard !reduceMotion, !isSearching, !isWorking, !playing else { gaze = .zero; return }
                switch phase {
                case .active(let point):
                    gaze = CGSize(width: min(1, max(-1, (point.x / max(size, 1) - 0.5) * 2)),
                                  height: min(1, max(-1, (point.y / max(size, 1) - 0.5) * 2)))
                case .ended: gaze = .zero
                }
            }
            .onAppear { _ = searchSucceeded }
            .onChange(of: reactionID) { id in
                guard id > 0, reactionMood == .success || reactionMood == .attention else { return }
                gaze = .zero
                playedMood = reactionMood
                playID = id
                playing = !reduceMotion
            }
            .onChange(of: reduceMotion) { reduced in
                if reduced { playing = false; gaze = .zero }
            }
            .task(id: playID) {
                guard playing else { return }
                let duration = playedMood == .success
                    ? NoriMotion.celebrationDuration : NoriMotion.failureDuration
                do { try await Task.sleep(nanoseconds: UInt64((duration + 0.1) * 1_000_000_000)) }
                catch { return }
                playing = false
            }
            .accessibilityHidden(true)
    }
}
