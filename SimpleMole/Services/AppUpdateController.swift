import AppKit
import Combine
import Sparkle

/// Sparkle owns scheduling, persisted preferences, signature verification and installation.
@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, NSMenuItemValidation {
    static let shared = AppUpdateController()

    enum Status: Equatable {
        case idle, checking, updateAvailable(String), upToDate, deferred, failed(String)
    }

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var status: Status = .idle
    private var observations = Set<AnyCancellable>()
    private var started = false
    private var userInitiatedCycle = false
    private var isSafeToRelaunch: () -> Bool = { true }
    private var postponedInstallation: (() -> Void)?
    private var relaunchTimer: Timer?
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func start(isSafeToRelaunch: @escaping () -> Bool) {
        guard !started else { return }
        self.isSafeToRelaunch = isSafeToRelaunch
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
        do {
            try updater.start()
            started = true
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        userInitiatedCycle = true
        controller.checkForUpdates(nil)
    }

    @objc func checkForUpdatesFromMenu(_ sender: Any?) { checkForUpdates() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheckForUpdates }

    func feedURLString(for updater: SPUUpdater) -> String? {
        // Select the installed executable's architecture, including an Intel build under Rosetta.
        // Hardware detection could replace that build with an incompatible architecture.
        #if arch(arm64)
        return "https://github.com/percentcola3/sweep/releases/latest/download/appcast-arm64.xml"
        #else
        return "https://github.com/percentcola3/sweep/releases/latest/download/appcast-x86_64.xml"
        #endif
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard isSafeToRelaunch() else {
            status = .deferred
            throw NSError(domain: "com.nori.app.updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.shared.t("updates.busy")])
        }
        status = .checking
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .updateAvailable(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let error = error as NSError
        let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue ?? -1
        if reason == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
            || reason == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) {
            status = .upToDate
        } else {
            // An empty/incompatible feed is not evidence that this is the latest version.
            reportUpdateFailure(error)
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        // Sparkle also aborts a cycle when it has positively found no newer compatible version.
        if nsError.domain == SUSparkleErrorDomain, nsError.code == SUError.noUpdateError.rawValue { return }
        if nsError.domain == "com.nori.app.updates" { return }
        if nsError.domain == SUSparkleErrorDomain, nsError.code == SUError.installationCanceledError.rawValue {
            status = .idle
            return
        }
        reportUpdateFailure(error)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if status == .checking { status = .idle }
        userInitiatedCycle = false
    }

    private func reportUpdateFailure(_ error: Error) {
        status = .failed(error.localizedDescription)
        if userInitiatedCycle {
            TaskFeedbackNotice.reportFailure(details: [error.localizedDescription])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard !isSafeToRelaunch() else { return false }
        status = .deferred
        postponedInstallation = installHandler
        relaunchTimer?.invalidate()
        relaunchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.resumeInstallationIfSafe() }
        }
        relaunchTimer?.tolerance = 0.2
        return true
    }

    private func resumeInstallationIfSafe() {
        guard isSafeToRelaunch(), let install = postponedInstallation else { return }
        relaunchTimer?.invalidate()
        relaunchTimer = nil
        postponedInstallation = nil
        install()
    }

    func stop() {
        relaunchTimer?.invalidate()
        relaunchTimer = nil
        postponedInstallation = nil
    }
}
