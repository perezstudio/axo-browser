// The Mac only: iPhone and iPad update through the App Store.
#if os(macOS)
import AppKit
import SwiftUI

/// Software Update's window (#180), as the Software updates board draws it: a status window
/// while checking, downloading, unpacking, ready, and installing; the update window with what's
/// new and three choices; and an alert when a check finds nothing or something goes wrong.
/// Closing it does what its Cancel, Remind Me Later, or OK would.
@MainActor
public final class SoftwareUpdateWindow: NSObject, SoftwareUpdatePresenting, NSWindowDelegate {
    private let update: SoftwareUpdate
    private var window: NSWindow?
    /// Set while the window closes because Software Update asked, not the person.
    private var isClosingForUpdate = false

    /// Creates the window controller for `update`, and makes it the update's presenter.
    public init(update: SoftwareUpdate) {
        self.update = update
        super.init()
        update.presenter = self
    }

    /// Shows the window, centered the first time, bringing Axo forward when `activate`.
    public func show(activate: Bool) {
        let window = self.window ?? makeWindow()
        self.window = window
        // Centered each time it opens, since its size follows the phase.
        if !window.isVisible { window.center() }
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    /// Closes the window.
    public func close() {
        guard let window, window.isVisible else { return }
        isClosingForUpdate = true
        window.close()
        isClosingForUpdate = false
    }

    public func windowWillClose(_ notification: Notification) {
        guard !isClosingForUpdate else { return }
        update.windowClosed()
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: SoftwareUpdateView(update: update))
        // The window follows the content's size as the phase changes.
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

/// The window's content for each phase.
struct SoftwareUpdateView: View {
    let update: SoftwareUpdate

    var body: some View {
        Group {
            switch update.phase {
            case .found(let offer):
                OfferView(update: update, offer: offer)
            case .upToDate, .failed:
                AlertView(update: update)
            case .idle:
                Color.clear.frame(width: 1, height: 1)
            default:
                StatusView(update: update)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("softwareUpdate")
    }
}

/// Axo's icon, beside each of the window's layouts.
private struct AppIcon: View {
    var size: CGFloat = 64

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Checking, downloading, unpacking, ready, and installing.
private struct StatusView: View {
    let update: SoftwareUpdate

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AppIcon(size: 48)
            VStack(alignment: .leading, spacing: 8) {
                if let status = update.status {
                    Text(status.title).font(.headline)
                    progress
                    Text(status.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Spacer()
                    buttons
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder private var progress: some View {
        switch update.phase {
        case .downloading(let received, let expected?) where expected > 0:
            ProgressView(value: Double(received), total: Double(expected))
                .accessibilityLabel("Download progress")
        case .extracting(let progress?):
            ProgressView(value: progress)
                .accessibilityLabel("Extraction progress")
        case .readyToInstall:
            ProgressView(value: 1)
                .accessibilityLabel("Ready")
        default:
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel("Progress")
        }
    }

    @ViewBuilder private var buttons: some View {
        switch update.phase {
        case .checking, .downloading:
            Button("Cancel") { update.cancel() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cancelUpdateButton")
        case .readyToInstall, .installing(canRetry: true):
            Button("Install and Relaunch") { update.install() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("installAndRelaunchButton")
        default:
            // Keeps the window's height while nothing can be done.
            Button("Cancel") {}
                .disabled(true)
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

/// An update is available: the version, what's new, and three choices.
private struct OfferView: View {
    let update: SoftwareUpdate
    let offer: SoftwareUpdate.Offer

    private var installTitle: String {
        if offer.isInformational { return "Learn More…" }
        return offer.stage == .installing ? "Install and Relaunch" : "Install Update"
    }

    var body: some View {
        @Bindable var update = update
        HStack(alignment: .top, spacing: 16) {
            AppIcon()
            VStack(alignment: .leading, spacing: 10) {
                Text("A new version of Axo is available!")
                    .font(.headline)
                Text(offer.stage == .notDownloaded
                     ? "Axo \(offer.version) is now available—you have \(update.currentVersion). Would you like to download it now?"
                     : "Axo \(offer.version) is downloaded and ready to install—you have \(update.currentVersion).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Release Notes:")
                    .font(.callout.bold())
                    .padding(.top, 4)
                ScrollView {
                    Text(offer.releaseNotes ?? "")
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 200)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .overlay {
                    if offer.releaseNotes == nil {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Loading release notes")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Release notes")
                .accessibilityIdentifier("releaseNotes")
                if !offer.isInformational {
                    Toggle("Automatically download and install updates in the future", isOn: $update.automaticallyDownloadsUpdates)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .accessibilityIdentifier("automaticUpdatesCheckbox")
                }
                HStack {
                    if !offer.isCritical {
                        Button("Skip This Version") { update.skipVersion() }
                            .accessibilityIdentifier("skipVersionButton")
                    }
                    Spacer()
                    if !offer.isCritical {
                        Button(offer.stage == .installing ? "Install on Quit" : "Remind Me Later") { update.remindLater() }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("remindLaterButton")
                    }
                    Button(installTitle) { update.install() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("installUpdateButton")
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Up to date, or something went wrong.
private struct AlertView: View {
    let update: SoftwareUpdate

    private var isFailure: Bool {
        if case .failed = update.phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 12) {
            AppIcon()
            Text(update.alertTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(update.alertMessage)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                if isFailure {
                    Button { update.tryAgain() } label: {
                        Text("Try Again").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("updateTryAgainButton")
                }
                Button { update.acknowledge() } label: {
                    Text("OK").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(isFailure ? .cancelAction : .defaultAction)
                .accessibilityIdentifier("updateOKButton")
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 280)
    }
}
/// Settings › General › Software Update: Check Now, checking automatically, downloading and
/// installing automatically, and betas.
struct SoftwareUpdateSettings: View {
    let update: SoftwareUpdate

    var body: some View {
        @Bindable var update = update
        Section("Software Update") {
            LabeledContent {
                if update.pendingRestart != nil {
                    // Sparkle checks nothing more until the waiting update installs.
                    Button("Restart to Update") { update.restartToUpdate() }
                        .accessibilityIdentifier("restartToUpdateButton")
                } else {
                    Button("Check Now") { update.checkForUpdates() }
                        .disabled(!update.canCheckForUpdates && update.phase == .idle)
                        .accessibilityIdentifier("checkForUpdatesButton")
                }
            } label: {
                Text("Axo \(update.currentVersion)")
                if let waiting = update.pendingRestart {
                    Text("Axo \(waiting.version) is ready. It installs the next time Axo quits.")
                } else {
                    Text(Self.lastChecked(update.lastUpdateCheckDate))
                        .accessibilityIdentifier("lastUpdateCheck")
                }
            }
            Toggle(isOn: $update.automaticallyChecksForUpdates) {
                Text("Check for updates automatically")
                Text("Axo looks once a day, in the background.")
            }
            .accessibilityIdentifier("automaticallyChecksToggle")
            Toggle(isOn: $update.automaticallyDownloadsUpdates) {
                Text("Download and install updates automatically")
                Text(update.automaticallyDownloadsUpdates
                     ? "Updates download in the background and install when Axo quits."
                     : "Axo asks before it downloads an update.")
            }
            .disabled(!update.automaticallyChecksForUpdates)
            .accessibilityIdentifier("automaticallyDownloadsToggle")
            Toggle(isOn: $update.includesBetaVersions) {
                Text("Include beta versions")
                Text("Try new features early. Betas can have rough edges.")
            }
            .accessibilityIdentifier("includesBetasToggle")
        }
        .onAppear { update.refreshSettings() }
        .onChange(of: update.phase) { update.refreshSettings() }
    }

    /// "Last checked Today at 9:41 AM", or that Axo hasn't checked yet.
    static func lastChecked(_ date: Date?, locale: Locale = .current) -> String {
        guard let date else { return "Not checked yet" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return "Last checked \(formatter.string(from: date))"
    }
}

/// The Axo menu's Restart to Update Axo (while an update waits for Axo to quit) and Check for
/// Updates…, below About Axo.
public struct SoftwareUpdateCommands: Commands {
    let update: SoftwareUpdate?

    /// The commands for `update`; none without one.
    public init(update: SoftwareUpdate?) {
        self.update = update
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            if let update {
                if update.pendingRestart != nil {
                    Button("Restart to Update Axo") { update.restartToUpdate() }
                }
                Button("Check for Updates…") { update.checkForUpdates() }
                    .disabled(!update.canCheckForUpdates && update.phase == .idle)
            }
        }
    }
}
#endif
