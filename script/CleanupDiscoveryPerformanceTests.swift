import Darwin
import Foundation

@main
struct CleanupDiscoveryPerformanceTests {
    typealias Matcher = NativeCore.CleanupDiscoveryMatcher

    static func legacyOverlap(_ path: String, roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
    }

    static func legacyWhitelist(_ path: String, entries: [String]) -> Bool {
        entries.contains { entry in
            func hasGlob() -> Bool { entry.contains { $0 == "*" || $0 == "?" || $0 == "[" } }
            return path == entry || (hasGlob() && fnmatch(entry, path, 0) == 0)
                || (!hasGlob() && path.hasPrefix(entry + "/"))
        }
    }

    static func main() throws {
        let home = "/synthetic/home"
        let trash = home + "/.Trash"
        let accent = "\u{301}"
        let roots = [home + "/owner", home + "/owner", home + "/owner/nested",
                     home + "/owner-sibling", home + "/caf\u{e9}", trash + "/" + accent + "child"]
        let patterns = [trash + "/keep", trash + "/q?", trash + "/file[37]", trash + "/bad[",
                        trash + "/*-keep", trash + "/caf\u{e9}", trash + "/" + accent + "literal",
                        trash + "/*" + accent, "/"]
        let queries = [home, home + "/owner", home + "/owner/child", home + "/owner2",
                       home + "/owner/nested/deep", home + "/owner-sibling/child",
                       home + "/cafe" + accent + "/child", trash + "/" + accent + "child",
                       trash + "/" + accent + "child/deeper", trash + "/keep", trash + "/keep/child",
                       trash + "/keep-sibling", trash + "/q7", trash + "/file3", trash + "/file4",
                       trash + "/bad[", trash + "/bad[/child", trash + "/payload-keep",
                       trash + "/cafe" + accent, trash + "/" + accent + "literal/child",
                       trash + "/*" + accent, "/", "//child"]
        let matcher = Matcher(residueRoots: roots, whitelist: patterns)
        for root in [home, trash, home + "/owner", home + "/unrelated"] {
            let scope = matcher.residueScope(for: root)
            for path in queries {
                precondition(matcher.overlapsResidue(path) == legacyOverlap(path, roots: roots), "Residue matching changed")
                precondition(matcher.overlapsResidue(path, scope: scope) == legacyOverlap(path, roots: roots),
                             "Root-hoisting changed a Unicode, ancestor or near-prefix boundary")
                precondition(matcher.directlyMatchesWhitelist(path) == legacyWhitelist(path, entries: patterns),
                             "Compiled whitelist changed literal/glob/Unicode semantics")
            }
        }
        for pattern in patterns + [trash + "/raw?" + accent, trash + "/raw[" + accent] {
            let single = Matcher(residueRoots: [], whitelist: [pattern])
            for path in queries + [pattern, pattern + "/child", pattern + "-sibling"] {
                precondition(single.directlyMatchesWhitelist(path) == legacyWhitelist(path, entries: [pattern]),
                             "Grapheme-aware glob detection changed")
            }
        }
        let completed: Set<String> = [trash + "/done", trash + "/caf\u{e9}", trash + "/" + accent + "done"]
        for path in queries + [trash + "/done", trash + "/done/child", trash + "/done2",
                               trash + "/cafe" + accent, trash + "/" + accent + "done/child"] {
            let early = NativeCore.isCoveredByScannedRoot(path, roots: completed)
            let old = completed.contains { path == $0 || path.hasPrefix($0 + "/") }
            precondition(early == old, "Early completed filtering changed the literal path relation")
        }

        // No real files, URLs, Trash enumeration, scanning or app startup.
        let count = 145_562
        let paths = (0..<count).map { trash + "/cache-" + String($0) }
        let residues = (0..<384).map { home + "/Library/Application Support/Owner-" + String($0) + "/state" }
        let largeMatcher = Matcher(residueRoots: residues, whitelist: patterns)
        let trashScope = largeMatcher.residueScope(for: trash)
        let completedLarge = Set(stride(from: 0, to: count, by: 3).map { paths[$0] })
        let sample = Array(paths.prefix(4096))
        let baselineStart = ProcessInfo.processInfo.systemUptime
        let baseline = sample.filter {
            !legacyWhitelist($0, entries: patterns) && !legacyOverlap($0, roots: residues)
                && !NativeCore.isCoveredByScannedRoot($0, roots: completedLarge)
        }
        let baselineSeconds = ProcessInfo.processInfo.systemUptime - baselineStart
        func optimized(_ input: [String]) -> [String] {
            input.filter {
                !NativeCore.isCoveredByScannedRoot($0, roots: completedLarge)
                    && !largeMatcher.directlyMatchesWhitelist($0)
                    && !largeMatcher.overlapsResidue($0, scope: trashScope)
            }
        }
        let optimizedStart = ProcessInfo.processInfo.systemUptime
        let optimizedSample = optimized(sample)
        let optimizedSeconds = ProcessInfo.processInfo.systemUptime - optimizedStart
        precondition(optimizedSample == baseline, "Optimized discovery differs from the old predicates")
        let fullStart = ProcessInfo.processInfo.systemUptime
        let full = optimized(paths)
        let fullSeconds = ProcessInfo.processInfo.systemUptime - fullStart
        precondition(full.count == count - completedLarge.count)
        print("Discovery parity: duplicates/nested/near-prefix/Unicode/slash/globs/completed passed")
        print(String(format: "Matching-only 4096 paths: legacy=%.4fs optimized=%.4fs", baselineSeconds, optimizedSeconds))
        print(String(format: "Synthetic 145562 paths: optimized=%.4fs retained=%d earlySkipped=%d", fullSeconds, full.count, completedLarge.count))
        print("Disjoint residue scope: 384 root comparisons, zero per-entry residue-array scans; legacy upper work=145562*384")
        try CleanupInspectionTransferTests.run()
    }
}
