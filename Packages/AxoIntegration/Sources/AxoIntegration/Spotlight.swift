import AxoCore
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// One thing Axo puts in Spotlight: a pinned tab or a page from history.
public struct SpotlightEntry: Hashable, Sendable {
    /// Identifies the result when the person opens it. See ``SpotlightTarget``.
    public var identifier: String
    /// The group it belongs to, so a whole group can be replaced at once.
    public var domain: String
    public var title: String
    public var url: URL
    /// A second line, such as "Pinned in Work".
    public var detail: String
    public var lastUsed: Date?
}

/// Where a Spotlight result goes when it's opened.
public enum SpotlightTarget: Equatable, Sendable {
    /// A pinned tab, shown in its Space.
    case tab(Tab.ID)
    /// A page from history, opened in a new tab.
    case page(URL)

    /// The target for a result's identifier, or `nil` if it isn't one of Axo's.
    public init?(identifier: String) {
        if identifier.hasPrefix("tab:"), let id = UUID(uuidString: String(identifier.dropFirst(4))) {
            self = .tab(id)
        } else if identifier.hasPrefix("page:"), let url = URL(string: String(identifier.dropFirst(5))) {
            self = .page(url)
        } else {
            return nil
        }
    }
}

/// Where Spotlight entries go. The real one is the system's Core Spotlight index; tests use a fake.
public protocol SpotlightIndex: Sendable {
    /// Replaces everything in `domain` with `entries`.
    func replace(domain: String, with entries: [SpotlightEntry]) async throws
}

/// The system's Core Spotlight index.
public struct SystemSpotlightIndex: SpotlightIndex {
    public init() {}

    public func replace(domain: String, with entries: [SpotlightEntry]) async throws {
        let index = CSSearchableIndex.default()
        try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
        guard !entries.isEmpty else { return }
        let items = entries.map { entry in
            let attributes = CSSearchableItemAttributeSet(contentType: .url)
            attributes.title = entry.title
            attributes.contentDescription = entry.detail
            attributes.url = entry.url
            attributes.contentURL = entry.url
            attributes.lastUsedDate = entry.lastUsed
            return CSSearchableItem(uniqueIdentifier: entry.identifier, domainIdentifier: entry.domain, attributeSet: attributes)
        }
        try await index.indexSearchableItems(items)
    }
}

/// Keeps Spotlight showing Axo's pinned tabs (from every Space) and recent history, so they can be
/// found and opened from system search. It rebuilds Axo's entries a moment after the data changes.
@MainActor
public final class SpotlightIndexer {
    /// The group for pinned tabs.
    public nonisolated static let pinnedTabsDomain = "com.perezstudio.Axo.pinnedTabs"
    /// The group for history.
    public nonisolated static let historyDomain = "com.perezstudio.Axo.history"

    private let store: TabStore
    private let index: any SpotlightIndex
    private let historyLimit: Int
    private let delay: Duration
    private var observation: Task<Void, Never>?
    private var pending: Task<Void, Never>?

    /// Creates an indexer. Call ``start()`` to begin.
    ///
    /// - Parameters:
    ///   - historyLimit: How many of the most recently visited pages to include.
    ///   - delay: How long to wait after a change before rebuilding, so a burst of visits rebuilds
    ///     once.
    public init(store: TabStore, index: any SpotlightIndex = SystemSpotlightIndex(), historyLimit: Int = 500, delay: Duration = .seconds(5)) {
        self.store = store
        self.index = index
        self.historyLimit = historyLimit
        self.delay = delay
    }

    /// Indexes the current content, then keeps the index current until ``stop()``.
    public func start() {
        observation?.cancel()
        let updates = store.observeSearchableContent(historyLimit: historyLimit)
        observation = Task { [weak self] in
            do {
                for try await content in updates {
                    self?.schedule(content)
                }
            } catch {}
        }
    }

    /// Stops keeping the index current.
    public func stop() {
        observation?.cancel()
        pending?.cancel()
    }

    private func schedule(_ content: SearchableContent) {
        pending?.cancel()
        let index = index
        let delay = delay
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            try? await index.replace(domain: Self.pinnedTabsDomain, with: Self.pinnedEntries(content))
            try? await index.replace(domain: Self.historyDomain, with: Self.historyEntries(content))
        }
    }

    /// Entries for pinned tabs.
    nonisolated static func pinnedEntries(_ content: SearchableContent) -> [SpotlightEntry] {
        content.pinnedTabs.map { pinned in
            let url = pinned.tab.homeURL ?? pinned.tab.url
            return SpotlightEntry(
                identifier: "tab:\(pinned.tab.id.uuidString)",
                domain: pinnedTabsDomain,
                title: pinned.tab.title.isEmpty ? (url.host() ?? url.absoluteString) : pinned.tab.title,
                url: url,
                detail: "Pinned in \(pinned.spaceName)",
                lastUsed: pinned.tab.lastActiveAt
            )
        }
    }

    /// Entries for history pages that aren't already there as pinned tabs.
    nonisolated static func historyEntries(_ content: SearchableContent) -> [SpotlightEntry] {
        let pinnedURLs = Set(content.pinnedTabs.flatMap { [$0.tab.url, $0.tab.homeURL].compactMap { $0 } })
        return content.history
            .filter { !pinnedURLs.contains($0.item.url) }
            .map { page in
                SpotlightEntry(
                    identifier: "page:\(page.item.url.absoluteString)",
                    domain: historyDomain,
                    title: page.item.title.isEmpty ? (page.item.url.host() ?? page.item.url.absoluteString) : page.item.title,
                    url: page.item.url,
                    detail: page.item.url.host() ?? page.item.url.absoluteString,
                    lastUsed: page.item.lastVisitedAt
                )
            }
    }
}
