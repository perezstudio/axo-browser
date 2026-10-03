# AxoExtensions

`WKWebExtensionController` per profile, CRX install, and the `WKWebExtensionTab` and `WKWebExtensionWindow` adapters.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoCore, AxoWeb (the `AxoExtensions` target); nothing (the `AxoCRX` target)

## Targets

### AxoCRX (standalone, meant to be open sourced early)

No Axo or third-party dependencies.

- **`CRXPackage(_:)`** parses a CRX3 file and verifies it. It reads the protobuf `CrxFileHeader`, finds the RSA proof whose key hashes to the signed `crx_id`, and verifies its RSA-SHA256 signature over `"CRX3 SignedData\0"`, the length, the signed header data, and the archive (Security framework). Other proofs, such as the Chrome Web Store's, are allowed. CRX2 files and ECDSA-only developer signatures are rejected.
  - `extensionID` and `CRXPackage.extensionID(forPublicKey:)` use Chrome's ID scheme: the first 16 bytes of SHA-256 of the key, written in letters a–p.
- **`ZipArchive.extract(_:to:sizeLimit:)`** handles stored and deflate entries (Compression framework). It verifies each entry's CRC-32, refuses paths that escape the destination, symlinks, encrypted entries, and Zip64, and caps the expanded size (512 MB by default).
- **`ExtensionManifest.read(fromExtensionAt:)`** checks `manifest.json` (a byte-order mark is fine): name, version, and manifest version 2 or 3.

### AxoExtensions

- **`ExtensionInstaller(root:)`** installs extensions per profile under `root/<profile ID>/<extension ID>`.
  - `install(crx:for:)` verifies the package, extracts it to a staging folder, checks the manifest, then moves or replaces the installed copy. A failed install leaves nothing behind.
  - `inspectUnpacked(at:)` checks a developer-mode folder, which is used in place with Chrome's path-derived ID.
  - `installedExtensions(for:)` lists installs, and `uninstall(_:for:)` removes them (it never deletes unpacked folders).
- **`InstalledExtension.load()`** creates a `WKWebExtension`, so WebKit validates the files.
- **`ExtensionManager`** (`@MainActor`, `@Observable`) runs extensions.
  - **Controllers:** one `WKWebExtensionController` per profile, with persistent storage keyed by the profile ID (`persistent: false` for tests) and the profile's website data store. It attaches each controller to new web views through `WebViewPool.configureWebView`.
  - **Lifecycle:** `install(crx:for:)`, `installUnpacked(at:for:)`, `setEnabled(_:extensionID:profileID:)`, `uninstall(_:profileID:)`, and `loadExtensions(for:)` keep the files, the database records (`ExtensionStore`), and the loaded contexts in step. `loadErrors` reports extensions that can't load.
  - **Each context:**
    - `uniqueIdentifier` is the Chrome extension ID (so `browser.runtime.id` matches Chrome), and `baseURL` is the stable `webkit-extension://<id>/` (so the extension's storage survives relaunches).
    - `isInspectable` is on.
    - The requested permissions and all requested match patterns are granted, as Chrome does at install. Optional permissions are not granted.

Still to come in Milestone 3: the tab and window adapters, the toolbar and popups, the install prompt, permission management, and install UI.

## Testing

```bash
swift test
```

Content scripts don't run on `file:` pages, so tests serve pages from `LoopbackWebServer` (127.0.0.1 only). The `AxoExtensionsTestSupport` target builds fixtures in code: zip archives (including malicious ones) and CRX3 files signed with freshly generated RSA keys. Its CRC-32 is independent of the code under test. It isn't a product.
