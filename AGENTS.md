# Working on Switchboard

Read `README.md` and the relevant guide in `docs/` before changing behavior.

- Never read, print, upload, switch, or delete real user credentials for testing. Use injected stores and synthetic accounts. Do not invoke the real Keychain smoke script unless the task explicitly requires it.
- Use `--demo`, `--render-preview`, or `scripts/ui-smoke.sh` for visuals. Never publish screenshots of real accounts.
- Preserve unrelated provider configuration. Test interrupted writes, rollback, and concurrent login changes when touching switching.
- Keep missing, failed, stale, and zero usage distinct. Never invent quota, renewal, or billing data.
- Run `swift test`, `node scripts/test-billing-reader.mjs`, and `python3 scripts/check-site.py` for relevant changes. See `CONTRIBUTING.md` for native UI checks.
- Keep tokens, personal paths, account identifiers, and private operational notes out of Git. `worklog.md`, `artifacts/`, and build output are intentionally ignored. Maintain the local worklog when making material changes.
- The public site is static. Preserve source attribution and `site/fonts/OFL.txt`. Agent installation instructions are `site/install.md`; keep them consistent with packaged artifacts and `site/release.json`.
- Stop any dev server or preview process you start before finishing. Do not overwrite a running installed app.
- Publishing a release, changing DNS, or deploying needs authorization from the task owner. A local build is not a release.
