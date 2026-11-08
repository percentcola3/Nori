import Foundation

/// Display metadata only. None of these caches authorize filesystem mutation.
struct CleanupCoverageRule: Equatable, Sendable {
    let id: UUID
    let directories: [String]
}

struct CleanupCoverageIndex: Sendable {
    private struct Owner: Sendable { let order: Int; let id: UUID; let root: String }
    private var owners: [String: Owner] = [:]
    var isEmpty: Bool { owners.isEmpty }

    init(rules: [CleanupCoverageRule] = []) {
        for (order, rule) in rules.enumerated() {
            for directory in rule.directories {
                let root = Self.normalized(directory)
                if owners[root] == nil { owners[root] = Owner(order: order, id: rule.id, root: root) }
            }
        }
    }

    static func normalized(_ path: String) -> String {
        // Keep the existing display lookup's Foundation semantics, including
        // relative paths, dot segments and Unicode. Resolve each root once.
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    func ruleID(covering directory: String) -> UUID? {
        guard !isEmpty else { return nil }
        let path = Self.normalized(directory)
        var best = owners[path]
        for index in path.indices.reversed() where path[index] == "/" && index != path.startIndex {
            if let owner = owners[String(path[..<index])],
               (path == owner.root || path.hasPrefix(owner.root + "/")),
               owner.order < (best?.order ?? Int.max) {
                best = owner
            }
        }
        // A root of "/" historically only matched itself: root + "/" is
        // "//". Do not silently widen that behavior for malformed saved rules.
        return best?.id
    }
}

struct CleanupPresentationGroup: Identifiable, Sendable {
    let kind: CleanupGroupBucket
    let categoryIDs: [UUID]
    let bytes: UInt64
    var id: String { kind.rawValue }
}

struct CleanupPresentation: Sendable {
    struct CategoryInput: Sendable {
        let id: UUID
        let name: String
        let paths: [String]
        let bytes: UInt64
        let source: CleanupSource
        let activityGuard: CleanupActivityGuard
        let isMessengerData: Bool

        init(_ category: CleanupCategory) {
            id = category.id; name = category.name; paths = category.paths
            bytes = category.bytes; source = category.source
            activityGuard = category.activityGuard; isMessengerData = category.isMessengerData
        }
    }

    let groups: [CleanupPresentationGroup]
    let categoryIDs: [UUID]
    let categoryIndices: [UUID: Int]
    let coveredPaths: [UUID: Set<String>]
    let visitedPathCount: Int
    static let empty = CleanupPresentation(groups: [], categoryIDs: [], categoryIndices: [:], coveredPaths: [:], visitedPathCount: 0)

    static func inventoryMatches(_ old: [CleanupCategory], _ new: [CleanupCategory]) -> Bool {
        guard old.count == new.count else { return false }
        return zip(old, new).allSatisfy { a, b in
            a.id == b.id && a.name == b.name && a.bytes == b.bytes && a.source == b.source
                && a.activityGuard == b.activityGuard && a.isMessengerData == b.isMessengerData
                && a.paths == b.paths
        }
    }

    static func ruleCatalog(_ rules: [AutoCleanupRule]) -> [CleanupCoverageRule] {
        // Enabled/authorization state and execution statistics do not change
        // the existing "configured" badge. Array order determines precedence.
        rules.map { CleanupCoverageRule(id: $0.id, directories: $0.directories) }
    }

    static func build(categories: [CategoryInput], index: CleanupCoverageIndex,
                      home: String = NSHomeDirectory(),
                      isCancelled: () -> Bool = { false }) -> CleanupPresentation? {
        var buckets: [CleanupGroupBucket: [CategoryInput]] = [:]
        var indices: [UUID: Int] = [:]
        var coverage: [UUID: Set<String>] = [:]
        var visited = 0
        for (position, category) in categories.enumerated() {
            guard !isCancelled() else { return nil }
            if indices[category.id] == nil { indices[category.id] = position }
            let bucket = CleanupGroupBucket(paths: category.paths, source: category.source,
                activityGuard: category.activityGuard, isMessengerData: category.isMessengerData,
                homeDirectory: home)
            buckets[bucket, default: []].append(category)
            if !index.isEmpty, coverage[category.id] == nil {
                var paths = Set<String>()
                for path in category.paths {
                    if visited % 256 == 0 && isCancelled() { return nil }
                    visited += 1
                    if index.ruleID(covering: path) != nil { paths.insert(path) }
                }
                coverage[category.id] = paths
            }
        }
        let groups = buckets.map { kind, categories in
            CleanupPresentationGroup(kind: kind, categoryIDs: categories.sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                let order = $0.name.localizedStandardCompare($1.name)
                if order != .orderedSame { return order == .orderedAscending }
                return ($0.paths.first ?? "").localizedStandardCompare($1.paths.first ?? "") == .orderedAscending
            }.map(\.id), bytes: categories.reduce(0) { $0 &+ $1.bytes })
        }.sorted {
            if ($0.kind == .system) != ($1.kind == .system) { return $0.kind != .system }
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.kind.sortOrder < $1.kind.sortOrder
        }
        guard !isCancelled() else { return nil }
        return CleanupPresentation(groups: groups, categoryIDs: categories.map(\.id), categoryIndices: indices,
                                   coveredPaths: coverage, visitedPathCount: visited)
    }
}

