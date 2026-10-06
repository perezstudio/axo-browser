import Foundation

/// Fills in Chrome extension features WebKit lacks, so extensions that assume them can start.
///
/// For extensions installed from a CRX (never a developer's unpacked folder), Axo adds a small
/// script (``scriptName``) that runs before the extension's own background code. It provides:
///
/// - a stand-in `chrome.notifications` (notifications don't appear yet; see
///   `docs/webkit-gaps.md`), so code that reads it at startup doesn't throw;
/// - stand-ins for `webNavigation` events WebKit doesn't have (`onCreatedNavigationTarget` and
///   others), which never fire, and an empty `storage.managed`;
/// - `declarativeNetRequest.updateSessionRules` and `updateDynamicRules` that retry without
///   the request and response headers WebKit doesn't recognize, instead of failing.
///
/// The background is pointed at a wrapper (``wrapperName``) that runs the script first: an ES
/// module importing it and then the original worker, `importScripts` for a classic worker, or
/// an extra first entry in Manifest V2's background scripts. Only Axo's installed copy changes,
/// after its signature was checked. Applying again is harmless and refreshes the script.
public enum ExtensionCompatibility {
    /// The compatibility script's file name, at the extension's root.
    public static let scriptName = "axo-compat.js"
    /// The background wrapper's file name, at the extension's root.
    public static let wrapperName = "axo-background.js"

