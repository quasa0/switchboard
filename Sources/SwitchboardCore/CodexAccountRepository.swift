import Foundation
import Darwin

public final class CodexAccountRepository {
    public static let vaultService = "com.quasa0.switchboard.codex-accounts"
    public let directory: URL
    public let secrets: SecretStore
    public let live: CodexLoginStore
    public let vaultService: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private struct UsageCheck {
        var installation: CodexInstallation
        var saved: CodexCredentialSnapshot
    }
    private var usageChecks: [UUID: UsageCheck] = [:]

    public init(directory: URL, secrets: SecretStore, installation: CodexInstallation,
                vaultService: String = CodexAccountRepository.vaultService) {
        self.directory = directory; self.secrets = secrets; self.vaultService = vaultService
        live = CodexLoginStore(installation: installation)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func withLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("accounts.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SwitchboardError.message("Cannot open the ChatGPT account lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw SwitchboardError.message("Another Switchboard window is updating ChatGPT accounts. Try again.")
        }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }

    public func accounts() throws -> [SavedAccount] {
        let file = directory.appendingPathComponent("accounts.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try decoder.decode([SavedAccount].self, from: Data(contentsOf: file))
    }
    private func save(_ accounts: [SavedAccount]) throws {
        try privateWrite(encoder.encode(accounts), to: directory.appendingPathComponent("accounts.json"))
    }

    public func credential(for id: UUID) throws -> CodexCredentialSnapshot {
        guard let data = try secrets.read(service: vaultService, account: id.uuidString) else {
            throw SwitchboardError.message("The saved ChatGPT login is missing. Sign in and save this account again.")
        }
        let snapshot = try decoder.decode(CodexCredentialSnapshot.self, from: data)
        _ = try snapshot.validated()
        return snapshot
    }

    public func state() throws -> SwitchboardState {
        let accounts = try accounts()
        let current = try live.snapshot()?.validated()
        return SwitchboardState(accounts: accounts, current: current, activeID: accounts.first {
            $0.accountUUID == current?.accountUUID && $0.organizationUUID == current?.organizationUUID
        }?.id)
    }

    @discardableResult
    public func capture(_ snapshot: CodexCredentialSnapshot, label: String = "") throws -> SavedAccount {
        let identity = try snapshot.validated()
        var accounts = try accounts()
        let index = accounts.firstIndex { $0.accountUUID == identity.accountUUID && $0.organizationUUID == identity.organizationUUID }
        var account = index.map { accounts[$0] } ?? SavedAccount(label: identity.email, email: identity.email,
            accountUUID: identity.accountUUID, organizationUUID: identity.organizationUUID, plan: identity.plan)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { account.label = String(trimmed.prefix(80)) }
        account.email = identity.email; account.plan = identity.plan
        let previous = try secrets.read(service: vaultService, account: account.id.uuidString)
        try secrets.write(encoder.encode(snapshot), service: vaultService, account: account.id.uuidString)
        if let index { accounts[index] = account } else { accounts.append(account) }
        do { try save(accounts) }
        catch {
            if let previous { try? secrets.write(previous, service: vaultService, account: account.id.uuidString) }
            else { try? secrets.delete(service: vaultService, account: account.id.uuidString) }
            throw error
        }
        return account
    }

    public func captureCurrent(label: String) throws {
        guard let snapshot = try live.snapshot() else {
            throw SwitchboardError.message("No ChatGPT subscription login was found in Codex. Choose Sign in another account.")
        }
        try capture(snapshot, label: label)
    }

    public func activate(_ id: UUID) throws {
        guard usageChecks.isEmpty else { throw SwitchboardError.message("Wait for the ChatGPT usage check to finish before switching accounts.") }
        let before = try live.snapshot()
        if let before { try capture(before) }
        guard try accounts().contains(where: { $0.id == id }) else {
            throw SwitchboardError.message("This ChatGPT account is no longer saved.")
        }
        let target = try recoverProfileCredential(id)
        if let before {
            try secrets.write(encoder.encode(before), service: vaultService, account: "previous-login")
        }
        // Only auth.json changes. The private atomic rename needs no two-store recovery journal.
        // Codex does not honor our advisory lock; detect a refreshed login immediately before replacement.
        try live.apply(target, ifUnchangedFrom: before)
    }

    public func rename(_ id: UUID, label: String) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SwitchboardError.message("Enter an account name.") }
        var accounts = try accounts()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].label = String(trimmed.prefix(80))
        try save(accounts)
    }

    public func remove(_ id: UUID) throws {
        guard usageChecks[id] == nil else { throw SwitchboardError.message("Wait for this account's usage check to finish before removing it.") }
        let existing = try accounts()
        let previous = try secrets.read(service: vaultService, account: id.uuidString)
        try secrets.delete(service: vaultService, account: id.uuidString)
        do { try save(existing.filter { $0.id != id }) }
        catch {
            if let previous { try? secrets.write(previous, service: vaultService, account: id.uuidString) }
            throw error
        }
        // Deleting our saved copy never calls logout or revokes the active Codex session.
        try? FileManager.default.removeItem(at: usageInstallation(id).home)
    }

    public func updateUsage(_ id: UUID, usage: UsageSnapshot) throws {
        var accounts = try accounts()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].usage = usage
        try save(accounts)
    }

    public func usageInstallation(_ id: UUID) -> CodexInstallation {
        .isolated(at: directory.appendingPathComponent("profiles/\(id.uuidString)", isDirectory: true))
    }

    public func prepareUsage(_ id: UUID) throws -> CodexInstallation {
        guard usageChecks[id] == nil else { throw SwitchboardError.message("This ChatGPT account is already being checked.") }
        guard try accounts().contains(where: { $0.id == id }) else { throw SwitchboardError.message("This ChatGPT account is no longer saved.") }
        let state = try state()
        let installation: CodexInstallation
        if state.activeID == id {
            // Use the live file, not a token clone. Codex can rotate it during account/read.
            if let current = try live.snapshot() { try capture(current) }
            installation = live.installation
        } else {
            installation = usageInstallation(id)
            let snapshot = try recoverProfileCredential(id)
            try createProfile(installation)
            try CodexLoginStore(installation: installation).apply(snapshot)
        }
        usageChecks[id] = UsageCheck(installation: installation, saved: try credential(for: id))
        return installation
    }

    public func collectUsageCredentials(_ id: UUID, from installation: CodexInstallation) throws {
        guard let check = usageChecks.removeValue(forKey: id), check.installation == installation else {
            throw SwitchboardError.message("This ChatGPT usage check is no longer current. Refresh again.")
        }
        guard let snapshot = try CodexLoginStore(installation: installation).snapshot() else {
            throw SwitchboardError.message("Codex did not retain this account's login. Sign in again.")
        }
        let identity = try snapshot.validated()
        guard let account = try accounts().first(where: { $0.id == id }),
              identity.accountUUID == account.accountUUID, identity.organizationUUID == account.organizationUUID else {
            throw SwitchboardError.message("The Codex login changed during the usage check. Refresh again.")
        }
        let current = try credential(for: id)
        guard current == check.saved || current == snapshot else {
            throw SwitchboardError.message("A newer ChatGPT login was saved during the usage check. The newer saved login was kept.")
        }
        try capture(snapshot)
    }

    private func recoverProfileCredential(_ id: UUID) throws -> CodexCredentialSnapshot {
        let saved = try credential(for: id)
        guard let profile = try CodexLoginStore(installation: usageInstallation(id)).snapshot(),
              profile.refreshedAt ?? .distantPast > saved.refreshedAt ?? .distantPast else { return saved }
        let expected = try saved.validated(), actual = try profile.validated()
        guard expected.accountUUID == actual.accountUUID, expected.organizationUUID == actual.organizationUUID else {
            throw SwitchboardError.message("The saved ChatGPT usage profile belongs to another account. No login was changed.")
        }
        // A prior process may have exited after Codex rotated its token but before collection.
        try capture(profile)
        return profile
    }

    private func createProfile(_ installation: CodexInstallation) throws {
        try FileManager.default.createDirectory(at: installation.home.appendingPathComponent("home"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try privateWrite(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: installation.configFile)
    }
}
