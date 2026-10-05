import AxoPersistence
import Foundation
import GRDB

/// A rule that opens links from other apps in a chosen Space.
public struct LinkRoute: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "linkRoute"

    /// What the rule matches.
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Links sent by an app, matched by bundle ID.
        case app
        /// Links to a domain or any of its subdomains.
        case domain
    }

    public var id: UUID
    public var kind: Kind
    /// The app's bundle ID, or the lowercased domain.
    public var value: String
    /// The app's name, for app rules. Empty for domain rules.
    public var displayName: String
    /// The Space matching links open in.
    public var spaceID: Space.ID
    public var createdAt: Date

    /// Creates a rule.
    public init(id: UUID = UUID(), kind: Kind, value: String, displayName: String = "", spaceID: Space.ID, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.value = value
        self.displayName = displayName
        self.spaceID = spaceID
        self.createdAt = createdAt
    }

    /// Column names, for building queries.
    public enum Columns {
        public static let kind = Column(CodingKeys.kind)
        public static let value = Column(CodingKeys.value)
        public static let createdAt = Column(CodingKeys.createdAt)
    }

    /// Turns what someone typed (`GitHub.com`, `https://www.github.com/axo`, `.github.com`) into
    /// a domain for a rule (`github.com`), or `nil` if it isn't one.
    public static func normalizedDomain(from text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if candidate.contains("://") {
            // A full address: use its host, if it has one.
            guard let host = URL(string: candidate)?.host() else { return nil }
            candidate = host
        } else if let slash = candidate.firstIndex(of: "/") {
            candidate = String(candidate[..<slash])
        }
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if candidate.hasPrefix("www.") { candidate.removeFirst(4) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:"))
        guard !candidate.isEmpty, candidate.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return candidate
    }

    /// The rule a link from another app follows, if any.
    ///
    /// Domain rules come first, and the most specific domain wins (`docs.example.com` over
    /// `example.com`). Otherwise a rule for the app that sent the link applies.
    public static func route(for url: URL, from sourceBundleID: String?, in routes: [LinkRoute]) -> LinkRoute? {
        if let host = url.host()?.lowercased() {
            let matches = routes.filter { $0.kind == .domain && (host == $0.value || host.hasSuffix("." + $0.value)) }
            if let best = matches.max(by: { $0.value.count < $1.value.count }) { return best }
        }
        guard let sourceBundleID else { return nil }
        return routes.first { $0.kind == .app && $0.value == sourceBundleID }
    }
}

/// Errors thrown by ``LinkRouteStore``.
public enum LinkRouteError: Error, Equatable {
    /// There's already a rule for this app or domain.
    case duplicate
}

/// Saves link routing rules, in the same database as the sidebar.
public final class LinkRouteStore: Sendable {
    private let database: AppDatabase

    /// Creates a store over `database`. Usually reached through ``TabStore/linkRoutes``.
    public init(database: AppDatabase) {
        self.database = database
    }

    /// Every rule, oldest first.
    public func routes() async throws -> [LinkRoute] {
        try await database.writer.read { db in try Self.orderedRoutes.fetchAll(db) }
    }

    /// Rules oldest first. Rules saved within the same instant keep the order they were added
    /// (row ID), not the order of their text.
    private static let orderedRoutes = LinkRoute.order(LinkRoute.Columns.createdAt, Column.rowID)

    /// Streams every rule: the current list first, then a new list after every change.
    public func observeRoutes() -> AsyncValueObservation<[LinkRoute]> {
        ValueObservation
            .tracking { db in try Self.orderedRoutes.fetchAll(db) }
            .values(in: database.writer)
    }

    /// Adds a rule.
    ///
    /// - Throws: ``LinkRouteError/duplicate`` if there's already a rule for the same app or
    ///   domain, or ``TabStoreError/spaceNotFound(_:)``.
    @discardableResult
    public func add(_ kind: LinkRoute.Kind, value: String, displayName: String = "", spaceID: Space.ID, at date: Date = Date()) async throws -> LinkRoute {
        try await database.writer.write { db in
            guard try Space.exists(db, id: spaceID) else { throw TabStoreError.spaceNotFound(spaceID) }
            let duplicate = try LinkRoute.filter(LinkRoute.Columns.kind == kind.rawValue).filter(LinkRoute.Columns.value == value).fetchCount(db) > 0
            guard !duplicate else { throw LinkRouteError.duplicate }
            let route = LinkRoute(kind: kind, value: value, displayName: displayName, spaceID: spaceID, createdAt: date)
            try route.insert(db)
            return route
        }
    }

    /// Sends a rule's links to another Space.
    public func setSpace(_ spaceID: Space.ID, for id: LinkRoute.ID) async throws {
        try await database.writer.write { db in
            guard try Space.exists(db, id: spaceID) else { throw TabStoreError.spaceNotFound(spaceID) }
            guard var route = try LinkRoute.fetchOne(db, id: id) else { return }
            route.spaceID = spaceID
            try route.update(db)
        }
    }

    /// Deletes a rule.
    public func delete(_ id: LinkRoute.ID) async throws {
        _ = try await database.writer.write { db in
            try LinkRoute.deleteOne(db, id: id)
        }
    }
}

extension TabStore {
    /// Link routing rules, in the same database as the sidebar.
    public var linkRoutes: LinkRouteStore {
        LinkRouteStore(database: database)
    }
}
