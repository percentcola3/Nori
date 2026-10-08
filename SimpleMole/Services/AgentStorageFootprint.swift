import Darwin
import Foundation

/// A projection of one Agent scan, shared by the Agent and software pages.
/// These are identified data bytes, not an estimate of the whole data root.
/// Installation bodies and shared Skill/MCP bodies have their own inventory.
struct AgentStorageFootprint: Sendable, Equatable {
    enum Role: String, Sendable, Equatable {
        case reclaimable
        case preserved
    }

    struct Entry: Sendable, Equatable {
        let path: String
        let bytes: UInt64
        let role: Role
        /// Consumers may each display an associated resource. A combined
        /// overview can union these IDs instead of adding their capacities.
        let resourceID: String
        let consumerAgentIDs: [String]
        let physicalPath: String

        init(path: String, bytes: UInt64, role: Role, resourceID: String = "", consumerAgentIDs: [String] = [],
             physicalPath: String? = nil) {
            self.path = path
            self.bytes = bytes
            self.role = role
            self.resourceID = resourceID.isEmpty ? "path:" + path : resourceID
            self.consumerAgentIDs = consumerAgentIDs
            self.physicalPath = physicalPath ?? path
        }
    }

    struct Totals: Sendable, Equatable {
        let identifiedDataBytes: UInt64
        let reclaimableBytes: UInt64
        let preservedBytes: UInt64
        let measurementComplete: Bool
    }

    let agentID: String
    let identifiedDataBytes: UInt64
    let reclaimableBytes: UInt64
    let preservedBytes: UInt64
    let measurementComplete: Bool
    let entries: [Entry]

