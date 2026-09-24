import AppKit
import SwiftUI
import SwitchboardCore

private enum Palette {
    static let canvas = adaptive(light: 0xF6F4F0, dark: 0x191918)
    static let paper = adaptive(light: 0xFFFEFB, dark: 0x222220)
    static let ink = adaptive(light: 0x33332E, dark: 0xECEAE4)
    static let muted = adaptive(light: 0x706C65, dark: 0xADA79D)
    static let faint = adaptive(light: 0xE3E0D9, dark: 0x393834)
    static let coral = adaptive(light: 0xC2644A, dark: 0xDE987D)
    static let coralWash = adaptive(light: 0xF5E6D9, dark: 0x3A2D27)
    static let green = adaptive(light: 0x4A7057, dark: 0x9ABB9C)
    static let greenWash = adaptive(light: 0xE6F0E0, dark: 0x2D3A2D)
    static let accentText = adaptive(light: 0xA34B34, dark: 0xEBA68A)
    static let warning = adaptive(light: 0x90601B, dark: 0xE4BA75)
    static let danger = adaptive(light: 0xB13B32, dark: 0xF2A39B)
    static let meter = adaptive(light: 0x807A70, dark: 0xB7B0A4)
    static let edge = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.07)
    })

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

struct AccountListView: View {
    @ObservedObject var model: AppModel
    @State private var showingAddAccount = false
    @State private var accountToRename: SavedAccount?
    @State private var accountToRemove: SavedAccount?

