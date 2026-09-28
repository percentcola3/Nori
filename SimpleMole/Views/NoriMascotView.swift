import AppKit
import SwiftUI

/// Reusable native counterpart of Support/Nori/Animations/*.svg.
/// Kept decorative: the surrounding UI provides the actual status text/progress.
struct NoriMascotView: View {
    var mood: NoriMood = .idle
    var size: CGFloat = 32
    var gaze: CGSize = .zero

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
            Canvas { context, canvas in
                context.scaleBy(x: canvas.width / NoriGeometry.canvas,
                                y: canvas.height / NoriGeometry.canvas)
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
                if pose.confetti > 0 && !reduceMotion { drawRibbons(in: &context, progress: pose.confetti) }
            }
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
            do { try await Task.sleep(nanoseconds: mood == .success ? 1_500_000_000 : 900_000_000) }
            catch { return }
            settled = true
        }
        .accessibilityHidden(true)
    }

    private func noriColor(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }

    private func drawRibbons(in context: inout GraphicsContext, progress: Double) {
        let colors = [NoriGeometry.ribbonBlue, NoriGeometry.ribbonGold, NoriGeometry.ribbonLilac]
        let ribbons: [(Double, Double, Double, Double, Double)] = [
            (70, 80, -46, -25, -120), (90, 54, -37, -28, 100), (128, 42, -12, -30, -80),
            (177, 44, 15, -30, 110), (211, 63, 25, -30, -120), (218, 106, 20, 8, 140)
        ]
        let travel = 1 - pow(1 - progress, 2)
        for (index, ribbon) in ribbons.enumerated() {
            context.drawLayer { particle in
                particle.opacity = min(1, progress * 8) * (1 - progress)
                particle.translateBy(x: ribbon.0 + ribbon.2 * travel, y: ribbon.1 + ribbon.3 * travel)
                particle.rotate(by: .degrees(ribbon.4 * travel))
                particle.fill(Path(roundedRect: CGRect(x: -3, y: -7, width: 6, height: 14), cornerRadius: 2),
                              with: .color(noriColor(colors[index % colors.count])))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var gaze: CGSize = .zero
    @State private var celebrationID = 0
    @State private var celebrating = false
    @State private var feedback = NoriScanFeedback()

    private struct ScanState: Equatable {
        let scanning: Bool
        let succeeded: Bool
    }
    private var scanState: ScanState { ScanState(scanning: isSearching, succeeded: searchSucceeded) }

    var body: some View {
        NoriMascotView(mood: (isSearching || isWorking) ? .working : celebrating ? .success : .idle, size: size, gaze: gaze)
            .contentShape(Rectangle())
            .allowsHitTesting(true)
            .onContinuousHover { phase in
                guard !reduceMotion, !isSearching, !isWorking else { gaze = .zero; return }
                switch phase {
                case .active(let point):
                    gaze = CGSize(width: min(1, max(-1, (point.x / max(size, 1) - 0.5) * 2)),
                                  height: min(1, max(-1, (point.y / max(size, 1) - 0.5) * 2)))
                case .ended: gaze = .zero
                }
            }
            .onAppear { _ = feedback.update(scanning: isSearching, succeeded: searchSucceeded) }
            .onChange(of: scanState) { state in
                gaze = .zero
                celebrationID += 1
                celebrating = feedback.update(scanning: state.scanning, succeeded: state.succeeded) && !reduceMotion
            }
            .onChange(of: reduceMotion) { reduced in
                if reduced { celebrating = false; gaze = .zero }
            }
            .task(id: celebrationID) {
                guard celebrating else { return }
                do { try await Task.sleep(nanoseconds: 1_500_000_000) }
                catch { return }
                celebrating = false
            }
            .accessibilityHidden(true)
    }
}
