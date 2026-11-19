import AppKit
import AxoSync
import AxoUI
import CloudKit
import Foundation
import Observation

/// Runs iCloud sync for the app and backs the iCloud pane in Settings.
///
/// Sync runs only in builds signed with the iCloud entitlement (Release builds, through
/// `Axo-Release.entitlements`), never in test runs, and only while the person has it on and is
/// signed in to iCloud.
@MainActor
@Observable
final class ICloudSyncController: SyncControlling {
    /// Axo's CloudKit container.
    static let containerIdentifier = "iCloud.com.perezstudio.Axo"
    /// Whether sync is on, in `UserDefaults`. Missing means on.
    static let enabledKey = "iCloudSyncEnabled"

    /// Where sync stands, from what the controller knows (``status(isAvailable:isEnabled:isSignedIn:hasFinishedFirstSync:lastSynced:problem:)``).
    var status: SyncStatus {
        Self.status(
            isAvailable: isAvailable, isEnabled: isEnabled, isSignedIn: isSignedIn,
            hasFinishedFirstSync: hasFinishedFirstSync, lastSynced: lastSynced, problem: problem
        )
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            Task { await refresh() }
        }
    }

    /// Whether an iCloud account is signed in; `nil` until asked.
    private var isSignedIn: Bool?
    /// Whether this Mac finished its first sync with the account.
    private var hasFinishedFirstSync = false
    private var lastSynced: Date?
    /// The last problem, until a sync finishes.
    private var problem: SyncProblem?

    @ObservationIgnored private let store: SyncStore
    @ObservationIgnored private let isAvailable: Bool
    @ObservationIgnored private var sync: CloudKitSync?
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?
    /// Told the names of Spaces that arrive through iCloud (``BrowserModel/spacesArrivedThroughSync(_:)``).
    @ObservationIgnored var onSpacesArrived: @MainActor ([String]) -> Void = { _ in }

    init(store: SyncStore, isAvailable: Bool) {
        self.store = store
        self.isAvailable = isAvailable
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        guard isAvailable else { return }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// The pane's state (#174), in order: a build that can't sync, sync turned off, an account
    /// signed out (also when CloudKit says so), storage full, another problem, the first sync
    /// still running, and up to date.
    static func status(
        isAvailable: Bool, isEnabled: Bool, isSignedIn: Bool?, hasFinishedFirstSync: Bool, lastSynced: Date?, problem: SyncProblem?
    ) -> SyncStatus {
        guard isAvailable else { return .unavailable }
        guard isEnabled else { return .off }
        if isSignedIn == false || problem == .signedOut { return .paused(.signedOut) }
        switch problem {
        case .storageFull: return .paused(.storageFull)
        case .other(let code, let description): return .failed(details: "\(description) (CloudKit error \(code))")
        case .signedOut, nil: break
        }
        guard isSignedIn == true, hasFinishedFirstSync else { return .settingUp }
        return .upToDate(lastSynced: lastSynced)
    }

    /// Starts or stops sync to match the setting and the iCloud account.
    func refresh() async {
        guard isAvailable else { return }
        guard isEnabled else {
            stopSyncing()
            problem = nil
            return
        }
        let container = CKContainer(identifier: Self.containerIdentifier)
        do {
            guard try await container.accountStatus() == .available else {
                stopSyncing()
                isSignedIn = false
                return
            }
            isSignedIn = true
            if problem == .signedOut { problem = nil }
            if sync == nil {
                let store = store
                let sync = CloudKitSync(
                    store: store, database: container.privateCloudDatabase,
                    onSynced: { [weak self] date in
                        guard let self else { return }
                        lastSynced = date
                        problem = nil
                        Task { self.hasFinishedFirstSync = (try? await store.hasFinishedFirstSync()) ?? false }
                    },
                    onProblem: { [weak self] in self?.problem = $0 },
                    onSpacesArrived: { [weak self] in self?.onSpacesArrived($0) }
                )
                self.sync = sync
                // The engine learns about other devices' changes through push notifications.
                NSApplication.shared.registerForRemoteNotifications()
                try await sync.start()
            }
            hasFinishedFirstSync = (try? await store.hasFinishedFirstSync()) ?? false
        } catch {
            problem = SyncProblem.from(error)
        }
    }

    func syncNow() async {
        do {
            try await sync?.syncNow()
        } catch {
            let found = SyncProblem.from(error)
            if !found.isTransient { problem = found }
        }
    }

    /// System Settings' Apple Account pane, where the person signs in to iCloud. Opening it
    /// changes nothing.
    func openAccountSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The same pane, which leads to iCloud storage.
    func openStorageSettings() {
        openAccountSettings()
    }

    private func stopSyncing() {
        sync?.stop()
        sync = nil
    }
}
