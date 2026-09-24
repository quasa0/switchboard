import AppKit
import SwiftUI
import SwitchboardCore

enum UIPreviewState: String, CaseIterable {
    case accounts, empty, loading, error, unavailable, exhausted, switching
    case longLabel = "long-label"
    case missingFiveHour = "missing-five-hour"
}

struct UILaunchOptions {
    let requiresDemo: Bool
    let runsCredentialSmoke: Bool
    let runsUISmoke: Bool
    let checksQuit: Bool
    let rendersPreview: Bool
    let previewState: UIPreviewState
    let previewProvider: SubscriptionProvider?
    let previewWidth: CGFloat
    let previewHeight: CGFloat
    let isDark: Bool
    let renderOutput: URL?
    let smokeOutput: URL
    let validationError: String?

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
                  !arguments[index + 1].hasPrefix("--") else { return nil }
            return arguments[index + 1]
        }

        let uiOnly = arguments.contains {
            $0.hasPrefix("--demo") || $0.hasPrefix("--render-preview") ||
            $0.hasPrefix("--preview-") || $0.hasPrefix("--ui-smoke-test") ||
            $0 == "--empty" || $0 == "--dark" || $0 == "--light"
        }
        // Parse all UI modes before DashboardModel can construct either account engine. Combining a
        // UI flag with the credential smoke flag still selects the UI-only path.
        requiresDemo = uiOnly || arguments.contains("--smoke-test") || arguments.contains("--check-quit")
        runsCredentialSmoke = arguments.contains("--smoke-test") && !uiOnly
        runsUISmoke = arguments.contains("--ui-smoke-test")
        checksQuit = arguments.contains("--check-quit")
        rendersPreview = arguments.contains("--render-preview")
        isDark = arguments.contains("--dark")

        var failure: String?
        let providerName = value(after: "--preview-provider")
        previewProvider = providerName.flatMap(SubscriptionProvider.init(rawValue:))
        if arguments.contains("--preview-provider"), providerName.flatMap(SubscriptionProvider.init(rawValue:)) == nil {
            failure = "Choose --preview-provider claude or chatGPT."
        }
        let stateName = value(after: "--preview-state")
        previewState = stateName.flatMap(UIPreviewState.init(rawValue:)) ?? (arguments.contains("--empty") ? .empty : .accounts)
        if arguments.contains("--preview-state"), stateName.flatMap(UIPreviewState.init(rawValue:)) == nil {
            failure = "Choose --preview-state accounts, empty, loading, error, unavailable, exhausted, switching, long-label, or missing-five-hour."
        }

        if arguments.contains("--preview-width") {
            if let raw = value(after: "--preview-width"), let width = Double(raw), width.isFinite, (620...1600).contains(width) {
                previewWidth = CGFloat(width)
            } else {
                previewWidth = 1120
                failure = "Use --preview-width with a number from 620 to 1600."
            }
        } else { previewWidth = 1120 }

        if arguments.contains("--preview-height") {
            if let raw = value(after: "--preview-height"), let height = Double(raw), height.isFinite, (490...1600).contains(height) {
                previewHeight = CGFloat(height)
            } else {
                previewHeight = 780
                failure = "Use --preview-height with a number from 490 to 1600."
            }
        } else { previewHeight = 780 }

        renderOutput = value(after: "--render-preview").map { URL(fileURLWithPath: $0) }
        if rendersPreview && renderOutput == nil { failure = "Give --render-preview a PNG output path." }
        smokeOutput = value(after: "--ui-smoke-test").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-ui-smoke-\(UUID().uuidString)")
        validationError = failure
    }
}

struct UIRenderRecord: Codable {
    let file: String
    let state: String
    let provider: String
    let dark: Bool
    let width: Double
    let height: Double
    let pixelWidth: Int
    let pixelHeight: Int
}

struct UISmokeReport: Codable {
    let credentialAccess: Bool
    let assertions: [String]
    let renders: [UIRenderRecord]
    let quitCleanupPassed: Bool

