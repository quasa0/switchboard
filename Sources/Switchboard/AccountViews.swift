import AppKit
import SwiftUI
import SwitchboardCore

private enum Palette {
    static let canvas = adaptive(light: 0xFAFAF9, dark: 0x141413)
    static let paper = adaptive(light: 0xFFFFFF, dark: 0x1E1E1C)
    static let ink = adaptive(light: 0x242423, dark: 0xE8E8E5)
    static let muted = adaptive(light: 0x70706B, dark: 0xA1A19B)
    static let faint = adaptive(light: 0xE7E7E3, dark: 0x2C2C29)
    static let accent = adaptive(light: 0x0B8866, dark: 0x10B981)
    static let accentWash = adaptive(light: 0xEDF7F2, dark: 0x16281F)
    static let green = adaptive(light: 0x15835F, dark: 0x6BCBA9)
    static let greenWash = adaptive(light: 0xE7F4EE, dark: 0x193126)
    static let accentText = adaptive(light: 0x0B7557, dark: 0x74D5B3)
    static let warning = adaptive(light: 0x90601B, dark: 0xE4BA75)
    static let danger = adaptive(light: 0xB13B32, dark: 0xF2A39B)
    static let errorWash = adaptive(light: 0xFBEFEC, dark: 0x321C1A)
    static let meter = adaptive(light: 0x0B9970, dark: 0x10B981)
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

private struct AccountActionTarget: Identifiable {
    let provider: SubscriptionProvider
    let account: SavedAccount
    var id: String { "\(provider.rawValue)-\(account.id.uuidString)" }
}

struct AccountListView: View {
    @ObservedObject var model: DashboardModel
    @State private var accountToAdd: SubscriptionProvider?
    @State private var accountToRename: AccountActionTarget?
    @State private var accountToRenew: AccountActionTarget?
    @State private var accountToViewResets: AccountActionTarget?
    @State private var accountToRemove: AccountActionTarget?

    private var isPresentingAccountAction: Bool {
        accountToAdd != nil || accountToRename != nil || accountToRenew != nil
            || accountToViewResets != nil || accountToRemove != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(model.providers, id: \.provider) { providerModel in
                            ProviderAccountSection(
                                model: providerModel,
                                wideLayout: geometry.size.width >= 950,
                                isBlocked: model.isBlocked || isPresentingAccountAction,
                                onAdd: { accountToAdd = providerModel.provider },
                                onRename: { accountToRename = AccountActionTarget(provider: providerModel.provider, account: $0) },
                                onSetRenewal: { accountToRenew = AccountActionTarget(provider: providerModel.provider, account: $0) },
                                onViewResets: { accountToViewResets = AccountActionTarget(provider: providerModel.provider, account: $0) },
                                onRemove: { accountToRemove = AccountActionTarget(provider: providerModel.provider, account: $0) }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            footer
        }
        .frame(minWidth: 620, idealWidth: 1120, minHeight: 490, idealHeight: 780)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .sheet(item: $accountToAdd) { provider in
            AddAccountSheet(model: model.model(for: provider))
        }
        .sheet(item: $accountToRename) { target in
            RenameAccountSheet(model: model.model(for: target.provider), account: target.account)
        }
        .sheet(item: $accountToRenew) { target in
            RenewalDateSheet(model: model.model(for: target.provider), account: target.account)
        }
        .sheet(item: $accountToViewResets) { target in
            ResetDetailsSheet(account: target.account, provider: target.provider)
        }
        .alert("Remove saved account?", isPresented: Binding(
            get: { accountToRemove != nil },
            set: { if !$0 { accountToRemove = nil } }
        ), presenting: accountToRemove) { target in
            Button("Cancel", role: .cancel) { accountToRemove = nil }
            Button("Remove", role: .destructive) {
                accountToRemove = nil
                Task { await model.model(for: target.provider).remove(target.account) }
            }
        } message: { target in
            Text("Remove \(target.account.label) from Switchboard? This deletes its saved login. It does not cancel the subscription or sign \(target.provider.cliName) out.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 25)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 11) {
                    Text("Switchboard")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.5)
                    Text("\(model.accountCount) accounts")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                Text(model.isDemo ? "Preview · Sample accounts" : "All your accounts, at a glance.")
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
                    Text("Refresh all")
                }
            }
            .buttonStyle(ActionButtonStyle(prominent: false, staticFeedback: true))
            .help("Refresh all accounts and usage (⌘R)")
            .accessibilityLabel("Refresh all accounts and usage")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isBlocked || isPresentingAccountAction)

