import AppKit
import SwiftUI
import SwitchboardCore

enum UIPreviewState: String, CaseIterable {
    case accounts, empty, loading, error, unavailable, exhausted, switching
    case longLabel = "long-label"
}

struct UILaunchOptions {
    let requiresDemo: Bool
    let runsCredentialSmoke: Bool
    let runsUISmoke: Bool
    let checksQuit: Bool
    let rendersPreview: Bool
    let previewState: UIPreviewState
    let previewProvider: SubscriptionProvider
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
        // Parse all UI modes before AppModel can construct AccountEngine. Combining a
        // UI flag with the credential smoke flag still selects the UI-only path.
        requiresDemo = uiOnly || arguments.contains("--smoke-test") || arguments.contains("--check-quit")
        runsCredentialSmoke = arguments.contains("--smoke-test") && !uiOnly
        runsUISmoke = arguments.contains("--ui-smoke-test")
        checksQuit = arguments.contains("--check-quit")
        rendersPreview = arguments.contains("--render-preview")
        isDark = arguments.contains("--dark")

        var failure: String?
        let providerName = value(after: "--preview-provider")
        previewProvider = providerName.flatMap(SubscriptionProvider.init(rawValue:)) ?? .claude
        if arguments.contains("--preview-provider"), providerName.flatMap(SubscriptionProvider.init(rawValue:)) == nil {
            failure = "Choose --preview-provider claude or chatGPT."
        }
        let stateName = value(after: "--preview-state")
        previewState = stateName.flatMap(UIPreviewState.init(rawValue:)) ?? (arguments.contains("--empty") ? .empty : .accounts)
        if arguments.contains("--preview-state"), stateName.flatMap(UIPreviewState.init(rawValue:)) == nil {
            failure = "Choose --preview-state accounts, empty, loading, error, unavailable, exhausted, switching, or long-label."
        }

        if arguments.contains("--preview-width") {
            if let raw = value(after: "--preview-width"), let width = Double(raw), width.isFinite, (620...1600).contains(width) {
                previewWidth = CGFloat(width)
            } else {
                previewWidth = 720
                failure = "Use --preview-width with a number from 620 to 1600."
            }
        } else { previewWidth = 720 }

        if arguments.contains("--preview-height") {
            if let raw = value(after: "--preview-height"), let height = Double(raw), height.isFinite, (490...1600).contains(height) {
                previewHeight = CGFloat(height)
            } else {
                previewHeight = 740
                failure = "Use --preview-height with a number from 490 to 1600."
            }
        } else { previewHeight = 740 }

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
    static func render(model: AppModel, state: UIPreviewState, to output: URL,
                       width: CGFloat = 720, height: CGFloat = 740, dark: Bool = false) async throws -> UIRenderRecord {
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
        return UIRenderRecord(file: output.lastPathComponent, state: state.rawValue, provider: model.provider.rawValue, dark: dark,
                              width: Double(width), height: Double(height),
                              pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh)
    }
}

