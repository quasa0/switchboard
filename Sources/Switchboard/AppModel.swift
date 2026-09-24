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
    @Published private(set) var provider: SubscriptionProvider
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
    private var engines: [SubscriptionProvider: any SubscriptionEngine] = [:]
    private var engine: (any SubscriptionEngine)? { engines[provider] }
    private struct ProviderState {
        var accounts: [SavedAccount]
        var activeID: UUID?
        var current: CurrentLogin?
        var usageErrors: [UUID: String]
        var loadError: String?
    }
    private var providerStates: [SubscriptionProvider: ProviderState] = [:]
    private var refreshTask: Task<Void, Never>?
    init(demo: Bool = false, empty: Bool = false, previewState: UIPreviewState? = nil,
         provider: SubscriptionProvider? = nil) {
        // Every preview entry point selects this branch before a live engine can exist.
        isDemo = demo || empty || previewState != nil
        self.provider = provider ?? (isDemo ? .claude :
            UserDefaults.standard.string(forKey: "selectedProvider").flatMap(SubscriptionProvider.init(rawValue:)) ?? .claude)
        if isDemo {
            configurePreview(previewState ?? (empty ? .empty : .accounts))
        } else { createEngine(); isLoading = true }
    }

    var isCredentialFreePreview: Bool { isDemo && engines.isEmpty }

    private func createEngine() {
        guard !isDemo, engines[provider] == nil else { return }
        switch provider {
        case .claude: engines[provider] = AccountEngine()
        case .chatGPT: engines[provider] = CodexAccountEngine()
        }
    }

    func selectProvider(_ selected: SubscriptionProvider) async {
        guard selected != provider, !isBusy, !isRefreshing, !isLoading, !loginInProgress else { return }
        providerStates[provider] = ProviderState(accounts: accounts, activeID: activeID, current: current,
                                                  usageErrors: usageErrors, loadError: loadError)
        provider = selected
        error = nil; notice = nil; switchingAccountID = nil
        if let cached = providerStates[selected] {
            accounts = cached.accounts; activeID = cached.activeID; current = cached.current
            usageErrors = cached.usageErrors; loadError = cached.loadError
        } else {
            accounts = []; activeID = nil; current = nil; usageErrors = [:]; loadError = nil
            if isDemo { configurePreview(.accounts) }
        }
        guard !isDemo else { return }
        UserDefaults.standard.set(selected.rawValue, forKey: "selectedProvider")
        createEngine()
        await refresh()
    }

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
        if provider == .chatGPT {
            accounts[0].plan = "Pro"
            accounts[1].plan = "Plus"
            for index in accounts.indices {
                accounts[index].accountUUID = "codex-demo-\(index)"
                accounts[index].organizationUUID = ""
                accounts[index].usage?.modelScoped = []
            }
        }
        activeID = accounts[0].id
        current = previewLogin(for: accounts[0])
        switch state {
        case .accounts:
            break
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
                fiveHour: UsageWindow(utilization: 100, resetsAt: now.addingTimeInterval(2640)),
                sevenDay: UsageWindow(utilization: 100, resetsAt: now.addingTimeInterval(239400)),
                modelScoped: provider == .claude ? [NamedUsageWindow(name: "Fable 5", window: UsageWindow(utilization: 100, resetsAt: now.addingTimeInterval(181200)))] : [])
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
        guard let engine else { return }
        isLoading = true
        defer { isLoading = false }
        // Display metadata can load even when the selected CLI login is unavailable.
        do { accounts = try await engine.savedAccounts() }
        catch {
            current = nil; activeID = nil
            loadError = "Couldn’t load saved accounts. \(error.localizedDescription)"
            return
        }
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
    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy, !isRefreshing, !isLoading else {
            error = "Wait for the current operation to finish, then try again."
            return
        }
        isBusy = true; error = nil; notice = nil
        defer { isBusy = false }
        do { try await operation(); await load() }
        catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard !isRefreshing, !isBusy, !loginInProgress else { return }
        error = nil
        guard let engine else { notice = "Preview data only. Your logins are unchanged."; return }
        isRefreshing = true
        defer { isRefreshing = false }
        await load()
        let task = Task { [weak self] in
            guard let self else { return }
            for account in accounts {
                if Task.isCancelled { break }
                do { try await engine.usage(account.id); usageErrors[account.id] = nil }
                catch is CancellationError { break }
                catch { usageErrors[account.id] = error.localizedDescription }
            }
            await load()
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
        await perform {
            if let engine { try await engine.rename(account.id, label: label) }
            else if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index].label = label }
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
        refreshTask?.cancel()
        await refreshTask?.value
        for engine in engines.values { await engine.shutdown() }
    }
}
