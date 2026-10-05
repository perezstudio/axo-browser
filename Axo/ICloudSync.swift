import AppKit
import AxoSync
import AxoUI
import CloudKit
import Foundation
import Observation

/// Runs iCloud sync for the app and backs the iCloud pane in Settings.
///
/// Sync runs only in builds signed with the iCloud entitlement (Release builds, through
/// `Axo-Release.entitlements`), never in UI testing, and only while the person has it on and is
/// signed in to iCloud.
@MainActor
@Observable
final class ICloudSyncController: SyncControlling {
    /// Axo's CloudKit container.
    static let containerIdentifier = "iCloud.com.perezstudio.Axo"
    /// Whether sync is on, in `UserDefaults`. Missing means on.
    static let enabledKey = "iCloudSyncEnabled"

    private(set) var status: SyncStatus
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            Task { await refresh() }
        }
    }

    @ObservationIgnored private let store: SyncStore
    @ObservationIgnored private let isAvailable: Bool
    @ObservationIgnored private var sync: CloudKitSync?
    @ObservationIgnored private var lastSynced: Date?
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?

    init(store: SyncStore, isAvailable: Bool) {
        self.store = store
        self.isAvailable = isAvailable
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        status = isAvailable ? .off : .unavailable
        guard isAvailable else { return }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// Starts or stops sync to match the setting and the iCloud account.
    func refresh() async {
        guard isAvailable else { return }
        guard isEnabled else {
            stopSyncing()
            status = .off
            return
        }
        let container = CKContainer(identifier: Self.containerIdentifier)
        do {
            guard try await container.accountStatus() == .available else {
                stopSyncing()
                status = .noAccount
                return
            }
            if sync == nil {
                let sync = CloudKitSync(store: store, database: container.privateCloudDatabase) { [weak self] date in
                    self?.lastSynced = date
                    if self?.isEnabled == true { self?.status = .on(lastSynced: date) }
                }
                self.sync = sync
                // The engine learns about other devices' changes through push notifications.
                NSApplication.shared.registerForRemoteNotifications()
                try await sync.start()
            }
            status = .on(lastSynced: lastSynced)
        } catch {
            status = .failed("Axo couldn't reach iCloud. \(error.localizedDescription)")
        }
    }

    func syncNow() async {
        do {
            try await sync?.syncNow()
        } catch {
            status = .failed("Axo couldn't sync. \(error.localizedDescription)")
        }
    }

    private func stopSyncing() {
        sync?.stop()
        sync = nil
    }
}
