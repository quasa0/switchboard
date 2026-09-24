# Switchboard

A native macOS app for saving and switching **Claude subscriptions in Claude Code** and **ChatGPT subscriptions in Codex**. All accounts appear together in a compact dashboard. Each provider keeps its own active login; click another account's row to switch it.

Claude rows include weekly Fable, five-hour, weekly, and other reported model limits. ChatGPT rows show the Codex allowances attached to that subscription. Bars and percentages show **remaining allowance**. Reset countdowns and exact local dates stay visible beside each account's tier. A successful response that omits a window hides its meter; this does not establish that the plan has no such limit.

## Use it

1. Open **Switchboard** from `~/Applications`.
2. Compare the **Claude** and **ChatGPT** sections. Each marks its active account.
3. Click **Add account**, choose a provider, then **Save current login** to save that CLI's current subscription login. Give it a name such as Personal. If no login is available, choose **Sign in to Claude Code** or **Sign in to Codex**.
4. To add another account, click **Add account → Sign in another account**. Complete the official browser sign-in, return to Switchboard, and click **Save new login**.
5. Quit open sessions for that provider. Click the saved account you want, then restart Claude Code or Codex. The other provider’s selected account stays unchanged.

For Claude, if your browser returns a login code, expand **Browser gave you a code?** and paste it. Codex returns through its local browser callback; it has no code-paste field in Switchboard. Finish or cancel any other Codex sign-in before starting one here.

Browser sessions can automatically choose the account already signed in. Check the saved email before switching. macOS can ask for Keychain access when Switchboard saves or reads an account.

Account tiers include their reported multiplier: Claude Pro · 1× or Max · 5×/20×; ChatGPT Plus · 1× or Pro · 5×/20×. Codex calls the smaller Pro tier `prolite`. Unknown plans keep their name without a guessed multiplier. These multipliers are provider-specific, not equivalent allowances across providers.

Use an account's **… → Set renewal date** to enter its billing renewal date and time. The inspected CLI interfaces do not provide a verified billing date. These dates are explicitly manual; they are never inferred from token expiry or quota resets and never advance automatically. Editing a date or account name changes display metadata without reading credentials.

You can also sign in manually with `claude auth login --claudeai`, then save that current login. **Save each account before signing into the next. Do not run `claude auth logout` between them:** current Claude Code revokes refresh tokens on logout. For additional ChatGPT accounts, use Switchboard’s isolated sign-in so Codex does not replace or revoke the existing local login. Removing an account from Switchboard deletes its saved copy and leaves the active CLI login intact.

## How it works

