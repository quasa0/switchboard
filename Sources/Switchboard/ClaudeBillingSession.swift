import AppKit
import SwiftUI
import WebKit
import SwitchboardCore

/// A separate first-party web session for each saved account. Cookies stay inside WebKit.
@MainActor final class ClaudeBillingSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var isChecking = false
    @Published private(set) var status = "Sign in to Claude with this account, then choose Read billing."
    let account: SavedAccount
    let webView: WKWebView?
    private var loadCompletion: CheckedContinuation<Void, Error>?
    private var loadTimeout: Task<Void, Never>?
    private var stopped = false

    static func isConnected(_ id: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: "claudeBillingConnected.\(id.uuidString)")
    }
    static func setConnected(_ connected: Bool, for id: UUID) {
        UserDefaults.standard.set(connected, forKey: "claudeBillingConnected.\(id.uuidString)")
    }

    static func forget(_ id: UUID) async throws {
        setConnected(false, for: id)
        try await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    init(account: SavedAccount, enabled: Bool = true) {
        self.account = account
        if enabled {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: account.id)
            webView = WKWebView(frame: .zero, configuration: configuration)
        } else { webView = nil }
        super.init()
        webView?.navigationDelegate = self
        webView?.uiDelegate = self
    }

    func open() {
        guard !stopped, let webView, webView.url == nil else { return }
        webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/billing")!))
    }

    /// Existing connected sessions refresh without presenting another login or touching CLI credentials.
    func refresh() async throws -> ClaudeBillingSnapshot {
        guard !stopped, webView != nil else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loadCompletion = continuation
                loadTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    self?.finishLoad(.failure(SwitchboardError.message("Claude billing did not load. Connect billing again from account options.")))
                }
                open()
            }
            try Task.checkCancellation()
            return try await read()
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func read() async throws -> ClaudeBillingSnapshot {
        guard !stopped, !isChecking, let webView,
              webView.url?.scheme == "https", webView.url?.host == "claude.ai" else {
            throw SwitchboardError.message("Finish signing in to Claude, then choose Read billing.")
        }
        isChecking = true
        defer { isChecking = false }
        status = "Checking the account and its billing dates…"
        do {
            // Fixed first-party GETs. No browser cookies or access tokens cross the WebKit bridge.
            let result = try await webView.callAsyncJavaScript(Self.billingScript,
                arguments: ["expectedAccount": account.accountUUID, "expectedOrganization": account.organizationUUID],
                in: nil, contentWorld: .defaultClient)
            guard !stopped, !Task.isCancelled else { throw CancellationError() }
            guard let raw = result as? String, raw.utf8.count <= 32_768,
                  let data = raw.data(using: .utf8),
                  let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SwitchboardError.message("Claude returned an unreadable billing response.")
            }
            if let failure = envelope["error"] as? String {
                switch failure {
                case "wrongAccount": throw SwitchboardError.message("This browser is signed in to another Claude account. Sign in as \(account.email).")
                case "signedOut": throw SwitchboardError.message("Sign in to Claude as \(account.email), then choose Read billing.")
                default: throw SwitchboardError.message("Claude billing is unavailable. Your saved billing dates were kept.")
                }
            }
            let snapshot = try ClaudeBillingSnapshot.parseBridge(data,
                expectedAccountUUID: account.accountUUID, expectedOrganizationUUID: account.organizationUUID)
            status = "Billing dates connected."
            return snapshot
        } catch {
            // WebKit errors can contain page details; publish only our fixed, account-scoped errors.
            let safe = error as? SwitchboardError ?? SwitchboardError.message("Couldn’t read Claude billing. Finish signing in, then try again.")
            status = safe.localizedDescription
            if Task.isCancelled || stopped { throw CancellationError() }
            throw safe
        }
    }

    func stop() {
        stopped = true
        webView?.stopLoading()
        finishLoad(.failure(CancellationError()))
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        loadTimeout?.cancel(); loadTimeout = nil
        let continuation = loadCompletion; loadCompletion = nil
        continuation?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(SwitchboardError.message("Claude billing could not load. Your saved dates were kept.")))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(SwitchboardError.message("Claude billing could not load. Your saved dates were kept.")))
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Keep first-party sign-in popups in the same isolated session.
        guard let url = navigationAction.request.url, url.scheme == "https" else { return nil }
        webView.load(navigationAction.request)
        return nil
    }

    private static let billingScript = #"""
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    const get = async path => {
      const r = await fetch(path, {credentials: 'include', signal: controller.signal,
        cache: 'no-store', redirect: 'error', headers: {'Accept':'application/json'}});
      if (!r.ok) throw new Error(r.status === 401 || r.status === 403 ? 'signedOut' : 'unavailable');
      return await r.json();
    };
    try {
      const bootstrap = await get('/api/bootstrap?statsig_hashing_algorithm=djb2&growthbook_format=sdk&include_system_prompts=false');
      const account = bootstrap.account;
      const memberships = account?.memberships;
      if (!account?.uuid) return JSON.stringify({error:'signedOut'});
      if (account.uuid !== expectedAccount || !Array.isArray(memberships) ||
          !memberships.some(m => m.organization?.uuid === expectedOrganization))
        return JSON.stringify({error:'wrongAccount'});
      const details = await get('/api/organizations/' + encodeURIComponent(expectedOrganization) + '/subscription_details');
      const fields = ['next_charge_at','next_charge_date','plan_ending_at','plan_ending_before',
        'status','payment_paused_until','gift_details'];
      const selected = Object.fromEntries(fields.filter(k => k in details).map(k => [k,details[k]]));
      if (selected.gift_details) selected.gift_details = {paid_through: selected.gift_details.paid_through};
      return JSON.stringify({accountUUID:account.uuid,organizationUUID:expectedOrganization,details:selected});
    } catch(e) { return JSON.stringify({error:e.message === 'signedOut' ? 'signedOut':'unavailable'}); }
    finally { clearTimeout(timeout); }
    """#
}

private struct ClaudeBillingWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ClaudeBillingSheet: View {
    let account: SavedAccount
    @ObservedObject var model: AppModel
    @StateObject private var session: ClaudeBillingSession
    @Environment(\.dismiss) private var dismiss
    @State private var readTask: Task<Void, Never>?
    @State private var saving = false

    init(account: SavedAccount, model: AppModel) {
        self.account = account; self.model = model
        _session = StateObject(wrappedValue: ClaudeBillingSession(account: account, enabled: !model.isDemo))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Claude billing").font(.system(size: 20, weight: .semibold))
            Text(account.email).font(.system(size: 13, weight: .medium))
            Text("Sign in once to read billing dates automatically. This web session is separate from Claude Code and stays on this Mac.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let webView = session.webView {
                ClaudeBillingWebView(webView: webView)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Billing sign-in is disabled in preview mode.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 14) {
                Text(session.status).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 8)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Read billing") {
                    readTask = Task {
                        saving = true
                        defer { saving = false }
                        do {
                            let billing = try await session.read()
                            try Task.checkCancellation()
                            if await model.saveClaudeBilling(account: account, billing: billing) { dismiss() }
                        } catch { /* The session exposes a sanitized, actionable message. */ }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(saving || session.isChecking || model.isDemo)
            }
        }
        .padding(20).frame(width: 840, height: 640)
        .onAppear { session.open() }
        .onDisappear { readTask?.cancel(); session.stop() }
    }
}
