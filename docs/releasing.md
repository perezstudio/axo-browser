# Releasing Axo for the Mac

Axo ships outside the Mac App Store, as a DMG signed with a Developer ID and notarized by Apple (`docs/PLAN.md`, "Distribution"). `scripts/package-release.sh` builds one. Signing and notarizing use the owner's Developer ID and Apple account, and updates are signed with the owner's Sparkle key; all of them stay in the owner's keychain and never go in the repo (CLAUDE.md, hard rule 8). Axo updates itself through Sparkle (#180) from an appcast on GitHub Pages.

## One-time setup

1. **A Developer ID Application certificate** for the team in the Axo target (`DEVELOPMENT_TEAM`), in the login keychain. Xcode › Settings › Accounts › Manage Certificates can make one.
2. **The App ID's capabilities.** Release builds sign with `Axo/Axo-Release.entitlements` (iCloud's CloudKit container `iCloud.com.perezstudio.Axo` and push notifications), so the App ID `com.perezstudio.Axo` needs both. The export lets Xcode make the Developer ID provisioning profile (`-allowProvisioningUpdates`). Profiles are gitignored.
3. **A notarytool keychain profile.** Use an app-specific password from account.apple.com or an App Store Connect API key:

   ```bash
   xcrun notarytool store-credentials axo-notary
   ```

   It prompts for the Apple ID, team ID, and password and keeps them in the keychain. To use another name, set `AXO_NOTARY_PROFILE`.
4. **A Sparkle signing key.** Updates carry an EdDSA signature that Axo checks with the public key it ships with. Sparkle's `generate_keys` makes the pair once and keeps the private key in the login keychain (after a build, it's in `DerivedData/Axo-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`):

   ```bash
   generate_keys
   ```

   It prints the public key. Set the Axo target's `AXO_SPARKLE_PUBLIC_KEY` build setting to it (both configurations) and commit that: it's public. Back up the private key (`generate_keys -x <file>`) somewhere safe outside the repo; without it, no copy of Axo already out there can be updated again. Builds without the public key don't update themselves.
5. **The appcast on GitHub Pages.** Axo checks `https://perezstudio.github.io/axo-browser/appcast.xml` (`SUFeedURL` in `Axo/Info.plist`). Turn on GitHub Pages for the repo from a `gh-pages` branch holding one `appcast.xml`:

   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
     <channel>
       <title>Axo</title>
     </channel>
   </rss>
   ```
6. **The engine**, built from a clean, committed checkout of axo-chromium next to Axo (or at `AXO_CHROMIUM_OUT`), matching this Axo's engine API header.

## Making a release

```bash
scripts/package-release.sh --notes notes.txt
```

`--notes` takes the release notes as plain text, which the update window shows as they are (with bullets as `•` and a blank line between sections). Add `--beta` for a beta: it goes on the appcast's `beta` channel, which only people who turned on Include beta versions are offered.

It refuses if Axo or the engine checkout has uncommitted changes, if the engine build is older than the fork's last change, or if the API headers differ. Those checks can't prove the engine build came from the checked-out commit. Edits made directly in `chromium/src` (gitignored in the fork) aren't seen, and neither is checking out an older commit after building a newer one. So build the engine from the commit you're releasing, right before packaging. Then it:

1. Archives Release. The embed phase copies the engine in and signs it as Chrome does, with secure timestamps.
2. Exports the archive with the Developer ID.
3. Checks the result with `scripts/verify-engine-signing.sh --release`: every helper has Hardened Runtime, the renderer and GPU helpers have Chrome's JIT entitlement, every item (app, framework, helpers, and libraries) is signed with the Developer ID and a timestamp, and the app has no `get-task-allow`.
4. Notarizes and staples `Axo.app`, so a copied app opens offline. Then it builds the DMG (Axo and an Applications link), signs it with the same certificate as the app (by fingerprint, so a renewed certificate beside an expired one can't confuse it), and notarizes and staples that too.
5. Checks that `AXO_SPARKLE_PUBLIC_KEY` is the public half of the Sparkle key in your keychain (otherwise every update would be refused), then signs the DMG with it (Sparkle's `sign_update`) and writes the update's appcast `<item>`: its version and build, the minimum macOS, the release notes, the channel, and the DMG's download address on GitHub Releases (`releases/download/v<version>/`, or `AXO_RELEASE_DOWNLOAD_URL`) with its signature and length.
6. Writes the manifest beside the DMG. It records Axo's commit and what identifies the engine build the DMG carries: the fork's commit, the Chromium version, and the engine binary's SHA-256.

Output goes in `build/release/` (gitignored, or `AXO_RELEASE_DIR`): `Axo-<version>-<build>.dmg`, its `.txt` manifest, its `.appcast-item.xml`, and the archive and export logs. Set the version in the Axo target's `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` first.

To try a DMG on this Mac without notarizing, use `--skip-notarize`. With `--allow-dirty` it also packages uncommitted changes. The manifest marks both; never publish those DMGs.

Debug builds signed with your team identity also get Hardened Runtime on the engine's helpers, so a debugger can't attach to renderer or GPU processes. Use an ad hoc build (`CODE_SIGN_IDENTITY=-`) to debug them.

## Publishing it

1. Make a GitHub release tagged `v<version>` (a prerelease for a beta) and attach the DMG.
2. Add the `.appcast-item.xml`'s `<item>` to `appcast.xml` on `gh-pages`, inside `<channel>`, newest first, and push. Copies of Axo that check from then on are offered it. Never edit an item's `enclosure` afterwards: its signature covers the DMG it names.

Sparkle installs only versions newer than the one running, so a stale or tampered appcast can't move anyone back to an older Axo, and nothing installs without your key's signature.

## Checking an update by hand

Updating can't be tested automatically (it needs a signed build and your key), so check it once before the first release, and after changing the updater:

1. Build two versions with `scripts/package-release.sh --skip-notarize`, the second with a higher `CURRENT_PROJECT_VERSION` (and `MARKETING_VERSION`).
2. Put the second DMG and an `appcast.xml` holding its `<item>` in a folder, with the item's `enclosure` pointed at `http://127.0.0.1:8000/<its file name>`, and serve the folder: `python3 -m http.server 8000 --bind 127.0.0.1`.
3. Install the first version in Applications, then point it at the local feed (only addresses on this Mac are accepted): `defaults write com.perezstudio.Axo AXOUpdateFeedURL http://127.0.0.1:8000/appcast.xml`.
4. Open it, choose Axo › Check for Updates…, and install: the update window, the download, Ready to Install, and Install and Relaunch should bring back the second version with your windows and tabs. Then check the background path: turn on "Download and install updates automatically", bump a third build, and check again; the notice with Restart Now and Axo › Restart to Update Axo should appear.
5. Remove the override afterwards: `defaults delete com.perezstudio.Axo AXOUpdateFeedURL`.

A Debug build updates only while that override points at this Mac, so a development build never replaces itself with a release.

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
