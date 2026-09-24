import SwiftUI
import AppKit
import SwitchboardCore

actor AccountEngine: SubscriptionEngine {
    let repository: AccountRepository
    var login: LoginSession?
    var refreshing = false
    init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Switchboard")
        repository = AccountRepository(directory: directory, secrets: KeychainStore(), installation: ClaudeInstallation())
    }
    func state() throws -> SwitchboardState { try repository.withLock { try repository.state() } }
    func savedAccounts() throws -> [SavedAccount] { try repository.withLock { try repository.accounts() } }
    func saveCurrent(label: String) throws { try repository.withLock { try repository.captureCurrent(label: label) } }
    func activate(_ id: UUID) throws {
        guard !refreshing else { throw SwitchboardError.message("Wait for the usage check to finish, then switch accounts.") }
        try repository.withLock { try repository.activate(id) }
    }
    func rename(_ id: UUID, label: String) throws { try repository.withLock { try repository.rename(id, label: label) } }
    func setRenewal(_ id: UUID, date: Date?) throws { try repository.withLock { try repository.setRenewal(id, date: date) } }
    func remove(_ id: UUID) throws { try repository.withLock { try repository.remove(id) } }
    func usage(_ id: UUID) async throws {
        refreshing = true
        defer { refreshing = false }
        let installation = try repository.withLock { try repository.prepareUsage(id) }
        do {
            let usage = try await CLIUsageClient(executable: ClaudeExecutable.find()).fetch(installation: installation)
            try repository.withLock {
                try repository.collectUsageCredentials(id, from: installation)
                try repository.updateUsage(id, usage: usage)
            }
        } catch {
            // Preserve token rotation even if the subsequent usage request failed.
            try repository.withLock { try repository.collectUsageCredentials(id, from: installation) }
            throw error
        }
    }
    func beginLogin() throws {
        guard login == nil else { return }
        let directory = repository.directory.appendingPathComponent("login/\(UUID().uuidString)")
        let session = try LoginSession(directory: directory, executable: ClaudeExecutable.find())
        try session.start()
        login = session
    }
    func submitLoginCode(_ code: String) throws { try login?.submit(code: code) }
    func finishLogin(label: String) throws {
        guard let login else { throw SwitchboardError.message("Start a new sign-in first.") }
        try login.checkFinished()
        let store = ClaudeLoginStore(installation: login.installation, secrets: repository.secrets)
        guard let snapshot = try store.snapshot() else { throw SwitchboardError.message("Claude Code has not saved a login yet.") }
        try repository.withLock { _ = try repository.capture(snapshot, label: label) }
        try cancelLogin()
    }
    func cancelLogin() throws {
        guard let login else { return }
        login.stop()
        try repository.secrets.delete(service: login.installation.keychainService, account: login.installation.keychainAccount)
        try FileManager.default.removeItem(at: login.installation.configDirectory)
        self.login = nil
    }
    func shutdown() { try? cancelLogin() }
}

@MainActor final class AppModel: ObservableObject {
    let provider: SubscriptionProvider
    @Published var accounts: [SavedAccount] = []
    @Published var activeID: UUID?
    @Published var switchingAccountID: UUID?
    @Published var current: CurrentLogin?
    @Published var isBusy = false
    @Published var isRefreshing = false
    @Published var error: String?
    @Published var loadError: String?
    @Published var isLoading = false
    @Published var notice: String?
    @Published var usageErrors: [UUID: String] = [:]
    @Published var loginInProgress = false
    let isDemo: Bool
    private let engine: (any SubscriptionEngine)?
    private var refreshTask: Task<Void, Never>?
    private var stopping = false
    init(demo: Bool = false, empty: Bool = false, previewState: UIPreviewState? = nil,
         provider: SubscriptionProvider = .claude) {
        // Every preview entry point selects this branch before a live engine can exist.
        isDemo = demo || empty || previewState != nil
        self.provider = provider
        if isDemo {
            engine = nil
            configurePreview(previewState ?? (empty ? .empty : .accounts))
        } else {
            switch provider {
            case .claude: engine = AccountEngine()
            case .chatGPT: engine = CodexAccountEngine()
            }
            isLoading = true
        }
    }

    var isCredentialFreePreview: Bool { isDemo && engine == nil }

