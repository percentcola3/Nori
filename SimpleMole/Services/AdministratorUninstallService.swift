import Darwin
import Foundation

/// Elevation only moves the reviewed /Applications bundle into the requesting
/// user's Trash. Residues still use the normal, unprivileged uninstall plan.
enum AdministratorUninstallPlan {
    static let workerArgument = "--nori-uninstall-administrator"
    static let reportPrefix = "NORI_UNINSTALL_ADMIN\t"

    struct Request: Codable {
        let app: UninstallApp
        let metadata: DeletionPlan.Metadata
    }

    static func allows(_ app: UninstallApp) -> Bool {
        DeletionPlan.isLexicallySafePath(app.path)
            && (app.path as NSString).deletingLastPathComponent == "/Applications"
            && (app.path as NSString).pathExtension.lowercased() == "app"
            && !(app.path as NSString).lastPathComponent.hasPrefix(".")
            && !app.appIdentity.isEmpty && !app.infoIdentity.isEmpty
            && !app.bundleID.isEmpty && app.bundleID != "com.nori.app"
    }

    static func runWorker(arguments: [String]) -> Int32 {
        guard geteuid() == 0, arguments.count == 2,
              let uid = uid_t(arguments[0]), uid != 0,
              let account = getpwuid(uid), let directory = account.pointee.pw_dir,
              let home = String(validatingUTF8: directory),
              DeletionPlan.isLexicallySafePath(home), home != "/",
              let data = AdministratorCleanupPlan.readPrivatePlan(arguments[1], owner: uid),
              let request = try? JSONDecoder().decode(Request.self, from: data) else { return 64 }
        let result = execute(request, home: home, uid: uid)
        guard let report = try? JSONEncoder().encode(AdministratorCleanupPlan.Report(result)),
              let text = String(data: report, encoding: .utf8) else { return 70 }
        print(reportPrefix + text)
        return 0
    }

    static func execute(_ request: Request, home: String, uid: uid_t,
                        core: NativeCore = .shared) -> NativeCore.ApplySummary {
        let app = request.app
        guard allows(app), DeletionPlan.Metadata.read(app.path) == request.metadata,
              DeletionPlan.identity(at: app.path) == app.appIdentity,
              DeletionPlan.identity(at: app.path + "/Contents/Info.plist") == app.infoIdentity,
              bundleIdentifier(app.path) == app.bundleID else {
            return .init(removed: 0, skipped: 0, failed: 1,
                         messages: ["Application changed or is outside the authorized uninstall location."],
                         remainingPaths: [app.path])
        }
        let result = core.applyCleanup(items: [.init(record: app.path, identity: app.appIdentity,
                                              metadata: request.metadata)],
            permanent: false, homeDirectory: home, allowedRoots: [app.path],
            allowApplicationBundle: true,
            finalValidation: { path in
                DeletionPlan.Metadata.read(path) == request.metadata
                    && DeletionPlan.identity(at: path + "/Contents/Info.plist") == app.infoIdentity
                    && bundleIdentifier(path) == app.bundleID
            }, trashHandler: { _ in
                try moveToTrash(request, home: home, uid: uid)
            })
        return core.verifyUninstallResult(result, files: [.init(bytes: 0, label: app.name, path: app.path)])
    }

    private static func bundleIdentifier(_ path: String) -> String? {
        // Check every ancestor with O_NOFOLLOW before Foundation reads metadata.
        let contents = openDirectory(path + "/Contents")
        guard contents >= 0 else { return nil }
        defer { close(contents) }
        let info = openat(contents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard info >= 0 else { return nil }
        defer { close(info) }
        var metadata = stat()
        guard fstat(info, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0, metadata.st_size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes {
                read(info, $0.baseAddress!.advanced(by: offset), remaining)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            offset += count
        }
        let plist = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil)
        return (plist as? [String: Any])?["CFBundleIdentifier"] as? String
    }

    private static func openDirectory(_ path: String) -> Int32 {
        guard DeletionPlan.isLexicallySafePath(path) else { return -1 }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for part in path.split(separator: "/") {
            let next = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return -1 }
            descriptor = next
        }
        return descriptor
    }

