import AppKit
import CoreServices
import Darwin
import Foundation
import Security

struct ApplicationBundleMetadata: Sendable {
    let name: String
    let bundleID: String
}

/// Application discovery and bundle evidence; no deletion or process control.
protocol ApplicationInventoryReading: Sendable {
    func roots(home: URL) -> [(URL, String)]
    func children(of directory: URL) -> [URL]
    func metadata(at url: URL) -> ApplicationBundleMetadata?
    func applicationGroups(at url: URL) -> Set<String>
    func directoryIdentity(_ url: URL) -> String?
    func installedApps(in roots: [(URL, String)]) -> [UninstallApp]
}

extension ApplicationInventoryReading {
    func applicationGroups(at url: URL) -> Set<String> { [] }
}

struct NativeApplicationInventory: ApplicationInventoryReading {
    private var fileManager: FileManager { .default }
    private let sizer: any ApplicationSizeMeasuring
    private let ownBundleID: String?
    private let discoveredApplications: @Sendable () -> [URL]

    init(sizer: any ApplicationSizeMeasuring = BoundedApplicationSizeMeasurer(),
         ownBundleID: String? = Bundle.main.bundleIdentifier,
         discoveredApplications: @escaping @Sendable () -> [URL] = { Self.systemApplications() }) {
        self.sizer = sizer
        self.ownBundleID = ownBundleID
        self.discoveredApplications = discoveredApplications
    }

    /// Scan canonical roots once; names and Bundle IDs are not unique installs.
    func installedApps(in roots: [(URL, String)]) -> [UninstallApp] {
        var apps: [UninstallApp] = []
        var seen = Set<String>()
        for (root, source) in uniqueRoots(roots) {
            for item in children(of: root) {
                guard item.pathExtension.lowercased() == "app",
                      !item.lastPathComponent.hasPrefix("."),
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

    /// Read group ownership from the embedded signature without launching a
    /// helper process or recursively enumerating the application bundle.
    func applicationGroups(at url: URL) -> Set<String> {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return [] }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [CFString: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        return Set(groups.filter(CleanupRiskPolicy.isValidReverseDNSOwner))
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
            (home.appendingPathComponent("Downloads", isDirectory: true), "Downloads"),
            (home.appendingPathComponent("Desktop", isDirectory: true), "Desktop"),
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
        // Reuse these roots for uninstall sibling checks and orphan detection,
        // so discovering a portable copy also protects its shared app data.
        for app in discoveredApplications() where isStandaloneApplication(app) {
            let parent = app.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(parent.path).inserted else { continue }
            roots.append((parent, "Other Applications"))
        }
        return uniqueRoots(roots)
    }

    private func isStandaloneApplication(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              !url.lastPathComponent.hasPrefix("."),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let ancestors = resolved.deletingLastPathComponent().pathComponents
        // Spotlight and NSWorkspace can also report embedded helpers, trashed
        // copies and Gatekeeper's temporary AppTranslocation mount.
        guard !ancestors.contains(where: {
            $0.hasPrefix(".") || $0 == "AppTranslocation" || $0 == "Contents"
                || $0 == "Caches" || $0 == "DerivedData"
                || ["app", "framework", "bundle", "xpc"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }), !resolved.path.hasPrefix("/System/"),
            (try? resolved.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true,
            let metadata = metadata(at: resolved), !metadata.bundleID.isEmpty,
            metadata.bundleID != ownBundleID, !metadata.bundleID.hasPrefix("com.apple."),
            directoryIdentity(resolved) != nil else { return false }
        return true
    }

    /// Spotlight finds closed apps outside installation folders; the workspace
    /// covers running apps on volumes where indexing is disabled. No disk walk.
    private static func systemApplications() -> [URL] {
        var urls = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        guard let query = MDQueryCreate(kCFAllocatorDefault,
            "kMDItemContentType == 'com.apple.application-bundle'" as CFString, nil, nil) else { return urls }
        MDQuerySetSearchScope(query, [kMDQueryScopeComputerIndexed!] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return urls }
        defer { MDQueryStop(query) }
        for index in 0..<MDQueryGetResultCount(query) {
            guard let result = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(result).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String {
                urls.append(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        return urls
    }
}
