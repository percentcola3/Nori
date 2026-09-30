import Foundation

/// The keeper is part of the plan, even though it is never sent to the delete
/// sink. Similar-image groups preserve a member, but do not claim equal bytes.
struct DuplicateDeletionGroup: Sendable {
    let files: [DuplicateFile]
    let requiresExactMatch: Bool
}

struct DuplicateDeletionPlan: Sendable {
    struct Target: Sendable {
        let file: DuplicateFile
        let keeper: DuplicateFile
        let requiresExactMatch: Bool
    }

    enum InvalidPlan: Error {
        case empty, unknownSelection, missingKeeper, invalidEvidence
    }

    let targets: [Target]
    private let targetsByPath: [String: Target]
    let roots: [String]
    let home: String

    init(groups: [DuplicateDeletionGroup], selectedPaths: Set<String>,
         roots: [String], home: String = NSHomeDirectory()) throws {
        guard !selectedPaths.isEmpty, !roots.isEmpty else { throw InvalidPlan.empty }
        let allPaths = groups.flatMap(\.files).map(\.path)
        guard Set(allPaths).count == allPaths.count,
              selectedPaths.isSubset(of: Set(allPaths)) else { throw InvalidPlan.unknownSelection }
        var targets: [Target] = []
        for group in groups {
            let selected = group.files.filter { selectedPaths.contains($0.path) }
            guard !selected.isEmpty else { continue }
            guard let keeper = group.files.first(where: { !selectedPaths.contains($0.path) }) else {
                throw InvalidPlan.missingKeeper
            }
            for file in selected {
                guard !file.sha256.isEmpty, !keeper.sha256.isEmpty,
                      file.identity.device != keeper.identity.device
                        || file.identity.inode != keeper.identity.inode,
                      !group.requiresExactMatch || (file.size == keeper.size && file.sha256 == keeper.sha256) else {
                    throw InvalidPlan.invalidEvidence
                }
                targets.append(Target(file: file, keeper: keeper,
                                      requiresExactMatch: group.requiresExactMatch))
            }
        }
        self.targets = targets
        self.targetsByPath = Dictionary(uniqueKeysWithValues: targets.map { ($0.file.path, $0) })
        self.roots = roots
        self.home = home
    }

    var items: [DeletionPlan.Item] {
        targets.map { target in
            let identity = target.file.identity
            return DeletionPlan.Item(record: target.file.path,
                identity: "\(identity.device):\(identity.inode):\(identity.modifiedSeconds)")
        }
    }

    /// Called by NativeCore after its runtime checks and immediately before
    /// Trash. A changed/missing keeper or selected file rejects the operation.
    func validate(_ path: String, control: DuplicateScanControl) throws {
        guard let target = targetsByPath[path] else {
            throw InvalidPlan.unknownSelection
        }
        try DuplicateScanner.revalidate(target.keeper, allowedRoots: roots, control: control, home: home)
        try DuplicateScanner.revalidate(target.file, allowedRoots: roots, control: control, home: home)
        // Reading a large target can take time: check the keeper again after it.
        try DuplicateScanner.validateUnchanged(target.keeper, allowedRoots: roots, home: home)
        try DuplicateScanner.validateUnchanged(target.file, allowedRoots: roots, home: home)
    }
}
