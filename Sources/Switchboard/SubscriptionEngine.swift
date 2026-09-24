import Foundation
import SwitchboardCore

protocol SubscriptionEngine: Actor {
    func state() async throws -> SwitchboardState
    func savedAccounts() async throws -> [SavedAccount]
    func saveCurrent(label: String) async throws
    func activate(_ id: UUID) async throws
    func rename(_ id: UUID, label: String) async throws
    func setRenewal(_ id: UUID, date: Date?) async throws
    func setClaudeBilling(_ id: UUID, billing: ClaudeBillingSnapshot) async throws
    func remove(_ id: UUID) async throws
    func usage(_ id: UUID) async throws
    func beginLogin() async throws
    func submitLoginCode(_ code: String) async throws
    func finishLogin(label: String) async throws
    func cancelLogin() async throws
    func shutdown() async
}

extension SubscriptionEngine {
    func setClaudeBilling(_ id: UUID, billing: ClaudeBillingSnapshot) throws {
        throw SwitchboardError.message("Web billing is available for Claude accounts.")
    }
}
