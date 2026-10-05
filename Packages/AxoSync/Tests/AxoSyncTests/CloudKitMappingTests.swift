import CloudKit
import Foundation
import Testing
@testable import AxoSync

/// The CloudKit side's record mapping. These build `CKRecord`s locally and never reach iCloud.
struct CloudKitMappingTests {
    let tab = SyncRecord(
        id: SyncRecordID(.tab, UUID()),
        fields: ["spaceID": UUID().uuidString.lowercased(), "url": "https://example.com/", "title": "Example", "sortKey": "a0"],
        modifiedAt: Date(timeIntervalSince1970: 1_800_000_000.123)
    )

    @Test func recordNamesSayWhatTheyAre() throws {
        let id = SyncRecordID(.folder, UUID())
        #expect(id.recordName == "Folder.\(id.id.uuidString.lowercased())")
        #expect(SyncRecordID(recordName: id.recordName) == id)
        #expect(SyncRecordID(recordName: "Folder") == nil)
        #expect(SyncRecordID(recordName: "Window.\(id.id.uuidString)") == nil)

        let recordID = CloudKitSync.recordID(for: id)
        #expect(recordID.zoneID.zoneName == "Axo")
        #expect(CloudKitSync.syncRecordID(recordID: recordID) == id)
        #expect(CloudKitSync.syncRecordID(recordID: CKRecord.ID(recordName: id.recordName)) == nil, "Only Axo's zone")
    }

    @Test func recordsRoundTripThroughCloudKitRecords() throws {
        let ckRecord = CloudKitSync.ckRecord(from: StampedSyncRecord(record: tab, systemFields: nil))
        #expect(ckRecord.recordType == "Tab")
        #expect(ckRecord["url"] as? String == "https://example.com/")
        #expect(ckRecord["folderID"] == nil, "Missing fields stay empty")

        let back = try #require(CloudKitSync.stampedRecord(from: ckRecord))
        #expect(back.record == tab)
        #expect(back.systemFields != nil)
    }

    @Test func outgoingRecordsKeepTheirSystemFields() throws {
        let first = CloudKitSync.ckRecord(from: StampedSyncRecord(record: tab, systemFields: nil))
        let systemFields = CloudKitSync.systemFields(of: first)
        var renamed = tab
        renamed.fields["title"] = "Renamed"
        let second = CloudKitSync.ckRecord(from: StampedSyncRecord(record: renamed, systemFields: systemFields))
        #expect(second.recordID == first.recordID)
        #expect(second["title"] as? String == "Renamed")
        #expect(CloudKitSync.record(fromSystemFields: Data("junk".utf8)) == nil)
    }

    @Test func recordsOfAnotherTypeOrZoneAreIgnored() {
        let wrongType = CKRecord(recordType: "Space", recordID: CloudKitSync.recordID(for: tab.id))
        #expect(CloudKitSync.stampedRecord(from: wrongType) == nil)
        let elsewhere = CKRecord(recordType: "Tab", recordID: CKRecord.ID(recordName: tab.id.recordName))
        #expect(CloudKitSync.stampedRecord(from: elsewhere) == nil)
    }

    @Test func unsignedBuildsDontSync() {
        // Test runners aren't signed with Axo's iCloud entitlement.
        #expect(!CloudKitSync.isAvailable(containerIdentifier: "iCloud.com.perezstudio.Axo"))
    }
}