@MainActor enum UISmokeCheck {
    static func run(model: AppModel, output: URL) async throws -> UISmokeReport {
        try require(model.isCredentialFreePreview, "UI smoke must have no AccountEngine.")
        try checkSafeLaunchFlags()
        // Use a fresh in-memory model, independent of the requested screenshot state.
        let fixture = AppModel(demo: true)
        try require(fixture.isCredentialFreePreview && fixture.accounts.count == 2, "Synthetic accounts were not initialized.")
        let first = fixture.accounts[0]
        let second = fixture.accounts[1]

        await fixture.switchAccount(second)
        try require(fixture.activeID == second.id && fixture.current?.accountUUID == second.accountUUID,
                    "Switching did not update the in-memory account identity.")
        try require(fixture.switchingAccountID == nil && !fixture.isBusy,
                    "Switching left its progress state active after completion.")
        try require(fixture.notice?.contains("Restart open Claude Code sessions") == true,
                    "Switching omitted the session restart notice.")
        await fixture.rename(second, label: "Client projects")
        try require(fixture.accounts.first(where: { $0.id == second.id })?.label == "Client projects",
                    "Renaming did not update the in-memory account.")
        await fixture.remove(first)
        try require(fixture.accounts.count == 1 && fixture.activeID == second.id,
                    "Removing an inactive account changed the selection.")
        await fixture.remove(second)
        try require(fixture.accounts.isEmpty && fixture.activeID == nil && fixture.current?.accountUUID == second.accountUUID,
                    "Removing the saved active account did not preserve the simulated CLI login.")
        await fixture.beginLogin()
        try require(!fixture.loginInProgress && fixture.isCredentialFreePreview,
                    "Preview sign-in attempted to start a real login.")
        await fixture.shutdown()

        let providers = AppModel(demo: true)
        let claudeAccount = providers.accounts[1]
        await providers.switchAccount(claudeAccount)
        await providers.selectProvider(.chatGPT)
        try require(providers.provider == .chatGPT && providers.accounts.count == 2 && providers.isCredentialFreePreview,
                    "ChatGPT selection did not use an isolated preview state.")
        let codexAccount = providers.accounts[1]
        await providers.switchAccount(codexAccount)
        try require(providers.notice?.contains("Start a new Codex session") == true,
                    "Codex switching omitted its own session restart notice.")
        await providers.rename(codexAccount, label: "ChatGPT Work")
        await providers.selectProvider(.claude)
        try require(providers.activeID == claudeAccount.id && providers.accounts.count == 2,
                    "Selecting ChatGPT changed the Claude selection.")
        await providers.selectProvider(.chatGPT)
        try require(providers.activeID == codexAccount.id && providers.accounts[1].label == "ChatGPT Work",
                    "Returning to ChatGPT lost its independent account state.")
        providers.isBusy = true
        await providers.selectProvider(.claude)
        try require(providers.provider == .chatGPT, "Provider changed during a busy operation.")
        providers.isBusy = false
        providers.loginInProgress = true
        await providers.selectProvider(.claude)
        try require(providers.provider == .chatGPT, "Provider changed during sign-in.")
        providers.loginInProgress = false
        await providers.shutdown()

        let cases: [(String, UIPreviewState, Bool, CGFloat)] = [
            ("accounts-light", .accounts, false, 720),
            ("accounts-dark", .accounts, true, 720),
            ("empty", .empty, false, 720),
            ("loading", .loading, false, 720),
            ("error", .error, false, 720),
            ("unavailable", .unavailable, false, 720),
            ("exhausted", .exhausted, false, 720),
            ("switching", .switching, false, 720),
            ("long-label", .longLabel, false, 720),
            ("minimum-width", .accounts, false, 620)
        ]
        var records: [UIRenderRecord] = []
        for provider in SubscriptionProvider.allCases {
            for (name, state, dark, width) in cases {
                let sample = AppModel(demo: true, previewState: state, provider: provider)
                let prefix = provider == .claude ? "" : "chatgpt-"
                records.append(try await UIPreviewRenderer.render(model: sample, state: state,
                    to: output.appendingPathComponent("\(prefix)\(name).png"), width: width, dark: dark))
                try require(sample.isCredentialFreePreview, "A render fixture acquired live account access.")
            }
        }
        return UISmokeReport(credentialAccess: false,
            assertions: ["Every UI flag selects demo before model initialization", "No AccountEngine in preview models",
                         "Switch updates active identity", "Switch includes session restart notice", "Rename updates label",
                         "Remove preserves simulated current login", "Preview sign-in stays in memory",
                         "Claude and ChatGPT selections are independent", "Provider is fixed during operations and sign-in"],
            renders: records, quitCleanupPassed: false)
    }

    private static func checkSafeLaunchFlags() throws {
        let cases = [
            ["--demo"], ["--empty"], ["--dark"], ["--light"], ["--check-quit"],
            ["--render-preview", "/tmp/example.png"], ["--preview-state", "error"],
            ["--preview-width", "620"], ["--preview-height", "740"], ["--ui-smoke-test"],
            ["--preview-provider", "chatGPT"], ["--preview-provider", "invalid"],
            ["--ui-smoke-test", "--smoke-test"], ["--demo", "--smoke-test"],
            ["--preview-state", "invalid"], ["--preview-width", "invalid"]
        ]
        for arguments in cases {
            let options = UILaunchOptions(arguments: ["Switchboard"] + arguments)
            try require(options.requiresDemo && !options.runsCredentialSmoke,
                        "A UI flag selected the credential-backed launch path.")
            let sample = AppModel(demo: options.requiresDemo, previewState: options.previewState, provider: options.previewProvider)
            try require(sample.isCredentialFreePreview, "A UI flag initialized AccountEngine.")
        }
        try require(AppModel(empty: true).isCredentialFreePreview,
                    "An empty-state preview initialized AccountEngine.")
        try require(AppModel(previewState: .error).isCredentialFreePreview,
                    "A named-state preview initialized AccountEngine.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw UIVerificationError(message: message) }
    }
}
