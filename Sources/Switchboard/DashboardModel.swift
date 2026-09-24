import Combine
import SwiftUI
import SwitchboardCore

/// Both providers remain live in the same dashboard. Each account action keeps its
/// owning provider model, so it cannot accidentally target another provider's login.
@MainActor final class DashboardModel: ObservableObject {
    let claude: AppModel
    let chatGPT: AppModel
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var stopping = false
    @Published private var refreshingAll = false

    init(demo: Bool = false, empty: Bool = false, previewState: UIPreviewState? = nil,
         previewProvider: SubscriptionProvider? = nil) {
        let preview = demo || empty || previewState != nil || previewProvider != nil
        let state = previewState ?? (empty ? .empty : .accounts)
        claude = AppModel(demo: preview,
            previewState: preview ? (previewProvider == nil || previewProvider == .claude ? state : .accounts) : nil,
            provider: .claude)
        chatGPT = AppModel(demo: preview,
            previewState: preview ? (previewProvider == nil || previewProvider == .chatGPT ? state : .accounts) : nil,
            provider: .chatGPT)
        for model in providers {
            model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &subscriptions)
        }
    }

    var providers: [AppModel] { [claude, chatGPT] }
    func model(for provider: SubscriptionProvider) -> AppModel { provider == .claude ? claude : chatGPT }
    var isDemo: Bool { providers.allSatisfy(\.isDemo) }
    var isCredentialFreePreview: Bool { providers.allSatisfy(\.isCredentialFreePreview) }
    var accountCount: Int { providers.reduce(0) { $0 + $1.accounts.count } }
    var isBusy: Bool { providers.contains(where: \.isBusy) }
    var isLoading: Bool { providers.contains(where: \.isLoading) }
    var isRefreshing: Bool { refreshingAll || providers.contains(where: \.isRefreshing) }
    var loginInProgress: Bool { providers.contains(where: \.loginInProgress) }
    var isBlocked: Bool { isBusy || isLoading || isRefreshing || loginInProgress }

    func refresh() async {
        guard !stopping, !isBusy, !isRefreshing, !loginInProgress else { return }
        refreshingAll = true
        defer { refreshingAll = false }
        let task = Task { [claude, chatGPT] in
            // These engines use separate credential stores. One slow provider must
            // not delay the other provider's account list or usage result.
            async let claudeRefresh: Void = claude.refresh()
            async let chatGPTRefresh: Void = chatGPT.refresh()
            _ = await (claudeRefresh, chatGPTRefresh)
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func shutdown() async {
        stopping = true
        refreshTask?.cancel()
        // Cancel the child models before awaiting the dashboard task: their
        // usage tasks own the CLI processes and must be allowed to reap them.
        async let claudeShutdown: Void = claude.shutdown()
        async let chatGPTShutdown: Void = chatGPT.shutdown()
        _ = await (claudeShutdown, chatGPTShutdown)
        await refreshTask?.value
    }
}
