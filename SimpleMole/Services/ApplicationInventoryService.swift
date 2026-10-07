import Darwin
import Foundation

struct ApplicationBundleMetadata: Sendable {
    let name: String
    let bundleID: String
}

/// Application discovery and bundle evidence; no deletion or process control.
protocol ApplicationInventoryReading: Sendable {
    func roots(home: URL) -> [(URL, String)]
    func children(of directory: URL) -> [URL]
    func metadata(at url: URL) -> ApplicationBundleMetadata?
    func directoryIdentity(_ url: URL) -> String?
    func installedApps(in roots: [(URL, String)]) -> [UninstallApp]
}

struct NativeApplicationInventory: ApplicationInventoryReading {
    private var fileManager: FileManager { .default }
    private let sizer: any ApplicationSizeMeasuring
    private let ownBundleID: String?

    init(sizer: any ApplicationSizeMeasuring = BoundedApplicationSizeMeasurer(),
         ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.sizer = sizer
        self.ownBundleID = ownBundleID
    }

    /// Scan canonical roots once; names and Bundle IDs are not unique installs.
    func installedApps(in roots: [(URL, String)]) -> [UninstallApp] {
        var apps: [UninstallApp] = []
        var seen = Set<String>()
        for (root, source) in uniqueRoots(roots) {
            for item in children(of: root) {
                guard item.pathExtension.lowercased() == "app",
                      (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      let metadata = metadata(at: item),
                      !metadata.bundleID.isEmpty, metadata.bundleID != ownBundleID,
                      !metadata.bundleID.hasPrefix("com.apple."),
                      let identity = directoryIdentity(item), seen.insert(identity).inserted else { continue }
                apps.append(.init(name: metadata.name, bundleID: metadata.bundleID, source: source,
                                  path: item.path, size: ByteFormat.format(sizer.allocatedBytes(at: item))))
            }
        }
        return apps.sorted {
            let lhs = ByteFormat.parse($0.size), rhs = ByteFormat.parse($1.size)
            if lhs != rhs { return lhs > rhs }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func children(of directory: URL) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.map { directory.appendingPathComponent($0) }
    }

    func metadata(at url: URL) -> ApplicationBundleMetadata? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return .init(name: name, bundleID: bundleID)
    }

    func directoryIdentity(_ url: URL) -> String? {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return nil }
        return "\(metadata.st_dev):\(metadata.st_ino)"
    }

    /// Resolve installer-volume aliases before enumeration and preserve the
    /// first source label associated with each physical root.
    private func uniqueRoots(_ roots: [(URL, String)]) -> [(URL, String)] {
        var seen = Set<String>()
        return roots.compactMap { root, source in
            let resolved = root.resolvingSymlinksInPath().standardizedFileURL
            guard let identity = directoryIdentity(resolved), seen.insert(identity).inserted else { return nil }
            return (resolved, source)
        }
    }

    func roots(home: URL) -> [(URL, String)] {
        var roots: [(URL, String)] = [
            (URL(fileURLWithPath: "/Applications", isDirectory: true), "Applications"),
            (URL(fileURLWithPath: "/System/Applications", isDirectory: true), "System Applications"),
            (home.appendingPathComponent("Applications", isDirectory: true), "User Applications"),
            (home.appendingPathComponent("Library/Application Support/Setapp/Applications", isDirectory: true), "Setapp"),
            (home.appendingPathComponent("Library/Application Support/Steam/steamapps/common", isDirectory: true), "Steam")
        ]
        for (path, label) in [("/usr/local", "Package install"), ("/opt", "Package install")] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) { roots.append((url, label)) }
        }
        var seen = Set(roots.map { $0.0.standardizedFileURL.path })
        if let volumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) {
            for volume in volumes {
                let applications = volume.appendingPathComponent("Applications", isDirectory: true)
                let path = applications.standardizedFileURL.path
                guard seen.insert(path).inserted, fileManager.fileExists(atPath: path) else { continue }
                roots.append((applications, "External Applications"))
            }
        }
        return uniqueRoots(roots)
    }
}
