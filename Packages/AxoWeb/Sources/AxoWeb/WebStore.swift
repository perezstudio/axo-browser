import AxoCore
import Foundation
import WebKit

/// The Chrome Web Store's "Add to Axo" button.
///
/// On an extension's store page (`chromewebstore.google.com/detail/<name>/<id>`), a script in an
/// isolated content world adds an "Add to Axo" button beside the store's own install button, or
/// a floating one if that button can't be found, so a store redesign degrades instead of
/// breaking. Clicking it reports the extension's ID to the pool. Page scripts can't see the
/// script, and only real clicks in the store's main frame count.
public enum WebStore {
    /// The Chrome Web Store's host.
    public static let host = "chromewebstore.google.com"
    /// The isolated world the button's script runs in.
    @MainActor static var world: WKContentWorld { .world(name: "AxoWebStore") }
    /// The message handler name the button posts to.
    static let handlerName = "axoWebStore"

    /// Whether a string is a Chrome extension ID: 32 letters from a to p.
    public static func isValidExtensionID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }

    /// The extension ID in a store detail page's URL, or `nil` for any other page.
    public static func extensionID(fromPageURL url: URL) -> String? {
        guard url.scheme == "https", url.host() == host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.first == "detail", parts.count >= 2, let id = parts.last, isValidExtensionID(id) else { return nil }
        return id
    }

    /// The script that adds the button. It runs in every page but only acts on store detail
    /// pages, and it follows the store's in-page navigation.
    static let source = """
    (() => {
      if (location.host !== "\(host)") return;
      const ID = /^[a-p]{32}$/;
      const currentID = () => {
        const parts = location.pathname.split("/").filter(Boolean);
        const id = parts[parts.length - 1];
        return parts[0] === "detail" && ID.test(id) ? id : null;
      };
      // The store's install button mentions Chrome ("Add to Chrome", "Available on Chrome", …).
      const storeButton = () => [...document.querySelectorAll("button")]
        .find((b) => !b.dataset.axo && /\\bChrome\\b/.test(b.textContent || ""));
      const makeButton = () => {
        const button = document.createElement("button");
        button.type = "button";
        button.dataset.axo = "add";
        button.textContent = "Add to Axo";
        Object.assign(button.style, {
          background: "#9B2A5C", color: "#fff", border: "none", borderRadius: "18px",
          height: "36px", padding: "0 20px", font: "500 14px -apple-system, system-ui, sans-serif",
          cursor: "pointer", marginInlineEnd: "8px",
        });
        button.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          const id = currentID();
          // Only a real click counts, so the page can't start an install on its own.
          if (id && event.isTrusted) window.webkit.messageHandlers.\(handlerName).postMessage(id);
        });
        return button;
      };
      let scheduled = false;
      const update = () => {
        scheduled = false;
        let ours = document.querySelector("button[data-axo]");
        if (!currentID()) { ours?.remove(); return; }
        const anchor = storeButton();
        const placed = anchor ? ours && ours.nextElementSibling === anchor : ours && ours.dataset.floating;
        if (placed) return;
        ours?.remove();
        ours = makeButton();
        if (anchor && anchor.parentElement) {
          anchor.parentElement.insertBefore(ours, anchor);
        } else {
          ours.dataset.floating = "1";
          Object.assign(ours.style, { position: "fixed", top: "16px", right: "16px", zIndex: "2147483647" });
          document.body.appendChild(ours);
        }
      };
      update();
      new MutationObserver(() => {
        // A timer, not requestAnimationFrame, which never fires in hidden tabs.
        if (!scheduled) { scheduled = true; setTimeout(update, 100); }
      }).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

    @MainActor
    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
    }
}

/// Receives the button's clicks, accepting only the store's main frame and valid IDs. It holds
/// its callback weakly through the pool, so web views don't keep the pool alive.
@MainActor
final class WebStoreMessageHandler: NSObject, WKScriptMessageHandler {
    private let onInstall: (String) -> Void

    init(onInstall: @escaping (String) -> Void) {
        self.onInstall = onInstall
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == WebStore.host,
              let id = message.body as? String, WebStore.isValidExtensionID(id) else { return }
        onInstall(id)
    }
}
