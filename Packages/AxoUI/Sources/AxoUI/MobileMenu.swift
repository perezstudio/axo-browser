import AxoCore
import Foundation

/// Where the iPhone's address bar sits (#181): at the bottom, near the thumb, or at the top.
public enum MobileAddressBarPlacement: String, CaseIterable, Sendable {
    case bottom, top

    /// The key it's kept under in the app's settings.
    public static let storageKey = "mobileAddressBarPlacement"
}

/// An item of the iPhone's ••• menu (#181).
public enum MobileMenuItem: Hashable, Sendable {
    case back, forward, reload, stop, share
    case findOnPage, copyLink, summarize
    case addToPinned, removeFromPinned
    case siteSettings
    case addressBarPlacement(MobileAddressBarPlacement)

    /// The item's title.
    public var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .reload: "Reload"
        case .stop: "Stop"
        case .share: "Share"
        case .findOnPage: "Find on Page"
        case .copyLink: "Copy Link"
        case .summarize: "Summarize Page"
        case .addToPinned: "Add to Pinned"
        case .removeFromPinned: "Remove from Pinned"
        case .siteSettings: "Site Settings"
        case .addressBarPlacement(let placement): placement == .top ? "Address Bar at Top" : "Address Bar at Bottom"
        }
    }

    /// The item's symbol.
    public var systemImage: String {
        switch self {
        case .back: "chevron.backward"
        case .forward: "chevron.forward"
        case .reload: "arrow.clockwise"
        case .stop: "xmark"
        case .share: "square.and.arrow.up"
        case .findOnPage: "text.magnifyingglass"
        case .copyLink: "link"
        case .summarize: "text.line.3.summary"
        case .addToPinned: "pin"
        case .removeFromPinned: "pin.slash"
        case .siteSettings: "slider.horizontal.3"
        case .addressBarPlacement(let placement): placement == .top ? "platter.filled.top.iphone" : "platter.filled.bottom.iphone"
        }
    }
}

/// One of the menu's items and whether it can be chosen now.
public struct MobileMenuEntry: Hashable, Sendable {
    public var item: MobileMenuItem
    public var isEnabled: Bool
}

extension BrowserModel {
    /// The iPhone's ••• menu, nearest the button first (#181): Back, Forward, Reload (Stop while
    /// loading), and Share as one row; then the page's tools (Find on Page, Copy Link, Summarize
    /// Page where there's a summarizer, Add to or Remove from Pinned, and Site Settings); then
    /// where the address bar goes. Reader and extensions aren't built on iPhone yet.
    func mobileMenu(placement: MobileAddressBarPlacement) -> [[MobileMenuEntry]] {
        let page = selectedPage
        let hasPage = shownTab != nil
        let isWeb = siteSettingsOrigin != nil
        let navigation = [
            MobileMenuEntry(item: .back, isEnabled: page?.canGoBack == true),
            MobileMenuEntry(item: .forward, isEnabled: page?.canGoForward == true),
            MobileMenuEntry(item: page?.isLoading == true ? .stop : .reload, isEnabled: hasPage),
            MobileMenuEntry(item: .share, isEnabled: isWeb),
        ]
        var tools = [
            MobileMenuEntry(item: .findOnPage, isEnabled: hasPage),
            MobileMenuEntry(item: .copyLink, isEnabled: shownPageURL != nil),
        ]
        if pageSummarizer != nil {
            tools.append(MobileMenuEntry(item: .summarize, isEnabled: canSummarizePage))
        }
        if let tab = selectedTab {
            tools.append(MobileMenuEntry(item: tab.isPinned ? .removeFromPinned : .addToPinned, isEnabled: true))
        }
        tools.append(MobileMenuEntry(item: .siteSettings, isEnabled: isWeb))
        let other: MobileAddressBarPlacement = placement == .bottom ? .top : .bottom
        return [navigation, tools, [MobileMenuEntry(item: .addressBarPlacement(other), isEnabled: true)]]
    }

    /// Runs a menu item. Share and the address bar's placement are the view's (a share sheet,
    /// and the app's settings).
    func performMobileMenu(_ item: MobileMenuItem) {
        switch item {
        case .back: goBack()
        case .forward: goForward()
        case .reload, .stop: reloadOrStop()
        case .findOnPage: showFindBar()
        case .copyLink: copyShownPageLink()
        case .summarize: Task { await summarizeSelectedPage() }
        case .addToPinned, .removeFromPinned:
            guard let tab = selectedTab else { return }
            Task { await setPinned(!tab.isPinned, tabID: tab.id) }
        case .siteSettings: Task { await showSiteSettings() }
        case .share, .addressBarPlacement: break
        }
    }

    /// What the iPhone's address shows: the site, as the Mac's pill names it, or the
    /// placeholder for a tab with no address.
    var mobileAddressText: String? {
        AddressDisplay.shown(for: shownPageURL)?.text
    }

    /// Brings the iPhone's shrunk bar back in full (#182), as tapping its pill does.
    func expandChrome() {
        guard let selectedTabID else { return }
        pool.expandChrome(for: selectedTabID)
    }

    /// Shows the next (`step` 1) or previous (-1) Space, in the switcher's order, wrapping
    /// around, as swiping the iPhone's bar does (#182).
    func selectAdjacentSpace(by step: Int) async {
        guard spaces.count > 1, let current = space, let index = spaces.firstIndex(where: { $0.id == current.id }) else { return }
        let next = (index + step + spaces.count) % spaces.count
        await selectSpace(spaces[next].id)
    }
}

