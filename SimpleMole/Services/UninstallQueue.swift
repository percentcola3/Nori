import Foundation

/// A confirmed request owns its app identity and preview snapshot. It never
/// reads the currently selected row when it eventually reaches the worker.
struct UninstallJob: Identifiable, Equatable {
    enum Scope: Equatable {
        case applicationAndResidues
        case installationOnly
    }
    enum State: Equatable {
        case queued, preparing, running, succeeded, failed

        var isPending: Bool { self == .queued }
        var isActive: Bool { self == .preparing || self == .running }
        var isFinished: Bool { self == .succeeded || self == .failed }
    }

    let id: UUID
    let app: UninstallApp
    let plan: UninstallPlan?
    let dataPaths: Set<String>
    let scope: Scope
    fileprivate(set) var state: State = .queued
    fileprivate(set) var message: String?

    init(id: UUID, app: UninstallApp, plan: UninstallPlan?, dataPaths: Set<String>,
         scope: Scope = .applicationAndResidues) {
        self.id = id
        self.app = app
        self.plan = plan
        self.dataPaths = dataPaths
        self.scope = scope
    }
}

/// Main-actor-owned, in-memory FIFO. Confirmations are intentionally not
/// persisted: restarting the app must not resume destructive work by itself.
struct UninstallQueue {
    private(set) var jobs: [UninstallJob] = []

    var activeJob: UninstallJob? { jobs.first { $0.state.isActive } }
    var hasPendingJobs: Bool { jobs.contains { $0.state.isPending } }
    var hasWork: Bool { activeJob != nil || hasPendingJobs }

    func containsPendingOrActive(_ app: UninstallApp) -> Bool {
        let path = URL(fileURLWithPath: app.path).standardizedFileURL.path
        return jobs.contains {
            !$0.state.isFinished
                && URL(fileURLWithPath: $0.app.path).standardizedFileURL.path == path
        }
    }

    @discardableResult
    mutating func enqueue(app: UninstallApp, plan: UninstallPlan?, dataPaths: Set<String> = [],
                          scope: UninstallJob.Scope = .applicationAndResidues) -> UUID? {
        guard !app.appIdentity.isEmpty, !containsPendingOrActive(app) else { return nil }
        jobs.removeAll { $0.state.isFinished && $0.app.id == app.id }
        let job = UninstallJob(id: UUID(), app: app, plan: plan, dataPaths: dataPaths, scope: scope)
        jobs.append(job)
        trimHistory()
        return job.id
    }

    /// The caller supplies the shared disk-work gate. Starting is atomic, so
    /// repeated UI/Combine notifications cannot create a second worker.
    mutating func startNext(blocked: Bool) -> UninstallJob? {
        guard !blocked, activeJob == nil,
              let index = jobs.firstIndex(where: { $0.state.isPending }) else { return nil }
        // Every request refreshes disposable residues before applying, even
        // when the list already had a cached size/preview.
        jobs[index].state = .preparing
        return jobs[index]
    }

    @discardableResult
    mutating func markRunning(_ id: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.state.isActive }) else {
            return false
        }
        jobs[index].state = .running
        return true
    }

    @discardableResult
    mutating func finish(_ id: UUID, succeeded: Bool, message: String) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.state.isActive }) else {
            return false
        }
        jobs[index].state = succeeded ? .succeeded : .failed
        jobs[index].message = message
        trimHistory()
        return true
    }

    @discardableResult
    mutating func cancel(_ id: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.state.isPending }) else {
            return false
        }
        jobs.remove(at: index)
        return true
    }

    private mutating func trimHistory() {
        let oldIDs = Set(jobs.filter { $0.state.isFinished }.dropLast(8).map(\.id))
        jobs.removeAll { oldIDs.contains($0.id) }
    }
}