/// Owned by AppState's main actor. All three revisions must match on publish,
/// even if an obsolete detached worker has already passed its cancel check.
struct CleanupPresentationCache {
    struct Version: Equatable, Sendable {
        var inventory: UInt64 = 0
        var rules: UInt64 = 0
        var generation: UInt64 = 0
    }
    private(set) var version = Version()
    private(set) var value = CleanupPresentation.empty

    mutating func invalidate(inventory: Bool = false, rules: Bool = false) -> Version {
        if inventory { version.inventory &+= 1 }
        if rules { version.rules &+= 1 }
        version.generation &+= 1
        value = .empty
        return version
    }

    @discardableResult
    mutating func updateInventory(from old: [CleanupCategory], to new: [CleanupCategory]) -> Bool {
        guard !CleanupPresentation.inventoryMatches(old, new) else { return false }
        invalidate(inventory: true)
        return true
    }

    @discardableResult
    mutating func updateRules(from old: [CleanupCoverageRule], to new: [CleanupCoverageRule]) -> Bool {
        guard old != new else { return false }
        invalidate(rules: true)
        return true
    }

    @discardableResult
    mutating func accept(_ result: CleanupPresentation, version expected: Version) -> Bool {
        guard expected == version else { return false }
        value = result
        return true
    }
}

/// Scalar identities only: no hashing/comparing a large selected Set in body,
/// in a task ID, or on an unrelated metrics/expansion update.
struct CleanupSelectionKey: Hashable, Sendable {
    let id: UUID
    let inventory: UUID
    let selection: UUID
    let bytes: UInt64
    let canSelect: Bool

    init(_ category: CleanupCategory) {
        id = category.id; inventory = category.pathOrderToken
        selection = category.selectionToken; bytes = category.bytes; canSelect = category.canSelect
    }
}

struct CleanupSelectionPresentation: Sendable {
    static func selectedCount(_ category: CleanupCategory?) -> Int {
        guard let category, category.canSelect else { return 0 }
        return category.selectedPathCount
    }

    struct Input: Sendable {
        let id: UUID
        let constantBytes: UInt64?
        let selectedPaths: Set<String>
        let pathBytes: [String: UInt64]

        init(_ category: CleanupCategory) {
            id = category.id
            if !category.canSelect {
                constantBytes = 0; selectedPaths = []; pathBytes = [:]
            } else if category.allSelected {
                constantBytes = category.bytes; selectedPaths = []; pathBytes = [:]
            } else if category.selectedPathCount == 0 {
                constantBytes = 0; selectedPaths = []; pathBytes = [:]
            } else {
                constantBytes = nil; selectedPaths = category.selectedPaths
                pathBytes = category.pathBytes
            }
        }
    }

    let bytesByCategory: [UUID: UInt64]
    let totalBytes: UInt64
    let visitedSelectedPaths: Int
    static let empty = CleanupSelectionPresentation(bytesByCategory: [:], totalBytes: 0, visitedSelectedPaths: 0)

    /// Main-actor fast path consumes only category-sized metadata. Partial
    /// selections always require the explicitly detached builder below.
    static func immediate(_ inputs: [Input]) -> CleanupSelectionPresentation? {
        guard inputs.allSatisfy({ $0.constantBytes != nil }) else { return nil }
        return build(inputs)
    }

    static func build(_ inputs: [Input], isCancelled: () -> Bool = { false }) -> CleanupSelectionPresentation? {
        var totals: [UUID: UInt64] = [:]
        var total: UInt64 = 0
        var visited = 0
        for input in inputs {
            guard !isCancelled() else { return nil }
            let bytes: UInt64
            if let known = input.constantBytes { bytes = known }
            else {
                var sum: UInt64 = 0
                for path in input.selectedPaths {
                    if visited % 256 == 0 && isCancelled() { return nil }
                    visited += 1
                    sum &+= input.pathBytes[path] ?? 0
                }
                bytes = sum
            }
            totals[input.id] = bytes
            total &+= bytes
        }
        guard !isCancelled() else { return nil }
        return CleanupSelectionPresentation(bytesByCategory: totals, totalBytes: total, visitedSelectedPaths: visited)
    }
}

/// AppState owns this on the main actor, independently of inventory/coverage.
/// Cached results retain only numeric sizes, never the selected Sets.
struct CleanupSelectionCache {
    private(set) var generation: UInt64 = 0
    private var keys: [CleanupSelectionKey] = []
    private(set) var value: CleanupSelectionPresentation? = .empty

    @discardableResult
    mutating func update(_ next: [CleanupSelectionKey]) -> Bool {
        guard keys != next else { return false }
        keys = next
        generation &+= 1
        value = nil
        return true
    }

    @discardableResult
    mutating func accept(_ result: CleanupSelectionPresentation, generation expected: UInt64) -> Bool {
        guard generation == expected else { return false }
        value = result
        return true
    }
}
