import Foundation
import WebKit

/// Reports the link under the pointer, or with keyboard focus, on WebKit pages, for the status
/// label over the page. WebKit has no public API for it, so a small script in every frame, in an
/// isolated world the page's scripts can't see, follows the pointer and focus and posts where the
/// link goes. As in Chromium, a link with focus (not from a click) wins over the one under the
/// pointer, and only real events count: a page can't fake a hover with `dispatchEvent`.
@MainActor
enum HoveredLinks {
    static let world = WKContentWorld.world(name: "AxoHoveredLinks")
    static let messageName = "axoHoveredLink"
    /// The longest address shown; longer ones are cut, so a huge `data:` link can't slow Axo down.
    static let maxLength = 2048

    static let userScript = WKUserScript(source: """
        (() => {
          let hovered = null, focused = null, shown = null;
          // The event's path, not its target, so links inside web components (shadow DOM) count.
          const link = event => event.composedPath()
            .find(node => node instanceof Element && node.matches('a[href], area[href]')) ?? null;
          const address = element => {
            const href = element?.href;
            if (typeof href === 'string') return href;
            // An SVG link's address isn't resolved against the page's.
            try { return href ? new URL(href.baseVal, document.baseURI).href : null; } catch { return null; }
          };
          const update = () => {
            let url = address(focused ?? hovered);
            // A huge address (a data: link with a whole file in it) would only slow Axo down.
            if (url && url.length > \(HoveredLinks.maxLength)) url = url.slice(0, \(HoveredLinks.maxLength));
            if (url === shown) return;
            shown = url;
            window.webkit.messageHandlers.\(messageName).postMessage(url);
          };
          addEventListener('mouseover', event => {
            if (!event.isTrusted) return;
            hovered = link(event);
            update();
          }, true);
          addEventListener('mouseout', event => {
            if (!event.isTrusted || event.relatedTarget) return;
            hovered = null;
            update();
          }, true);
          // As in Chromium, a link a click focused doesn't count: the pointer shows that one.
          let clicked = false;
          addEventListener('mousedown', event => { if (event.isTrusted) clicked = true; }, true);
          // A click focuses (or doesn't) before the button comes up.
          addEventListener('mouseup', event => { if (event.isTrusted) clicked = false; }, true);
          addEventListener('focusin', event => {
            if (!event.isTrusted) return;
            focused = clicked ? null : link(event);
            clicked = false;
            update();
          }, true);
          addEventListener('focusout', event => {
            if (!event.isTrusted) return;
            focused = null;
            update();
          }, true);
          addEventListener('pagehide', () => {
            hovered = focused = null;
            update();
          }, true);
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)

    /// Adds the script and its message handler to a new page's configuration. Set the handler's
    /// page once the page exists.
    static func install(in configuration: WKWebViewConfiguration) -> Handler {
        let handler = Handler()
        configuration.userContentController.addUserScript(userScript)
        configuration.userContentController.add(handler, contentWorld: world, name: messageName)
        return handler
    }

    /// Passes the script's messages to its page's delegate. The content controller keeps it, so
    /// it holds the page weakly.
    final class Handler: NSObject, WKScriptMessageHandler {
        weak var page: WebKitPage?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let page else { return }
            let url: URL?
            switch message.body {
            case let string as String: url = URL(string: String(string.prefix(maxLength)))
            case is NSNull: url = nil
            default: return
            }
            page.delegate?.page(page, hoversLinkTo: url)
        }
    }
}