    func writeAfterQuitCleanup(to directory: URL) throws {
        let finished = UISmokeReport(credentialAccess: credentialAccess, assertions: assertions,
                                    renders: renders, quitCleanupPassed: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(finished).write(to: directory.appendingPathComponent("ui-smoke-report.json"), options: .atomic)
    }
}

private struct UIVerificationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor enum UIPreviewRenderer {
    static func render(model: DashboardModel, state: UIPreviewState, to output: URL,
                       width: CGFloat = 1120, height: CGFloat = 780, dark: Bool = false) async throws -> UIRenderRecord {
        guard model.isCredentialFreePreview else {
            throw UIVerificationError(message: "Refusing to render a model with live account access.")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let view = AccountListView(model: model)
            .frame(width: width, height: height)
            .environment(\.colorScheme, dark ? .dark : .light)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // Allow native scroll content to complete its display pass.
        try await Task.sleep(nanoseconds: 200_000_000)
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw UIVerificationError(message: "The preview bitmap could not be created.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count > 1000 else {
            throw UIVerificationError(message: "The preview PNG could not be created.")
        }
        try data.write(to: output, options: .atomic)
        return UIRenderRecord(file: output.lastPathComponent, state: state.rawValue, provider: "all", dark: dark,
                              width: Double(width), height: Double(height),
                              pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh)
    }
}

@MainActor enum UISmokeCheck {
    static func run(model: DashboardModel, output: URL) async throws -> UISmokeReport {
        try require(model.isCredentialFreePreview, "UI smoke must have no account engines.")
        try checkSafeLaunchFlags()
        let fixture = DashboardModel(demo: true)
        try require(fixture.isCredentialFreePreview && fixture.accountCount == 4,
                    "Both providers' synthetic accounts were not initialized together.")
        try require(fixture.providers.map(\.provider) == [.claude, .chatGPT] &&
                    fixture.claude.activeID != nil && fixture.chatGPT.activeID != nil,
                    "Both independent active accounts must exist on the same dashboard.")
        try require(fixture.chatGPT.accounts.map { SubscriptionProvider.chatGPT.planLabel($0.plan) } == ["Pro · 20×", "Pro · 5×"],
                    "ChatGPT preview tiers must distinguish the 20× and 5× Pro allowances.")
        try require(fixture.claude.accounts.allSatisfy { $0.usage?.manualResets == nil } &&
                    fixture.chatGPT.accounts[0].usage?.manualResets?.availableCount == 3 &&
                    fixture.chatGPT.accounts[0].usage?.manualResets?.credits?.count == 3 &&
                    fixture.chatGPT.accounts[1].usage?.manualResets?.availableCount == 0,
                    "Manual reset fixtures must distinguish provider-unavailable data from reported positive and zero counts.")
        for provider in SubscriptionProvider.allCases {
            try await checkProviderActions(in: fixture, provider: provider)
        }
        try require(fixture.accountCount == 0, "Dashboard account count did not track provider removals.")
        fixture.claude.isBusy = true
        try require(fixture.isBusy && fixture.isBlocked, "Dashboard missed Claude's busy state.")
        fixture.claude.isBusy = false
        fixture.chatGPT.loginInProgress = true
        try require(fixture.loginInProgress && fixture.isBlocked, "Dashboard missed ChatGPT's sign-in state.")
        fixture.chatGPT.loginInProgress = false
        try require(!fixture.isBlocked, "Dashboard remained blocked after provider operations completed.")
        await fixture.shutdown()

        let stopped = DashboardModel(demo: true)
        let stoppedAccounts = stopped.providers.map(\.accounts)
        let stoppedActiveIDs = stopped.providers.map(\.activeID)
        let stoppedCurrent = stopped.providers.map(\.current)
        await stopped.shutdown()
        await stopped.refresh()
        for providerModel in stopped.providers {
            await providerModel.switchAccount(providerModel.accounts[1])
            await providerModel.setRenewal(account: providerModel.accounts[0], date: Date().addingTimeInterval(100))
        }
        try require(stopped.providers.map(\.accounts) == stoppedAccounts &&
                    stopped.providers.map(\.activeID) == stoppedActiveIDs &&
                    stopped.providers.map(\.current) == stoppedCurrent && !stopped.isRefreshing,
                    "Shutdown must prevent new refresh, account switching, or metadata changes.")

        let cases: [(String, UIPreviewState, Bool, CGFloat)] = [
            ("accounts-light", .accounts, false, 1120),
            ("accounts-dark", .accounts, true, 1120),
            ("empty", .empty, false, 1120),
            ("loading", .loading, false, 1120),
            ("error", .error, false, 1120),
            ("unavailable", .unavailable, false, 1120),
            ("exhausted", .exhausted, false, 1120),
            ("switching", .switching, false, 1120),
            ("long-label", .longLabel, false, 1120),
            ("missing-five-hour", .missingFiveHour, false, 1120),
            ("minimum-width", .accounts, false, 620)
        ]
        var records: [UIRenderRecord] = []
        for (name, state, dark, width) in cases {
            let sample = DashboardModel(demo: true, previewState: state)
            records.append(try await UIPreviewRenderer.render(model: sample, state: state,
                to: output.appendingPathComponent("\(name).png"), width: width, dark: dark))
            try require(sample.isCredentialFreePreview, "A render fixture acquired live account access.")
        }
        let partialFailure = DashboardModel(demo: true, previewState: .error, previewProvider: .chatGPT)
        try require(partialFailure.claude.usageErrors.isEmpty && !partialFailure.chatGPT.usageErrors.isEmpty,
                    "A ChatGPT fixture error contaminated the Claude accounts.")
        records.append(try await UIPreviewRenderer.render(model: partialFailure, state: .error,
            to: output.appendingPathComponent("one-provider-error.png")))

        for provider in SubscriptionProvider.allCases {
            let sample = DashboardModel(demo: true)
            let other = sample.model(for: provider == .claude ? .chatGPT : .claude)
            other.accounts = []; other.activeID = nil; other.current = nil
            try require(sample.accountCount == 2, "A single-provider fixture retained the other provider's accounts.")
            let name = provider == .claude ? "only-claude" : "only-chatgpt"
            records.append(try await UIPreviewRenderer.render(model: sample, state: .accounts,
                to: output.appendingPathComponent("\(name).png")))
        }
        let restored = DashboardModel(demo: true, previewState: .missingFiveHour)
        try require(restored.providers.allSatisfy { $0.accounts.allSatisfy { $0.usage != nil && $0.usage?.fiveHour == nil } },
                    "Missing-five-hour fixtures must keep successful usage snapshots for both providers.")
        for providerModel in restored.providers {
            for account in providerModel.accounts {
                let metrics = accountUsageMetrics(account.usage, provider: providerModel.provider)
                try require(!metrics.contains(where: { $0.id == "five-hour" }) &&
                            metrics.contains(where: { $0.id == "weekly" && $0.window == account.usage?.sevenDay }),
                            "A missing five-hour meter must stay hidden while the reported weekly window remains visible.")
            }
            let weekly = providerModel.accounts[0].usage?.sevenDay
            providerModel.usageErrors[providerModel.accounts[0].id] = "Synthetic retained usage error"
            providerModel.accounts[0].usage?.fiveHour = UsageWindow(utilization: 17, resetsAt: Date().addingTimeInterval(3_600))
            let metrics = accountUsageMetrics(providerModel.accounts[0].usage, provider: providerModel.provider)
            try require(metrics.contains(where: { $0.id == "five-hour" && $0.window.utilization == 17 }) &&
                        metrics.contains(where: { $0.id == "weekly" && $0.window == weekly }),
                        "A newly reported five-hour window did not return without changing weekly usage.")
            try require(providerModel.usageErrors[providerModel.accounts[0].id] == "Synthetic retained usage error",
                        "A metric update discarded an unrelated usage error.")
            providerModel.usageErrors = [:]
        }
        records.append(try await UIPreviewRenderer.render(model: restored, state: .accounts,
            to: output.appendingPathComponent("five-hour-restored.png")))

        let resetStates = DashboardModel(demo: true)
        resetStates.chatGPT.accounts[0].usage?.manualResets = ManualResetSummary(availableCount: 4, credits: nil)
        resetStates.chatGPT.accounts[1].usage?.manualResets = ManualResetSummary(availableCount: 3, credits: [
            ManualResetCredit(id: "sample-no-expiry", resetType: "codexRateLimits", status: "available",
                grantedAt: Date().addingTimeInterval(-86_400), expiresAt: nil, title: "No expiry"),
            ManualResetCredit(id: "sample-past-expiry", resetType: "codexRateLimits", status: "available",
                grantedAt: Date().addingTimeInterval(-30 * 86_400), expiresAt: Date().addingTimeInterval(-60), title: "Awaiting updated status")
        ])
        try require(resetStates.chatGPT.accounts[0].usage?.manualResets?.credits == nil &&
                    resetStates.chatGPT.accounts[1].usage?.manualResets?.availableCount == 3 &&
                    resetStates.chatGPT.accounts[1].usage?.manualResets?.credits?.count == 2,
                    "Missing or capped reset details must not replace the reported available count.")
        records.append(try await UIPreviewRenderer.render(model: resetStates, state: .accounts,
            to: output.appendingPathComponent("manual-reset-states.png")))

        return UISmokeReport(credentialAccess: false,
            assertions: ["Every UI flag selects demo before model initialization", "No account engines in preview dashboards",
                         "Both providers and active accounts coexist", "Each provider switch updates only its own identity",
                         "ChatGPT sample plans distinguish Pro 20× and Pro 5×",
                         "Manual reset counts preserve unavailable, zero, capped details, due dates, and no expiry",
                         "Each provider switch includes its session notice", "Rename and remove preserve sibling provider state",
                         "Remove preserves simulated current login", "Preview sign-in stays in memory",
                         "Dashboard count and busy state aggregate both providers", "One provider error leaves the other healthy",
                         "Shutdown prevents subsequent refresh, switch, and renewal changes",
                         "Successful usage without five-hour data and later restoration both render"],
            renders: records, quitCleanupPassed: false)
    }

