# Architecture and compatibility

## How it works

Saved login snapshots use separate Mac Keychain services: `com.quasa0.switchboard.accounts` for Claude and `com.quasa0.switchboard.codex-accounts` for ChatGPT. Account names, emails, and usage snapshots are stored separately under `~/Library/Application Support/Switchboard`, with owner-only permissions. Those metadata files contain no tokens. Switchboard does not print tokens to logs.

Claude billing connections use one persistent WebKit website data store per saved account. Cookies remain in WebKit; the app does not copy cookies from your browser. Removing a saved Claude account also deletes its billing web session. The billing reader performs first-party GET requests only and retains an allowlist of dates and status fields, never payment methods, invoices, or authentication fields.

The Codex subscription claim names follow [CLIProxyAPI's ID-token parser](https://github.com/router-for-me/CLIProxyAPI/blob/main/internal/auth/codex/jwt_parser.go). Claude billing uses the first-party web app's `/api/organizations/{organizationUUID}/subscription_details` contract. These are internal provider formats and can change; missing metadata remains unavailable instead of being guessed.

### Claude Code

- Adding an account uses a separate CLI configuration and Keychain namespace. It leaves the current Claude Code login active. Switchboard owns and stops the sign-in subprocess.
- Switching first saves the latest current credentials. It changes `claudeAiOauth` in Claude’s credential entry and `oauthAccount` in Claude’s config. It preserves unrelated credentials, preferences, projects, and MCP settings. It clears account-specific caches and Anthropic device/gateway credentials. Organizations that require trusted-device enrollment may need to enroll again.
- Claude’s credential entry is read and written through Apple’s `security` helper, as Claude Code expects. Credential JSON uses compact ASCII encoding. Writes send data through stdin and reject entries that exceed the helper’s command limit before changing anything. Saved Switchboard snapshots use the native Keychain API.
- A switch saves the previous login and an interruption journal in Keychain. Failed config writes roll back the credential write. The next launch completes or rolls back an interrupted switch when its recorded credentials still match. It refuses to overwrite a login changed by another process during recovery.
- Usage comes from the **unmodified Claude Code CLI**, through its experimental `get_usage` control request. No model prompt is sent. Claude Code performs its own token refresh. Each inactive account uses a separate configuration for this check.

### ChatGPT through Codex

- Switchboard supports Codex’s **file credential store**. The active subscription login is in `auth.json` under `CODEX_HOME`, normally `~/.codex/auth.json`. Settings that select `keyring`, `auto`, or `ephemeral`, unrecognized storage settings, and enforced login/workspace restrictions are rejected without changing the login or configuration. Switchboard does not probe Codex’s Keychain entry. See [Codex authentication](https://learn.chatgpt.com/docs/auth).
- Adding an account runs the official `codex login` command in a new, empty, isolated `CODEX_HOME`. The existing login is never copied into that sign-in folder. This keeps the old login out of the replacement/revocation path. The browser handles authentication; **Save new login** collects the completed login into the ChatGPT vault.
- Switching saves the current credentials, checks that the live file has not changed, and atomically replaces only `auth.json` with owner-only permissions. The complete selected payload is preserved. Codex configuration and conversations are unchanged. Close existing Codex sessions before switching to avoid concurrent token refreshes.
- Usage comes from the official Codex App Server over its local stdio connection: `account/read` followed by `account/rateLimits/read`. It starts no conversation and sends no model prompt. If the usage endpoint returns HTTP 401, Switchboard asks Codex to refresh its token and retries once. Other errors show a sanitized HTTP or RPC status without raw server responses. Refreshed credentials are retained even if usage fails. See the [App Server account and rate-limit API](https://learn.chatgpt.com/docs/app-server).
- The active account’s usage check uses its live auth file. Inactive accounts use private profile files. Refreshed credentials are collected into the saved vault, including when the subsequent usage read fails. These working `auth.json` files contain tokens and have owner-only permissions; the saved account metadata does not.

## Limits and freshness

Claude Code 2.1.280 may answer usage from a cache younger than 60 seconds, or use a matching-account cache up to one hour old when a network request fails. Its control response omits provenance. **Checked** means the CLI was queried; it does not guarantee a new server response.

Codex returns named quota windows with their duration, usage percentage, and next reset timestamp. Five-hour and weekly windows appear in their matching columns. Other durations and named limits retain their reported meaning rather than being relabeled as weekly limits. **These are Codex allowances attached to a ChatGPT subscription, not chatgpt.com message quotas.** Switchboard does not change browser sessions or the ChatGPT app’s account.

Codex manual resets show the provider's available count and individual credit expiry dates. A missing response stays unavailable; it is not displayed as zero. The count remains authoritative even if the detail list is incomplete. The app only reads this data; it does not redeem resets. Claude's inspected usage interface does not expose equivalent manual-reset details.

Unavailable usage remains unavailable, never a fabricated zero. Failed checks retain the last snapshot with a visible warning. If a later successful response adds a previously absent quota window, its meter returns automatically.

Reset countdowns and checked ages update locally once a minute. This display update does not query either CLI or Keychain. When a saved reset time passes, the app asks you to refresh; it does not assume that usage has returned to zero.

Existing Claude Code processes keep authentication in memory and can refresh their tokens. Quit them before switching. Switchboard does not terminate your sessions or migrate an in-flight conversation. Run `claude --continue` after restarting if you want to continue the latest conversation in the same project.

Embedded clients also need a fresh Claude session after switching. Restart the client's Claude session so it reads the selected login. Restarting a session does not repair invalid credentials.

Claude logins use Keychain first, matching Claude Code. If no Keychain entry exists, Switchboard supports an existing `.credentials.json` fallback. A leftover file does not block a Keychain login. Switches preserve the selected store and unrelated credentials; file writes are atomic and owner-only. Linked, malformed, oversized, and unreadable fallback files are rejected. A locked or inaccessible Keychain is an error, not evidence that its entry is absent. Switchboard does not create new plaintext credential stores. Saved account snapshots still require Keychain. Custom `CLAUDE_CONFIG_DIR`, `CLAUDE_SECURESTORAGE_CONFIG_DIR`, and `CODEX_HOME` values are supported when passed to the app process; a Finder launch uses the default configuration. Environment-based API keys and provider settings in your terminal can override subscription authentication independently of Switchboard.

Claude’s local credential format and `get_usage` protocol are not stable public APIs. The implementation was checked against installed Claude Code **2.1.280**. Recheck these interfaces after major CLI changes. No proxy, model routing, automatic account rotation, public service, or shared credential server is involved.

## References

- [Claude Code authentication and credential storage](https://code.claude.com/docs/en/authentication#credential-management)
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Codex authentication and credential storage](https://learn.chatgpt.com/docs/auth)
- [Codex App Server account and rate-limit API](https://learn.chatgpt.com/docs/app-server)
- [Vercel design guidance](https://vercel.com/design.md)
- [Theo’s original dashboard post](https://x.com/theo/status/2095969972841525526) and [fork comment](https://x.com/theo/status/2095975684967673991)

Claude storage, cache invalidation, namespace hashing, and usage-protocol details were also verified by inspecting the installed Claude Code executable. Synthetic tests use isolated credential namespaces or temporary file stores. Live usage checks use the accounts that the user has explicitly saved.