Saved login snapshots use separate Mac Keychain services: `com.quasa0.switchboard.accounts` for Claude and `com.quasa0.switchboard.codex-accounts` for ChatGPT. Account names, emails, and usage snapshots are stored separately under `~/Library/Application Support/Switchboard`, with owner-only permissions. Those metadata files contain no tokens. Switchboard does not print tokens to logs.

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
- Usage comes from the official Codex App Server over its local stdio connection: `account/read` followed by `account/rateLimits/read`. It starts no conversation and sends no model prompt. Codex handles token refresh. See the [App Server account and rate-limit API](https://learn.chatgpt.com/docs/app-server).
- The active account’s usage check uses its live auth file. Inactive accounts use private profile files. Refreshed credentials are collected into the saved vault, including when the subsequent usage read fails. These working `auth.json` files contain tokens and have owner-only permissions; the saved account metadata does not.

## Limits and freshness

Claude Code 2.1.280 may answer usage from a cache younger than 60 seconds, or use a matching-account cache up to one hour old when a network request fails. Its control response omits provenance. **Checked** means the CLI was queried; it does not guarantee a new server response.

Codex returns named quota windows with their duration, usage percentage, and next reset timestamp. Five-hour and weekly windows appear in their matching columns. Other durations and named limits retain their reported meaning rather than being relabeled as weekly limits. **These are Codex allowances attached to a ChatGPT subscription, not chatgpt.com message quotas.** Switchboard does not change browser sessions or the ChatGPT app’s account.

Codex manual resets show the provider's available count and individual credit expiry dates. A missing response stays unavailable; it is not displayed as zero. The count remains authoritative even if the detail list is incomplete. The app only reads this data; it does not redeem resets. Claude's inspected usage interface does not expose equivalent manual-reset details.

Unavailable usage remains unavailable, never a fabricated zero. Failed checks retain the last snapshot with a visible warning. If a later successful response adds a previously absent quota window, its meter returns automatically.

Reset countdowns and checked ages update locally once a minute. This display update does not query either CLI or Keychain. When a saved reset time passes, the app asks you to refresh; it does not assume that usage has returned to zero.

Existing Claude Code processes keep authentication in memory and can refresh their tokens. Quit them before switching. Switchboard does not terminate your sessions or migrate an in-flight conversation. Run `claude --continue` after restarting if you want to continue the latest conversation in the same project.

Embedded clients also need a fresh Claude session after switching. In T3 Code, right-click the affected thread and select **Settle thread**, then **Un-settle thread**. The next message resumes its saved conversation with a fresh Claude process. This restarts a session; it does not repair invalid credentials.

Claude support requires macOS Keychain logins. If Claude has a `.credentials.json` fallback in the selected configuration, the app stops rather than guessing which store to modify. Custom `CLAUDE_CONFIG_DIR`, `CLAUDE_SECURESTORAGE_CONFIG_DIR`, and `CODEX_HOME` values are supported when passed to the app process; a Finder launch uses the default configuration. Environment-based API keys and provider settings in your terminal can override subscription authentication independently of Switchboard.

Claude’s local credential format and `get_usage` protocol are not stable public APIs. The implementation was checked against installed Claude Code **2.1.280**. Recheck these interfaces after major CLI changes. No proxy, model routing, automatic account rotation, public service, or shared credential server is involved.

## Build and verify

Requires macOS 14+, Swift 5.10+ / Xcode Command Line Tools, and the CLI for each provider you use: Claude Code or Codex. No package dependencies.

- `swift test` runs synthetic account, persistence, protocol, and process-cleanup tests. It does not read real credentials.
- `./scripts/ui-smoke.sh "$HOME/Applications/Switchboard.app"` checks in-memory UI actions and independent active accounts, renders the combined dashboard in light/dark and exceptional states, and verifies normal quit cleanup. It never initializes either account engine or accesses credentials. Use this for visual work.
- `./scripts/install.sh` builds, signs with an available Apple Development identity (or ad hoc), and installs `~/Applications/Switchboard.app`. Quit the app before rebuilding it.
- `./scripts/smoke.sh "$HOME/Applications/Switchboard.app"` runs the Claude credential smoke with synthetic accounts. It exercises **real Keychain** writes in unique temporary namespaces, verifies switching and token preservation, removes test secrets, and renders light/dark/empty UI previews. It never reads your Claude login. This is separate from the credential-free UI smoke and can cause Keychain permission prompts.
- `.build/debug/Switchboard --demo` opens an interactive preview with sample accounts and no credential access. Quit it with ⌘Q.

The app uses no background daemon or login item. Codex browser sign-in temporarily uses its official localhost callback on port 1455; usage checks use stdio. Closing the window keeps the menu bar available. **Quit Switchboard** or ⌘Q stops the app and its owned subprocesses.

## References

- [Claude Code authentication and credential storage](https://code.claude.com/docs/en/authentication#credential-management)
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Codex authentication and credential storage](https://learn.chatgpt.com/docs/auth)
- [Codex App Server account and rate-limit API](https://learn.chatgpt.com/docs/app-server)
- [Vercel design guidance](https://vercel.com/design.md)
- [Theo’s original dashboard post](https://x.com/theo/status/2095969972841525526) and [fork comment](https://x.com/theo/status/2095975684967673991)

Claude storage, cache invalidation, namespace hashing, and usage-protocol details were also verified by inspecting the installed Claude Code executable. Synthetic tests use isolated credential namespaces or temporary file stores. Live usage checks use the accounts that the user has explicitly saved.
