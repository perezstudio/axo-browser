import SwiftUI

/// Why iCloud sync is paused until the person acts.
public enum SyncPause: Equatable, Sendable {
    /// No iCloud account is signed in, or it needs signing in again.
    case signedOut
    /// The person's iCloud storage is full.
    case storageFull
    /// Screen Time or a management profile keeps Axo from iCloud on this Mac.
    case restricted
}

/// Where iCloud sync stands, for the iCloud pane in Settings (#174), as the iCloud sync board
/// draws it.
public enum SyncStatus: Equatable, Sendable {
    /// This build can't use iCloud (it isn't signed with Axo's iCloud entitlement).
    case unavailable
    /// The person turned sync off.
    case off
    /// The first sync with this iCloud account: Spaces from both sides are joined.
    case settingUp
    /// Syncing, with the time of the last finished sync, if any.
    case upToDate(lastSynced: Date?)
    /// Waiting for the person: signed out, or iCloud storage is full.
    case paused(SyncPause)
    /// Something else went wrong; Axo tries again on its own. `details` holds the error and its
    /// code, for Show Details.
    case failed(details: String)
}

/// Turns iCloud sync on and off and reports how it's going. The app provides it over AxoSync's
/// `CloudKitSync`; AxoUI doesn't depend on AxoSync.
@MainActor
public protocol SyncControlling: AnyObject {
    /// Whether sync is on. On by default.
    var isEnabled: Bool { get set }
    /// Where sync stands now.
    var status: SyncStatus { get }
    /// Syncs now rather than when the engine would (Sync Now, and Try Again).
    func syncNow() async
    /// Opens System Settings where the person signs in to iCloud.
    func openAccountSettings()
    /// Opens System Settings where the person manages iCloud storage.
    func openStorageSettings()
}

/// The iCloud pane in Settings (#174): a card saying how sync is going with what to do about it,
/// the Sync with iCloud switch (turning it off asks first), and what syncs and what stays on
/// this Mac.
struct SyncSettings: View {
    let sync: any SyncControlling
    @State private var isConfirmingTurnOff = false
    @State private var showsDetails = false

    /// What syncs through iCloud.
    static let syncedItems = "Profiles, Spaces and their themes, folders, pinned tabs, and favorites"
    /// What stays on this Mac.
    static let localItems = "Open tabs, history, website data and logins, site permissions, extensions, link rules, site customizations, and settings"

    var body: some View {
        Form {
            Section {
                statusCard
            }
            Section {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { sync.isEnabled },
                    set: { on in
                        if on { sync.isEnabled = true } else { isConfirmingTurnOff = true }
                    }
                ))
                .disabled(sync.status == .unavailable)
                .accessibilityIdentifier("syncToggle")
                LabeledContent("Syncs") {
                    Text(Self.syncedItems).multilineTextAlignment(.trailing)
                }
                LabeledContent("Stays on this Mac") {
                    Text(Self.localItems).multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Turn off iCloud sync?", isPresented: $isConfirmingTurnOff) {
            Button("Turn Off") { sync.isEnabled = false }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Everything stays on this Mac. Changes here stop reaching your other devices, and theirs stop arriving.")
        }
    }

    /// The state's symbol, title, explanation, and what to do about it.
    private var statusCard: some View {
        let status = sync.status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: Self.symbol(for: status))
                    .foregroundStyle(Self.isProblem(status) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.title(for: status))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("syncStatusTitle")
                    // Redrawn each minute, so "Last synced" stays true while the pane is open.
                    TimelineView(.everyMinute) { _ in
                        Text(Self.message(for: status))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("syncStatus")
                    }
                }
                Spacer(minLength: 0)
                if status == .settingUp {
                    // The title already says it; VoiceOver doesn't need it twice.
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
            }
            actions(for: status)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("syncStatusCard")
    }

    @ViewBuilder
    private func actions(for status: SyncStatus) -> some View {
        switch status {
        case .off:
            Button("Turn On") { sync.isEnabled = true }
                .accessibilityIdentifier("syncTurnOnButton")
        case .upToDate:
            Button("Sync Now") { Task { await sync.syncNow() } }
                .accessibilityIdentifier("syncNowButton")
        case .paused(.signedOut):
            Button("Open System Settings…") { sync.openAccountSettings() }
                .accessibilityIdentifier("syncAccountButton")
        case .paused(.storageFull):
            Button("Manage Storage…") { sync.openStorageSettings() }
                .accessibilityIdentifier("syncStorageButton")
        case .paused(.restricted):
            EmptyView()
        case .failed(let details):
            HStack {
                Button("Try Again") { Task { await sync.syncNow() } }
                    .accessibilityIdentifier("syncTryAgainButton")
                Button(showsDetails ? "Hide Details" : "Show Details") { showsDetails.toggle() }
                    .accessibilityIdentifier("syncDetailsButton")
            }
            if showsDetails {
                Text(details)
                    .accessibilityIdentifier("syncDetails")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        case .unavailable, .settingUp:
            EmptyView()
        }
    }

    /// The state's title, as the board names it.
    static func title(for status: SyncStatus) -> String {
        switch status {
        case .unavailable: "iCloud Isn’t Available"
        case .off: "Off"
        case .settingUp: "Setting Up"
        case .upToDate: "Up to Date"
        case .paused: "Paused"
        case .failed: "Couldn’t Sync"
        }
    }

    /// A plain description of the state and what to do.
    static func message(for status: SyncStatus) -> String {
        switch status {
        case .unavailable: "This copy of Axo can't use iCloud. Official releases can."
        case .off: "Turn it on to keep your Spaces the same on your other Macs."
        case .settingUp: "Bringing your Spaces together with the ones in iCloud. Spaces from both sides are kept; nothing is replaced."
        case .upToDate(nil): "Waiting for the first sync."
        case .upToDate(let date?):
            "Last synced \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))."
        case .paused(.signedOut): "You're signed out of iCloud. Sign in to keep syncing; everything stays on this Mac meanwhile."
        case .paused(.storageFull): "Your iCloud storage is full, so changes here aren't reaching your other devices."
        case .paused(.restricted): "Screen Time or your organization keeps Axo from using iCloud on this Mac."
        case .failed: "Axo couldn't sync with iCloud. It tries again on its own."
        }
    }

    static func symbol(for status: SyncStatus) -> String {
        switch status {
        case .unavailable, .off: "icloud.slash"
        case .settingUp: "arrow.triangle.2.circlepath.icloud"
        case .upToDate: "checkmark.icloud"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.icloud"
        }
    }

    /// Whether the state needs the person.
    static func isProblem(_ status: SyncStatus) -> Bool {
        switch status {
        case .paused, .failed: true
        default: false
        }
    }
}

extension BrowserModel {
    /// Tells VoiceOver about Spaces that arrived through iCloud (#174). Their dots appear in the
    /// sidebar on their own; there's no notice, as with other changes the person didn't make.
    public func spacesArrivedThroughSync(_ names: [String]) {
        switch names.count {
        case 0: return
        case 1: announce("“\(names[0])” arrived from iCloud")
        default: announce("\(names.count) Spaces arrived from iCloud")
        }
    }
}
