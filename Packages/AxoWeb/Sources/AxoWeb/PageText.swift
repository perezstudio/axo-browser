import AxoCore
import Foundation
import WebKit

/// Reading and rewriting a page's text, for translation and summaries.
///
/// Runs in an isolated content world, so pages can't see or interfere with it.
@MainActor
enum PageText {
    static let world = WKContentWorld.world(name: "AxoPageText")

    /// Collects the page's visible text nodes (skipping scripts, styles, and code), remembers
    /// them, and returns their text. Trims to `limit` nodes.
    static let collect = """
        const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'CODE', 'PRE', 'TEXTAREA', 'SVG']);
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            if (!node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
            for (let el = node.parentElement; el; el = el.parentElement) {
              if (skip.has(el.tagName) || el.isContentEditable) return NodeFilter.FILTER_REJECT;
            }
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        const nodes = [];
        while (walker.nextNode() && nodes.length < limit) nodes.push(walker.currentNode);
        if (!window.axoTextOriginals) window.axoTextOriginals = new Map();
        window.axoTextNodes = nodes;
        return nodes.map(node => node.nodeValue.trim());
        """

    /// Replaces the collected nodes' text, keeping each node's surrounding spaces and its
    /// original text for restoring.
    static let replace = """
        const nodes = window.axoTextNodes || [];
        nodes.forEach((node, index) => {
          if (index >= texts.length || !node.isConnected) return;
          if (!window.axoTextOriginals.has(node)) window.axoTextOriginals.set(node, node.nodeValue);
          const original = window.axoTextOriginals.get(node);
          const lead = original.match(/^\\s*/)[0], trail = original.match(/\\s*$/)[0];
          node.nodeValue = lead + texts[index] + trail;
        });
        return nodes.length;
        """

    /// Puts back the original text of every replaced node.
    static let restore = """
        const originals = window.axoTextOriginals || new Map();
        originals.forEach((text, node) => { if (node.isConnected) node.nodeValue = text; });
        originals.clear();
        return true;
        """

    /// The page's readable text, collapsed and trimmed to `limit` characters.
    static let readable = """
        const text = (document.body ? document.body.innerText : '').replace(/[ \\t]+/g, ' ').replace(/\\n{3,}/g, '\\n\\n').trim();
        return text.length > limit ? text.slice(0, limit) : text;
        """
}

extension WebViewPool {
    /// The visible text of a live tab's page, in order, for translation. Each string is one text
    /// node; pass the translations back to ``replacePageText(_:in:)`` in the same order.
    public func pageTextSegments(in tabID: Tab.ID, limit: Int = 2_000) async throws -> [String] {
        guard let webView = liveWebView(for: tabID) else { return [] }
        let result = try await webView.callAsyncJavaScript(PageText.collect, arguments: ["limit": limit], contentWorld: PageText.world)
        return result as? [String] ?? []
    }

    /// Replaces the text collected by ``pageTextSegments(in:limit:)`` with `texts`, in order.
    public func replacePageText(_ texts: [String], in tabID: Tab.ID) async throws {
        guard let webView = liveWebView(for: tabID) else { return }
        _ = try await webView.callAsyncJavaScript(PageText.replace, arguments: ["texts": texts], contentWorld: PageText.world)
    }

    /// Puts back the page's original text after ``replacePageText(_:in:)``.
    public func restorePageText(in tabID: Tab.ID) async throws {
        guard let webView = liveWebView(for: tabID) else { return }
        _ = try await webView.callAsyncJavaScript(PageText.restore, contentWorld: PageText.world)
    }

    /// A live tab's readable text, up to `limit` characters, for summaries.
    public func readablePageText(in tabID: Tab.ID, limit: Int = 6_000) async throws -> String {
        guard let webView = liveWebView(for: tabID) else { return "" }
        let result = try await webView.callAsyncJavaScript(PageText.readable, arguments: ["limit": limit], contentWorld: PageText.world)
        return result as? String ?? ""
    }
}
