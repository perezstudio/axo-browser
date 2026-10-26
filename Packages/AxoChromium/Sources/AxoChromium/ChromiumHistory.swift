import AxoEngineAPI
import Foundation

/// A change to a profile's history that the engine made without a page visit, for
/// ``ChromiumEngine/onHistoryChange``.
///
/// The engine keeps its own copy of history, recording page visits itself, because visited links,
/// `chrome.history`, and `chrome.topSites` come from it. Axo records the same visits in its own
/// history; these are the other changes, which Axo applies so the two stay in step.
public enum ChromiumHistoryChange: Hashable, Sendable {
    /// An extension added a visit (`chrome.history.addUrl`).
    case visited(URL, title: String, at: Date)
    /// These pages have no visits left.
    case deleted([URL])
    /// All history was deleted.
    case deletedAll

    @MainActor init(_ change: any AXOHistoryChange) {
        switch change.kind {
        case .visited:
            if let url = change.urls.first {
                self = .visited(url, title: change.title, at: change.date ?? Date())
            } else {
                self = .deleted([])
            }
        case .deletedAll:
            self = .deletedAll
        default:
            self = .deleted(change.urls)
        }
    }
}