    private static func moveToTrash(_ request: Request, home: String, uid: uid_t) throws {
        let source = openDirectory("/Applications")
        guard source >= 0 else { throw POSIXError(.EACCES) }
        defer { close(source) }
        let destinationHome = openDirectory(home)
        guard destinationHome >= 0 else { throw POSIXError(.EACCES) }
        defer { close(destinationHome) }
        var homeMetadata = stat()
        guard fstat(destinationHome, &homeMetadata) == 0, homeMetadata.st_uid == uid else {
            throw POSIXError(.EACCES)
        }
        if mkdirat(destinationHome, ".Trash", 0o700) == 0 {
            guard fchownat(destinationHome, ".Trash", uid, homeMetadata.st_gid, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw POSIXError(.EACCES)
            }
        } else if errno != EEXIST { throw POSIXError(.EACCES) }
        let trash = openat(destinationHome, ".Trash", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard trash >= 0 else { throw POSIXError(.EACCES) }
        defer { close(trash) }
        var trashMetadata = stat(), appMetadata = stat()
        let name = (request.app.path as NSString).lastPathComponent
        guard fstat(trash, &trashMetadata) == 0, trashMetadata.st_uid == uid,
              trashMetadata.st_mode & 0o077 == 0,
              fstatat(source, name, &appMetadata, AT_SYMLINK_NOFOLLOW) == 0,
              appMetadata.st_mode & S_IFMT == S_IFDIR,
              request.metadata.matches(appMetadata),
              DeletionPlan.identity(at: request.app.path + "/Contents/Info.plist") == request.app.infoIdentity,
              bundleIdentifier(request.app.path) == request.app.bundleID else { throw POSIXError(.EACCES) }
        let destination = (name as NSString).deletingPathExtension + " " + UUID().uuidString + ".app"
        guard renameatx_np(source, name, trash, destination, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

enum AdministratorUninstallService {
    static func apply(_ app: UninstallApp) async -> NativeCore.ApplySummary {
        guard AdministratorUninstallPlan.allows(app), let metadata = DeletionPlan.Metadata.read(app.path) else {
            return .init(removed: 0, skipped: 0, failed: 1,
                         messages: ["Administrator uninstall only supports reviewed apps in /Applications."],
                         remainingPaths: [app.path])
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nori-admin-uninstall-" + UUID().uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else {
            return .init(removed: 0, skipped: 0, failed: 1, messages: [String(cString: strerror(errno))])
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("plan.json")
        do {
            let data = try JSONEncoder().encode(AdministratorUninstallPlan.Request(app: app, metadata: metadata))
            try data.write(to: manifest, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        } catch {
            return .init(removed: 0, skipped: 0, failed: 1, messages: [error.localizedDescription])
        }
        let result = await MoleEngine.shared.runPrivilegedBridge("bin/app_uninstall_admin.sh",
            arguments: [String(getuid()), manifest.path], timeout: 900)
        let lines = result.output.components(separatedBy: .newlines).filter {
            $0.hasPrefix(AdministratorUninstallPlan.reportPrefix)
        }
        guard result.succeeded, lines.count == 1,
              let data = lines[0].dropFirst(AdministratorUninstallPlan.reportPrefix.count).data(using: .utf8),
              let report = try? JSONDecoder().decode(AdministratorCleanupPlan.Report.self, from: data),
              report.removed >= 0, report.removed <= 1, report.failed >= 0, report.skipped >= 0,
              report.removedPaths == (report.removed == 1 ? [app.path] : []),
              report.removed == 0 || (report.failed == 0 && report.skipped == 0) else {
            return .init(removed: 0, skipped: 0, failed: 1, messages: [result.diagnosticOutput],
                         remainingPaths: [app.path])
        }
        return .init(removed: report.removed, skipped: report.skipped,
                     failed: report.removed == 0 ? max(report.failed, 1) : report.failed,
                     messages: report.messages, removedPaths: Set(report.removedPaths),
                     remainingPaths: report.removed == 1 ? [] : [app.path])
    }
}