    private static func checkProviderActions(in dashboard: DashboardModel, provider: SubscriptionProvider) async throws {
        let selected = dashboard.model(for: provider)
        let sibling = dashboard.model(for: provider == .claude ? .chatGPT : .claude)
        let siblingAccounts = sibling.accounts, siblingActiveID = sibling.activeID, siblingCurrent = sibling.current
        let siblingErrors = sibling.usageErrors
        func siblingUnchanged() throws {
            try require(sibling.accounts == siblingAccounts && sibling.activeID == siblingActiveID &&
                        sibling.current == siblingCurrent && sibling.usageErrors == siblingErrors,
                        "A \(provider.rawValue) operation changed its sibling provider's accounts or identity.")
        }
        let first = selected.accounts[0], second = selected.accounts[1]
        await selected.switchAccount(second)
        try require(selected.activeID == second.id && selected.current?.accountUUID == second.accountUUID,
                    "Switching \(provider.rawValue) did not update its in-memory identity.")
        try require(selected.switchingAccountID == nil && !selected.isBusy,
                    "Switching left its progress state active after completion.")
        let notice = provider == .claude ? "Restart open Claude Code sessions" : "Start a new Codex session"
        try require(selected.notice?.contains(notice) == true, "Switching omitted its provider's session notice.")
        try siblingUnchanged()
        await selected.rename(second, label: "\(provider.rawValue) projects")
        try require(selected.accounts.first(where: { $0.id == second.id })?.label == "\(provider.rawValue) projects",
                    "Renaming did not update the selected provider's account.")
        try siblingUnchanged()
        await selected.remove(first)
        try require(selected.accounts.count == 1 && selected.activeID == second.id,
                    "Removing an inactive account changed the selected provider's active identity.")
        try siblingUnchanged()
        await selected.remove(second)
        try require(selected.accounts.isEmpty && selected.activeID == nil && selected.current?.accountUUID == second.accountUUID,
                    "Removing the saved active account did not preserve its simulated CLI login.")
        try siblingUnchanged()
        await selected.beginLogin()
        try require(!selected.loginInProgress && selected.isCredentialFreePreview,
                    "Preview sign-in attempted to start a real login.")
        try siblingUnchanged()
    }