            Menu {
                Button("Add Claude account") { accountToAdd = .claude }
                Button("Add ChatGPT account") { accountToAdd = .chatGPT }
            } label: {
                Label("Add account", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(ActionButtonStyle(prominent: false))
            .fixedSize()
            .disabled(model.isBlocked || isPresentingAccountAction)
            .accessibilityLabel("Add account")
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.faint).frame(height: 0.7)
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 11))
                Text("Close Codex before switching. Restart Claude Code after switching.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                Image(systemName: "lock.shield").font(.system(size: 12))
                    .help("Saved logins stay in your Mac’s Keychain.")
                    .accessibilityLabel("Saved logins stay in your Mac’s Keychain")
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 24)
            .padding(.vertical, 13)
        }
    }
}

private struct ProviderAccountSection: View {
    @ObservedObject var model: AppModel
    let wideLayout: Bool
    let isBlocked: Bool
    let onAdd: () -> Void
    let onRename: (SavedAccount) -> Void
    let onSetRenewal: (SavedAccount) -> Void
    let onViewResets: (SavedAccount) -> Void
    let onRemove: (SavedAccount) -> Void

    private var metricTitles: [String] {
        let metrics = model.accounts.flatMap { accountUsageMetrics($0.usage, provider: model.provider) }
        let ordered = metrics.filter(\.isFeatured)
            + metrics.filter { $0.id == "five-hour" }
            + metrics.filter { $0.id == "weekly" }
            + metrics.filter { !$0.isFeatured && $0.id != "five-hour" && $0.id != "weekly" }
        return ordered.reduce(into: []) { titles, metric in
            if !titles.contains(metric.title) { titles.append(metric.title) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader
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
                    ProgressView("Loading \(model.provider.displayName) accounts…")
                        .frame(maxWidth: .infinity, minHeight: 130)
                } else if model.loadError != nil {
                    unavailableState
                } else {
                    emptyState
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(model.accounts) { account in
                        AccountRow(
                            account: account,
                            provider: model.provider,
                            wideLayout: wideLayout,
                            metricTitles: metricTitles,
                            showsManualResets: model.provider == .chatGPT || model.accounts.contains { $0.usage?.manualResets != nil },
                            isActive: account.id == model.activeID,
                            isBusy: isBlocked,
                            isSwitching: account.id == model.switchingAccountID,
                            usageError: model.usageErrors[account.id],
                            onSwitch: { Task { await model.switchAccount(account) } },
                            onRename: { onRename(account) },
                            onSetRenewal: { onSetRenewal(account) },
                            onViewResets: { onViewResets(account) },
                            onRemove: { onRemove(account) }
                        )
                    }
                }
                if let current = model.current, model.activeID == nil, !model.loginInProgress {
                    unsavedLogin(current)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(model.provider.displayName)
                    .font(.system(size: 15, weight: .semibold))
                Text("\(model.accounts.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .accessibilityLabel("\(model.accounts.count) saved accounts")
                Spacer(minLength: 12)
                Button(action: onAdd) {
                    Label("Add account", systemImage: "plus")
                }
                .buttonStyle(ActionButtonStyle(prominent: false))
                .disabled(isBlocked)
                .accessibilityLabel("Add \(model.provider.displayName) account")
            }
            Text(model.provider == .chatGPT
                 ? "Codex allowance remaining · ChatGPT chat quotas are separate."
                 : "Claude Code · Allowance remaining")
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("No saved \(model.provider.displayName) accounts", systemImage: "person.crop.rectangle.stack")
                .font(.system(size: 13, weight: .medium))
            Text("Save a \(model.provider.cliName) login to see its limits and switch accounts.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let current = model.current {
                Text("Signed in as \(current.email)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
            }
            Button("Add \(model.provider.displayName) account", action: onAdd)
                .buttonStyle(ActionButtonStyle(prominent: true))
                .disabled(isBlocked)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.edge, lineWidth: 1))
    }

    private var unavailableState: some View {
        HStack(spacing: 14) {
            Text("Accounts couldn’t be loaded.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Button("Try again") { Task { await model.load() } }
                .buttonStyle(ActionButtonStyle(prominent: false))
                .disabled(isBlocked)
        }
        .padding(16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16))
    }

    private func unsavedLogin(_ current: CurrentLogin) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 18))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your current login isn’t saved.").font(.system(size: 12, weight: .medium))
                Text(current.email).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Save login", action: onAdd)
                .buttonStyle(ActionButtonStyle(prominent: false))
                .disabled(isBlocked)
        }
        .padding(14)
        .background(Palette.accentWash.opacity(0.4), in: RoundedRectangle(cornerRadius: 13))
    }
}