    /// Reuse measured report values. Only bounded path metadata is consulted
    /// for aliases; no directory or session content is enumerated or reread.
    static func build(report: AgentScanReport, cli: [AgentCLIInstallation]) -> [String: Self] {
        let paths = PathMetadata()
        let excluded = Exclusions(paths: paths, cli: cli, skills: report.skills,
                                  installations: report.installations)
        let categories = Dictionary(report.categories.map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let skills = Dictionary(report.skills.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        let resourcesComplete = report.skills.allSatisfy(\.measurementComplete)
            && report.installations.allSatisfy(\.measurementComplete)
        let groups = report.groups.filter { $0.id != "shared" && $0.id != "shared-mcp" }
            .sorted { $0.id < $1.id }
        var complete = Dictionary(groups.map { ($0.id, report.complete && resourcesComplete) },
                                  uniquingKeysWith: { first, _ in first })
        var observations: [Observation] = []

        func append(path: String, bytes: UInt64?, identity: String?, role: Role, agentID: String) {
            guard DeletionPlan.isLexicallySafePath(path) else {
                complete[agentID] = false
                return
            }
            if bytes == nil { complete[agentID] = false }
            let bytes = bytes ?? 0
            let metadata = paths.metadata(path)
            // A link's target is not this Agent's measured data. Scanner
            // measurements also use physical traversal and skip link bodies.
            if metadata.isLink {
                if bytes > 0 { complete[agentID] = false }
                return
            }
            let object = PathMetadata.objectKey(identity) ?? metadata.object
            if excluded.contains(metadata.path, object: object) { return }
            if excluded.hasDescendant(in: metadata.path) {
                // An aggregate cannot be partitioned around a body using only
                // its total. Keep the known lower bound, with incomplete state.
                complete[agentID] = false
                return
            }
            observations.append(.init(agentID: agentID, path: path, physicalPath: metadata.path,
                                      object: object, bytes: bytes, role: role))
        }

        for group in groups {
            for id in Set(group.categoryIDs) {
                guard let category = categories[id], [.aiCache, .aiSession].contains(category.source) else {
                    complete[group.id] = false
                    continue
                }
                let recommendedReview = group.documented && category.risk == .warning
                    && category.source == .aiSession && category.reasonKey == "agents.reason.review"
                    && report.recommendedCleanupCategoryIDs.contains(id)
                let safeCache = category.source == .aiCache && category.risk == .safe
                    && category.reasonKey != "agents.reason.showOnly"
                let role: Role = category.disposal == .permanentDelete && (safeCache || recommendedReview)
                    ? .reclaimable : .preserved
                for path in Set(category.paths) {
                    append(path: path, bytes: category.pathBytes[path], identity: category.pathIdentities[path],
                           role: role, agentID: group.id)
                }
            }
            for id in Set(group.skillIDs) {
                guard let skill = skills[id] else { complete[group.id] = false; continue }
                guard skill.agentID == group.id, !skill.linked, Set(skill.usedBy).count <= 1 else { continue }
                append(path: skill.path, bytes: skill.bytes, identity: skill.identity, role: .preserved, agentID: group.id)
            }
        }

        // Consumers each see their associated data, while shared preserved
        // evidence prevents another consumer from labelling it as garbage.
        let preservedPaths = Set(observations.filter { $0.role == .preserved }.map(\.physicalPath))
        let preservedAncestors = ancestorPaths(of: preservedPaths)
        let preservedObjects = Set(observations.filter { $0.role == .preserved }.compactMap(\.object))
        let consumers = consumerIndex(observations.map {
            (resource: $0.resourceID, path: $0.physicalPath, consumers: Set([$0.agentID]))
        })
        // Physical aliases and hard links describe one object within an
        // Agent's footprint. They never clear another consumer's capacity.
        var aliases: [Observation] = []
        var byPath: [String: Int] = [:]
        var byObject: [String: Int] = [:]
        for var observation in observations.sorted(by: Observation.ownerOrder) {
            if DeletionPlan.isPathCovered(observation.physicalPath, by: preservedPaths)
                || preservedAncestors.contains(observation.physicalPath)
                || observation.object.map(preservedObjects.contains) == true
                || (consumers[observation.resourceID]?.count ?? 0) > 1 {
                observation.role = .preserved
            }
            let pathKey = observation.agentID + "\0" + observation.physicalPath
            let objectKey = observation.object.map { observation.agentID + "\0" + $0 }
            if let index = byPath[pathKey] ?? objectKey.flatMap({ byObject[$0] }) {
                if aliases[index].bytes != observation.bytes {
                    complete[aliases[index].agentID] = false
                    complete[observation.agentID] = false
                    aliases[index].bytes = min(aliases[index].bytes, observation.bytes)
                }
                if observation.role == .preserved { aliases[index].role = .preserved }
                byPath[pathKey] = index
                if let object = objectKey { byObject[object] = index }
            } else {
                byPath[pathKey] = aliases.count
                if let object = objectKey { byObject[object] = aliases.count }
                aliases.append(observation)
            }
        }

        // Keep outer measured roots once. A preserved nested observation
        // makes the enclosing aggregate preserved; it cannot become all junk.
        var union: [Observation] = []
        var roots: [String: [String: Int]] = [:]
        for observation in aliases.sorted(by: Observation.pathOrder) {
            if let parent = coveringRoot(observation.physicalPath, in: roots[observation.agentID] ?? [:]) {
                if observation.role == .preserved { union[parent].role = .preserved }
                if observation.bytes > union[parent].bytes { complete[union[parent].agentID] = false }
            } else {
                roots[observation.agentID, default: [:]][observation.physicalPath] = union.count
                union.append(observation)
            }
        }

        let byAgent = Dictionary(grouping: union, by: \.agentID)
        return groups.reduce(into: [:]) { result, group in
            let entries = (byAgent[group.id] ?? []).map {
                Entry(path: $0.path, bytes: $0.bytes, role: $0.role, resourceID: $0.resourceID,
                      consumerAgentIDs: Array(consumers[$0.resourceID] ?? []).sorted(), physicalPath: $0.physicalPath)
            }
                .sorted { $0.path < $1.path }
            var identified: UInt64 = 0
            var reclaimable: UInt64 = 0
            for entry in entries {
                let sum = identified.addingReportingOverflow(entry.bytes)
                identified = sum.overflow ? .max : sum.partialValue
                if sum.overflow { complete[group.id] = false }
                if entry.role == .reclaimable {
                    let sum = reclaimable.addingReportingOverflow(entry.bytes)
                    reclaimable = sum.overflow ? .max : sum.partialValue
                    if sum.overflow { complete[group.id] = false }
                }
            }
            result[group.id] = Self(agentID: group.id, identifiedDataBytes: identified,
                reclaimableBytes: reclaimable, preservedBytes: identified - reclaimable,
                measurementComplete: complete[group.id] ?? false, entries: entries)
        }
    }

    /// An overview counts each physical resource and containing tree once.
    /// Use only the cached projection: gathering totals never touches disk.
    /// Shared resources are preserved, and checkbox impact remains separate.
    static func totals(_ footprints: [Self]) -> Totals {
        var complete = !footprints.isEmpty && footprints.allSatisfy(\.measurementComplete)
        let entries = footprints.flatMap { footprint in
            footprint.entries.map { entry in
                (entry: entry, consumers: Set(entry.consumerAgentIDs + [footprint.agentID]))
            }
        }
        let consumers = consumerIndex(entries.map {
            (resource: $0.entry.resourceID, path: $0.entry.physicalPath, consumers: $0.consumers)
        })
        var aliases: [Entry] = []
        var byResource: [String: Int] = [:]
        var byPath: [String: Int] = [:]
        for value in entries.sorted(by: { $0.entry.path < $1.entry.path }) {
            let entry = value.entry
            let role: Role = entry.role == .preserved || (consumers[entry.resourceID]?.count ?? 0) > 1
                ? .preserved : .reclaimable
            if let index = byResource[entry.resourceID] ?? byPath[entry.physicalPath] {
                let previous = aliases[index]
                if previous.bytes != entry.bytes { complete = false }
                aliases[index] = Entry(path: previous.path, bytes: min(previous.bytes, entry.bytes),
                    role: previous.role == .preserved || role == .preserved ? .preserved : .reclaimable,
                    resourceID: previous.resourceID, consumerAgentIDs: previous.consumerAgentIDs,
                    physicalPath: previous.physicalPath)
                byResource[entry.resourceID] = index
                byPath[entry.physicalPath] = index
            } else {
                byResource[entry.resourceID] = aliases.count
                byPath[entry.physicalPath] = aliases.count
                aliases.append(Entry(path: entry.path, bytes: entry.bytes, role: role,
                    resourceID: entry.resourceID, consumerAgentIDs: Array(consumers[entry.resourceID] ?? []).sorted(),
                    physicalPath: entry.physicalPath))
            }
        }
        var union: [Entry] = []
        var roots: [String: Int] = [:]
        for entry in aliases.sorted(by: {
            $0.physicalPath.utf8.count == $1.physicalPath.utf8.count
                ? $0.physicalPath < $1.physicalPath : $0.physicalPath.utf8.count < $1.physicalPath.utf8.count
        }) {
            if let parent = coveringRoot(entry.physicalPath, in: roots) {
                let previous = union[parent]
                if entry.bytes > previous.bytes { complete = false }
                if entry.role == .preserved {
                    union[parent] = Entry(path: previous.path, bytes: previous.bytes, role: .preserved,
                        resourceID: previous.resourceID, consumerAgentIDs: previous.consumerAgentIDs,
                        physicalPath: previous.physicalPath)
                }
            } else {
                roots[entry.physicalPath] = union.count
                union.append(entry)
            }
        }
        var identified: UInt64 = 0
        var reclaimable: UInt64 = 0
        for entry in union {
            let sum = identified.addingReportingOverflow(entry.bytes)
            identified = sum.overflow ? .max : sum.partialValue
            if sum.overflow { complete = false }
            if entry.role == .reclaimable {
                let sum = reclaimable.addingReportingOverflow(entry.bytes)
                reclaimable = sum.overflow ? .max : sum.partialValue
                if sum.overflow { complete = false }
            }
        }
        return Totals(identifiedDataBytes: identified, reclaimableBytes: reclaimable,
                      preservedBytes: identified - reclaimable, measurementComplete: complete)
    }

    private struct Observation {
        let agentID: String
        let path: String
        let physicalPath: String
        let object: String?
        var bytes: UInt64
        var role: Role
        var resourceID: String { object.map { "object:" + $0 } ?? "path:" + physicalPath }

        static func ownerOrder(_ lhs: Self, _ rhs: Self) -> Bool {
            lhs.agentID != rhs.agentID ? lhs.agentID < rhs.agentID : lhs.path < rhs.path
        }
        static func pathOrder(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.physicalPath.utf8.count != rhs.physicalPath.utf8.count {
                return lhs.physicalPath.utf8.count < rhs.physicalPath.utf8.count
            }
            return lhs.physicalPath != rhs.physicalPath ? lhs.physicalPath < rhs.physicalPath : ownerOrder(lhs, rhs)
        }
    }

    private final class PathMetadata {
        struct Value { let path: String; let object: String?; let isLink: Bool }
        private var values: [String: Value] = [:]

        func metadata(_ path: String) -> Value {
            if let value = values[path] { return value }
            var info = stat()
            let exists = lstat(path, &info) == 0
            let linked = exists && info.st_mode & S_IFMT == S_IFLNK
            let url = URL(fileURLWithPath: path)
            let physical = linked
                ? url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
                : url.resolvingSymlinksInPath().path
            let value = Value(path: physical,
                object: exists ? "\(info.st_dev):\(info.st_ino)" : nil, isLink: linked)
            values[path] = value
            return value
        }

        static func objectKey(_ identity: String?) -> String? {
            guard let parts = identity?.split(separator: ":"), parts.count >= 2,
                  let device = UInt64(parts[0]), let inode = UInt64(parts[1]) else { return nil }
            return "\(device):\(inode)"
        }
    }

    private struct Exclusions {
        private var roots = Set<String>()
        private var ancestors = Set<String>()
        private var objects = Set<String>()

        init(paths: PathMetadata, cli: [AgentCLIInstallation], skills: [AgentSkill], installations: [AgentMCPInstallation]) {
            var bodies: [(String, String?)] = cli.flatMap { installation in
                installation.managedPaths.map { ($0, installation.identities[$0]) }
            }
            bodies += skills.filter { !$0.linked && ($0.agentID == "shared" || Set($0.usedBy).count > 1) }
                .map { ($0.path, $0.identity) }
            bodies += installations.map { ($0.path, $0.identity) }
            for (path, identity) in bodies where DeletionPlan.isLexicallySafePath(path) {
                let metadata = paths.metadata(path)
                roots.insert(metadata.path)
                if let object = PathMetadata.objectKey(identity) ?? metadata.object { objects.insert(object) }
            }
            ancestors = AgentStorageFootprint.ancestorPaths(of: roots)
        }

        func contains(_ path: String, object: String?) -> Bool {
            DeletionPlan.isPathCovered(path, by: roots) || object.map(objects.contains) == true
        }
        func hasDescendant(in path: String) -> Bool { ancestors.contains(path) }
    }

    private static func coveringRoot(_ path: String, in roots: [String: Int]) -> Int? {
        if let exact = roots[path] { return exact }
        for slash in path.utf8.indices where path.utf8[slash] == 0x2f {
            let parent = String(path[..<slash])
            if let index = roots[parent], path.hasPrefix(parent + "/") { return index }
        }
        return nil
    }

    private static func ancestorPaths(of roots: Set<String>) -> Set<String> {
        var ancestors = Set<String>()
        for root in roots {
            for slash in root.utf8.indices where root.utf8[slash] == 0x2f {
                let parent = String(root[..<slash])
                if root.hasPrefix(parent + "/") { ancestors.insert(parent) }
            }
        }
        return ancestors
    }

    /// Expand only known consumer notes through measured parent/child paths.
    /// A scoped report cannot establish consumers it did not discover.
    private static func consumerIndex(_ values: [(resource: String, path: String, consumers: Set<String>)]) -> [String: Set<String>] {
        var byResource: [String: Set<String>] = [:]
        var byPath: [String: Set<String>] = [:]
        var descendants: [String: Set<String>] = [:]
        for value in values {
            byResource[value.resource, default: []].formUnion(value.consumers)
            byPath[value.path, default: []].formUnion(value.consumers)
            for parent in ancestorPaths(of: [value.path]) {
                descendants[parent, default: []].formUnion(value.consumers)
            }
        }
        for value in values {
            if let notes = byPath[value.path] { byResource[value.resource, default: []].formUnion(notes) }
            if let notes = descendants[value.path] { byResource[value.resource, default: []].formUnion(notes) }
            for parent in ancestorPaths(of: [value.path]) {
                if let notes = byPath[parent] { byResource[value.resource, default: []].formUnion(notes) }
            }
        }
        return byResource
    }
}
