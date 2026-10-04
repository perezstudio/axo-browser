import AxoCore
import Foundation
import WebKit

/// Turns per-site customizations into WebKit user scripts.
///
/// Each customization becomes its own scripts, so a mistake in one site's JavaScript can't break
/// another's. Each script checks the page's host itself, and steps aside when a more specific
/// customization matches (`docs.example.com` over `example.com`). User scripts aren't subject to
/// pages' Content Security Policy.
@MainActor
enum SiteCustomizationScripts {
    /// An isolated world for the CSS, so pages can't see or undo the code that adds it.
    static let cssWorld = WKContentWorld.world(name: "AxoSiteCustomizations")

    /// The scripts for the enabled customizations.
    static func userScripts(for customizations: [SiteCustomization]) -> [WKUserScript] {
        let enabled = customizations.filter(\.isEnabled)
        let domains = enabled.map(\.domain)
        return enabled.flatMap { customization -> [WKUserScript] in
            var scripts: [WKUserScript] = []
            let applies = Self.matchCheck(for: customization.domain, among: domains)
            if !customization.css.isEmpty {
                // Before the page renders, in every frame of the site.
                let source = """
                    if (\(applies)) {
                      const style = document.createElement('style');
                      style.dataset.axoSiteCustomization = \(Self.literal(customization.domain));
                      style.textContent = \(Self.literal(customization.css));
                      (document.head || document.documentElement).appendChild(style);
                    }
                    """
                scripts.append(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: cssWorld))
            }
            if !customization.js.isEmpty {
                // Once the page loads, in the page's own world, like a userscript. Only the top
                // frame, so it runs once per page.
                let source = """
                    if (\(applies)) {
                    \(customization.js)
                    }
                    """
                scripts.append(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
            }
            return scripts
        }
    }

    /// A JavaScript expression that's true when the page's host is `domain` or one of its
    /// subdomains, and no more specific customized domain also matches.
    static func matchCheck(for domain: String, among domains: [String]) -> String {
        let moreSpecific = domains.filter { $0 != domain && $0.hasSuffix("." + domain) }
        return """
            ((h, d, more) => (h === d || h.endsWith('.' + d)) && !more.some(m => h === m || h.endsWith('.' + m)))\
            (location.hostname.toLowerCase(), \(literal(domain)), \(literal(moreSpecific)))
            """
    }

    /// A value as a JavaScript literal.
    static func literal(_ value: some Encodable) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
        // JSON is valid JavaScript, except that U+2028 and U+2029 end lines in older engines.
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