    var body: some View {
        VStack(spacing: 0) {
            header
            providerNavigation
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let loadError = model.loadError {
                        MessageStrip(symbol: "exclamationmark.circle", text: loadError, isError: true)
                    }
                    if let error = model.error {
                        MessageStrip(symbol: "exclamationmark.circle", text: error, isError: true)
                    } else if model.loadError == nil, let notice = model.notice {
                        MessageStrip(symbol: "checkmark.circle", text: notice, isError: false)
                    }

                    if model.accounts.isEmpty {
                        if model.isLoading {
                            ProgressView("Loading accounts…")
                                .frame(maxWidth: .infinity, minHeight: 280)
                        } else if model.loadError != nil {
                            unavailableState
                        } else {
                            emptyState
                        }
                    } else {
                        accountSectionHeader
                        ForEach(model.accounts) { account in
                            AccountCard(
                                account: account,
                                provider: model.provider,
                                isActive: account.id == model.activeID,
                                isBusy: model.isBusy || model.isRefreshing || model.isLoading || model.loginInProgress,
                                isSwitching: account.id == model.switchingAccountID,
                                usageError: model.usageErrors[account.id],
                                onSwitch: { Task { await model.switchAccount(account) } },
                                onRename: { accountToRename = account },
                                onRemove: { accountToRemove = account }
                            )
                        }
                        if let current = model.current, model.activeID == nil, !model.loginInProgress {
                            unsavedLogin(current)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 490, idealHeight: 740)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .sheet(isPresented: $showingAddAccount) { AddAccountSheet(model: model) }
        .sheet(item: $accountToRename) { account in RenameAccountSheet(model: model, account: account) }
        .alert("Remove saved account?", isPresented: Binding(
            get: { accountToRemove != nil },
            set: { if !$0 { accountToRemove = nil } }
        ), presenting: accountToRemove) { account in
            Button("Cancel", role: .cancel) { accountToRemove = nil }
            Button("Remove", role: .destructive) {
                accountToRemove = nil
                Task { await model.remove(account) }
            }
        } message: { account in
            Text("Remove \(account.label) from Switchboard? This deletes its saved login. It does not cancel the subscription or sign \(model.provider.cliName) out.")
        }
        .onChange(of: model.provider) { _, _ in
            showingAddAccount = false
            accountToRename = nil
            accountToRemove = nil
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            SwitchboardMark(size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("Switchboard")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.5)
                Text(model.isDemo ? "Preview · Sample accounts" : "Your subscriptions, ready to switch.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 12)
            Button { Task { await model.refresh() } } label: {
                HStack(spacing: 7) {
                    ZStack {
                        Image(systemName: "arrow.clockwise")
                            .opacity(model.isRefreshing ? 0 : 1)
                        if model.isRefreshing { ProgressView().controlSize(.mini) }
                    }
                    .frame(width: 14, height: 14)
                    Text("Refresh")
                }
            }
            .buttonStyle(ActionButtonStyle(prominent: false, staticFeedback: true))
            .help("Refresh accounts and usage (⌘R)")
            .accessibilityLabel("Refresh accounts and usage")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isBusy || model.isRefreshing || model.isLoading || model.loginInProgress)

            Button { showingAddAccount = true } label: {
                Label("Add account", systemImage: "plus")
            }
            .buttonStyle(ActionButtonStyle(prominent: true))
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.isBusy || model.isRefreshing || model.isLoading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }

    private var providerNavigation: some View {
        HStack(alignment: .center, spacing: 20) {
            Picker("Subscription provider", selection: Binding(
                get: { model.provider },
                set: { provider in Task { await model.selectProvider(provider) } }
            )) {
                Text("Claude").tag(SubscriptionProvider.claude)
                Text("ChatGPT").tag(SubscriptionProvider.chatGPT)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(width: 210)
            .disabled(model.isBusy || model.isRefreshing || model.isLoading || model.loginInProgress
                      || showingAddAccount || accountToRename != nil || accountToRemove != nil)
            .accessibilityLabel("Subscription provider")
            .help("Choose which subscription’s accounts to manage. Each provider keeps its own active account.")

            Text(model.provider == .chatGPT
                 ? "ChatGPT subscriptions used in Codex.\nChatGPT message quotas are separate."
                 : "Claude subscriptions used in Claude Code.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
    }

    private var accountSectionHeader: some View {
        HStack {
            HStack(spacing: 7) {
                Text("ACCOUNTS").tracking(1.1)
                Text("\(model.accounts.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.faint.opacity(0.6), in: Capsule())
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                Text(model.provider.cliName)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Palette.muted)
        .padding(.bottom, 1)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Palette.coralWash.opacity(0.55)).frame(width: 100, height: 100)
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Palette.coral)
            }
            .padding(.bottom, 23)
            Text("Your \(model.provider.displayName) accounts, together.")
                .font(.system(size: 22, weight: .medium))
                .tracking(-0.5)
            Text("Save your \(model.provider.cliName) login. Add another account.\nSee your limits and switch with a click.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .padding(.top, 11)
                .padding(.bottom, 25)
            Button { showingAddAccount = true } label: {
                Label("Add your first account", systemImage: "plus")
            }
            .buttonStyle(ActionButtonStyle(prominent: true))
            .disabled(model.isBusy || model.isRefreshing)
            if let current = model.current {
                Text("Signed in as \(current.email)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 16)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }

    private var unavailableState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.lock")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.coral)
            Text("Accounts couldn’t be loaded")
                .font(.system(size: 20, weight: .medium))
            Text("Resolve the error above, then try again.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Button("Try again") { Task { await model.load() } }
                .buttonStyle(ActionButtonStyle(prominent: true))
                .disabled(model.isBusy || model.isRefreshing || model.isLoading)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private func unsavedLogin(_ current: CurrentLogin) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 19))
                .foregroundStyle(Palette.coral)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your current \(model.provider.cliName) login isn’t saved yet.").font(.system(size: 12, weight: .medium))
                Text(current.email).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer()
            Button("Save login") { showingAddAccount = true }
                .buttonStyle(ActionButtonStyle(prominent: false))
                .disabled(model.isBusy || model.isRefreshing)
        }
        .padding(15)
        .background(Palette.coralWash.opacity(0.4), in: RoundedRectangle(cornerRadius: 13))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.faint).frame(height: 0.7)
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 11))
                Text(model.provider.restartNotice)
                    .font(.system(size: 11))
                Spacer(minLength: 10)
                Image(systemName: "lock.shield").font(.system(size: 12))
                    .help("Saved logins stay in your Mac’s Keychain.")
                    .accessibilityLabel("Saved logins stay in your Mac’s Keychain")
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }
}

private struct AccountCard: View {
    let account: SavedAccount
    let provider: SubscriptionProvider
    let isActive: Bool
    let isBusy: Bool
    let isSwitching: Bool
    let usageError: String?
    let onSwitch: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var hasCustomName: Bool {
        account.label.caseInsensitiveCompare(account.email) != .orderedSame
    }

    var body: some View {
        Button(action: onSwitch) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 22) {
                    identity
                    HStack(alignment: .top, spacing: 20) {
                        if provider == .claude {
                            UsageMeter(title: featuredModelLimit.map { "Weekly \($0.name)" } ?? "Weekly Fable",
                                       window: featuredModelLimit?.window, isFeatured: true)
                            metricDivider
                        }
                        UsageMeter(title: "Five-hour limit", window: account.usage?.fiveHour)
                        metricDivider
                        UsageMeter(title: "Weekly limit", window: account.usage?.sevenDay)
                    }
                    if let usage = account.usage {
                        ForEach(Array(usage.modelScoped.enumerated()), id: \.offset) { index, scoped in
                            if index != featuredModelLimitIndex {
                                UsageMeter(title: scopedLimitTitle(scoped.name), window: scoped.window)
                            }
                        }
                        if provider == .claude {
                            if let sonnet = usage.sevenDaySonnet {
                                UsageMeter(title: "Weekly Sonnet", window: sonnet)
                            }
                            if let opus = usage.sevenDayOpus {
                                UsageMeter(title: "Weekly Opus", window: opus)
                            }
                        }
                    }
                }
                .padding(20)

                Rectangle().fill(Palette.edge).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if usageError != nil {
                            Image(systemName: "exclamationmark.circle")
                            if let usage = account.usage {
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    Text("Saved usage · checked \(relativeDate(usage.fetchedAt, now: context.date))")
                                }
                            } else { Text("Usage unavailable") }
                        } else if let usage = account.usage {
                            Image(systemName: "clock")
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                Text("Checked \(relativeDate(usage.fetchedAt, now: context.date))")
                            }
                        } else {
                            Image(systemName: "clock")
                            Text("Usage hasn’t been checked")
                        }
                        Spacer(minLength: 12)
                        if isActive { Text("Used for new \(provider.cliName) sessions").foregroundStyle(Palette.muted) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(usageError == nil ? Palette.muted : Palette.danger)
                    if let usageError {
                        Text(usageError)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Palette.canvas.opacity(0.38))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(CardButtonStyle())
        .background(Palette.paper)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isActive ? Palette.coral.opacity(0.65) : Palette.edge.opacity(isHovered ? 1.8 : 1),
                              lineWidth: isActive ? 1.25 : 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.035), radius: 1, x: 0, y: 1)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.025), radius: 5, x: 0, y: 3)
        .overlay {
            RoundedRectangle(cornerRadius: 21)
                .stroke(Palette.accentText, lineWidth: 2)
                .padding(-3)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .focusEffectDisabled()
        .focused($isFocused)
        .disabled(isActive || isBusy)
        .accessibilityLabel(hasCustomName ? "\(account.label), \(account.email), \(account.plan)" : "\(account.email), \(account.plan)")
        .accessibilityValue(isActive ? "Active account. \(usageDescription)" : usageDescription)
        .accessibilityHint(isActive ? "Used for new \(provider.cliName) sessions" : "Switch \(provider.cliName) to this account")
        .onHover { isHovered = $0 }
        .overlay(alignment: .topTrailing) { options.padding(.top, 23).padding(.trailing, 14) }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            Text(account.initials.isEmpty ? "C" : account.initials)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(isActive ? Palette.accentText : Palette.muted)
                .frame(width: 40, height: 40)
                .background(isActive ? Palette.coralWash : Palette.canvas, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(account.label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(hasCustomName ? .tail : .middle)
                HStack(spacing: 7) {
                    if hasCustomName {
                        Text(account.email).lineLimit(1).truncationMode(.middle)
                        Text("·").accessibilityHidden(true)
                    }
                    Text(account.plan).fixedSize()
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            }
            .help(hasCustomName ? "\(account.label)\n\(account.email)" : account.email)
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Active")
                } else if isSwitching {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                    Text("Switching…")
                } else {
                    Text("Switch")
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isActive ? Palette.green : Palette.ink)
            .padding(.leading, isActive ? 10 : 12)
            .padding(.trailing, 10)
            .frame(height: 29)
            .background(isActive ? Palette.greenWash : Palette.canvas, in: Capsule())
            .fixedSize()
            .padding(.trailing, 30)
        }
    }

    private var options: some View {
        Menu {
            Button("Rename account…", systemImage: "pencil", action: onRename)
            Divider()
            Button("Remove saved account…", systemImage: "trash", role: .destructive, action: onRemove)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isBusy)
        .help("Rename or remove \(account.label)")
        .accessibilityLabel("Options for \(account.label)")
    }

    private var metricDivider: some View {
        Rectangle().fill(Palette.edge).frame(width: 1, height: 108).accessibilityHidden(true)
    }

    private var featuredModelLimit: NamedUsageWindow? {
        guard let index = featuredModelLimitIndex else { return nil }
        return account.usage?.modelScoped[index]
    }

    private var featuredModelLimitIndex: Int? {
        guard provider == .claude else { return nil }
        return account.usage?.modelScoped.firstIndex {
            $0.name.range(of: "\\bfable\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private func scopedLimitTitle(_ name: String) -> String {
        provider == .claude ? "Weekly \(name)" : name
    }

    private var usageDescription: String {
        func describe(_ label: String, _ window: UsageWindow?) -> String {
            guard let window else { return "\(label) usage unavailable." }
            return "\(label) \(usagePercentage(window)) percent used. \(window.fraction >= 1 ? "Limit reached. " : "")\(resetDescription(window.resetsAt))."
        }
        let fiveHour = describe("Five-hour limit", account.usage?.fiveHour)
        let weekly = describe("Weekly limit", account.usage?.sevenDay)
        let models = account.usage?.modelScoped.map {
            describe(scopedLimitTitle($0.name), $0.window)
        }.joined(separator: " ") ?? ""
        let failure = usageError.map { "Usage check failed: \($0)" } ?? ""
        return "\(fiveHour) \(weekly) \(models) \(failure)"
    }
}

private struct UsageMeter: View {
    let title: String
    let window: UsageWindow?
    var isFeatured = false

    private var color: Color {
        guard let window else { return Palette.faint }
        if window.fraction >= 1 { return Palette.danger }
        if window.fraction >= 0.9 { return Palette.warning }
        return isFeatured ? Palette.coral : Palette.meter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .help(title)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let window {
                    Text("\(usagePercentage(window))%")
                        .font(.system(size: 23, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(window.fraction >= 1 ? Palette.danger : Palette.ink)
                    Text(window.fraction >= 1 ? "limit reached" : "used")
                        .font(.system(size: 10))
                        .foregroundStyle(window.fraction >= 1 ? Palette.danger : Palette.muted)
                        .lineLimit(1)
                } else {
                    Text("—").font(.system(size: 23, weight: .regular)).foregroundStyle(Palette.muted)
                    Text("unavailable").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.faint.opacity(0.7))
                    if let window, window.fraction > 0 {
                        Capsule().fill(color).frame(width: max(3, geometry.size.width * window.fraction))
                    }
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    Text(resetCountdown(window?.resetsAt, now: context.date))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(window?.resetsAt == nil ? Palette.muted : Palette.ink)
                    Text(resetDateText(window?.resetsAt, now: context.date))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .help(window?.resetsAt?.formatted(date: .complete, time: .shortened) ?? "Reset time unavailable")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func usagePercentage(_ window: UsageWindow) -> String {
    window.utilization.formatted(.number.precision(.fractionLength(0...1)))
}

private struct AddAccountSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var authorizationCode = ""
    @FocusState private var labelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.loginInProgress ? "Finish signing in" : "Add a \(model.provider.displayName) account")
                        .font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                    Text(model.loginInProgress ? "Your browser handles the sign-in." : "Keep a login ready for whenever you need it.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                SwitchboardMark(size: 35)
            }

            if model.loginInProgress {
                VStack(alignment: .leading, spacing: 14) {
                    loginStep(number: "1", text: "Choose the account you want to add in your browser.")
                    loginStep(number: "2", text: model.provider == .chatGPT
                              ? "Complete the Codex sign-in with your ChatGPT account."
                              : "Complete the Claude Code sign-in.")
                    loginStep(number: "3", text: "Return here and save the new login.")
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))

                if model.provider == .claude {
                    DisclosureGroup("Browser gave you a code?") {
                        HStack(spacing: 8) {
                            TextField("Paste the sign-in code", text: $authorizationCode)
                                .textFieldStyle(.roundedBorder)
                                .privacySensitive()
                                .autocorrectionDisabled()
                                .accessibilityLabel("Claude sign-in code")
                            Button("Continue") {
                                Task {
                                    await model.submitLoginCode(authorizationCode)
                                    if model.error == nil { authorizationCode = "" }
                                }
                            }
                            .disabled(model.isBusy || model.isRefreshing || authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.top, 8)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                }
            } else if let current = model.current {
                HStack(spacing: 11) {
                    Image(systemName: "terminal").font(.system(size: 21)).foregroundStyle(Palette.coral)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CURRENT \(model.provider.cliName.uppercased()) LOGIN")
                            .font(.system(size: 9, weight: .semibold)).tracking(1)
                            .foregroundStyle(Palette.muted)
                        Text(current.email).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                    }
                    Spacer()
                    Text(current.plan).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                }
                .padding(16)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
            } else {
                MessageStrip(symbol: "terminal", text: model.provider == .chatGPT
                             ? "Sign in to Codex with your ChatGPT account to add your subscription."
                             : "Sign in with the official Claude Code CLI to add your first account.", isError: false)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text("Account name").font(.system(size: 12, weight: .medium))
                    Text("optional").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                TextField("e.g. Personal or Work", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($labelFocused)
                    .disabled(model.isBusy || model.isRefreshing)
                    .accessibilityLabel("Account name")
            }

            if let error = model.error {
                MessageStrip(symbol: "exclamationmark.circle", text: error, isError: true)
            }

            if !model.loginInProgress {
                VStack(spacing: 11) {
                    if model.current != nil {
                        Button {
                            Task {
                                await model.saveCurrent(label: label)
                                if model.error == nil { dismiss() }
                            }
                        } label: {
                            Label("Save current login", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ActionButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy || model.isRefreshing)
                    }
                    Button {
                        Task { await model.beginLogin() }
                    } label: {
                        HStack {
                            Text(model.current == nil ? "Sign in to \(model.provider.cliName)" : "Sign in another account")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(ActionButtonStyle(prominent: model.current == nil))
                    .disabled(model.isBusy || model.isRefreshing)
                    Text("Opens the official \(model.provider.cliName) sign-in in your browser.")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }

            HStack {
                Label("Saved securely in your Mac’s Keychain", systemImage: "lock.shield")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Cancel") {
                    Task {
                        if model.loginInProgress { await model.cancelLogin() }
                        if !model.loginInProgress { dismiss() }
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
                if model.loginInProgress {
                    Button {
                        Task {
                            await model.finishLogin(label: label)
                            if !model.loginInProgress && model.error == nil { dismiss() }
                        }
                    } label: {
                        Text(model.isBusy ? "Saving…" : "Save new login")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.ink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.isRefreshing)
                }
            }
        }
        .padding(28)
        .frame(width: 485)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .interactiveDismissDisabled(model.loginInProgress || model.isBusy)
        .onAppear { labelFocused = true }
    }

    private func loginStep(number: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number).font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.coral)
                .frame(width: 19, height: 19)
                .background(Palette.coralWash, in: Circle())
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RenameAccountSheet: View {
    @ObservedObject var model: AppModel
    let account: SavedAccount
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename account").font(.system(size: 21, weight: .semibold))
            Text(account.email).font(.system(size: 12)).foregroundStyle(Palette.muted)
            TextField("Account name", text: $label)
                .textFieldStyle(.roundedBorder).controlSize(.large).focused($focused)
            if let error = model.error {
                MessageStrip(symbol: "exclamationmark.circle", text: error, isError: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save name") {
                    Task {
                        await model.rename(account, label: label)
                        if model.error == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent).tint(Palette.ink).keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || model.isRefreshing || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26).frame(width: 390)
        .background(Palette.canvas)
        .onAppear { label = account.label; focused = true }
        .interactiveDismissDisabled(model.isBusy)
    }
}

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("Subscription") {
            providerMenuItem(.claude)
            providerMenuItem(.chatGPT)
        }
        .disabled(model.isBusy || model.isRefreshing || model.isLoading || model.loginInProgress)
        Divider()
        Text("\(model.provider.displayName) accounts · \(model.provider.cliName)")
        if model.accounts.isEmpty {
            Text(model.isLoading ? "Loading accounts…" : model.loadError == nil ? "No saved accounts" : "Accounts unavailable — open Switchboard")
        } else if model.loadError != nil {
            Text("Active account unknown — open Switchboard")
        }
        ForEach(model.accounts) { account in
            Button {
                Task { await model.switchAccount(account) }
            } label: {
                if model.activeID == account.id {
                    Label(account.label, systemImage: "checkmark")
                } else {
                    Text(account.label)
                }
            }
            .disabled(model.isBusy || model.isRefreshing || model.isLoading || model.loginInProgress || model.activeID == account.id)
        }
        Divider()
        Button("Open Switchboard") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o", modifiers: .command)
        Button("Refresh usage") { Task { await model.refresh() } }
            .disabled(model.isBusy || model.isRefreshing || model.isLoading || model.loginInProgress)
        Divider()
        Button("Quit Switchboard") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
    }

    private func providerMenuItem(_ provider: SubscriptionProvider) -> some View {
        Button {
            Task { await model.selectProvider(provider) }
        } label: {
            if model.provider == provider {
                Label(provider.displayName, systemImage: "checkmark")
            } else {
                Text(provider.displayName)
            }
        }
        .disabled(model.provider == provider)
    }
}

private struct SwitchboardMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29)
                .fill(Palette.coral)
                .shadow(color: Palette.coral.opacity(0.13), radius: 5, x: 0, y: 2)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: size * 0.40, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.94))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct MessageStrip: View {
    let symbol: String
    let text: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).padding(.top, 1)
            Text(text).font(.system(size: 11)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isError ? Palette.danger : Palette.muted)
        .padding(12)
        .background(isError ? Palette.coralWash.opacity(0.5) : Palette.faint.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct ActionButtonStyle: ButtonStyle {
    var prominent: Bool
    var staticFeedback = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var keyboardEvent: Bool {
        NSApp.currentEvent?.type == .keyDown || NSApp.currentEvent?.type == .keyUp
    }

    func makeBody(configuration: Configuration) -> some View {
        let moving = !staticFeedback && !reduceMotion && !keyboardEvent
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .foregroundStyle(prominent ? Palette.canvas : Palette.ink)
            .background(prominent ? Palette.ink : Palette.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(prominent ? Color.clear : Palette.edge, lineWidth: 1))
            .shadow(color: .black.opacity(prominent ? 0 : 0.04), radius: 1, x: 0, y: 1)
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.accentText, lineWidth: 2).padding(-3).opacity(isFocused ? 1 : 0))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .scaleEffect(moving && configuration.isPressed ? 0.96 : 1)
            .animation(moving ? .timingCurve(0.2, 0, 0, 1, duration: 0.15) : nil, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Account switching is frequent. Keep the surface still and the usage legible.
        configuration.label.background(Palette.ink.opacity(configuration.isPressed ? 0.035 : 0))
    }
}

private func relativeDate(_ date: Date, now: Date = Date()) -> String {
    let age = max(0, now.timeIntervalSince(date))
    if age < 60 { return "just now" }
    if age < 3600 { return "\(Int(age / 60))m ago" }
    if age < 86400 { return "\(Int(age / 3600))h ago" }
    return "\(Int(age / 86400))d ago"
}

private func resetDescription(_ date: Date?) -> String {
    guard let date else { return "Reset time unavailable" }
    return "Resets \(date.formatted(date: .complete, time: .shortened))"
}

private func resetCountdown(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "Reset time unknown" }
    let remaining = date.timeIntervalSince(now)
    if remaining <= 0 { return "Reset time passed" }
    let minutes = max(1, Int(ceil(remaining / 60)))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    if days > 0 { return "Resets in \(days)d \(hours)h" }
    return hours > 0 ? "Resets in \(hours)h \(minutes % 60)m" : "Resets in \(minutes)m"
}

private func resetDateText(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "Refresh to check" }
    guard date > now else { return "Refresh to check usage" }
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
    if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now),
       Calendar.current.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow at \(time)" }
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE d MMM jm")
    return formatter.string(from: date)
}