    private static func checkSafeLaunchFlags() throws {
        let cases = [
            ["--demo"], ["--empty"], ["--dark"], ["--light"], ["--check-quit"],
            ["--render-preview", "/tmp/example.png"], ["--preview-state", "error"],
            ["--preview-width", "620"], ["--preview-height", "780"], ["--ui-smoke-test"],
            ["--preview-state", "missing-five-hour"],
            ["--preview-provider", "chatGPT"], ["--preview-provider", "invalid"],
            ["--ui-smoke-test", "--smoke-test"], ["--demo", "--smoke-test"],
            ["--preview-state", "invalid"], ["--preview-width", "invalid"]
        ]
        for arguments in cases {
            let options = UILaunchOptions(arguments: ["Switchboard"] + arguments)
            try require(options.requiresDemo && !options.runsCredentialSmoke,
                        "A UI flag selected the credential-backed launch path.")
            let sample = DashboardModel(demo: options.requiresDemo, previewState: options.previewState, previewProvider: options.previewProvider)
            try require(sample.isCredentialFreePreview, "A UI flag initialized an account engine.")
        }
        let defaults = UILaunchOptions(arguments: ["Switchboard", "--demo"])
        try require(defaults.previewProvider == nil && defaults.previewWidth == 1120 && defaults.previewHeight == 780,
                    "The default preview must show the unified dashboard at its standard size.")
        try require(DashboardModel(empty: true).isCredentialFreePreview,
                    "An empty-state preview initialized an account engine.")
        try require(DashboardModel(previewState: .error).isCredentialFreePreview,
                    "A named-state preview initialized an account engine.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw UIVerificationError(message: message) }
    }
}