struct AccountUsageMetric: Identifiable {
    let id: String
    let title: String
    let window: UsageWindow
    var isFeatured = false
}

/// Only reported windows become meters. Missing fields do not mean zero usage or a failed request.
func accountUsageMetrics(_ usage: UsageSnapshot?, provider: SubscriptionProvider) -> [AccountUsageMetric] {
    guard let usage else { return [] }
    var metrics: [AccountUsageMetric] = []
    let featuredIndex = provider == .claude ? usage.modelScoped.firstIndex {
        $0.name.range(of: "\\bfable\\b", options: [.regularExpression, .caseInsensitive]) != nil
    } : nil
    if let featuredIndex {
        let scoped = usage.modelScoped[featuredIndex]
        metrics.append(AccountUsageMetric(id: "model-\(featuredIndex)", title: "Weekly \(scoped.name)",
                                          window: scoped.window, isFeatured: true))
    }
    if let window = usage.fiveHour {
        metrics.append(AccountUsageMetric(id: "five-hour", title: "Five-hour limit", window: window))
    }
    if let window = usage.sevenDay {
        metrics.append(AccountUsageMetric(id: "weekly", title: "Weekly limit", window: window))
    }
    for (index, scoped) in usage.modelScoped.enumerated() where index != featuredIndex {
        metrics.append(AccountUsageMetric(id: "model-\(index)",
                                          title: provider == .claude ? "Weekly \(scoped.name)" : scoped.name,
                                          window: scoped.window))
    }
    if provider == .claude {
        if let window = usage.sevenDaySonnet {
            metrics.append(AccountUsageMetric(id: "sonnet", title: "Weekly Sonnet", window: window))
        }
        if let window = usage.sevenDayOpus {
            metrics.append(AccountUsageMetric(id: "opus", title: "Weekly Opus", window: window))
        }
    }
    return metrics
}

private struct AccountRow: View {
    let account: SavedAccount
    let provider: SubscriptionProvider
    let wideLayout: Bool
    let metricTitles: [String]
    let showsManualResets: Bool
    let isActive: Bool
    let isBusy: Bool
    let isSwitching: Bool
    let usageError: String?
    let onSwitch: () -> Void
    let onRename: () -> Void
    let onSetRenewal: () -> Void
    let onViewResets: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var hasCustomName: Bool {
        account.label.caseInsensitiveCompare(account.email) != .orderedSame
    }

    private var metrics: [AccountUsageMetric] {
        accountUsageMetrics(account.usage, provider: provider)
    }

