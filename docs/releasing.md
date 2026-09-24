# Release procedure

## Build locally on macOS

1. Update `scripts/version.sh`, `CHANGELOG.md`, and versioned links in `README.md`, `site/index.html`, and `site/install.md`.
2. Run `swift test` and `node scripts/test-billing-reader.mjs`.
3. Run `./scripts/package-release.sh`. This builds both Mac architectures, explicitly signs ad hoc, verifies the signature, runs the credential-free UI smoke, and packages DMG and ZIP files. It does not install the app or publish anything.
4. Inspect `dist/releases/<version>/`. `release-manifest.py` generates checksums and copies `release.json` into `site/` from the actual artifact bytes. The manifest truthfully marks these releases as not notarized. Do not use this script for notarized releases until its signing, stapling, and manifest handling are updated together.
5. Extract the ZIP to a temporary directory. Verify the extracted app and run `scripts/ui-smoke.sh` against it. Mount the DMG read-only, check its app and Applications link, then detach it. Check both architectures' minimum OS, bundle metadata, and absence of private paths or development certificates.

Never publish a personal Apple Development certificate in a public package. Developer ID signing and notarization are separate distribution work; do not label an ad hoc build as notarized. Intel is cross-built; record separately whether an Intel Mac was used for runtime verification.

## Publish

After authorization, commit the source and public assets. Tag that exact commit `v<version>`. Create a GitHub release with the DMG, ZIP, `SHA256SUMS.txt`, and `release.json`. Do not overwrite assets for an existing release: publish a new version when bytes change.

Verify the remote release metadata, download both artifacts, and compare their hashes with the manifest. At least one extracted release download must pass the UI smoke on a Mac. Keep credentials and local artifacts outside Git.

## Website

`site/` is a standalone static Vercel project. Deploy **only that directory**. It contains no auth, backend API, analytics, or package dependencies. Never deploy the repository root or local `artifacts/`.

Run `python3 scripts/check-site.py` before deployment. Link the directory to the intended Vercel project, then run `./scripts/deploy-site.sh`. That script deploys and automatically runs `scripts/smoke-site.py` against the resulting production deployment and canonical domain. Configure `switchboard.quasa0.com` as a production domain before using it.

The smoke fetches the page, CSS, JavaScript, font, screenshot, agent docs, manifest, and every published download. It verifies nonempty assets and SHA-256 checksums. There is no authenticated site API or realtime connection to test. Also inspect desktop/mobile and light/dark browser views, copy-prompt behavior, navigation, and downloads. A health response alone is not a successful release.

Keep deployment credentials out of Git. `.vercel/` is ignored. The website's Geist font uses SIL OFL; keep `site/fonts/OFL.txt` published.