    private func configurePreview(_ state: UIPreviewState) {
        let now = Date()
        accounts = [
            SavedAccount(label: "Personal", email: "alex@personal.example", accountUUID: "demo-one", organizationUUID: "org-one", plan: "Max 20×",
                usage: UsageSnapshot(fiveHour: UsageWindow(utilization: 84, resetsAt: now.addingTimeInterval(1260)),
                                     sevenDay: UsageWindow(utilization: 61, resetsAt: now.addingTimeInterval(239400)),
                                     modelScoped: [NamedUsageWindow(name: "Fable 5", window: UsageWindow(utilization: 92, resetsAt: now.addingTimeInterval(181200)))])),
            SavedAccount(label: "Studio", email: "alex@studio.example", accountUUID: "demo-two", organizationUUID: "org-two", plan: "Max 20×",
                usage: UsageSnapshot(fiveHour: UsageWindow(utilization: 12, resetsAt: now.addingTimeInterval(13800)),
                                     sevenDay: UsageWindow(utilization: 28, resetsAt: now.addingTimeInterval(410400)),
                                     modelScoped: [NamedUsageWindow(name: "Fable 5", window: UsageWindow(utilization: 18, resetsAt: now.addingTimeInterval(324000)))]))
        ]
        accounts[0].renewalAt = now.addingTimeInterval(9 * 86_400 + 7_200)
        accounts[1].renewalAt = now.addingTimeInterval(24 * 86_400 + 18_000)
        if provider == .chatGPT {
            accounts[0].plan = "Pro"
            accounts[1].plan = "Prolite"
            for index in accounts.indices {
                accounts[index].accountUUID = "codex-demo-\(index)"
                accounts[index].organizationUUID = ""
                accounts[index].usage?.fiveHour = nil
                accounts[index].usage?.modelScoped = []
            }
            accounts[0].usage?.manualResets = ManualResetSummary(availableCount: 3, credits: [
                ManualResetCredit(id: "sample-reset-one", resetType: "codexRateLimits", status: "available",
                    grantedAt: now.addingTimeInterval(-5 * 86_400), expiresAt: now.addingTimeInterval(3 * 86_400 + 7_200), title: "Earned reset"),
                ManualResetCredit(id: "sample-reset-two", resetType: "codexRateLimits", status: "available",
                    grantedAt: now.addingTimeInterval(-2 * 86_400), expiresAt: now.addingTimeInterval(14 * 86_400 + 3_600), title: "Earned reset"),
                ManualResetCredit(id: "sample-reset-three", resetType: "codexRateLimits", status: "available",
                    grantedAt: now.addingTimeInterval(-86_400), expiresAt: now.addingTimeInterval(27 * 86_400 + 10_800), title: "Earned reset")
            ])
            accounts[1].usage?.manualResets = ManualResetSummary(availableCount: 0, credits: [])
        }
        activeID = accounts[0].id
        current = previewLogin(for: accounts[0])
        switch state {
        case .accounts:
            break
        case .missingFiveHour:
            for index in accounts.indices { accounts[index].usage?.fiveHour = nil }
        case .empty, .loading, .unavailable:
            accounts = []; activeID = nil; current = nil
            isLoading = state == .loading
            isRefreshing = state == .loading
            isBusy = state == .loading
            if state == .unavailable {
                loadError = "Couldn’t load saved accounts. Check access to your account data, then try again."
            }
        case .error:
            usageErrors[accounts[0].id] = "The usage request timed out. Check your connection and refresh to try again."
            usageErrors[accounts[1].id] = "\(provider.cliName) could not load subscription limits. Try refreshing again."
            accounts[0].usage?.fetchedAt = now.addingTimeInterval(-5400)
            accounts[1].usage = nil
        case .switching:
            isBusy = true
            switchingAccountID = accounts[1].id
        case .exhausted:
            accounts[0].usage = UsageSnapshot(
                fiveHour: provider == .claude ? UsageWindow(utilization: 100, resetsAt: now.addingTimeInterval(2640)) : nil,
                sevenDay: UsageWindow(utilization: 100, resetsAt: now.addingTimeInterval(239400)),
                modelScoped: provider == .claude ? [NamedUsageWindow(name: "Fable 5", window: UsageWindow(utilization: 100, resetsAt: now.addingTimeInterval(181200)))] : [],
                manualResets: accounts[0].usage?.manualResets)
        case .longLabel:
            accounts[0].label = "Personal account for research and independent projects with a very long name"
            accounts[0].email = "alexandra.research.and.development@a-long-personal-domain.example"
            accounts[1].label = "Studio and client work across multiple organizations"
            accounts[1].email = "alexandra.client.projects@a-long-studio-domain.example"
            current = previewLogin(for: accounts[0])
        }
    }

