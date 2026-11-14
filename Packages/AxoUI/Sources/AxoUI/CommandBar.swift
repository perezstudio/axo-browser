import AxoCore
import Foundation

/// An action the command bar can run.
public enum CommandAction: String, CaseIterable, Hashable, Sendable {
    case newSpace
    case newFolder
    case reopenClosedTab
    case showArchivedTabs
    case showDownloads
    case pinTab
    case unpinTab
    case findInPage
    case printPage
    case makeDefaultBrowser
    case importBrowserData
    case renameSpace
    case deleteSpace
    case renameFolder
    case deleteFolder
    case addSplitView
    case separateSplitView
    case rotateSplitView
    case translatePage
    case showOriginalPage
    case summarizePage
    case duplicateTab
    case closeOtherTabs
    case closeTabsBelow

    /// The name shown in the command bar.
    public var title: String {
        switch self {
        case .newSpace: "New Space"
        case .newFolder: "New Folder"
        case .reopenClosedTab: "Reopen Closed Tab"
        case .showArchivedTabs: "Show Archived Tabs"
        case .showDownloads: "Show Downloads"
        case .pinTab: "Pin Tab"
        case .unpinTab: "Unpin Tab"
        case .findInPage: "Find on Page"
        case .printPage: "Print Page"
        case .makeDefaultBrowser: "Make Axo Your Default Browser"
        case .importBrowserData: "Import from Another Browser"
        case .renameSpace: "Rename Space"
        case .deleteSpace: "Delete Space"
        case .renameFolder: "Rename Folder"
        case .deleteFolder: "Delete Folder"
        case .addSplitView: "Add Split View"
        case .separateSplitView: "Separate Split View"
        case .rotateSplitView: "Rotate Split View"
        case .translatePage: "Translate Page"
        case .showOriginalPage: "Show Original Page"
        case .summarizePage: "Summarize Page"
        case .duplicateTab: "Duplicate Tab"
        case .closeOtherTabs: "Close Other Tabs"
        case .closeTabsBelow: "Close Tabs Below"
        }
    }

    /// The SF Symbol shown next to the title.
    public var systemImage: String {
        switch self {
        case .newSpace: "square.stack"
        case .newFolder: "folder.badge.plus"
        case .reopenClosedTab: "arrow.uturn.backward"
        case .showArchivedTabs: "archivebox"
        case .showDownloads: "arrow.down.circle"
        case .pinTab: "pin"
        case .unpinTab: "pin.slash"
        case .findInPage: "magnifyingglass"
        case .printPage: "printer"
        case .makeDefaultBrowser: "checkmark.seal"
        case .importBrowserData: "square.and.arrow.down.on.square"
        case .renameSpace: "pencil"
        case .deleteSpace: "trash"
        case .renameFolder: "folder.badge.gearshape"
        case .deleteFolder: "folder.badge.minus"
        case .addSplitView: "rectangle.split.2x1"
        case .separateSplitView: "rectangle"
        case .rotateSplitView: "rectangle.split.1x2"
        case .translatePage: "translate"
        case .showOriginalPage: "arrow.uturn.backward.circle"
        case .summarizePage: "text.line.3.summary"
        case .duplicateTab: "plus.square.on.square"
        case .closeOtherTabs: "xmark.square"
        case .closeTabsBelow: "arrow.down.to.line"
        }
    }
}

/// One row in the command bar.
public enum CommandResult: Identifiable, Hashable {
    /// Open what was typed: a URL, or a search.
    case open(URL, isSearch: Bool, text: String)
    /// Switch to an open tab in this Space.
    case tab(AxoCore.Tab)
    /// Run an action.
    case action(CommandAction)
    /// Open a page from history in a new tab.
    case history(HistoryItem)

    public var id: String {
        switch self {
        case .open(let url, _, _): "open:\(url.absoluteString)"
        case .tab(let tab): "tab:\(tab.id)"
        case .action(let action): "action:\(action.rawValue)"
        case .history(let item): "history:\(item.url.absoluteString)"
        }
    }
}

/// What one command bar session has matched so far (#122): the last query, every open tab and
/// action it matched (not just the ones shown), and each tab's searchable text. Reset when the
/// bar opens, when the query is cleared, and whenever the tabs or actions change.
struct CommandSearchCache {
    private(set) var query = ""
    private var tabs: [AxoCore.Tab] = []
    private var actions: [CommandAction] = []
    private(set) var matchingTabs: [AxoCore.Tab] = []
    private(set) var matchingActions: [CommandAction] = []
    private var searchTexts: [AxoCore.Tab.ID: (title: String, url: URL, text: SearchText)] = [:]

    /// A tab's searchable text, and whether it's plain ASCII, worked out once.
    struct SearchText {
        let string: String
        let isASCII: Bool
    }

    /// Whether `query`'s matches are among the last query's: it extends the last query, over the
    /// same tabs and actions.
    func canNarrow(to query: String, tabs: [AxoCore.Tab], actions: [CommandAction]) -> Bool {
        !self.query.isEmpty && query.hasPrefix(self.query) && actions == self.actions && tabs == self.tabs
    }

