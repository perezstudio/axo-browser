import AxoPersistence
import Foundation
import GRDB

/// Custom CSS and JavaScript for a site: a domain and its subdomains, in every profile.
public struct SiteCustomization: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "siteCustomization"

    public var id: UUID
    /// The lowercased domain, such as `example.com`. Subdomains are included.
    public var domain: String
    /// CSS added to the site's pages before they render.
    public var css: String
    /// JavaScript run in the site's pages once they load.
    public var js: String
    /// Whether it applies. Turning it off keeps the code.
    public var isEnabled: Bool
    public var updatedAt: Date

    /// Creates a customization.
    public init(id: UUID = UUID(), domain: String, css: String = "", js: String = "", isEnabled: Bool = true, updatedAt: Date = Date()) {
        self.id = id
        self.domain = domain
        self.css = css
        self.js = js
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }

    /// Column names, for building queries.
    public enum Columns {
        public static let domain = Column(CodingKeys.domain)
    }

    /// The customization for a page's host: the enabled one for the most specific matching
    /// domain (`docs.example.com` over `example.com`), if any.
    public static func best(forHost host: String, in customizations: [SiteCustomization]) -> SiteCustomization? {
        let host = host.lowercased()
        return customizations
            .filter { $0.isEnabled && (host == $0.domain || host.hasSuffix("." + $0.domain)) }
            .max { $0.domain.count < $1.domain.count }
    }
}

/// Errors thrown by ``SiteCustomizationStore``.
public enum SiteCustomizationError: Error, Equatable {
    /// The text isn't a domain.
    case invalidDomain(String)
    /// Another customization already uses this domain.
    case duplicate(String)
}

/// Saves per-site custom CSS and JavaScript, in the same database as the sidebar.
public final class SiteCustomizationStore: Sendable {
    private let database: AppDatabase

    /// Creates a store over `database`. Usually reached through ``TabStore/siteCustomizations``.
    public init(database: AppDatabase) {
        self.database = database
    }

    /// Every customization, by domain.
    public func all() async throws -> [SiteCustomization] {
        try await database.writer.read { db in
            try SiteCustomization.order(SiteCustomization.Columns.domain).fetchAll(db)
        }
    }

    /// Streams every customization: the current list first, then a new list after every change.
    public func observe() -> AsyncValueObservation<[SiteCustomization]> {
        ValueObservation
            .tracking { db in try SiteCustomization.order(SiteCustomization.Columns.domain).fetchAll(db) }
            .values(in: database.writer)
    }

    /// Saves a customization: a new one, or changes to the one with `customization.id`. The
    /// domain is normalized first (`https://www.Example.com/x` becomes `example.com`).
    ///
    /// - Returns: The saved customization.
    /// - Throws: ``SiteCustomizationError``.
    @discardableResult
    public func save(_ customization: SiteCustomization, at date: Date = Date()) async throws -> SiteCustomization {
        guard let domain = LinkRoute.normalizedDomain(from: customization.domain) else {
            throw SiteCustomizationError.invalidDomain(customization.domain)
        }
        var normalized = customization
        normalized.domain = domain
        normalized.updatedAt = date
        let saved = normalized
        return try await database.writer.write { db in
            let clash = try SiteCustomization
                .filter(SiteCustomization.Columns.domain == domain)
                .fetchOne(db)
            if let clash, clash.id != saved.id { throw SiteCustomizationError.duplicate(domain) }
            try saved.save(db)
            return saved
        }
    }

    /// Turns a customization on or off.
    public func setEnabled(_ enabled: Bool, id: SiteCustomization.ID) async throws {
        try await database.writer.write { db in
            guard var customization = try SiteCustomization.fetchOne(db, id: id) else { return }
            customization.isEnabled = enabled
            try customization.update(db)
        }
    }

    /// Deletes a customization.
    public func delete(_ id: SiteCustomization.ID) async throws {
        _ = try await database.writer.write { db in
            try SiteCustomization.deleteOne(db, id: id)
        }
    }
}

extension TabStore {
    /// Per-site custom CSS and JavaScript, in the same database as the sidebar.
    public var siteCustomizations: SiteCustomizationStore {
        SiteCustomizationStore(database: database)
    }
}
