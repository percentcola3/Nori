import AppKit
import Sparkle

@main
struct AppUpdateControllerTests {
    @MainActor static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let domain = Bundle.main.bundleIdentifier!
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let service = AppUpdateController()
        var safe = false
        service.start { safe }
        pump(0.1)
        precondition(service.status == .idle, "A configured updater must start without error")
        precondition(service.canCheckForUpdates, "KVO must enable the manual check after startup")
        precondition(!service.automaticallyChecksForUpdates, "Fixture automatic checks must stay off")
        service.automaticallyChecksForUpdates = true
        service.automaticallyDownloadsUpdates = true
        precondition(service.automaticallyDownloadsUpdates)
        precondition(AppUpdateController().automaticallyDownloadsUpdates,
                     "Sparkle must persist download preferences across controller lifetimes")
        service.automaticallyChecksForUpdates = false
        pump(0.1)

        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                     updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        #if arch(arm64)
        precondition(service.feedURLString(for: updater)!.hasSuffix("appcast-arm64.xml"))
        #else
        precondition(service.feedURLString(for: updater)!.hasSuffix("appcast-x86_64.xml"))
        #endif
        for selector in ["updaterDidNotFindUpdate:error:", "updater:mayPerformUpdateCheck:error:",
                         "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
                         "updater:didFinishUpdateCycleForUpdateCheck:error:"] {
            precondition(service.responds(to: NSSelectorFromString(selector)),
                         "Sparkle must recognize its Swift delegate callback: \(selector)")
        }
        do {
            try service.updater(updater, mayPerform: .updates)
            preconditionFailure("Active tasks must defer update checks")
        } catch {
            precondition(service.status == .deferred)
        }
        safe = true
        try service.updater(updater, mayPerform: .updates)
        precondition(service.status == .checking)

        for reason in [SPUNoUpdateFoundReason.onLatestVersion, .onNewerThanLatestVersion] {
            service.updaterDidNotFindUpdate(updater, error: NSError(
                domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)]))
            precondition(service.status == .upToDate)
        }
        for reason in [SPUNoUpdateFoundReason.unknown, .systemIsTooOld, .hardwareDoesNotSupportARM64] {
            service.updaterDidNotFindUpdate(updater, error: NSError(
                domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)]))
            guard case .failed = service.status else {
                preconditionFailure("Empty or incompatible feeds must not report up to date")
            }
        }
        service.updater(updater, didAbortWithError: NSError(domain: NSURLErrorDomain,
                                                         code: NSURLErrorNotConnectedToInternet))
        guard case .failed = service.status else { preconditionFailure("Network errors must remain failures") }
        service.updater(updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain,
                                          code: Int(SUError.installationCanceledError.rawValue)))
        precondition(service.status == .idle)

        let item = SUAppcastItem.empty()
        var installs = 0
        safe = false
        precondition(service.updater(updater, shouldPostponeRelaunchForUpdate: item,
                                    untilInvokingBlock: { installs += 1 }))
        pump(1.2)
        precondition(installs == 0, "Screenshot/cleanup work must finish before restart")
        safe = true
        pump(1.3)
        precondition(installs == 1, "Deferred installation must resume once idle")
        pump(1.1)
        precondition(installs == 1, "Install handler must run once")
        safe = false
        precondition(service.updater(updater, shouldPostponeRelaunchForUpdate: item,
                                    untilInvokingBlock: { installs += 1 }))
        service.stop()
        safe = true
        pump(1.2)
        precondition(installs == 1, "Termination must discard the deferred restart timer")
        print("PASS: updater startup, persisted preferences, architecture feed, failure states and deferred restart")
    }

    @MainActor private static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }
}