    /// The text a tab is searched by: its title and address, kept while they stay the same.
    mutating func searchText(for tab: AxoCore.Tab) -> SearchText {
        if let kept = searchTexts[tab.id], kept.title == tab.title, kept.url == tab.url { return kept.text }
        let string = "\(tab.title) \(tab.url.absoluteString)"
        let text = SearchText(string: string, isASCII: string.allSatisfy(\.isASCII))
        searchTexts[tab.id] = (tab.title, tab.url, text)
        return text
    }

    mutating func remember(query: String, tabs: [AxoCore.Tab], actions: [CommandAction],
                           matchingTabs: [AxoCore.Tab], matchingActions: [CommandAction]) {
        self.query = query
        self.tabs = tabs
        self.actions = actions
        self.matchingTabs = matchingTabs
        self.matchingActions = matchingActions
    }

    /// Forgets the matches (the searchable text stays, since it depends only on each tab).
    mutating func reset() {
        query = ""
        tabs = []
        actions = []
        matchingTabs = []
        matchingActions = []
    }
}

/// Builds the command bar's results. Pure, so ranking is easy to test.
enum CommandRanking {
    static let maxTabs = 5
    static let maxActions = 3
    static let maxHistory = 8

    /// Whether every word of `query` appears in `text`, ignoring case and accents.
    static func matches(_ query: String, in text: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.allSatisfy { text.localizedStandardContains($0) }
    }

    /// Results that don't need the database: what was typed, open tabs, and actions.
    static func immediateResults(
        for query: String,
        tabs: [AxoCore.Tab],
        availableActions: [CommandAction]
    ) -> [CommandResult] {
        var cache = CommandSearchCache()
        return immediateResults(for: query, tabs: tabs, availableActions: availableActions, cache: &cache)
    }

    /// Results that don't need the database, narrowing the previous query's matches when the
    /// query only adds to it (#122). For plain ASCII text, whatever matches the longer query
    /// matched the shorter one, so only those need checking again. Text with characters that fold
    /// into more than one ("ß" matches "ss", "ﬁ" matches "fi") can match a longer query but not a
    /// shorter one ("Straße" matches "strass" but not "stras"), so those tabs are always checked
    /// again, and so are the actions, which are few. `cache` keeps the session's matches and each
    /// tab's searchable text.
    static func immediateResults(
        for query: String,
        tabs: [AxoCore.Tab],
        availableActions: [CommandAction],
        cache: inout CommandSearchCache
    ) -> [CommandResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cache.reset()
            return tabs.prefix(maxTabs * 2).map(CommandResult.tab)
        }
        var results: [CommandResult] = []
        if let url = AddressInput.url(from: trimmed) {
            let isSearch = url.host() == AddressInput.searchURL.host() && !trimmed.contains(".")
            results.append(.open(url, isSearch: isSearch, text: trimmed))
        }
        let narrows = cache.canNarrow(to: trimmed, tabs: tabs, actions: availableActions)
        let matchingTabs: [AxoCore.Tab]
        if narrows {
            // The previous matches, plus every tab whose text isn't plain ASCII, in sidebar order.
            let previous = Set(cache.matchingTabs.map(\.id))
            matchingTabs = tabs.filter { tab in
                let text = cache.searchText(for: tab)
                return (previous.contains(tab.id) || !text.isASCII) && matches(trimmed, in: text.string)
            }
        } else {
            matchingTabs = tabs.filter { matches(trimmed, in: cache.searchText(for: $0).string) }
        }
        let matchingActions = availableActions.filter { matches(trimmed, in: $0.title) }
        cache.remember(query: trimmed, tabs: tabs, actions: availableActions, matchingTabs: matchingTabs, matchingActions: matchingActions)
        results += matchingTabs.prefix(maxTabs).map(CommandResult.tab)
        results += matchingActions.prefix(maxActions).map(CommandResult.action)
        return results
    }

    /// History results to add, skipping pages already open as tabs.
    static func historyResults(_ items: [HistoryItem], excludingOpen tabs: [AxoCore.Tab]) -> [CommandResult] {
        let open = Set(tabs.map(\.url))
        return items.filter { !open.contains($0.url) }.prefix(maxHistory).map(CommandResult.history)
    }
}

extension CommandResult {
    /// The row's title.
    public var title: String {
        switch self {
        case .open(let url, let isSearch, let text): isSearch ? "Search for “\(text)”" : url.absoluteString
        case .tab(let tab): TabRow.displayTitle(for: tab)
        case .action(let action): action.title
        case .history(let item): item.title.isEmpty ? (item.url.host() ?? item.url.absoluteString) : item.title
        }
    }

    /// The page the row opens, for a typed address or search and for history.
    var pageURL: URL? {
        switch self {
        case .open(let url, _, _): url
        case .history(let item): item.url
        case .tab, .action: nil
        }
    }

    /// What Return does with the row, such as "Open" or "Switch to Tab".
    public var hint: String {
        switch self {
        case .open(_, let isSearch, _): isSearch ? "Search" : "Open"
        case .tab: "Switch to Tab"
        case .action: "Run"
        case .history: "Open"
        }
    }
}
