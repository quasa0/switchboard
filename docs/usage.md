# Using Switchboard

## Use it

1. Open **Switchboard** from `~/Applications`.
2. Compare the **Claude** and **ChatGPT** sections. Each marks its active account.
3. Click **Add account**, choose a provider, then **Save current login** to save that CLI's current subscription login. Give it a name such as Personal. If no login is available, choose **Sign in to Claude Code** or **Sign in to Codex**.
4. To add another account, click **Add account → Sign in another account**. Complete the official browser sign-in, return to Switchboard, and click **Save new login**.
5. Quit open sessions for that provider. Click the saved account you want, then restart Claude Code or Codex. The other provider’s selected account stays unchanged.

For Claude, if your browser returns a login code, expand **Browser gave you a code?** and paste it. Codex returns through its local browser callback; it has no code-paste field in Switchboard. Finish or cancel any other Codex sign-in before starting one here.

Browser sessions can automatically choose the account already signed in. Check the saved email before switching. macOS can ask for Keychain access when Switchboard saves or reads an account.

Account tiers include their reported multiplier: Claude Pro · 1× or Max · 5×/20×; ChatGPT Plus · 1× or Pro · 5×/20×. Codex calls the smaller Pro tier `prolite`. Unknown plans keep their name without a guessed multiplier. These multipliers are provider-specific, not equivalent allowances across providers.

ChatGPT subscription periods are read automatically from the saved Codex ID token during the normal account refresh. **Period ends** is the provider-reported boundary; the token does not confirm that the plan will renew. The original observation time stays in the tooltip. An elapsed period is not rolled forward and does not mean that the CLI login expired.

For each Claude account, choose **… → Connect billing**, sign into that account in the embedded Claude page, then click **Read billing**. This one-time web connection reads billing dates that the inspected CLI interface does not expose. Later Refresh actions update the dates through the same isolated web session. Gift subscriptions show **Gift covers through**; date-only coverage never gets an invented time. The app verifies both account and organization before saving metadata. A failed or expired web session preserves the last date and shows a billing warning.

**… → Set renewal date** remains an optional manual override. Clearing it restores the automatic date. Billing dates are never inferred from token expiry, subscription creation, or quota resets. Editing an override or account name changes display metadata without reading credentials.

You can also sign in manually with `claude auth login --claudeai`, then save that current login. **Save each account before signing into the next. Do not run `claude auth logout` between them:** current Claude Code revokes refresh tokens on logout. For additional ChatGPT accounts, use Switchboard’s isolated sign-in so Codex does not replace or revoke the existing local login. Removing an account from Switchboard deletes its saved copy and leaves the active CLI login intact.

## Usage errors

- **Claude credential files:** Switchboard supports both Keychain and an existing `.credentials.json` fallback. Keep the file intact. If Keychain is locked, unlock it before refreshing; Switchboard still saves account snapshots there.
- **Codex HTTP 401:** Switchboard tries one token refresh automatically. If the error remains, sign in to that account again.
- **Codex HTTP 403:** Check that the selected workspace allows Codex. A forbidden response does not prove the login expired.
- **Codex HTTP 429 or 5xx:** Wait before refreshing. These are service errors, not quota percentages.
- **Codex RPC errors:** The message identifies the failed account method and error code. Update the CLI when requested. For a bug report, include the error and CLI versions (`claude --version`, `codex --version`), never credential files or tokens.
