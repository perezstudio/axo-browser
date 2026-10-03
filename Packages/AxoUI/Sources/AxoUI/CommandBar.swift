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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return tabs.prefix(maxTabs * 2).map(CommandResult.tab)
        }
        var results: [CommandResult] = []
        if let url = AddressInput.url(from: trimmed) {
            let isSearch = url.host() == AddressInput.searchURL.host() && !trimmed.contains(".")
            results.append(.open(url, isSearch: isSearch, text: trimmed))
        }
        results += tabs
            .filter { matches(trimmed, in: "\($0.title) \($0.url.absoluteString)") }
            .prefix(maxTabs)
            .map(CommandResult.tab)
        results += availableActions
            .filter { matches(trimmed, in: $0.title) }
            .prefix(maxActions)
            .map(CommandResult.action)
        return results
    }

    /// History results to add, skipping pages already open as tabs.
    static func historyResults(_ items: [HistoryItem], excludingOpen tabs: [AxoCore.Tab]) -> [CommandResult] {
        let open = Set(tabs.map(\.url))
        return items.filter { !open.contains($0.url) }.prefix(maxHistory).map(CommandResult.history)
    }
}
