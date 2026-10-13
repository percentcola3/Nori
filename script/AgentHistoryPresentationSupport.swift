import Foundation

// The presentation harness renders the real history view/store, with all
// provider I/O disabled. It never reads user histories or runs Agent CLIs.
enum AgentHistoryService {
    static let interfacesEnabled = false
    static func list(context: AgentHistoryContext) async throws -> AgentHistoryInventory {
        throw AgentHistoryFailure("agents.history.pendingValidation")
    }
    static func delete(inventory: AgentHistoryInventory, selected: [AgentHistorySession],
                       progress: @escaping @Sendable (Int, Int) -> Void) async -> AgentHistoryDeleteResult {
        var result = AgentHistoryDeleteResult()
        for row in selected { result.failed[row.id] = "agents.history.pendingValidation" }
        return result
    }
}
