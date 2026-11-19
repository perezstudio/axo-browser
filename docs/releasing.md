# Releasing Axo for the Mac

Axo ships outside the Mac App Store, as a DMG signed with a Developer ID and notarized by Apple (`docs/PLAN.md`, "Distribution"). `scripts/package-release.sh` builds one. Signing and notarizing use the owner's Developer ID and Apple account, which stay in the owner's keychain and never go in the repo (CLAUDE.md, hard rule 8). Updates through Sparkle are #180.

## One-time setup

1. **A Developer ID Application certificate** for the team in the Axo target (`DEVELOPMENT_TEAM`), in the login keychain. Xcode › Settings › Accounts › Manage Certificates can make one.
2. **The App ID's capabilities.** Release builds sign with `Axo/Axo-Release.entitlements` (iCloud's CloudKit container `iCloud.com.perezstudio.Axo` and push notifications), so the App ID `com.perezstudio.Axo` needs both. The export lets Xcode make the Developer ID provisioning profile (`-allowProvisioningUpdates`). Profiles are gitignored.
3. **A notarytool keychain profile.** Use an app-specific password from account.apple.com or an App Store Connect API key:

   ```bash
   xcrun notarytool store-credentials axo-notary
   ```

   It prompts for the Apple ID, team ID, and password and keeps them in the keychain. To use another name, set `AXO_NOTARY_PROFILE`.
4. **The engine**, built from a clean, committed checkout of axo-chromium next to Axo (or at `AXO_CHROMIUM_OUT`), matching this Axo's engine API header.

## Making a release

```bash
scripts/package-release.sh
```

It refuses if Axo or the engine checkout has uncommitted changes, if the engine build is older than the fork's last change, or if the API headers differ. Then it:

1. Archives Release. The embed phase copies the engine in and signs it as Chrome does, with secure timestamps.
2. Exports the archive with the Developer ID.
3. Checks the result with `scripts/verify-engine-signing.sh --release`: every helper has Hardened Runtime, the renderer and GPU helpers have Chrome's JIT entitlement, everything is signed by the team with a timestamp, and the app has no `get-task-allow`.
4. Notarizes and staples `Axo.app`, so a copied app opens offline. Then it builds the DMG (Axo and an Applications link), signs it, and notarizes and staples that too.
5. Writes the manifest beside the DMG. It records Axo's commit and the engine build the DMG carries: the fork's commit, the Chromium version, and the engine binary's SHA-256.

Output goes in `build/release/` (gitignored, or `AXO_RELEASE_DIR`): `Axo-<version>-<build>.dmg`, its `.txt` manifest, and the archive and export logs. Set the version in the Axo target's `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` first.

To try a DMG on this Mac without notarizing, use `--skip-notarize`. With `--allow-dirty` it also packages uncommitted changes. The manifest marks both; never publish those DMGs.

## Checking a release

Notarization can't be tested automatically (it needs the owner's account), so each release is checked by hand on a Mac that has never run Axo (a fresh macOS virtual machine works):

1. Download the DMG through a browser, so it's quarantined, and open it. Gatekeeper should open it without warnings.
2. Copy Axo to Applications and open it, once with the network off: the stapled ticket means no online check is needed.
3. Load a few sites and watch a video. That covers the GPU, renderer, and utility helpers with Hardened Runtime.
4. Confirm `spctl --assess --verbose /Applications/Axo.app` says "Notarized Developer ID".

## Not done yet (#61)

Chrome's restricted entitlements aren't in Release builds yet. Each needs something only the owner can do:

- **Passkeys from iCloud Keychain** (`com.apple.developer.web-browser.public-key-credential`). Apple grants this to browsers on request. Once it's granted, add it to the App ID and to `Axo-Release.entitlements`.
- **Chrome's own keychain items** (the `keychain-access-groups` in Chrome's `app-entitlements-chrome.plist`: Chrome's passkey and unexportable-key storage). The engine names these groups from its build's `chrome_mac_team_id` and `chrome_mac_bundle_id`, so the engine's `args.gn` must set Axo's team and bundle ID (a full engine rebuild) before Axo's entitlements can list them.
- **Associated domains** (`com.apple.developer.associated-domains.applinks.read-write`): Chrome uses this to open universal links in apps. Axo doesn't need it until it opens universal links itself.

Without these, sites can still use security keys, and Chrome's password storage ("Chromium Safe Storage") still works through the login keychain.