    var body: some View {
        Button(action: onSwitch) {
            VStack(alignment: .leading, spacing: 10) {
                if wideLayout {
                    HStack(alignment: .top, spacing: 24) {
                        identity.frame(width: 220, alignment: .leading)
                        usageContent
                        actionIndicator
                    }
                    .frame(minHeight: 74, alignment: .top)
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        identity.frame(maxWidth: .infinity, alignment: .leading)
                        actionIndicator
                    }
                    if !metrics.isEmpty || account.usage != nil && showsManualResets {
                        usageContent.padding(.top, 5)
                    } else {
                        unavailableUsage
                    }
                }
                if let usageError {
                    Label(usageError, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AccountRowButtonStyle())
        .background(isActive ? Palette.greenWash.opacity(0.27) : isHovered ? Palette.paper.opacity(0.55) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.edge).frame(height: 0.7).padding(.horizontal, 16)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(Palette.green)
                .frame(width: 2).padding(.vertical, 15).opacity(isActive ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(Palette.accentText, lineWidth: 2)
                .padding(-2)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .focusEffectDisabled()
        .focused($isFocused)
        .disabled(isActive || isBusy)
        .accessibilityLabel(hasCustomName
                             ? "\(provider.displayName), \(account.label), \(account.email), \(provider.planLabel(account.plan))"
                             : "\(provider.displayName), \(account.email), \(provider.planLabel(account.plan))")
        .accessibilityValue("\(isActive ? "Active account. " : "")\(renewalDescription) \(usageDescription)")
        .accessibilityHint(isActive ? "Used for new \(provider.cliName) sessions" : "Switch \(provider.cliName) to this account")
        .onHover { isHovered = $0 }
        .overlay(alignment: .topTrailing) {
            options.padding(.trailing, 13).padding(.top, 15)
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(account.label)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(hasCustomName ? .tail : .middle)
            if hasCustomName {
                Text(account.email)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                PlanBadge(label: provider.planLabel(account.plan))
                if let usage = account.usage {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text("\(usageError == nil ? "Checked" : "Saved") \(relativeDate(usage.fetchedAt, now: context.date))")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(usageError == nil ? Palette.muted : Palette.danger)
                    .lineLimit(1)
                    .help("Last successful usage check: \(usage.fetchedAt.formatted(date: .complete, time: .shortened))")
                }
            }
            if let renewal = account.renewalAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("\(renewal > context.date ? "Renews" : "Renewal") \(compactDueDate(renewal)) · \(dueInterval(renewal, now: context.date))")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help("Renewal date set manually: \(renewal.formatted(date: .complete, time: .shortened)). Edit it in account options.")
            } else {
                Text("Renewal not set")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .help("Set the renewal date in account options.")
            }
        }
        .help(hasCustomName ? "\(account.label)\n\(account.email)" : account.email)
    }

    @ViewBuilder
    private var usageContent: some View {
        if !metrics.isEmpty || account.usage != nil && showsManualResets {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22, alignment: .top), count: min(3, metricTitles.count + (showsManualResets ? 1 : 0))),
                      alignment: .leading, spacing: 18) {
                ForEach(metricTitles, id: \.self) { title in
                    if let metric = metrics.first(where: { $0.title == title }) {
                        UsageMeter(title: metric.title, window: metric.window)
                    } else {
                        Color.clear.frame(height: 66).accessibilityHidden(true)
                    }
                }
                if showsManualResets {
                    ManualResetSummaryView(summary: account.usage?.manualResets)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            unavailableUsage
        }
    }

    private var unavailableUsage: some View {
        Text(account.usage != nil ? "No quota windows reported"
             : usageError == nil ? "Usage hasn’t been checked" : "Usage unavailable")
            .font(.system(size: 12))
            .foregroundStyle(usageError == nil ? Palette.muted : Palette.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionIndicator: some View {
        HStack(spacing: 5) {
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
        .frame(width: 90, height: 28)
        .background(isActive ? Palette.greenWash.opacity(0.7) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .padding(.trailing, 34)
        .help(isActive ? "Used for new \(provider.cliName) sessions" : "Switch \(provider.cliName) to this account")
    }

    private var options: some View {
        Menu {
            if account.usage?.manualResets != nil {
                Button("Manual reset details…", systemImage: "arrow.counterclockwise", action: onViewResets)
            }
            Button(account.renewalAt == nil ? "Set renewal date…" : "Edit renewal date…",
                   systemImage: "calendar", action: onSetRenewal)
            Button("Rename account…", systemImage: "pencil", action: onRename)
            Divider()
            Button("Remove saved account…", systemImage: "trash", role: .destructive, action: onRemove)
        } label: {
            Label("Options for \(provider.displayName) account \(account.label)", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isBusy)
        .help("Options for \(provider.displayName) account \(account.label): set renewal date, rename, or remove")
        .accessibilityLabel("Options for \(provider.displayName) account \(account.label)")
        .accessibilityIdentifier("account-options-\(provider.rawValue)-\(account.id.uuidString)")
    }

    private var usageDescription: String {
        let descriptions = metrics.map { metric in
            "\(metric.title) \(remainingPercentage(metric.window)) percent remaining, \(usagePercentage(metric.window)) percent used. \(metric.window.fraction >= 1 ? "Limit reached. " : "")\(resetDescription(metric.window.resetsAt))."
        }
        let emptyDescription = account.usage == nil
            ? (usageError == nil ? "Usage hasn’t been checked." : "Usage unavailable.")
            : "No quota windows reported."
        let windows = descriptions.isEmpty ? emptyDescription : descriptions.joined(separator: " ")
        let failure = usageError.map { "Usage check failed: \($0)" } ?? ""
        let resets: String
        if let summary = account.usage?.manualResets {
            let dates = summary.credits?.filter { $0.status == "available" }.enumerated().map { index, credit in
                "Reset \(index + 1) \(credit.expiresAt.map { "expires \($0.formatted(date: .complete, time: .shortened))" } ?? "has no expiry")."
            }.joined(separator: " ") ?? "Expiry details unavailable."
            resets = "\(summary.availableCount) manual resets available. \(dates)"
        } else { resets = showsManualResets ? "Manual resets unavailable." : "" }
        return "\(windows) \(resets) \(failure)"
    }

    private var renewalDescription: String {
        guard let renewal = account.renewalAt else { return "Renewal date not set." }
        return "Renewal date set manually: \(renewal.formatted(date: .complete, time: .shortened))."
    }
}

private struct UsageMeter: View {
    let title: String
    let window: UsageWindow

    private var color: Color {
        if window.fraction >= 1 { return Palette.danger }
        if window.fraction >= 0.9 { return Palette.warning }
        return Palette.meter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .help(title)
                Spacer(minLength: 0)
                Text("\(remainingPercentage(window))%")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.fraction >= 1 ? Palette.danger : Palette.ink)
                    .fixedSize()
                    .help("\(remainingPercentage(window))% remaining · \(usagePercentage(window))% used\(window.fraction >= 1 ? " · Limit reached" : "")")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.faint.opacity(0.7))
                    if window.fraction < 1 {
                        Capsule().fill(color).frame(width: geometry.size.width * (1 - window.fraction))
                    }
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    Text(resetCountdown(window.resetsAt, now: context.date))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(window.resetsAt == nil ? Palette.muted : Palette.ink)
                    Text(resetDateText(window.resetsAt, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .help(window.resetsAt?.formatted(date: .complete, time: .shortened) ?? "Reset time unavailable")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ManualResetSummaryView: View {
    let summary: ManualResetSummary?

    private var availableCredits: [ManualResetCredit] {
        summary?.credits?.filter { $0.status == "available" } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Manual resets")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            if let summary {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(summary.availableCount)")
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                    Text("available")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                ForEach(Array(availableCredits.enumerated()), id: \.offset) { index, credit in
                    if let expiry = credit.expiresAt {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("Reset \(index + 1) · \(expiry > context.date ? dueInterval(expiry, now: context.date) : "expired")")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(expiry > context.date ? Palette.ink : Palette.muted)
                                    Text("· \(compactDueDate(expiry))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.muted)
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Reset \(index + 1) · \(expiry > context.date ? dueInterval(expiry, now: context.date) : "expired")")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(expiry > context.date ? Palette.ink : Palette.muted)
                                    Text(compactDueDate(expiry))
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.muted)
                                }
                            }
                            .lineLimit(1)
                            .help("Reset \(index + 1) expires \(expiry.formatted(date: .complete, time: .shortened)). Status reported by provider: \(credit.status).")
                        }
                    } else {
                        Text("Reset \(index + 1) · No expiry")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                }
                if summary.credits == nil {
                    Text("Expiry details unavailable")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                } else if summary.availableCount > availableCredits.count {
                    Text("More expiry details unavailable")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                }
            } else {
                Text("Unavailable")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ResetDetailsSheet: View {
    let account: SavedAccount
    let provider: SubscriptionProvider
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Manual resets")
                .font(.system(size: 21, weight: .semibold))
            Text("\(provider.displayName) · \(account.email)")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            if let summary = account.usage?.manualResets {
                Text("\(summary.availableCount) available")
                    .font(.system(size: 16, weight: .semibold))
                if let credits = summary.credits {
                    if credits.isEmpty {
                        Text("The provider returned no individual reset details.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(credit.title ?? "Reset \(index + 1)")
                                                .font(.system(size: 13, weight: .semibold))
                                            Spacer()
                                            Text(credit.status.capitalized)
                                                .font(.system(size: 11))
                                                .foregroundStyle(Palette.muted)
                                        }
                                        if let detail = credit.detail, !detail.isEmpty {
                                            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                        }
                                        Text("Granted \(credit.grantedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                        Text(credit.expiresAt.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No expiry")
                                            .font(.system(size: 12, weight: .medium))
                                        Divider()
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxHeight: 360)
                    }
                } else {
                    Text("The available count was reported without individual expiry details.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            } else {
                Text("Manual reset information is unavailable.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            if let usage = account.usage {
                Text("Checked \(usage.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 490)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .onExitCommand { dismiss() }
    }
}

private func usagePercentage(_ window: UsageWindow) -> String {
    window.utilization.formatted(.number.precision(.fractionLength(0...1)))
}

private func remainingPercentage(_ window: UsageWindow) -> String {
    (100 * (1 - window.fraction)).formatted(.number.precision(.fractionLength(0...1)))
}

private struct PlanBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.muted)
            .fixedSize()
    }
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
                    Image(systemName: "terminal").font(.system(size: 21)).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Current \(model.provider.cliName) login")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.muted)
                        Text(current.email).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                    }
                    Spacer()
                    PlanBadge(label: model.provider.planLabel(current.plan))
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
                .foregroundStyle(Palette.accent)
                .frame(width: 19, height: 19)
                .background(Palette.accentWash, in: Circle())
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RenewalDateSheet: View {
    @ObservedObject var model: AppModel
    let account: SavedAccount
    @Environment(\.dismiss) private var dismiss
    @State private var renewalDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Subscription renewal")
                .font(.system(size: 21, weight: .semibold))
            Text(account.email)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Text("Enter the date from your billing settings. This date is saved locally and is not verified with \(model.provider.displayName).")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("Renewal date", selection: $renewalDate, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .controlSize(.large)
                .accessibilityLabel("Subscription renewal date and time")
                .disabled(model.isBusy || model.isRefreshing)
            if let error = model.error {
                MessageStrip(symbol: "exclamationmark.circle", text: error, isError: true)
            }
            HStack {
                if account.renewalAt != nil {
                    Button("Clear date", role: .destructive) { save(nil) }
                        .disabled(model.isBusy || model.isRefreshing)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isBusy)
                Button("Save date") { save(renewalDate) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.ink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.isRefreshing)
            }
        }
        .padding(26)
        .frame(width: 450)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .onAppear { renewalDate = account.renewalAt ?? Date() }
        .interactiveDismissDisabled(model.isBusy)
    }

    private func save(_ date: Date?) {
        Task {
            await model.setRenewal(account: account, date: date)
            if model.error == nil { dismiss() }
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
    @ObservedObject var model: DashboardModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ProviderMenuGroup(model: model.claude, isBlocked: model.isBlocked)
        Divider()
        ProviderMenuGroup(model: model.chatGPT, isBlocked: model.isBlocked)
        Divider()
        Button("Open Switchboard") {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o", modifiers: .command)
        Button("Refresh all usage") { Task { await model.refresh() } }
            .disabled(model.isBlocked)
        Divider()
        Button("Quit Switchboard") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
    }
}

private struct ProviderMenuGroup: View {
    @ObservedObject var model: AppModel
    let isBlocked: Bool

    var body: some View {
        Text("\(model.provider.displayName) · \(model.provider.cliName)")
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
            .disabled(isBlocked || model.activeID == account.id)
        }
    }
}

private struct SwitchboardMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29)
                .fill(Palette.ink)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: size * 0.40, weight: .medium))
                .foregroundStyle(Palette.canvas)
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
        .background(isError ? Palette.errorWash : Palette.faint.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
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

private struct AccountRowButtonStyle: ButtonStyle {
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

private func compactDueDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMdjm")
    return formatter.string(from: date)
}

private func dueInterval(_ date: Date, now: Date = Date()) -> String {
    let seconds = date.timeIntervalSince(now)
    let minutes = max(1, Int(ceil(abs(seconds) / 60)))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    let value: String
    if days > 0 { value = "\(days)d \(hours)h" }
    else if hours > 0 { value = "\(hours)h \(minutes % 60)m" }
    else { value = "\(minutes)m" }
    return seconds >= 0 ? "in \(value)" : "\(value) ago"
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
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
    if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now),
       Calendar.current.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow at \(time)" }
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE d MMM jm")
    return formatter.string(from: date)
}
