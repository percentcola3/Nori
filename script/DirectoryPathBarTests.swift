import Foundation

@main
enum DirectoryPathBarTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func checkCoverage(_ plan: DirectoryPathOverflowPlan, count: Int, width: CGFloat) {
        let covered = (plan.visibleIndices + plan.collapsedIndices).sorted()
        require(covered == Array(0..<count), "An ancestor became unreachable")
        require(Set(covered).count == covered.count, "An ancestor appears twice")
        require(plan.totalWidth <= max(0, width) + 0.0001, "Breadcrumbs exceed their available width")
        require(plan.itemWidths.allSatisfy { $0.isFinite && $0 >= 0 }, "Invalid allocated label width")
        if count > 0 {
            require(plan.visibleIndices.first == 0, "Root must stay visible")
            require(plan.visibleIndices.last == count - 1, "Current folder must stay visible")
        }
        if count > 1 {
            let closestParents = plan.visibleIndices.dropFirst().dropLast()
            if let first = closestParents.first {
                require(Array(closestParents) == Array(first..<(count - 1)), "Only the nearest contiguous parents should remain")
            }
        }
    }

    static func main() {
        let ordinary = DirectoryPathOverflowPlan.make(widths: [18, 55, 62, 80], availableWidth: 500)
        require(ordinary.visibleIndices == [0, 1, 2, 3], "A fitting path should remain complete")
        require(ordinary.collapsedIndices.isEmpty, "A fitting path should not show an overflow menu")
        checkCoverage(ordinary, count: 4, width: 500)

        let deep = DirectoryPathOverflowPlan.make(widths: [28, 80, 80, 80, 30, 80], availableWidth: 210)
        require(deep.visibleIndices == [0, 4, 5], "Keep the nearest parent before distant ancestors")
        require(deep.collapsedIndices == [1, 2, 3], "Every omitted ancestor must be in the menu")
        checkCoverage(deep, count: 6, width: 210)

        // Removing the overflow marker can allow all parents to fit when the
        // current filename itself is long. A greedy early break would miss it.
        let noMarker = DirectoryPathOverflowPlan.make(widths: [16, 1, 144, 200], availableWidth: 270)
        require(noMarker.visibleIndices == [0, 1, 2, 3], "Account for the width recovered when overflow disappears")
        require(noMarker.collapsedIndices.isEmpty, "The final visible parent removes the overflow marker")
        require(noMarker.itemWidths.last! < 200, "Only the long current name should truncate here")
        checkCoverage(noMarker, count: 4, width: 270)

        for width: CGFloat in [0, 1, 18, 28, 56, 72, 100, 160] {
            let narrow = DirectoryPathOverflowPlan.make(widths: [18, 100, 120, 260], availableWidth: width)
            checkCoverage(narrow, count: 4, width: width)
        }

        for width: CGFloat in [0, 8, 100] {
            let root = DirectoryPathOverflowPlan.make(widths: [18], availableWidth: width)
            require(root.visibleIndices == [0] && root.collapsedIndices.isEmpty, "Root path must not duplicate a current crumb")
            checkCoverage(root, count: 1, width: width)
        }
        let empty = DirectoryPathOverflowPlan.make(widths: [], availableWidth: 100)
        require(empty.visibleIndices.isEmpty && empty.totalWidth == 0, "Empty metrics should be safe")

        // English, Chinese and mixed names have very different measured widths;
        // each must truncate within its allocation, not displace path controls.
        for currentWidth: CGFloat in [1_200, 880, 2_400] {
            let longName = DirectoryPathOverflowPlan.make(widths: [18, 80, currentWidth], availableWidth: 200)
            require(longName.itemWidths[2] < currentWidth, "Long single names need a bounded width")
            checkCoverage(longName, count: 3, width: 200)
        }

        let veryDeep = DirectoryPathOverflowPlan.make(widths: [18] + Array(repeating: 64, count: 200), availableWidth: 640)
        checkCoverage(veryDeep, count: 201, width: 640)
        require(veryDeep.collapsedIndices.count > 180, "A deep path should remain a bounded row")

        let unicodeURL = URL(fileURLWithPath: "/Users/名字/一个很长的目录名/another very long folder/.hidden", isDirectory: true)
        let crumbs = DirectoryPathCrumb.components(for: unicodeURL)
        require(crumbs.first?.id == "/", "Crumbs must start at the filesystem root")
        require(crumbs.last?.url.path == unicodeURL.path, "Keep the full current address in crumb data")
        require(crumbs.map(\.position) == Array(crumbs.indices), "Widths must correspond to crumb positions")
        require(Set(crumbs.map(\.id)).count == crumbs.count, "Crumbs need stable unique path IDs")
        require(DirectoryPathCrumb.components(for: URL(fileURLWithPath: "/", isDirectory: true)).count == 1,
                "The filesystem root should be represented once")

        var seed: UInt64 = 0x42
        for _ in 0..<1_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let count = Int(seed % 96) + 1
            var widths: [CGFloat] = []
            for position in 0..<count {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                widths.append(position == 0 ? 18 : CGFloat(seed % 400 + 8))
            }
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let available = CGFloat(seed % 1_200)
            checkCoverage(DirectoryPathOverflowPlan.make(widths: widths, availableWidth: available),
                          count: count, width: available)
        }
        print("Directory path overflow tests passed")
    }
}