    /// Adds the compatibility script to the extension in `folder`.
    ///
    /// - Returns: Whether the background now runs it. `false` for extensions without a
    ///   background, with a background page (rare, left alone), or with a manifest Axo can't
    ///   rewrite.
    @discardableResult
    public static func apply(to folder: URL) throws -> Bool {
        let manifestURL = folder.appending(path: "manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any],
              var background = manifest["background"] as? [String: Any] else { return false }

        if let worker = background["service_worker"] as? String {
            if worker != wrapperName {
                let original = worker.hasPrefix("/") ? String(worker.dropFirst()) : worker
                let wrapper = (background["type"] as? String) == "module"
                    ? "import \"./\(scriptName)\";\nimport \"./\(original)\";\n"
                    : "importScripts(\"/\(scriptName)\", \"/\(original)\");\n"
                try Data(wrapper.utf8).write(to: folder.appending(path: wrapperName))
                background["service_worker"] = wrapperName
            }
        } else if var scripts = background["scripts"] as? [String] {
            if scripts.first != scriptName {
                scripts.insert(scriptName, at: 0)
                background["scripts"] = scripts
            }
        } else {
            return false
        }

        try Data(script.utf8).write(to: folder.appending(path: scriptName))
        manifest["background"] = background
        let rewritten = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        if rewritten != data { try rewritten.write(to: manifestURL) }
        return true
    }

    /// The compatibility script. It changes nothing where WebKit already has the feature.
    ///
    /// WebKit ignores attempts to redefine the namespaces on `chrome`, and it can hand out a fresh
    /// namespace object, so stand-ins attached to those objects can vanish. Instead the script
    /// replaces the `chrome` and `browser` globals with proxies: every read of a namespace goes
    /// through them and gets the missing members, whatever object WebKit returns.
    static let script = """
    // Added by Axo: fills in Chrome extension features WebKit doesn't have yet.
    (() => {
      const has = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
      const event = () => {
        const listeners = new Set();
        return {
          addListener: (listener) => { listeners.add(listener); },
          removeListener: (listener) => { listeners.delete(listener); },
          hasListener: (listener) => listeners.has(listener),
          hasListeners: () => listeners.size > 0,
        };
      };
      const answer = (callback, value) => { if (typeof callback === "function") callback(value); return Promise.resolve(value); };

      // chrome.notifications: a stand-in so code that uses it keeps running. Nothing is shown.
      let nextNotification = 0;
      const notifications = {
        create(idOrOptions, optionsOrCallback, callback) {
          const id = typeof idOrOptions === "string" && idOrOptions ? idOrOptions : `axo-${++nextNotification}`;
          return answer(typeof optionsOrCallback === "function" ? optionsOrCallback : callback, id);
        },
        update: (id, options, callback) => answer(callback, false),
        clear: (id, callback) => answer(callback, false),
        getAll: (callback) => answer(callback, {}),
        getPermissionLevel: (callback) => answer(callback, "denied"),
        onClicked: event(), onClosed: event(), onButtonClicked: event(),
        onShowSettings: event(), onPermissionLevelChanged: event(),
        TemplateType: { BASIC: "basic", IMAGE: "image", LIST: "list", PROGRESS: "progress" },
        PermissionLevel: { GRANTED: "granted", DENIED: "denied" },
      };

      // Members missing from namespaces WebKit has: webNavigation events that never fire, and an
      // empty storage.managed (settings an organization pushes).
      const missing = {
        webNavigation: Object.fromEntries(["onCreatedNavigationTarget", "onHistoryStateUpdated", "onReferenceFragmentUpdated", "onTabReplaced"]
          .map((name) => [name, event()])),
        storage: {
          managed: {
            get: (keys, callback) => answer(typeof keys === "function" ? keys : callback, {}),
            getBytesInUse: (keys, callback) => answer(typeof keys === "function" ? keys : callback, 0),
            onChanged: event(),
          },
        },
      };

      // declarativeNetRequest: WebKit rejects header names outside its list. Retry without the
      // rejected headers (dropping rules left with nothing to change), instead of failing.
      const rejectedHeaders = (error) => [...String(error && error.message || error)
        .matchAll(/header [`'"]([^`'"]+)[`'"] is not recognized/gi)].map((match) => match[1].toLowerCase());
      const withoutHeaders = (rules, names) => (rules || []).flatMap((rule) => {
        const action = rule && rule.action;
        if (!action || action.type !== "modifyHeaders") return [rule];
        const keep = (list) => list && list.filter((entry) => !names.has(String(entry.header).toLowerCase()));
        const requestHeaders = keep(action.requestHeaders), responseHeaders = keep(action.responseHeaders);
        if (!(requestHeaders && requestHeaders.length) && !(responseHeaders && responseHeaders.length)) return [];
        const changed = { ...action };
        if (requestHeaders) changed.requestHeaders = requestHeaders; else delete changed.requestHeaders;
        if (responseHeaders) changed.responseHeaders = responseHeaders; else delete changed.responseHeaders;
        return [{ ...rule, action: changed }];
      });
      const retryingWithoutRejectedHeaders = (original) => async (options, callback) => {
        let current = options || {};
        const removed = new Set();
        for (let attempt = 0; ; attempt++) {
          try {
            const result = await original(current);
            if (typeof callback === "function") callback(result);
            return result;
          } catch (error) {
            const names = rejectedHeaders(error).filter((header) => !removed.has(header));
            if (!names.length || attempt > 8) throw error;
            names.forEach((header) => removed.add(header));
            console.warn(`Axo: WebKit doesn't support changing these headers, so these rules skip them: ${names.join(", ")}`);
            current = { ...current, addRules: withoutHeaders(current.addRules, removed) };
          }
        }
      };
      const replaced = {
        declarativeNetRequest: { updateSessionRules: retryingWithoutRejectedHeaders, updateDynamicRules: retryingWithoutRejectedHeaders },
      };

      // A namespace with its missing members filled in and replaced methods swapped. WebKit's
      // functions expect the real namespace as `this`. One wrapper per namespace object.
      const wrappers = new WeakMap();
      const wrapNamespace = (real, name) => {
        if (!real || typeof real !== "object") return real;
        const extras = missing[name] || {}, swaps = replaced[name] || {};
        if (!Object.keys(swaps).length && Object.keys(extras).every((key) => real[key] !== undefined)) return real;
        let wrapper = wrappers.get(real);
        if (!wrapper) {
          const swapped = {};
          wrapper = new Proxy(real, {
            get(target, property) {
              const value = Reflect.get(target, property, target);
              if (has(swaps, property) && typeof value === "function") {
                return swapped[property] || (swapped[property] = swaps[property](value.bind(target)));
              }
              if (value === undefined && has(extras, property)) return extras[property];
              return typeof value === "function" ? value.bind(target) : value;
            },
            has: (target, property) => Reflect.has(target, property) || has(extras, property),
          });
          wrappers.set(real, wrapper);
        }
        return wrapper;
      };

      for (const globalName of ["chrome", "browser"]) {
        const root = globalThis[globalName];
        if (!root || typeof root !== "object") continue;
        const wrapper = new Proxy(root, {
          get(target, property) {
            const value = Reflect.get(target, property, target);
            if (property === "notifications" && value === undefined) return notifications;
            if (typeof property === "string" && (has(missing, property) || has(replaced, property))) return wrapNamespace(value, property);
            return typeof value === "function" ? value.bind(target) : value;
          },
          has: (target, property) => Reflect.has(target, property) || property === "notifications",
        });
        try { Object.defineProperty(globalThis, globalName, { value: wrapper, configurable: true, writable: true }); } catch {}
      }
    })();
    """
}
