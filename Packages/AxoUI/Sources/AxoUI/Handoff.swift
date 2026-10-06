import AxoCore
import Foundation
import SwiftUI

extension BrowserModel {
    /// The page to offer through Handoff: the selected page, if it's an http or https page.
    public var handoffURL: URL? {
        guard isHandoffEnabled, let url = selectedPage?.url ?? shownTab?.url,
              Self.isWebPage(url) else { return nil }
        return url
    }

    /// Opens a page handed off from another device, as a new tab in the current Space. Only web
    /// pages are opened, since another device decides the address.
    public func continueBrowsing(_ url: URL) async {
        guard Self.isWebPage(url) else { return }
        await openForIntent(url, in: nil)
    }

    static func isWebPage(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

/// Offers the selected page to the person's other devices through Handoff.
struct HandoffActivity: ViewModifier {
    let model: BrowserModel

    func body(content: Content) -> some View {
        content.userActivity(NSUserActivityTypeBrowsingWeb, isActive: model.handoffURL != nil) { activity in
            activity.webpageURL = model.handoffURL
            activity.title = model.selectedPage?.title ?? model.shownTab?.title
        }
    }
}