    private func previewLogin(for account: SavedAccount) -> CurrentLogin {
        CurrentLogin(email: account.email, accountUUID: account.accountUUID,
                     organizationUUID: account.organizationUUID, plan: account.plan)
    }
    func load() async {
        guard !stopping, let engine else { return }
        isLoading = true
        defer { isLoading = false }
        // Display metadata can load even when the selected CLI login is unavailable.
        do { accounts = try await engine.savedAccounts() }
        catch {
            current = nil; activeID = nil
            loadError = "Couldn’t load saved accounts. \(error.localizedDescription)"
            return
        }
        guard !stopping else { return }
        do {
            apply(try await engine.state())
            loadError = nil
        } catch {
            current = nil; activeID = nil
            loadError = "Couldn’t check the active \(provider.cliName) login. \(error.localizedDescription)"
        }
    }
    private func apply(_ state: SwitchboardState) {
        accounts = state.accounts; activeID = state.activeID; current = state.current
    }
    private func perform(checkLogin: Bool = true, _ operation: () async throws -> Void) async {
        guard !stopping else { return }
        guard !isBusy, !isRefreshing, !isLoading else {
            error = "Wait for the current operation to finish, then try again."
            return
        }
        isBusy = true; error = nil; notice = nil
        defer { isBusy = false }
        do {
            try await operation()
            if checkLogin { await load() }
            else if let engine { accounts = try await engine.savedAccounts() }
        }
        catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard !stopping, !isRefreshing, !isBusy, !loginInProgress else { return }
        error = nil
        guard let engine else { notice = "Preview data only. Your logins are unchanged."; return }
        isRefreshing = true
        defer { isRefreshing = false }
        await load()
        guard !stopping, !Task.isCancelled else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            for account in accounts {
                if stopping || Task.isCancelled { break }
                do { try await engine.usage(account.id); usageErrors[account.id] = nil }
                catch is CancellationError { break }
                catch { usageErrors[account.id] = error.localizedDescription }
            }
            if !Task.isCancelled { await load() }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }
    func saveCurrent(label: String) async {
        await perform {
            guard let engine else { notice = "Preview mode. No login was saved."; return }
            try await engine.saveCurrent(label: label)
            notice = "Current login saved. Add your other account whenever you’re ready."
        }
        if error == nil { await refresh() }
    }
    func switchAccount(_ account: SavedAccount) async {
        await perform {
            switchingAccountID = account.id
            defer { switchingAccountID = nil }
            if let engine { try await engine.activate(account.id) }
            else { activeID = account.id; current = previewLogin(for: account) }
            notice = provider == .chatGPT
                ? "\(account.label) is active. Start a new Codex session to use it."
                : "\(account.label) is active. Restart open Claude Code sessions to use it."
        }
    }
    func rename(_ account: SavedAccount, label: String) async {
        await perform(checkLogin: false) {
            if let engine { try await engine.rename(account.id, label: label) }
            else if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index].label = label }
        }
    }
    func setRenewal(account: SavedAccount, date: Date?) async {
        // A billing reminder changes display metadata only; do not query CLI credentials.
        await perform(checkLogin: false) {
            if let engine { try await engine.setRenewal(account.id, date: date) }
            else if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].renewalAt = date
            }
        }
    }
    func remove(_ account: SavedAccount) async {
        await perform {
            if let engine { try await engine.remove(account.id) }
            else {
                accounts.removeAll { $0.id == account.id }
                if activeID == account.id { activeID = nil }
                usageErrors[account.id] = nil
            }
            notice = "Saved account removed. The CLI login is unchanged."
        }
    }
    func beginLogin() async {
        await perform {
            guard let engine else { notice = "Browser sign-in is disabled in preview mode."; return }
            try await engine.beginLogin(); loginInProgress = true
        }
    }
    func submitLoginCode(_ code: String) async {
        await perform { try await engine?.submitLoginCode(code) }
    }
    func finishLogin(label: String) async {
        await perform {
            try await engine?.finishLogin(label: label)
            loginInProgress = false
            notice = "Account saved. Select it when you want to switch."
        }
        if error == nil { await refresh() }
    }
    func cancelLogin() async {
        await perform { try await engine?.cancelLogin(); loginInProgress = false }
    }
    func shutdown() async {
        stopping = true
        refreshTask?.cancel()
        await refreshTask?.value
        await engine?.shutdown()
    }
}
