import Foundation
import SQLite3
import Darwin

struct DirectorySearchHit: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool
    var id: String { url.path }
}

struct DirectoryIndexStatus: Sendable {
    let roots: [URL]
    let indexedItemCount: Int
    let lastUpdated: Date?
    let isBuilding: Bool
}

struct DirectoryIndexProgress: Sendable {
    let scannedCount: Int
    let skippedCount: Int
    let currentPath: String
}

enum DirectorySearchError: LocalizedError {
    case database(String)
    case invalidRoot(String)
    case alreadyBuilding
    case spotlightUnavailable

    var errorDescription: String? {
        switch self {
        case .database(let reason): return L10n.shared.tf("dir.searchError.database", reason)
        case .invalidRoot(let path): return L10n.shared.tf("dir.searchError.root", path)
        case .alreadyBuilding: return L10n.shared.t("dir.searchError.busy")
        case .spotlightUnavailable: return L10n.shared.t("dir.searchError.spotlight")
        }
    }
}

/// A private, persistent filename snapshot supplementing Spotlight, including dotfiles.
/// Enumeration reads metadata only. No file contents, symlinks or cloud downloads are followed.
/// External changes require explicit refresh; Nori mutations update affected paths immediately.
actor DirectorySearchIndex {
    private let database: OpaquePointer
    private let databaseDirectory: URL
    private let usesTrigrams: Bool
    private var isBuilding = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let excludedNames: Set<String> = [
        ".Trash", ".Trashes", ".fseventsd", ".Spotlight-V100", ".TemporaryItems", ".DocumentRevisions-V100"
    ]
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
    ]

    init(databaseURL: URL? = nil) throws {
        let url = databaseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nori/DirectoryIndex/files.sqlite", isDirectory: false)
        databaseDirectory = url.deletingLastPathComponent().standardizedFileURL
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let connection { sqlite3_close(connection) }
            throw DirectorySearchError.database(message)
        }
        database = connection
        sqlite3_busy_timeout(connection, 3_000)
        do {
            try Self.execute(connection, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            try Self.execute(connection, """
                CREATE TABLE IF NOT EXISTS files (
                    id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
                    folded_name TEXT NOT NULL, directory INTEGER NOT NULL, hidden INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS files_name ON files(folded_name);
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS pending_files (
                    path TEXT PRIMARY KEY, name TEXT NOT NULL, folded_name TEXT NOT NULL,
                    directory INTEGER NOT NULL, hidden INTEGER NOT NULL
                );
                DELETE FROM pending_files;
                """)
            // FTS5's trigram tokenizer accelerates infix filename searches. Older SQLite builds
            // without this optional tokenizer fall back to the same literal LIKE semantics.
            usesTrigrams = (try? Self.execute(connection, """
                CREATE VIRTUAL TABLE IF NOT EXISTS filename_search USING fts5(
                    folded_name, content='files', content_rowid='id', tokenize='trigram'
                );
                CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
                    INSERT INTO filename_search(rowid, folded_name) VALUES (new.id, new.folded_name);
                END;
                CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
                    INSERT INTO filename_search(filename_search, rowid, folded_name)
                    VALUES ('delete', old.id, old.folded_name);
                END;
                """)) != nil
        } catch {
            sqlite3_close(connection)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    /// Empty the persisted snapshot in place. The open database file is never
    /// unlinked: cleanup reaches this index only through the managed route.
    /// FTS triggers keep filename_search consistent with the emptied table.
    func clear() throws {
        guard !isBuilding else { throw DirectorySearchError.alreadyBuilding }
        try execute("DELETE FROM files; DELETE FROM pending_files; DELETE FROM metadata;")
        try execute("VACUUM;")
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    func status() throws -> DirectoryIndexStatus {
        let countStatement = try prepare("SELECT COUNT(*) FROM files")
        defer { sqlite3_finalize(countStatement) }
        try step(countStatement, expected: SQLITE_ROW)
        let rootData = try metadata("roots").flatMap { $0.data(using: .utf8) }
        let paths = rootData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let updated = try metadata("updated").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        return DirectoryIndexStatus(roots: paths.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                    indexedItemCount: Int(sqlite3_column_int64(countStatement, 0)),
                                    lastUpdated: updated, isBuilding: isBuilding)
    }

    func search(query: String, showHidden: Bool = true, limit: Int = 300) async throws -> [DirectorySearchHit] {
        try Task.checkCancellation()
        let folded = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folded.isEmpty, limit > 0 else { return [] }
        let bound = min(limit, 1_000)
        let useFTS = usesTrigrams && folded.unicodeScalars.count >= 3
        let statement = try prepare("""
            SELECT files.path, files.name, files.directory, files.hidden FROM files
            \(useFTS ? "JOIN filename_search ON filename_search.rowid=files.id" : "")
            WHERE \(useFTS ? "filename_search MATCH ? AND " : "")files.folded_name LIKE ? ESCAPE '\\'
            \(showHidden ? "" : "AND files.hidden=0")
            ORDER BY CASE WHEN files.folded_name=? THEN 0 ELSE 1 END, files.folded_name, files.path
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        var position: Int32 = 1
        if useFTS {
            try bind("\"" + folded.replacingOccurrences(of: "\"", with: "\"\"") + "\"", to: statement, at: position)
            position += 1
        }
        try bind("%" + Self.escapeLike(folded) + "%", to: statement, at: position)
        try bind(folded, to: statement, at: position + 1)
        sqlite3_bind_int(statement, position + 2, Int32(bound * 4))
        installCancellationHandler()
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        var hits: [DirectorySearchHit] = []
        while try next(statement) {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: string(statement, 0))
            // A deleted snapshot row must never be offered as an actionable file.
            guard Self.pathStatus(url) != nil else { continue }
            hits.append(DirectorySearchHit(url: url, name: string(statement, 1),
                                           isDirectory: sqlite3_column_int(statement, 2) != 0,
                                           isHidden: sqlite3_column_int(statement, 3) != 0))
            if hits.count == bound { break }
        }
        return hits
    }

    func searchPath(_ query: DirectoryPathQuery, showHidden: Bool, limit: Int = 100) throws -> [URL] {
        let fragments = query.indexFragments
        guard !fragments.isEmpty else { return [] }
        let clauses = fragments.map { _ in "folded_name LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
        let statement = try prepare("SELECT path FROM files WHERE (\(clauses)) \(showHidden ? "" : "AND hidden=0") ORDER BY path LIMIT 2000")
        defer { sqlite3_finalize(statement) }
        for (offset, fragment) in fragments.enumerated() {
            try bind("%" + Self.escapeLike(fragment) + "%", to: statement, at: Int32(offset + 1))
        }
        installCancellationHandler()
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        var scored: [(URL, Int)] = []
        while try next(statement) {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: string(statement, 0))
            let score = query.score(url)
            if score >= 55, Self.pathStatus(url) != nil { scored.append((url, score)) }
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Builds a replacement snapshot and publishes it atomically. Cancellation preserves
    /// the previous searchable snapshot and its root list and timestamp.
    func rebuild(roots: [URL], progress: @Sendable (DirectoryIndexProgress) -> Void = { _ in }) async throws -> DirectoryIndexStatus {
        guard !isBuilding else { throw DirectorySearchError.alreadyBuilding }
        let resolvedRoots = try Self.validateRoots(roots)
        isBuilding = true
        defer { isBuilding = false }
        try execute("DELETE FROM pending_files")
        try execute("BEGIN IMMEDIATE")
        do {
            var scanned = 0
            var skipped = 0
            for root in resolvedRoots {
                try await enumerate(root, into: "pending_files", scanned: &scanned, skipped: &skipped, progress: progress)
            }
            try Task.checkCancellation()
            try execute("COMMIT")
            installCancellationHandler()
            defer { sqlite3_progress_handler(database, 0, nil, nil) }
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("DELETE FROM files; INSERT INTO files(path,name,folded_name,directory,hidden) SELECT path,name,folded_name,directory,hidden FROM pending_files;")
                let data = try JSONEncoder().encode(resolvedRoots.map(\.path))
                try setMetadata("roots", value: String(decoding: data, as: UTF8.self))
                try setMetadata("updated", value: String(Date().timeIntervalSince1970))
                try Task.checkCancellation()
                try execute("COMMIT")
            } catch {
                sqlite3_progress_handler(database, 0, nil, nil)
                try? execute("ROLLBACK")
                throw error
            }
            try execute("DELETE FROM pending_files")
        } catch {
            sqlite3_progress_handler(database, 0, nil, nil)
            try? execute("ROLLBACK")
            try? execute("DELETE FROM pending_files")
            throw error
        }
        let result = try status()
        return DirectoryIndexStatus(roots: result.roots, indexedItemCount: result.indexedItemCount,
                                    lastUpdated: result.lastUpdated, isBuilding: false)
    }

    /// Updates only changed files/subtrees within configured roots, including removal of
    /// old paths after rename, move or trash. Overlapping paths are collapsed before scanning.
    func refresh(paths: [URL]) async throws {
        guard !isBuilding else { throw DirectorySearchError.alreadyBuilding }
        let roots = try status().roots
        let targets = Self.compactRoots(paths.filter(\.isFileURL).map(\.standardizedFileURL)).filter { target in
            roots.contains { Self.contains($0, target) }
        }
        guard !targets.isEmpty else { return }
        isBuilding = true
        defer { isBuilding = false }
        try execute("DELETE FROM pending_files")
        try execute("BEGIN IMMEDIATE")
        do {
            var scanned = 0
            var skipped = 0
            for target in targets {
                try Task.checkCancellation()
                if Self.pathStatus(target) != nil {
                    try await enumerate(target, into: "pending_files", scanned: &scanned, skipped: &skipped, progress: { _ in })
                }
            }
            try Task.checkCancellation()
            try execute("COMMIT")
            installCancellationHandler()
            defer { sqlite3_progress_handler(database, 0, nil, nil) }
            try execute("BEGIN IMMEDIATE")
            do {
                for target in targets {
                    let statement = try prepare("DELETE FROM files WHERE path=? OR path LIKE ? ESCAPE '\\'")
                    defer { sqlite3_finalize(statement) }
                    try bind(target.path, to: statement, at: 1)
                    try bind(Self.escapeLike(target.path + "/") + "%", to: statement, at: 2)
                    try step(statement)
                }
                try execute("INSERT OR REPLACE INTO files(path,name,folded_name,directory,hidden) SELECT path,name,folded_name,directory,hidden FROM pending_files;")
                try setMetadata("updated", value: String(Date().timeIntervalSince1970))
                try Task.checkCancellation()
                try execute("COMMIT")
            } catch {
                sqlite3_progress_handler(database, 0, nil, nil)
                try? execute("ROLLBACK")
                throw error
            }
            try execute("DELETE FROM pending_files")
        } catch {
            sqlite3_progress_handler(database, 0, nil, nil)
            try? execute("ROLLBACK")
            try? execute("DELETE FROM pending_files")
            throw error
        }
    }

    private func enumerate(_ root: URL, into table: String, scanned: inout Int, skipped: inout Int,
                           progress: @Sendable (DirectoryIndexProgress) -> Void) async throws {
        try Task.checkCancellation()
        guard !Self.contains(databaseDirectory, root) else { return }
        let statement = try prepare("INSERT OR REPLACE INTO \(table)(path,name,folded_name,directory,hidden) VALUES (?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        guard let rootStatus = Self.pathStatus(root) else { skipped += 1; return }
        if (rootStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            try insert(root, directory: false, hidden: (rootStatus.st_flags & UInt32(UF_HIDDEN)) != 0, using: statement)
            scanned += 1
            return
        }
        if Self.isDatalessDirectory(rootStatus) {
            try insert(root, directory: true, hidden: (rootStatus.st_flags & UInt32(UF_HIDDEN)) != 0, using: statement)
            scanned += 1
            return
        }
        let rootValues = try root.resourceValues(forKeys: Self.resourceKeys)
        try insert(root, values: rootValues, using: statement)
        scanned += 1
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              rootValues.isPackage != true, !Self.isUndownloadedCloudDirectory(rootValues) else { return }
        let failures = DirectoryEnumerationFailures()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [.skipsPackageDescendants], errorHandler: { _, _ in failures.increment(); return true }) else {
            skipped += 1
            return
        }
        let physicalRoot = Self.physicalURL(root)
        var visited = 0
        while let enumeratedURL = enumerator.nextObject() as? URL {
            // Foundation returns physical /private/var paths when the selected scope uses
            // /var or /tmp. Preserve the caller's root spelling so later incremental updates
            // delete precisely the same paths, without resolving an encountered symlink.
            let url: URL
            if root.path != physicalRoot.path, Self.contains(physicalRoot, enumeratedURL) {
                let suffix = String(enumeratedURL.path.dropFirst(physicalRoot.path.count))
                url = URL(fileURLWithPath: root.path + suffix)
            } else {
                url = enumeratedURL
            }
            try Task.checkCancellation()
            visited += 1
            if visited % 256 == 0 {
                progress(DirectoryIndexProgress(scannedCount: scanned, skippedCount: skipped + failures.count,
                                                 currentPath: url.path))
                await Task.yield()
                try Task.checkCancellation()
            }
            if Self.contains(databaseDirectory, url) || Self.excludedNames.contains(url.lastPathComponent)
                || (url.lastPathComponent == "Caches" && url.deletingLastPathComponent().lastPathComponent == "Library") {
                enumerator.skipDescendants()
                skipped += 1
                continue
            }
            guard let pathStatus = Self.pathStatus(url) else {
                enumerator.skipDescendants()
                skipped += 1
                continue
            }
            if (pathStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                try insert(url, directory: false, hidden: (pathStatus.st_flags & UInt32(UF_HIDDEN)) != 0, using: statement)
                scanned += 1
                enumerator.skipDescendants()
                continue
            }
            if Self.isDatalessDirectory(pathStatus) {
                try insert(url, directory: true, hidden: (pathStatus.st_flags & UInt32(UF_HIDDEN)) != 0, using: statement)
                scanned += 1
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Self.resourceKeys) else {
                enumerator.skipDescendants()
                skipped += 1
                continue
            }
            try insert(url, values: values, using: statement)
            scanned += 1
            if values.isSymbolicLink == true || Self.isUndownloadedCloudDirectory(values) {
                enumerator.skipDescendants()
            }
        }
        skipped += failures.count
        progress(DirectoryIndexProgress(scannedCount: scanned, skippedCount: skipped, currentPath: root.path))
    }

    private func insert(_ url: URL, values: URLResourceValues, using statement: OpaquePointer) throws {
        try insert(url, directory: values.isDirectory == true && values.isSymbolicLink != true,
                   hidden: values.isHidden == true, using: statement)
    }

    private func insert(_ url: URL, directory: Bool, hidden: Bool, using statement: OpaquePointer) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bind(url.path, to: statement, at: 1)
        try bind(url.lastPathComponent, to: statement, at: 2)
        try bind(Self.fold(url.lastPathComponent), to: statement, at: 3)
        sqlite3_bind_int(statement, 4, directory ? 1 : 0)
        sqlite3_bind_int(statement, 5, Self.isHidden(url) || hidden ? 1 : 0)
        try step(statement)
    }

    static func isHidden(_ url: URL) -> Bool {
        url.pathComponents.contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
    }

    static func pathStatus(_ url: URL) -> stat? {
        guard url.isFileURL else { return nil }
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &status)
        }
        return result == 0 ? status : nil
    }

    private static func physicalURL(_ url: URL) -> URL {
        // URL.resolvingSymlinksInPath() deliberately standardizes /private/var back
        // to /var on macOS; POSIX realpath retains the spelling used by enumerator.
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return url }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved))
        }
    }

    private static func isDatalessDirectory(_ status: stat) -> Bool {
        (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && (status.st_flags & UInt32(SF_DATALESS)) != 0
    }

    private static func isUndownloadedCloudDirectory(_ values: URLResourceValues) -> Bool {
        values.isDirectory == true && values.isUbiquitousItem == true
            && values.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    private static func validateRoots(_ roots: [URL]) throws -> [URL] {
        for root in roots where !root.isFileURL { throw DirectorySearchError.invalidRoot(root.absoluteString) }
        let result = compactRoots(roots.map(\.standardizedFileURL))
        for root in result {
            guard let status = pathStatus(root), (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw DirectorySearchError.invalidRoot(root.path)
            }
        }
        return result
    }

    private static func compactRoots(_ roots: [URL]) -> [URL] {
        var result: [URL] = []
        for root in Set(roots).sorted(by: { $0.path.count < $1.path.count }) {
            if !result.contains(where: { contains($0, root) }) { result.append(root) }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func contains(_ root: URL, _ child: URL) -> Bool {
        root.path == child.path || child.path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func metadata(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM metadata WHERE key=?")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        return try next(statement) ? string(statement, 0) : nil
    }

    private func setMetadata(_ key: String, value: String) throws {
        let statement = try prepare("INSERT OR REPLACE INTO metadata(key,value) VALUES (?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        try bind(value, to: statement, at: 2)
        try step(statement)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DirectorySearchError.database(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, at position: Int32) throws {
        guard sqlite3_bind_text(statement, position, value, -1, Self.transient) == SQLITE_OK else {
            throw DirectorySearchError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func string(_ statement: OpaquePointer, _ position: Int32) -> String {
        sqlite3_column_text(statement, position).map { String(cString: $0) } ?? ""
    }

    private func step(_ statement: OpaquePointer, expected: Int32 = SQLITE_DONE) throws {
        let result = sqlite3_step(statement)
        if result == SQLITE_INTERRUPT { throw CancellationError() }
        guard result == expected else { throw DirectorySearchError.database(String(cString: sqlite3_errmsg(database))) }
    }

    private func next(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        if result == SQLITE_INTERRUPT { throw CancellationError() }
        throw DirectorySearchError.database(String(cString: sqlite3_errmsg(database)))
    }

    private func installCancellationHandler() {
        sqlite3_progress_handler(database, 1_000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
    }

    private func execute(_ sql: String) throws { try Self.execute(database, sql) }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        if result == SQLITE_INTERRUPT { throw CancellationError() }
        guard result == SQLITE_OK else { throw DirectorySearchError.database(String(cString: sqlite3_errmsg(database))) }
    }
}

private final class DirectoryEnumerationFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return failures }
    func increment() { lock.lock(); failures += 1; lock.unlock() }
}

/// Uses the system-maintained global index rather than crawling all mounted disks on each keystroke.
/// A single request is bounded, and a replaced/cancelled request always releases its continuation.
@MainActor
final class DirectorySpotlightSearch {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var continuation: CheckedContinuation<[URL], Error>?
    private var timeout: Task<Void, Never>?
    private var requestID: UUID?
    private var showHidden = true
    private var limit = 300

    func search(query text: String, showHidden: Bool = true, limit: Int = 300) async throws -> [URL] {
        cancel()
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, limit > 0 else { return [] }
        let id = UUID()
        requestID = id
        self.showHidden = showHidden
        self.limit = min(limit, 1_000)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let query = NSMetadataQuery()
                self.query = query
                query.searchScopes = [NSMetadataQueryLocalComputerScope]
                query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemFSName", text)
                query.notificationBatchingInterval = 0.1
                for notification in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryGatheringProgress] {
                    observers.append(NotificationCenter.default.addObserver(forName: notification, object: query, queue: .main) { [weak self] notification in
                        let finished = notification.name == Notification.Name.NSMetadataQueryDidFinishGathering
                        Task { @MainActor [weak self] in
                            guard let self, self.requestID == id else { return }
                            if finished || (self.query?.resultCount ?? 0) >= self.limit { self.finish() }
                        }
                    })
                }
                guard query.start() else {
                    complete(.failure(DirectorySearchError.spotlightUnavailable))
                    return
                }
                timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled, let self, self.requestID == id else { return }
                    self.finish()
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.requestID == id else { return }
                self?.cancel()
            }
        })
    }

    func cancel() { complete(.failure(CancellationError())) }

    private func finish() {
        guard let query else { return }
        query.disableUpdates()
        var results: [URL] = []
        var seen = Set<String>()
        // Spotlight itself collects its matches; materializing paths/icons is capped here.
        for position in 0..<query.resultCount {
            guard let item = query.result(at: position) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            if !showHidden && (DirectorySearchIndex.isHidden(url) || (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true) { continue }
            guard seen.insert(path).inserted, DirectorySearchIndex.pathStatus(url) != nil else { continue }
            results.append(url)
            if results.count >= limit { break }
        }
        complete(.success(results))
    }

    private func complete(_ result: Result<[URL], Error>) {
        query?.stop()
        query = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        timeout?.cancel()
        timeout = nil
        requestID = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

/// Path input is resolved without opening files or walking entire volumes.
/// Existing ancestors supply bounded fuzzy candidates; the persistent index adds
/// matches when an ancestor is misspelled or the supplied path is only a suffix.
struct DirectoryPathQuery: Sendable {
    let text: String
    let components: [String]
    let isAbsolute: Bool

    init?(_ raw: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("file://") {
            guard let url = URL(string: value), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            value = url.path
        }
        value = value.replacingOccurrences(of: "\\ ", with: " ")
        guard value.contains("/") || value == "~" else { return nil }
        if value == "~" || value.hasPrefix("~/") { value = home.path + value.dropFirst() }
        isAbsolute = value.hasPrefix("/")
        text = isAbsolute ? URL(fileURLWithPath: value).standardizedFileURL.path : value
        components = text.split(separator: "/").map(String.init)
        guard components.count <= 64, value.count <= 4096 else { return nil }
    }

    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func similarity(_ left: String, _ right: String) -> Double {
        let a = Array(fold(left)), b = Array(fold(right))
        if a == b { return 1 }
        guard !a.isEmpty, !b.isEmpty, a.count <= 255, b.count <= 255 else { return 0 }
        if fold(right).contains(fold(left)) { return 0.8 + 0.1 * Double(a.count) / Double(b.count) }
        // Optimal string alignment also handles the common adjacent-letter typo.
        var previous = Array(0...b.count), beforePrevious = previous
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(row[j - 1] + 1, previous[j] + 1,
                             previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    row[j] = min(row[j], beforePrevious[j - 2] + 1)
                }
            }
            beforePrevious = previous; previous = row
        }
        return max(0, 1 - Double(previous[b.count]) / Double(max(a.count, b.count)))
    }

    func score(_ url: URL) -> Int {
        let actual = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
        if text == url.standardizedFileURL.path { return 100 }
        if components.isEmpty { return url.path == "/" ? 100 : 0 }
        let requested = components.filter { $0 != "." }
        guard let leaf = requested.last, let actualLeaf = actual.last else { return 0 }
        let leafScore = Self.similarity(leaf, actualLeaf)
        guard leafScore >= 0.5 else { return 0 }
        let pairs = Array(zip(requested.reversed(), actual.reversed()))
        let context = pairs.map { Self.similarity($0.0, $0.1) }.reduce(0, +) / Double(max(1, requested.count))
        let lengthPenalty = isAbsolute ? Double(abs(requested.count - actual.count)) * 0.025 : 0
        return min(99, max(1, Int((leafScore * 0.55 + context * 0.45 - lengthPenalty) * 100)))
    }

    func localCandidates(currentDirectory: URL, showHidden: Bool) throws -> [URL] {
        let manager = FileManager.default
        let exact = URL(fileURLWithPath: text, relativeTo: isAbsolute ? nil : currentDirectory).standardizedFileURL
        var result: [URL] = manager.fileExists(atPath: exact.path) ? [exact] : []
        var frontier = [isAbsolute ? URL(fileURLWithPath: "/", isDirectory: true) : currentDirectory]
        for (position, component) in components.enumerated() {
            try Task.checkCancellation()
            if component == "." { continue }
            if component == ".." { frontier = frontier.map { $0.deletingLastPathComponent() }; continue }
            var next: [(URL, Double)] = []
            for parent in frontier {
                let precise = parent.appendingPathComponent(component)
                if manager.fileExists(atPath: precise.path) {
                    next.append((precise, 1))
                    // Avoid enumerating high fan-out ancestors when they match exactly.
                    continue
                }
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey,
                                               .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
                guard let enumerator = manager.enumerator(at: parent, includingPropertiesForKeys: Array(keys),
                                                          options: [.skipsSubdirectoryDescendants]) else { continue }
                var inspected = 0
                while let child = enumerator.nextObject() as? URL, inspected < 4096 {
                    inspected += 1
                    try Task.checkCancellation()
                    guard let values = try? child.resourceValues(forKeys: keys),
                          showHidden || !(values.isHidden == true || child.lastPathComponent.hasPrefix(".")) else { continue }
                    if position < components.count - 1 {
                        guard values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true,
                              values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current else { continue }
                    }
                    let match = Self.similarity(component, child.lastPathComponent)
                    if match >= 0.5 { next.append((parent.appendingPathComponent(child.lastPathComponent), match)) }
                }
            }
            frontier = next.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.prefix(8).map(\.0)
            if frontier.isEmpty { break }
        }
        result += frontier
        var seen = Set<String>()
        return result.filter { seen.insert($0.path).inserted && score($0) > 0 }
    }

    var indexFragments: [String] {
        guard let leaf = components.last else { return [] }
        let folded = Self.fold(leaf)
        if folded.count <= 2 { return [folded] }
        return Array(Set([String(folded.prefix(2)), String(folded.suffix(2))])).sorted()
    }
}

/// Shared validation for system URL events. It never executes a path or URL.
enum DirectoryRevealRequest {
    static func fileURL(from url: URL) -> URL? {
        if url.isFileURL {
            guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            return url.standardizedFileURL
        }
        guard url.scheme?.lowercased() == "nori", url.host?.lowercased() == "reveal",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let text = parts.queryItems?.first(where: { $0.name == "path" })?.value,
              let query = DirectoryPathQuery(text), query.isAbsolute else { return nil }
        return URL(fileURLWithPath: query.text).standardizedFileURL
    }
}
