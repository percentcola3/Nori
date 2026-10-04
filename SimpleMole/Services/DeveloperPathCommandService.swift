import Foundation

/// Reads the commands provided by one PATH directory without evaluating shell configuration
/// or launching any of the discovered files. Inventories are refreshed on every scan.
enum DeveloperPathCommandService {
    enum Status: Equatable, Sendable {
        case available
        case missingDirectory
        case notDirectory
        case unavailable
    }

    struct Inventory: Equatable, Sendable {
        let names: [String]
        let status: Status
    }

    /// Relative paths and unresolved shell expressions cannot identify a PATH directory safely.
    static func normalizedDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    static func scan(directory: String) -> Inventory {
        guard let normalized = normalizedDirectory(directory) else {
            return Inventory(names: [], status: .unavailable)
        }
        let manager = FileManager.default
        let directoryURL = URL(fileURLWithPath: normalized, isDirectory: true)
        do {
            // Enumerate the resolved directory because Foundation's URL enumerator can reject
            // directory symlinks. The inventory still remains keyed by the original PATH entry.
            let resolvedDirectoryURL = directoryURL.resolvingSymlinksInPath()
            let attributes = try manager.attributesOfItem(atPath: resolvedDirectoryURL.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                return Inventory(names: [], status: .notDirectory)
            }
            let children = try manager.contentsOfDirectory(at: resolvedDirectoryURL,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])
            let names = children.compactMap { child -> String? in
                let name = child.lastPathComponent
                guard !name.hasPrefix("."), manager.isExecutableFile(atPath: child.path),
                      let attributes = try? manager.attributesOfItem(atPath: child.resolvingSymlinksInPath().path),
                      attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
                return name
            }.sorted()
            return Inventory(names: names, status: .available)
        } catch {
            let failure = error as NSError
            let isMissing = failure.domain == NSCocoaErrorDomain
                && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(failure.code)
            return Inventory(names: [], status: isMissing ? .missingDirectory : .unavailable)
        }
    }

    static func scan(directories: [String]) -> [String: Inventory] {
        var inventories: [String: Inventory] = [:]
        for directory in directories {
            guard let normalized = normalizedDirectory(directory), inventories[normalized] == nil else { continue }
            inventories[normalized] = scan(directory: normalized)
        }
        return inventories
    }
}
