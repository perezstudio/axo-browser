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
    /// These pages have no visits left in the engine's copy. With a range, only visits in it
    /// were deleted, so a page Axo last saw outside it keeps its history.
    case deleted([URL], in: ClosedRange<Date>?)
    /// All history was deleted.
    case deletedAll

    /// The engine's change, or `nil` for one Axo doesn't know, which it leaves alone.
    @MainActor init?(_ change: any AXOHistoryChange) {
        switch change.kind {
        case .visited:
            guard let url = change.urls.first else { return nil }
            self = .visited(url, title: change.title, at: change.date ?? Date())
        case .deleted:
            let range = change.date.flatMap { start in change.endDate.map { end in min(start, end)...max(start, end) } }
            self = .deleted(change.urls, in: range)
        case .deletedAll:
            self = .deletedAll
        @unknown default:
            return nil
        }
    }
}
