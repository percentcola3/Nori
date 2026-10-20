import Darwin
import Foundation

/// Only a confirmed uninstall may stop processes. Bind every signal to the
/// reviewed app identity, the process start identity and its executable path.
enum UninstallProcessController {
    struct Environment {
        var usesNativeSnapshot = true
        var sample: () -> [ProcessSample] = { ProcessSampler.shared.sample() } {
            didSet { usesNativeSnapshot = false }
        }
        var current: (ProcessIdentity) -> ProcessSample? = { ProcessSampler.shared.current(for: $0) }
        var signal: (Int32, Int32) -> Bool = { kill($0, $1) == 0 }
        var wait: () async -> Void = { try? await Task.sleep(nanoseconds: 100_000_000) }
        var appIsCurrent: (UninstallApp) -> Bool = {
            DeletionPlan.identity(at: $0.path) == $0.appIdentity
                && DeletionPlan.identity(at: $0.path + "/Contents/Info.plist") == $0.infoIdentity
        }
        var uid: UInt32 = getuid()
        var ownPID: Int32 = ProcessInfo.processInfo.processIdentifier
    }

    static func processes(for app: UninstallApp, samples: [ProcessSample]) -> [ProcessSample] {
        ApplicationProcessScope(root: app.path).processes(in: samples)
    }

    /// Re-enumerate to catch helpers spawned during shutdown. A bounded failure
    /// stops the uninstall before any application or residue is moved.
    static func stop(_ app: UninstallApp, environment env: Environment = Environment()) async -> Bool {
        var controller = ApplicationProcessController.Environment()
        controller.snapshot = { .init(processes: env.sample(), isComplete: true) }
        controller.current = env.current
        controller.signal = env.signal
        controller.wait = env.wait
        controller.uid = env.uid
        controller.ownPID = env.ownPID
        // Production requires a complete snapshot; injected fixtures preserve
        // the existing array interface without invoking native discovery.
        if !env.usesNativeSnapshot { controller.stopJobs = { _ in [] } }
        if env.usesNativeSnapshot { controller.snapshot = { ProcessSampler.shared.snapshot() } }
        let outcome = await ApplicationProcessController.stop(.init(root: app.path), remembering: [],
            force: true, environment: controller, stillCurrent: { env.appIsCurrent(app) })
        return outcome.completed
    }
}
