import AxoCore
import AxoWeb
import Foundation

/// Finds and opens the apps links to other apps go to (`mailto:`, `zoommtg:`). The app connects
/// the system's; Axo's default names no app and opens nothing, so tests never open one.
@MainActor
public protocol ExternalAppOpening: AnyObject {
    /// The name of the app that opens `url`, or `nil` when no app does.
    func appName(for url: URL) -> String?
    /// Opens `url` in its app.
    func open(_ url: URL)
}

/// Names no app and opens nothing: the default until the app connects the system's.
public final class NoExternalApps: ExternalAppOpening {
    public init() {}
    public func appName(for url: URL) -> String? { nil }
    public func open(_ url: URL) {}
}

/// A page's link to another app, waiting for the person: open it, or, with no app to open it, an
/// explanation.
public struct ExternalAppRequest: Hashable, Sendable {
    /// The tab whose page asked.
    public var tabID: AxoCore.Tab.ID
    /// The link.
    public var url: URL
    /// The site that asked, or `nil` when it has none to name.
    public var origin: PageOrigin?
    /// Whether the site can be allowed for good: it's secure (https, or this Mac).
    public var canAlwaysAllow: Bool { origin?.isPotentiallyTrustworthy == true }
    /// The app that opens it, or `nil` when none does.
    public var appName: String?

    public init(tabID: AxoCore.Tab.ID, url: URL, origin: PageOrigin?, appName: String?) {
        self.tabID = tabID
        self.url = url
        self.origin = origin
        self.appName = appName
    }
}

/// The person's answer to a link to another app.
public enum ExternalAppAnswer: Hashable, Sendable {
    /// Don't open it (also the answer when the prompt goes away).
    case cancel
    /// Open it this time.
    case allow
    /// Open it, and let the site open links of this kind without asking from now on.
    case alwaysAllow
}

extension BrowserModel {
    /// A page asked to open a link in another app. Only a tab shown on screen can ask, one link
    /// at a time per tab (checked as the request arrives, before anything waits), never for a
    /// scheme no page may open (``ExternalLinks/isRefused(_:)``), and, once the person cancels, not
    /// again without a click until the page navigates. So a page in the background, or one
    /// repeating itself, can't fill the screen with prompts. (Chromium also refuses a second
    /// request with nothing the person did in between.)
    func receiveExternalLink(_ link: ExternalLinkRequest) {
        guard pool.isVisible(link.tabID), !ExternalLinks.isRefused(link.url),
              link.userGesture || tabsMutedForExternalLinks[link.tabID] == nil,
              tabsOpeningExternalLinks.insert(link.tabID).inserted else { return }
        Task {
            await handleExternalLink(link)
            tabsOpeningExternalLinks.remove(link.tabID)
        }
    }

    /// Asks the person about a page's link to another app (unless they've let the site open that
    /// kind of link before) and opens it, or, after a click, says no app opens it: pages often try
    /// an app's link on their own to see whether it's installed, which shouldn't show an error.
    /// Only a secure site (``PageOrigin/isPotentiallyTrustworthy``) can be allowed for good.
    func handleExternalLink(_ link: ExternalLinkRequest) async {
        guard let appName = externalApps.appName(for: link.url) else {
            guard link.userGesture else { return }
            _ = await prompts.ask(ExternalAppRequest(tabID: link.tabID, url: link.url, origin: link.origin, appName: nil))
            return
        }
        let scheme = link.url.scheme?.lowercased() ?? ""
        let profileID = pool.liveProfileID(for: link.tabID) ?? space?.profileID
        let lasting = link.origin.flatMap { $0.isPotentiallyTrustworthy ? $0 : nil }
        if let origin = lasting, let profileID,
           (try? await store.externalAppPermissions.isAllowed(scheme: scheme, origin: origin.serialized, profileID: profileID)) == true {
            externalApps.open(link.url)
            return
        }
        switch await prompts.ask(ExternalAppRequest(tabID: link.tabID, url: link.url, origin: link.origin, appName: appName)) {
        case .cancel:
            tabsMutedForExternalLinks[link.tabID] = pool.state(for: link.tabID)?.url
        case .alwaysAllow:
            if let origin = lasting, let profileID {
                try? await store.externalAppPermissions.allow(scheme: scheme, origin: origin.serialized, profileID: profileID)
            }
            externalApps.open(link.url)
        case .allow:
            externalApps.open(link.url)
        }
    }

    /// Answers the current link to another app.
    public func answerExternalApp(_ answer: ExternalAppAnswer) {
        prompts.answerCurrent(externalApp: answer)
    }
}
