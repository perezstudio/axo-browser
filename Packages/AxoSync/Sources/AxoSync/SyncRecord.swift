import Foundation

/// The kinds of rows that sync, in the order a parent comes before its children.
public enum SyncRecordType: String, CaseIterable, Codable, Comparable, Sendable {
    case profile = "Profile"
    case space = "Space"
    case folder = "Folder"
    case tab = "Tab"

    /// The database table the rows live in.
    var table: String {
        switch self {
        case .profile: "profile"
        case .space: "space"
        case .folder: "folder"
        case .tab: "tab"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Identifies a synced row: its kind and its UUID. Its CloudKit record name holds both, so a
/// record ID alone (such as a deleted record's) says what it is.
public struct SyncRecordID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var type: SyncRecordType
    public var id: UUID

    public init(_ type: SyncRecordType, _ id: UUID) {
        self.type = type
        self.id = id
    }

    /// The CloudKit record name: the type and the lowercase UUID, as in `Tab.0f8f…`.
    public var recordName: String { "\(type.rawValue).\(id.uuidString.lowercased())" }

    /// Reads a CloudKit record name made by ``recordName``.
    public init?(recordName: String) {
        let parts = recordName.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let type = SyncRecordType(rawValue: String(parts[0])),
              let id = UUID(uuidString: String(parts[1])) else { return nil }
        self.init(type, id)
    }

    public var description: String { recordName }
}

/// A synced row's values, independent of CloudKit.
///
/// Fields hold text: names, sort keys, URLs, and other rows' IDs (as lowercase UUIDs). A field
/// that's missing means no value, such as a folder at the top level having no `parentID`.
///
/// | Type | Fields |
/// | --- | --- |
/// | Profile | `name` |
/// | Space | `profileID`, `name`, `sortKey` |
/// | Folder | `spaceID`, `parentID`, `name`, `sortKey` |
/// | Tab (pinned) | `spaceID`, `folderID`, `url` (its home page), `title`, `sortKey` |
public struct SyncRecord: Equatable, Codable, Sendable {
    public var id: SyncRecordID
    public var fields: [String: String]
    /// When the change this record carries was made, which settles conflicts: the later
    /// change wins.
    public var modifiedAt: Date

    public init(id: SyncRecordID, fields: [String: String], modifiedAt: Date) {
        self.id = id
        self.fields = fields
        self.modifiedAt = modifiedAt
    }

    /// The field names each type uses.
    public static func fieldNames(for type: SyncRecordType) -> [String] {
        switch type {
        case .profile: ["name"]
        case .space: ["profileID", "name", "sortKey"]
        case .folder: ["spaceID", "parentID", "name", "sortKey"]
        case .tab: ["spaceID", "folderID", "url", "title", "sortKey"]
        }
    }

    /// A field that holds another row's ID.
    func uuid(_ field: String) -> UUID? {
        fields[field].flatMap(UUID.init(uuidString:))
    }
}

/// A record and the CloudKit system fields (change tag and so on) it was last seen with.
public struct StampedSyncRecord: Equatable, Sendable {
    public var record: SyncRecord
    /// CloudKit's archived system fields, opaque to everything but the CloudKit adapter.
    /// `nil` for a record never sent or received.
    public var systemFields: Data?

    public init(record: SyncRecord, systemFields: Data?) {
        self.record = record
        self.systemFields = systemFields
    }
}

/// A local change waiting to be sent.
public struct PendingSyncChange: Equatable, Sendable {
    public var id: SyncRecordID
    /// Whether the row was deleted (or, for a tab, unpinned).
    public var isDeletion: Bool
    /// When the change was made.
    public var changedAt: Date

    public init(id: SyncRecordID, isDeletion: Bool, changedAt: Date) {
        self.id = id
        self.isDeletion = isDeletion
        self.changedAt = changedAt
    }
}
