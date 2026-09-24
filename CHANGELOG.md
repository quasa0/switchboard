# Changelog

## 0.5.2

- Support existing Claude file credential stores, with Keychain precedence and the correct secure-storage directory. Stale fallback files no longer block Keychain logins.
- Preserve unrelated credentials, owner-only file permissions, rollback, and interrupted-switch recovery for file-based logins. Refuse detected concurrent login changes.
- Retry Codex usage once after an HTTP 401 through the CLI’s token refresh. Preserve rotated credentials on failed usage reads.
- Show sanitized Codex HTTP/RPC errors instead of suggesting every failure is an expired login.

## 0.5.1

First downloadable public release.

- Universal macOS app for Apple silicon and Intel, with DMG, ZIP, and SHA-256 checksums.
- Public landing page, agent installation guide, and machine-readable release metadata.
- Focused setup documentation, contributor guide, security policy, and automated checks.
- Explicit ad hoc signing now stays ad hoc instead of selecting a personal development certificate.

The account-switching and dashboard behavior is unchanged from 0.5.0. This release is not Apple-notarized.

## 0.5.0

- Automatic subscription period metadata from saved Codex ID-token claims.
- Optional per-account Claude billing connections, with account and organization verification.
- Distinct charge dates, period ends, and gift coverage; manual date overrides.

## Earlier source releases

- Combined Claude Code and Codex dashboard with separate active accounts.
- Saved login switching, rollback, and interrupted-switch recovery.
- Remaining quotas, tiers, reset countdowns, exact local dates, and Codex manual reset credits.
