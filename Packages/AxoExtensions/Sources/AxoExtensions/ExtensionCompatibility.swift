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
    /// WebKit ignores redefining the members it has on a namespace object, and it can hand out a
    /// fresh namespace object later, so members added to one object can vanish. Each kind of
    /// namespace shares one prototype, though, which accepts new members and replacement methods,
    /// so the script patches the prototypes and keeps them alive.
    ///
    /// It never replaces the `chrome` or `browser` globals (they're the same object). WebKit looks
    /// them up when it delivers an event to the background, and with both replaced it delivers
    /// nothing: no toolbar clicks, no messages.
    static let script = """
    // Added by Axo: fills in Chrome extension features WebKit doesn't have yet.
    (() => {
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

      // WebKit's namespace objects share one prototype per kind, which accepts new members (and
      // replacements for its methods). Patch those, and hold them so they live as long as this
      // background does: a namespace object WebKit hands out later still has the patches.
      // Never replace the chrome or browser globals: WebKit finds them when it delivers an event,
      // and delivers nothing if they've been replaced.
      const prototypes = [];
      // The namespace's own prototype; never Object.prototype, which every object shares.
      const targetFor = (object) => {
        const prototype = Object.getPrototypeOf(object);
        if (!prototype || prototype === Object.prototype) return object;
        if (!prototypes.includes(prototype)) prototypes.push(prototype);
        return prototype;
      };
      const define = (object, name, value) => {
        try {
          Object.defineProperty(targetFor(object), name, { value, configurable: true, writable: true });
        } catch (error) {
          console.warn(`Axo: couldn't add ${name}: ${error}`);
        }
      };
      const root = globalThis.chrome || globalThis.browser;
      if (!root || typeof root !== "object") return;
      if (root.notifications === undefined) define(root, "notifications", notifications);
      for (const [name, members] of Object.entries(missing)) {
        const namespace = root[name];
        if (!namespace || typeof namespace !== "object") continue;
        for (const [member, value] of Object.entries(members)) {
          if (namespace[member] === undefined) define(namespace, member, value);
        }
      }
      for (const [name, methods] of Object.entries(replaced)) {
        const namespace = root[name];
        if (!namespace || typeof namespace !== "object") continue;
        for (const [method, wrap] of Object.entries(methods)) {
          const original = namespace[method];
          if (typeof original !== "function") continue;
          define(namespace, method, function (...args) { return wrap(original.bind(this))(...args); });
        }
      }
      globalThis[Symbol.for("axo.compatibility")] = prototypes;
    })();
    """
}
