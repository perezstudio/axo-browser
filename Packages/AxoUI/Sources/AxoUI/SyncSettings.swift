import SwiftUI

/// Where iCloud sync stands, for the iCloud pane in Settings.
public enum SyncStatus: Equatable, Sendable {
    /// This build can't use iCloud (it isn't signed with Axo's iCloud entitlement).
    case unavailable
    /// The person turned sync off.
    case off
    /// No iCloud account is signed in, or iCloud Drive is restricted.
    case noAccount
    /// Syncing, with the time of the last finished sync, if any.
    case on(lastSynced: Date?)
    /// Something went wrong, in plain words.
    case failed(String)
}

/// Turns iCloud sync on and off and reports how it's going. The app provides it over AxoSync's
/// `CloudKitSync`; AxoUI doesn't depend on AxoSync.
@MainActor
public protocol SyncControlling: AnyObject {
    /// Whether sync is on. On by default.
    var isEnabled: Bool { get set }
    /// Where sync stands now.
    var status: SyncStatus { get }
    /// Syncs now rather than when the engine would.
    func syncNow() async
}

/// The iCloud pane in Settings: a switch for syncing Spaces, folders, and pinned tabs, what
/// stays on this Mac, and how sync is going.
struct SyncSettings: View {
    let sync: any SyncControlling

    var body: some View {
        Form {
            Section {
                Toggle("Sync Spaces, folders, and pinned tabs with iCloud", isOn: Binding(
                    get: { sync.isEnabled },
                    set: { sync.isEnabled = $0 }
                ))
                .disabled(sync.status == .unavailable)
                .accessibilityIdentifier("syncToggle")
                Text("Open tabs, history, website data, and logins stay on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Status") {
                    Text(Self.message(for: sync.status))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("syncStatus")
                }
                if case .on = sync.status {
                    Button("Sync Now") { Task { await sync.syncNow() } }
                        .accessibilityIdentifier("syncNowButton")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A plain description of the status.
    static func message(for status: SyncStatus) -> String {
        switch status {
        case .unavailable: "This copy of Axo can't use iCloud. Official releases can."
        case .off: "Off"
        case .noAccount: "Sign in to iCloud in System Settings to sync."
        case .on(nil): "Waiting for the first sync"
        case .on(let date?):
            "Last synced \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
        case .failed(let message): message
        }
    }
}
