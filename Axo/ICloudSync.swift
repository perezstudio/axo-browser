import AppKit
import AxoSync
import AxoUI
import CloudKit
import Foundation
import Observation

/// What the iCloud pane shows, as a state machine over what happens (#174): the switch, the
/// iCloud account, the sync engine's events, and failures starting it. Pure, so tests replay
/// event sequences without iCloud.
struct ICloudSyncState: Equatable {
    /// The iCloud account, as far as Axo knows.
    enum Account: Equatable {
        /// Not known yet, or CloudKit couldn't tell (it's asked again).
        case unknown
        case available
        /// No account, or one that needs signing in again.
        case signedOut
        /// Screen Time or a management profile keeps Axo from iCloud.
        case restricted
    }

    /// Something that happened.
    enum Event: Equatable {
        case turnedOn
        case turnedOff
        /// CloudKit's answer about the account.
        case account(CKAccountStatus)
        /// The system says the account changed; the first sync runs again with it.
        case accountChanged
        /// Starting the engine or syncing failed.
        case failed(SyncProblem)
        /// The engine reported something.
        case engine(SyncEngineEvent)
        /// Whether the first sync with the account has finished, read from the store.
        case firstSync(finished: Bool)
    }

    var isAvailable: Bool
    var isEnabled: Bool
    var account: Account = .unknown
    var hasFinishedFirstSync = false
    var lastSynced: Date?
    /// The last problem the person can act on, until a send reaches iCloud without one.
    var problem: SyncProblem?

    mutating func handle(_ event: Event) {
        switch event {
        case .turnedOn:
            isEnabled = true
            problem = nil
        case .turnedOff:
            isEnabled = false
            problem = nil
        case .account(let status):
            switch status {
            case .available:
                account = .available
                if problem == .signedOut { problem = nil }
            case .noAccount, .temporarilyUnavailable:
                account = .signedOut
            case .restricted:
                account = .restricted
            default:
                // .couldNotDetermine: unknown until asked again.
                account = .unknown
            }
        case .accountChanged:
            hasFinishedFirstSync = false
        case .failed(let found):
            if !found.isTransient { problem = found }
        case .engine(.fetched(let date)):
            lastSynced = date
        case .engine(.sent(let date, nil)):
            // Changes reached iCloud: whatever stopped them before is over.
            lastSynced = date
            problem = nil
        case .engine(.sent(_, let found?)):
            problem = found
        case .engine(.startedOver):
            hasFinishedFirstSync = false
        case .engine(.spacesArrived):
            break
        case .firstSync(let finished):
            hasFinishedFirstSync = finished
        }
    }

    /// The pane's state, in order: a build that can't sync, sync turned off, the account
    /// signed out or restricted (also when CloudKit says so), storage full, another problem,
    /// the first sync still running (or the account not known yet), and up to date.
    var status: SyncStatus {
        guard isAvailable else { return .unavailable }
        guard isEnabled else { return .off }
        if account == .signedOut || problem == .signedOut { return .paused(.signedOut) }
        if account == .restricted { return .paused(.restricted) }
        switch problem {
        case .storageFull: return .paused(.storageFull)
        case .other(let domain, let code, let description):
            let source = domain == CKErrorDomain ? "CloudKit error" : "\(domain) error"
            return .failed(details: "\(description) (\(source) \(code))")
        case .signedOut, nil: break
        }
        guard account == .available, hasFinishedFirstSync else { return .settingUp }
        return .upToDate(lastSynced: lastSynced)
    }
}

/// Runs iCloud sync for the app and backs the iCloud pane in Settings.
///
/// Sync runs only in builds signed with the iCloud entitlement (Release builds, through
/// `Axo-Release.entitlements`), never in test runs, and only while the person has it on and is
/// signed in to iCloud. What the pane shows is ``ICloudSyncState``, fed by this controller.
@MainActor
@Observable
final class ICloudSyncController: SyncControlling {
    /// Axo's CloudKit container.
    static let containerIdentifier = "iCloud.com.perezstudio.Axo"
    /// Whether sync is on, in `UserDefaults`. Missing means on.
    static let enabledKey = "iCloudSyncEnabled"
    /// When Axo last synced, in `UserDefaults`, so the pane says so after a relaunch.
    static let lastSyncedKey = "iCloudLastSynced"
    /// How long to wait before asking iCloud again after it couldn't say or couldn't be reached.
    static let retryDelay: Duration = .seconds(60)

