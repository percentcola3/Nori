import AppKit
import SwiftUI

/// Initial state is injected only into a frozen temporary view source by the
/// test script. Product sources and the installed app's preferences stay intact.
@MainActor
enum IslandPresentationFixture {
    static var expanded = false
    static var resource: IslandResource?
    static var reduceTransparency = false
}

@MainActor
private final class IslandRegions {
    var rail: CGRect?
    var shape: NotchShape?
    var detail: CGRect?
}

@main
@MainActor
struct IslandSidePresentationTests {
    static func settle(_ seconds: TimeInterval = 0.6) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    static func approximately(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) <= 0.75
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func capture(_ state: AppState, edge: AppState.IslandEdge, expanded: Bool,
                        resource: IslandResource?, name: String, output: URL,
                        hardwareNotch: Bool = false, reduceTransparency: Bool = false) throws {
        IslandPresentationFixture.expanded = expanded
        IslandPresentationFixture.resource = resource
        IslandPresentationFixture.reduceTransparency = reduceTransparency
        let regions = IslandRegions()
        let safeTop: CGFloat = hardwareNotch ? 32 : 0
        let size = edge == .top
            ? NSSize(width: IslandLayout.panelWidth + IslandLayout.windowMargin * 2,
                     height: (hardwareNotch ? safeTop : IslandLayout.nonNotchExpandedTopInset)
                        + IslandLayout.metricsHeight + IslandLayout.detailBudget + IslandLayout.windowMargin)
            : IslandLayout.sideWindowSize
        let view = FloatingIslandView(state: state, safeTop: safeTop, hardwareNotch: hardwareNotch,
            edge: edge, onOpenMain: {}, onHitFrameChange: { frame, shape in
                regions.rail = frame
                regions.shape = shape
            }, onDetailHitFrameChange: { regions.detail = $0 })
            .environment(\.colorScheme, .dark)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = IslandHostingView(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.contentView = host
        window.center()
        let backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -40, dy: -40),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.backgroundColor = NSColor(srgbRed: 0.12, green: 0.15, blue: 0.18, alpha: 1)
        backdrop.isOpaque = true
        backdrop.ignoresMouseEvents = true
        defer {
            window.orderOut(nil)
            window.close()
            backdrop.orderOut(nil)
            backdrop.close()
        }
        backdrop.orderFront(nil)
        window.orderFrontRegardless()
        settle()
        host.layoutSubtreeIfNeeded()
        check(host.bounds.size == size, "\(name): visible content must retain the fixed window size")
        guard let rail = regions.rail, let shape = regions.shape else {
            preconditionFailure("\(name): visible rail must report geometry in the root coordinate space")
        }
        let bounds = host.bounds.insetBy(dx: -0.75, dy: -0.75)
        check(bounds.contains(rail), "\(name): rail escapes its window: \(rail), \(bounds)")
        check(rail.width > 0 && rail.height > 0, "\(name): rail must have a visible area")
        check(shape.path(in: rail).contains(CGPoint(x: rail.midX, y: rail.midY)),
              "\(name): reported rail shape must include its visible center")
        host.islandHitFrame = rail
        host.islandHitShape = shape
        host.islandDetailHitFrame = regions.detail
        func routes(_ point: CGPoint) -> Bool {
            let windowPoint = host.convert(point, to: nil)
            return host.containsScreenPoint(window.convertPoint(toScreen: windowPoint))
        }
        check(routes(CGPoint(x: rail.midX, y: rail.midY)),
              "\(name): cursor over the reported rail must disable click pass-through")
        func dragLeaves(in view: NSView) -> [IslandDragView] {
            if let drag = view as? IslandDragView { return [drag] }
            return view.subviews.flatMap { dragLeaves(in: $0) }
        }
        let dragControls = dragLeaves(in: host)
        let activeDragControls = dragControls.filter(\.isEnabled)
        if edge == .top {
            check(dragControls.isEmpty, "\(name): the top island must retain its original controls")
        } else {
            check(activeDragControls.count == 1, "\(name): exactly one visible side grip may receive native drag input")
            let drag = activeDragControls[0]
            let dragFrame = drag.convert(drag.bounds, to: host)
            check(rail.insetBy(dx: -0.75, dy: -0.75).contains(dragFrame),
                  "\(name): drag overlay must stay on its handle, outside CPU/memory metric actions")
            check(drag.accessibilityRole() == (expanded ? .slider : .button),
                  "\(name): expanded grip moves while collapsed grip remains an accessible click target")
            check(abs(drag.positionFraction - state.islandPosition(for: edge)) < 0.000001,
                  "\(name): drag accessibility value must expose this side's saved position")
            for hiddenDrag in dragControls where !hiddenDrag.isEnabled {
                let center = hiddenDrag.convert(
                    NSPoint(x: hiddenDrag.bounds.midX, y: hiddenDrag.bounds.midY), to: hiddenDrag.superview)
                check(hiddenDrag.hitTest(center) == nil,
                      "\(name): hidden native grips must not intercept clicks or focus")
            }
        }

        if edge == .top {
            check(approximately(rail.midX, host.bounds.midX), "\(name): top island must remain centered")
            check(approximately(rail.minY, 0), "\(name): top island must remain attached to screen top")
            check(regions.detail == nil, "\(name): legacy top details must remain part of the main surface")
            if !expanded {
                let width = hardwareNotch ? IslandLayout.virtualNotchWidth : IslandLayout.handleWidth
                let height = hardwareNotch ? safeTop + IslandLayout.notchLipHeight : IslandLayout.handleHeight
                check(approximately(rail.width, width) && approximately(rail.height, height),
                      "\(name): top collapsed baseline dimensions changed")
            }
        } else {
            let outwardX = edge == .left ? rail.minX : rail.maxX
            check(approximately(outwardX, edge == .left ? 0 : host.bounds.maxX),
                  "\(name): rail must touch its physical screen edge")
            check(approximately(rail.midY, host.bounds.midY), "\(name): side rail must remain vertically centered")
            if !expanded {
                check(approximately(rail.width, 12) && approximately(rail.height, 96),
                      "\(name): collapsed side handle must stay vertical")
                check(regions.detail == nil, "\(name): collapsed sidebar must not retain an invisible detail target")
            } else {
                check(approximately(rail.width, IslandLayout.sideRailWidth),
                      "\(name): vertical metric rail width changed")
                if resource == nil {
                    check(regions.detail == nil, "\(name): sidebar without a resource must not expose a detail target")
                } else {
                    guard let detail = regions.detail else {
                        preconditionFailure("\(name): selected CPU/memory must report a separate inward bubble")
                    }
                    check(bounds.contains(detail), "\(name): detail bubble escapes its window: \(detail)")
                    check(approximately(detail.width, IslandLayout.sideDetailWidth),
                          "\(name): detail text must retain the full bubble width")
                    check(detail.height <= IslandLayout.detailBudget + 0.75,
                          "\(name): long status must scroll within the detail height budget")
                    check(!rail.intersects(detail), "\(name): detail bubble must not overlap the metric rail")
                    let gap = edge == .left ? detail.minX - rail.maxX : rail.minX - detail.maxX
                    check(approximately(gap, IslandLayout.sideDetailGap),
                          "\(name): bubble must open inward with the intended transparent gap")
                    let gapPoint = CGPoint(x: edge == .left ? rail.maxX + gap / 2 : detail.maxX + gap / 2,
                                           y: detail.midY)
                    check(!shape.path(in: rail).contains(gapPoint) && !detail.contains(gapPoint),
                          "\(name): transparent rail/bubble gap must not become a hit target")
                    check(!routes(gapPoint), "\(name): native inspector must pass through the transparent gap")
                    check(routes(CGPoint(x: detail.midX, y: detail.midY)),
                          "\(name): native inspector must receive the separate detail bubble")
                    check(!routes(CGPoint(x: detail.minX + 0.25, y: detail.minY + 0.25)),
                          "\(name): native inspector must pass through the detail's rounded corner")
                }
            }
        }

        let path = output.appendingPathComponent(name + ".png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
        try process.run()
        process.waitUntilExit()
        check(process.terminationStatus == 0 && NSImage(contentsOf: path) != nil,
              "\(name): native own-window capture must succeed")
        print("Passed \(name): rail=\(rail), detail=\(String(describing: regions.detail)); \(path.path)")
    }

    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ReadmeFixture.root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let domain = "com.nori.island-presentation-fixture"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            ReadmeFixture.defaults.removePersistentDomain(forName: "com.nori.readme-fixtures")
        }
        for language in [AppLanguage.en, .zhHans] {
            L10n.shared.setLanguage(language)
            let locale = language == .en ? "en" : "zh-CN"
            let state = ReadmeFixture.makeState()
            state.islandLeftPosition = 0.23
            state.islandRightPosition = 0.77
            state.topCPUApps = state.topMemoryApps
            try capture(state, edge: .top, expanded: false, resource: nil,
                        name: "\(locale)-top-collapsed", output: output)
            try capture(state, edge: .top, expanded: true, resource: .memory,
                        name: "\(locale)-top-memory-baseline", output: output)
            for edge in [AppState.IslandEdge.left, .right] {
                try capture(state, edge: edge, expanded: false, resource: nil,
                            name: "\(locale)-\(edge.rawValue)-collapsed", output: output)
                for resource in [IslandResource.cpu, .memory] {
                    try capture(state, edge: edge, expanded: true, resource: resource,
                                name: "\(locale)-\(edge.rawValue)-\(resource.rawValue)", output: output)
                }
            }
            state.islandItems = Set(AppState.IslandItem.allCases)
            for edge in [AppState.IslandEdge.left, .right] {
                try capture(state, edge: edge, expanded: true, resource: nil,
                            name: "\(locale)-\(edge.rawValue)-all-metrics", output: output)
            }
        }
        L10n.shared.setLanguage(.zhHans)
        let state = ReadmeFixture.makeState()
        try capture(state, edge: .top, expanded: false, resource: nil,
                    name: "top-hardware-notch-baseline", output: output, hardwareNotch: true)
        for edge in [AppState.IslandEdge.left, .right] {
            try capture(state, edge: edge, expanded: true, resource: .memory,
                        name: "zh-CN-\(edge.rawValue)-opaque-fallback", output: output, reduceTransparency: true)
        }
        state.islandResourceStatus[.memory] = String(repeating:
            "缓存清理部分失败：应用仍在使用部分文件。请关闭对应应用后重新清理，其余未占用文件已经处理。", count: 20)
        for edge in [AppState.IslandEdge.left, .right] {
            try capture(state, edge: edge, expanded: true, resource: .memory,
                        name: "zh-CN-\(edge.rawValue)-long-status", output: output)
        }
        print("Island presentation: top baseline, left/right rail and CPU/memory bubble geometry, transparent gaps, all metrics, two languages and opaque fallback passed")
    }
}
