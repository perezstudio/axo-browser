// The Mac only: iPhone and iPad update through the App Store.
#if os(macOS)
import Foundation
import Observation

/// What Axo's updater does, apart from how it finds and installs updates: the app's
/// `SparkleUpdater` (Sparkle's `SPUUpdater`), or a stand-in in test runs, which never check for
/// updates (#180). It reports what happens to the ``SoftwareUpdate`` it's given, which shows it.
@MainActor
public protocol SoftwareUpdater: AnyObject {
    /// Starts a check the person asked for (the menu's Check for Updates…, Settings' Check Now,
    /// Try Again), once any session still ending has ended.
    func checkForUpdates()
    /// Whether Axo checks for updates on its own, once a day.
    var automaticallyChecksForUpdates: Bool { get set }
    /// Whether updates download in the background and install when Axo quits.
    var automaticallyDownloadsUpdates: Bool { get set }
    /// Whether beta versions are offered too.
    var includesBetaVersions: Bool { get set }
    /// When Axo last checked, if it has.
    var lastUpdateCheckDate: Date? { get }
}

/// Shows and closes Software Update's window. ``SoftwareUpdateWindow`` in the app; a recorder in
/// tests.
@MainActor
public protocol SoftwareUpdatePresenting: AnyObject {
    /// Shows the window, bringing Axo forward when `activate` (a check the person asked for).
    func show(activate: Bool)
    /// Closes the window, without counting it as the person closing it.
    func close()
}

/// Axo's software updates (#180), as the Software updates board draws them: the updater's states
/// in Axo's own wording, the person's choices sent back to the updater exactly once, Settings'
/// switches, and the Restart to Update Axo menu item and notice for an update that downloaded in
/// the background.
///
/// The updater reports what happens through the `updater…` methods, which mirror Sparkle's
/// `SPUUserDriver` calls; the window and menus act through the others. Each reply the updater
/// hands over is called at most once, and never after ``updaterDismissed()``.
@MainActor
@Observable
public final class SoftwareUpdate {
    /// The person's answer to an update offer or a ready update.
    public enum Choice: Equatable, Sendable {
        /// Download (if needed) and install it.
        case install
        /// Don't offer this version again.
        case skip
        /// Ask again later; a downloaded update installs when Axo quits.
        case later
    }

    /// How far an offered update has come.
    public enum Stage: Equatable, Sendable {
        case notDownloaded, downloaded, installing
    }

    /// An update the updater found.
    public struct Offer: Equatable, Sendable {
        /// The version, as people see it ("1.1").
        public var version: String
        /// What's new, as text, once it's known.
        public var releaseNotes: String?
        /// Whether it's an update Axo needs, which can't be skipped (closing the window still puts
        /// it off, as in Sparkle's own window).
        public var isCritical: Bool
        /// An update that can't be installed from here, only read about at ``infoURL``.
        public var isInformational: Bool
        /// Where to read about an informational update.
        public var infoURL: URL?
        /// How far it has come.
        public var stage: Stage
        /// Whether the person asked for the check that found it.
        public var isUserInitiated: Bool

        /// An offer.
        public init(version: String, releaseNotes: String? = nil, isCritical: Bool = false, isInformational: Bool = false,
                    infoURL: URL? = nil, stage: Stage = .notDownloaded, isUserInitiated: Bool = true) {
            self.version = version
            self.releaseNotes = releaseNotes
            self.isCritical = isCritical
            self.isInformational = isInformational
            self.infoURL = infoURL
            self.stage = stage
            self.isUserInitiated = isUserInitiated
        }
    }

    /// Why a check found nothing to install.
    public enum NoUpdateReason: Equatable, Sendable {
        /// This is the newest version.
        case onLatestVersion
        /// This version is newer than any offered (a build of Axo not yet released).
        case newerThanLatest
        /// A newer version needs a newer macOS.
        case systemTooOld(version: String?, minimumSystem: String?)
        /// A newer version doesn't run on this macOS.
        case systemTooNew(version: String?)
        /// A newer version doesn't run on this Mac's processor.
        case unsupportedHardware(version: String?)
    }

    /// What went wrong.
    public enum Failure: Equatable, Sendable {
        /// The feed couldn't be reached or read.
        case couldNotCheck
        /// The update didn't download.
        case couldNotDownload
        /// The update didn't pass its signature checks, so it wasn't installed.
        case couldNotVerify
        /// The update didn't install.
        case couldNotInstall
        /// Anything else, with the updater's own description.
        case other(String)
    }