    private var state: ICloudSyncState

    var status: SyncStatus { state.status }

    var isEnabled: Bool {
        get { state.isEnabled }
        set {
            guard newValue != state.isEnabled else { return }
            state.handle(newValue ? .turnedOn : .turnedOff)
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            Task { await refresh() }
        }
    }

    @ObservationIgnored private let store: SyncStore
    @ObservationIgnored private var sync: CloudKitSync?
    /// Bumped whenever the engine stops, so a stopped engine's late reports are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// Told the names of Spaces that arrive through iCloud (``BrowserModel/spacesArrivedThroughSync(_:)``).
    @ObservationIgnored var onSpacesArrived: @MainActor ([String]) -> Void = { _ in }

    init(store: SyncStore, isAvailable: Bool) {
        self.store = store
        state = ICloudSyncState(
            isAvailable: isAvailable,
            isEnabled: UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true,
            lastSynced: isAvailable ? UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date : nil
        )
        guard isAvailable else { return }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.state.handle(.accountChanged)
                await self?.refresh()
            }
        }
    }

    /// Starts or stops sync to match the setting and the iCloud account.
    func refresh() async {
        guard state.isAvailable else { return }
        retry?.cancel()
        guard state.isEnabled else {
            stopSyncing()
            return
        }
        let container = CKContainer(identifier: Self.containerIdentifier)
        do {
            let account = try await container.accountStatus()
            // Turned off while asking: don't start.
            guard state.isEnabled else { return }
            state.handle(.account(account))
            guard account == .available else {
                stopSyncing()
                if account == .couldNotDetermine { retryLater() }
                return
            }
            if sync == nil {
                let generation = generation
                let sync = CloudKitSync(store: store, database: container.privateCloudDatabase) { [weak self] event in
                    guard let self, self.generation == generation else { return }
                    self.handle(event)
                }
                self.sync = sync
                // The engine learns about other devices' changes through push notifications.
                NSApplication.shared.registerForRemoteNotifications()
                do {
                    try await sync.start()
                } catch {
                    stopSyncing()
                    throw error
                }
            }
            state.handle(.firstSync(finished: (try? await store.hasFinishedFirstSync()) ?? false))
        } catch {
            let problem = SyncProblem.from(error)
            state.handle(.failed(problem))
            if problem.isTransient { retryLater() }
        }
    }

    private func handle(_ event: SyncEngineEvent) {
        state.handle(.engine(event))
        switch event {
        case .fetched(let date), .sent(let date, nil):
            UserDefaults.standard.set(date, forKey: Self.lastSyncedKey)
            Task { [store] in
                let finished = (try? await store.hasFinishedFirstSync()) ?? false
                self.state.handle(.firstSync(finished: finished))
            }
        case .spacesArrived(let names):
            onSpacesArrived(names)
        case .sent, .startedOver:
            break
        }
    }

    /// Sync Now and Try Again: syncs if the engine is running, or starts it again if it isn't
    /// (it failed to start, or iCloud couldn't be reached).
    func syncNow() async {
        guard let sync else {
            await refresh()
            return
        }
        do {
            try await sync.syncNow()
        } catch {
            state.handle(.failed(SyncProblem.from(error)))
        }
    }

    private func retryLater() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// System Settings' Apple Account pane, where the person signs in to iCloud. Opening it
    /// changes nothing.
    func openAccountSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The same pane, which leads on to iCloud and its storage (System Settings has no public
    /// link to the storage page itself).
    func openStorageSettings() {
        openAccountSettings()
    }

    private func stopSyncing() {
        sync?.stop()
        sync = nil
        generation += 1
    }
}
