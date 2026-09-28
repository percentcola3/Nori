import Foundation
import ServiceManagement

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var failure: Error?
    var registrations = 0
    var removals = 0

    func register() throws {
        registrations += 1
        if let failure { throw failure }
        status = registrationStatus
    }

    func unregister() async throws {
        removals += 1
        if let failure { throw failure }
        status = .notRegistered
    }
}

@main
struct LoginItemControllerTests {
    @MainActor static func main() async {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service)
        controller.refresh()
        precondition(!controller.isRequested && service.registrations == 0,
                     "Startup and status refresh must never opt the user into login launch")

        await controller.setEnabled(true)
        precondition(controller.status == .enabled && service.registrations == 1)
        await controller.setEnabled(true)
        precondition(service.registrations == 1, "Already registered must not register again")
        await controller.setEnabled(false)
        precondition(!controller.isRequested && service.removals == 1)
        await controller.setEnabled(false)
        precondition(service.removals == 1)

        service.registrationStatus = .requiresApproval
        await controller.setEnabled(true)
        precondition(controller.isRequested && controller.needsApproval,
                     "Pending system approval must be shown separately from enabled")
        await controller.setEnabled(true)
        precondition(service.registrations == 2, "Pending approval must not be registered twice")
        await controller.setEnabled(false)
        precondition(!controller.isRequested && service.removals == 2,
                     "The user must be able to cancel a pending registration")

        service.failure = NSError(domain: "LoginItemTest", code: 1)
        await controller.setEnabled(true)
        precondition(!controller.isRequested && controller.errorMessage != nil && !controller.isUpdating,
                     "Registration failure must not leave a false enabled state or disable the control")
        service.failure = nil
        service.registrationStatus = .enabled
        await controller.setEnabled(true)
        precondition(controller.isRequested && controller.errorMessage == nil)
        service.failure = NSError(domain: "LoginItemTest", code: 2)
        await controller.setEnabled(false)
        precondition(controller.isRequested && controller.errorMessage != nil,
                     "Unregister failure must retain the actual system state")

        service.status = .notRegistered
        controller.refresh()
        precondition(!controller.isRequested, "External system changes must be reflected")
        service.failure = nil
        await controller.setEnabled(true)
        precondition(controller.status == .enabled)

        print("Login items: opt-in only, register/unregister, approval, failures and external changes passed")
    }
}