    /// What Software Update shows.
    public enum Phase: Equatable, Sendable {
        /// Nothing: the window is closed.
        case idle
        /// A check the person asked for.
        case checking
        /// An update is available.
        case found(Offer)
        /// The update is downloading: bytes so far, and how many there are once known.
        case downloading(received: UInt64, expected: UInt64?)
        /// The update is being unpacked and checked, with its progress once known.
        case extracting(progress: Double?)
        /// The update is ready to install.
        case readyToInstall
        /// The update is installing; `canRetry` while Axo hasn't quit yet (a page kept it open).
        case installing(canRetry: Bool)
        /// Nothing to install.
        case upToDate(NoUpdateReason)
        /// Something went wrong.
        case failed(Failure)
    }

    /// An update that downloaded in the background and installs when Axo quits.
    public struct PendingRestart: Equatable {
        /// Its version.
        public let version: String
    }

    /// This copy of Axo's version, as people see it.
    public let currentVersion: String
    /// What the window shows.
    public private(set) var phase: Phase = .idle
    /// An update waiting for Axo to quit, which Restart to Update Axo installs now.
    public private(set) var pendingRestart: PendingRestart?
    /// Whether the updater can start a check, as it reports it. Sparkle says yes while a check the
    /// person asked for is showing, so ``checkForUpdates()`` looks at ``phase`` first.
    public var canCheckForUpdates = false
    /// When Axo last checked, for Settings.
    public private(set) var lastUpdateCheckDate: Date?

