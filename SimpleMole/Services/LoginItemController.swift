import Combine
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: LoginItemService {}

/// macOS owns the preference. Reading status never registers or repairs a login item.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?
    private let service: any LoginItemService

    init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
        status = service.status
    }

    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        refresh()
        defer {
            refresh()
            isUpdating = false
        }
        do {
            if enabled && !isRequested {
                try service.register()
            } else if !enabled && isRequested {
                try await service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