    /// Whether Axo checks on its own, once a day.
    public var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    /// Whether updates download and install on their own.
    public var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard automaticallyDownloadsUpdates != oldValue else { return }
            updater?.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }
    /// Whether betas are offered.
    public var includesBetaVersions: Bool {
        didSet {
            guard includesBetaVersions != oldValue else { return }
            updater?.includesBetaVersions = includesBetaVersions
        }
    }

    /// The updater. It reports back to this object, which keeps it.
    @ObservationIgnored public private(set) var updater: (any SoftwareUpdater)?
    /// Shows and closes the window. Set by the app.
    @ObservationIgnored public var presenter: (any SoftwareUpdatePresenting)?
    /// Called with an update's version when one is ready to install on quit, so the browser can
    /// say so with a notice (``BrowserModel/softwareUpdate``).
    @ObservationIgnored var onReadyToInstallOnQuit: ((String) -> Void)?
    /// Opens a page about an informational update.
    @ObservationIgnored var openURL: ((URL) -> Void)?

    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var choiceReply: ((Choice) -> Void)?
    @ObservationIgnored private var acknowledgement: (() -> Void)?
    @ObservationIgnored private var retryTermination: (() -> Void)?
    @ObservationIgnored private var installNow: (() -> Void)?
    /// The version offered last, for the Restart to Update item after a ready update is put off.
    @ObservationIgnored private var offeredVersion: String?

    /// Creates Software Update for `currentVersion`, reading `updater`'s settings.
    public init(currentVersion: String, updater: any SoftwareUpdater) {
        self.currentVersion = currentVersion
        self.updater = updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        includesBetaVersions = updater.includesBetaVersions
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }

    // MARK: What the person does

    /// Checks for updates now.
    public func checkForUpdates() {
        // A check or update is showing: bring it forward rather than start another.
        guard phase == .idle else {
            presenter?.show(activate: true)
            return
        }
        guard canCheckForUpdates else { return }
        updater?.checkForUpdates()
    }

    /// The window's main button: Install Update, Install and Relaunch, or Learn More for an
    /// update that can only be read about.
    public func install() {
        switch phase {
        case .found(let offer):
            if offer.isInformational {
                // The feed isn't signed, so only a web page opens.
                if let url = offer.infoURL, ["http", "https"].contains(url.scheme?.lowercased()) { openURL?(url) }
                reply(.later)
            } else {
                reply(.install)
            }
        case .readyToInstall:
            reply(.install)
        case .installing(canRetry: true):
            // Sparkle allows asking again each time something keeps Axo open.
            retryTermination?()
        default:
            break
        }
    }

    /// Skip This Version.
    public func skipVersion() {
        guard case .found(let offer) = phase, !offer.isCritical else { return }
        // Skipping an update that waits to install cancels it.
        if offer.stage != .notDownloaded { clearPendingRestart() }
        reply(.skip)
    }

    /// Remind Me Later, or closing the window over an offer or a ready update. A ready update then
    /// installs when Axo quits, and Restart to Update Axo installs it sooner.
    public func remindLater() {
        switch phase {
        case .found(let offer):
            reply(.later)
            // One already installing installs on quit.
            if offer.stage == .installing, pendingRestart == nil { pendingRestart = PendingRestart(version: offer.version) }
        case .readyToInstall:
            reply(.later)
            if let offeredVersion { pendingRestart = PendingRestart(version: offeredVersion) }
        default:
            break
        }
    }

    /// Cancel, while checking or downloading.
    public func cancel() {
        switch phase {
        case .checking, .downloading:
            let cancel = take(&cancellation)
            finish()
            cancel?()
        default:
            break
        }
    }

    /// OK, after a check found nothing or something went wrong.
    public func acknowledge() {
        switch phase {
        case .upToDate, .failed:
            let acknowledge = take(&acknowledgement)
            finish()
            acknowledge?()
        default:
            break
        }
    }

    /// Try Again, after something went wrong. Sparkle ends the failed session only after the
    /// acknowledgement, so the updater starts the new check once it has (``SoftwareUpdater``).
    public func tryAgain() {
        guard case .failed = phase else { return }
        acknowledge()
        updater?.checkForUpdates()
    }

    /// The person closed the window: whatever its Cancel, Remind Me Later, or OK would do.
    /// Unpacking and installing can't be stopped, so closing then only hides the window.
    public func windowClosed() {
        switch phase {
        case .checking, .downloading: cancel()
        case .found, .readyToInstall: remindLater()
        case .upToDate, .failed: acknowledge()
        case .idle, .extracting, .installing: break
        }
    }

    /// Restart to Update Axo: installs the waiting update now, which quits Axo and opens the new
    /// version.
    public func restartToUpdate() {
        guard pendingRestart != nil else { return }
        if let installNow {
            // Kept: Sparkle allows it again if something (a page's "Leave this page?") keeps Axo
            // open. It goes once the update installs or is skipped.
            installNow()
        } else {
            // A ready update put off from the window: checking again resumes it, offering Install
            // and Relaunch.
            pendingRestart = nil
            updater?.checkForUpdates()
        }
    }

    /// Reads the updater's settings and last check again, as Settings appears.
    public func refreshSettings() {
        guard let updater else { return }
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        includesBetaVersions = updater.includesBetaVersions
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }

    // MARK: What the updater reports

    /// A check the person asked for started; `cancellation` stops it.
    public func updaterStartedCheck(cancellation: @escaping () -> Void) {
        dropReplies()
        self.cancellation = cancellation
        show(.checking, activate: true)
    }

    /// An update is available; `reply` takes the person's choice.
    public func updaterFound(_ offer: Offer, reply: @escaping (Choice) -> Void) {
        dropReplies()
        // A newer version than the one waiting replaces it.
        if let waiting = pendingRestart, waiting.version != offer.version { clearPendingRestart() }
        choiceReply = reply
        offeredVersion = offer.version
        lastUpdateCheckDate = updater?.lastUpdateCheckDate ?? lastUpdateCheckDate
        show(.found(offer), activate: offer.isUserInitiated)
    }

    /// The offered update's release notes arrived.
    public func updaterLoadedReleaseNotes(_ text: String) {
        guard case .found(var offer) = phase else { return }
        offer.releaseNotes = text
        phase = .found(offer)
    }

    /// A check found nothing to install; `acknowledgement` once the person has seen it.
    public func updaterFoundNoUpdate(_ reason: NoUpdateReason, acknowledgement: @escaping () -> Void) {
        dropReplies()
        self.acknowledgement = acknowledgement
        lastUpdateCheckDate = updater?.lastUpdateCheckDate ?? lastUpdateCheckDate
        show(.upToDate(reason), activate: true)
    }

    /// Something went wrong; `acknowledgement` once the person has seen it.
    public func updaterFailed(_ failure: Failure, acknowledgement: @escaping () -> Void) {
        dropReplies()
        self.acknowledgement = acknowledgement
        show(.failed(failure), activate: true)
    }

    /// The update started downloading; `cancellation` stops it.
    public func updaterStartedDownload(cancellation: @escaping () -> Void) {
        dropReplies()
        self.cancellation = cancellation
        show(.downloading(received: 0, expected: nil), activate: false)
    }

    /// The download's size became known.
    public func updaterExpectsDownloadLength(_ length: UInt64) {
        guard case .downloading(let received, _) = phase else { return }
        phase = .downloading(received: received, expected: length > 0 ? length : nil)
    }

    /// More of the download arrived.
    public func updaterReceivedDownloadData(length: UInt64) {
        guard case .downloading(let received, let expected) = phase else { return }
        let total = received &+ length
        // A server can send more than it said; the bar then shows the larger total.
        phase = .downloading(received: total, expected: expected.map { max($0, total) })
    }

    /// The update started unpacking.
    public func updaterStartedExtracting() {
        dropReplies()
        show(.extracting(progress: nil), activate: false)
    }

    /// Unpacking progressed, from 0 to 1.
    public func updaterExtracted(progress: Double) {
        guard case .extracting = phase else { return }
        phase = .extracting(progress: min(max(progress, 0), 1))
    }

    /// The update is ready; `reply` takes Install and Relaunch, or later.
    public func updaterReadyToInstall(reply: @escaping (Choice) -> Void) {
        dropReplies()
        choiceReply = reply
        show(.readyToInstall, activate: false)
    }

    /// The update is installing. Until Axo has quit (`applicationTerminated`), `retry` asks it
    /// to quit again, after something (a page's "Leave this page?") kept it open.
    public func updaterInstalling(applicationTerminated: Bool, retry: @escaping () -> Void) {
        dropReplies()
        retryTermination = applicationTerminated ? nil : retry
        show(.installing(canRetry: !applicationTerminated), activate: false)
    }

    /// The update installed. Nothing more to show: Axo opens in the new version.
    public func updaterInstalled(acknowledgement: @escaping () -> Void) {
        dropReplies()
        clearPendingRestart()
        finish()
        acknowledgement()
    }

    /// The updater asks to bring its window forward.
    public func updaterShowsInFocus() {
        guard phase != .idle else { return }
        presenter?.show(activate: true)
    }

    /// The updater ended the session: everything closes, and no reply is called.
    public func updaterDismissed() {
        dropReplies()
        finish()
    }

    /// An update downloaded in the background and installs when Axo quits; `installNow` installs
    /// it now, relaunching Axo. Restart to Update Axo appears, and the browser posts a notice.
    public func updaterWillInstallOnQuit(version: String, installNow: @escaping () -> Void) {
        self.installNow = installNow
        pendingRestart = PendingRestart(version: version)
        onReadyToInstallOnQuit?(version)
    }

    // MARK: Private

    private func clearPendingRestart() {
        pendingRestart = nil
        installNow = nil
    }

    private func show(_ phase: Phase, activate: Bool) {
        let wasIdle = self.phase == .idle
        self.phase = phase
        if wasIdle || activate { presenter?.show(activate: activate) }
    }

    private func finish() {
        phase = .idle
        presenter?.close()
    }

    /// Sends `choice` back. Installing keeps the window, which the download or installation
    /// shows next; the other choices close it.
    private func reply(_ choice: Choice) {
        guard let reply = take(&choiceReply) else { return }
        if choice != .install { finish() }
        reply(choice)
    }

    /// Drops replies the updater no longer waits for (it moved on, or dismissed the session).
    private func dropReplies() {
        cancellation = nil
        choiceReply = nil
        acknowledgement = nil
        retryTermination = nil
    }

    private func take<T>(_ value: inout T?) -> T? {
        defer { value = nil }
        return value
    }
}

// MARK: The browser

extension BrowserModel {
    /// Has Software Update's notices and pages go through this window's model.
    func connectSoftwareUpdate() {
        softwareUpdate?.onReadyToInstallOnQuit = { [weak self] version in
            self?.postUpdateReadyNotice(version: version)
        }
        softwareUpdate?.openURL = { [weak self] url in
            Task { await self?.openTab(url: url) }
        }
    }

    /// Says an update downloaded in the background, as the Software updates board proposes (a
    /// notice the person didn't cause, decided in #180's plan): Restart Now installs it.
    func postUpdateReadyNotice(version: String) {
        postNotice(SoftwareUpdate.readyNotice(version: version), actionTitle: "Restart Now") { [weak self] in
            self?.softwareUpdate?.restartToUpdate()
        }
    }
}

// MARK: Wording

extension SoftwareUpdate {
    /// Release notes as plain text. Axo's feed writes them as plain text; HTML (Sparkle's default)
    /// is turned into text rather than rendered, so a feed can't load anything into Axo's window.
    public nonisolated static func releaseNotesText(_ notes: String, format: String?) -> String {
        guard format?.lowercased() != "plain-text" else {
            return notes.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var text = notes
        // Line breaks where blocks end, and bullets for list items.
        for (pattern, replacement) in [
            (#"(?i)<\s*br\s*/?\s*>"#, "\n"),
            (#"(?i)</\s*(p|div|h[1-6]|ul|ol)\s*>"#, "\n"),
            (#"(?i)<\s*li[^>]*>"#, "\n• "),
            (#"(?is)<\s*(script|style)[^>]*>.*?<\s*/\s*\1\s*>"#, ""),
            (#"<[^>]*>"#, ""),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        // No more than one blank line in a row.
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) {
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The alert's title after a check found nothing or something went wrong.
    public var alertTitle: String {
        switch phase {
        case .upToDate(.onLatestVersion), .upToDate(.newerThanLatest): "You’re up to date!"
        case .upToDate: "This Mac can’t install the newest Axo"
        case .failed(.couldNotCheck): "Couldn’t check for updates"
        case .failed: "Couldn’t update Axo"
        default: ""
        }
    }

    /// The alert's message.
    public var alertMessage: String {
        switch phase {
        case .upToDate(.onLatestVersion):
            "Axo \(currentVersion) is currently the newest version available."
        case .upToDate(.newerThanLatest):
            "Axo \(currentVersion) is newer than the newest version available."
        case .upToDate(.systemTooOld(let version, let minimum)):
            minimum.map { "\(Self.named(version)) needs macOS \($0) or later." }
                ?? "\(Self.named(version)) needs a newer version of macOS."
        case .upToDate(.systemTooNew(let version)):
            "\(Self.named(version)) doesn’t run on this version of macOS."
        case .upToDate(.unsupportedHardware(let version)):
            "\(Self.named(version)) doesn’t run on this Mac’s processor."
        case .failed(.couldNotCheck):
            "Axo couldn’t reach its update server. Check your internet connection, then try again."
        case .failed(.couldNotDownload):
            "The update didn’t download. Check your internet connection, then try again."
        case .failed(.couldNotVerify):
            "The update couldn’t be verified, so Axo didn’t install it. You still have Axo \(currentVersion)."
        case .failed(.couldNotInstall):
            "The update couldn’t be installed. You still have Axo \(currentVersion)."
        case .failed(.other(let description)):
            description
        default:
            ""
        }
    }

    private static func named(_ version: String?) -> String {
        version.map { "Axo \($0)" } ?? "The newest Axo"
    }

    /// The status window's title and detail while checking, downloading, unpacking, ready, or
    /// installing.
    public var status: (title: String, detail: String)? {
        switch phase {
        case .checking:
            ("Checking for updates…", "Looking for a new version of Axo.")
        case .downloading(let received, let expected):
            ("Downloading update…", Self.downloadDetail(received: received, expected: expected))
        case .extracting:
            ("Extracting update…", "Getting it ready.")
        case .readyToInstall:
            ("Ready to Install", "Axo restarts, and your windows and tabs come back.")
        case .installing:
            ("Installing update…", "Axo opens again when it’s done.")
        default:
            nil
        }
    }

    /// "12.4 MB of 38.6 MB", or what has arrived while the size isn't known.
    nonisolated static func downloadDetail(received: UInt64, expected: UInt64?) -> String {
        let style = ByteCountFormatStyle(style: .file)
        let got = Int64(clamping: received).formatted(style)
        guard let expected else { return got }
        return "\(got) of \(Int64(clamping: expected).formatted(style))"
    }

    /// The notice for an update that downloaded in the background.
    nonisolated static func readyNotice(version: String) -> String {
        "Axo \(version) is ready. It installs the next time Axo quits."
    }
}
#endif
