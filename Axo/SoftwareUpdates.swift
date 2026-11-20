import AxoUI
import Foundation
import Sparkle

/// Which updater a launch gets (#180).
enum UpdaterKind: Equatable {
    /// Sparkle, checking Axo's feed.
    case sparkle
    /// A stand-in that never checks for updates, for test runs.
    case standIn
    /// None: this build can't update itself.
    case none

    /// Test runs get the stand-in, so they never check for updates. Otherwise Sparkle runs once
    /// the build has the feed's public key, and in Debug builds only when the feed points at this
    /// Mac (``SparkleUpdater/feedOverride(_:)``), so a development build never replaces itself
    /// with a release.
    static func forLaunch(isTestRun: Bool, isDebugBuild: Bool, hasPublicKey: Bool, hasLocalFeed: Bool) -> UpdaterKind {
        if isTestRun { return .standIn }
        guard hasPublicKey else { return .none }
        if isDebugBuild && !hasLocalFeed { return .none }
        return .sparkle
    }
}

/// Sparkle's updater behind Axo's ``SoftwareUpdater``, with Axo's own user driver
/// (``SparkleUserDriver``), so Axo's wording and windows show rather than Sparkle's.
final class SparkleUpdater: NSObject, SoftwareUpdater {
    /// The settings key for Include beta versions.
    static let includesBetasKey = "includesBetaVersions"
    /// A settings key that points the feed at this Mac, for checking an update by hand
    /// (`docs/releasing.md`). Only loopback addresses count.
    static let feedOverrideKey = "AXOUpdateFeedURL"

    private let settings: UserDefaults
    private let driver = SparkleUserDriver()
    private var updater: SPUUpdater!
    private var canCheckObservation: NSKeyValueObservation?

    init(settings: UserDefaults) {
        self.settings = settings
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    }

    /// Whether this build carries the feed's public key, without which Sparkle won't install
    /// anything.
    static var hasPublicKey: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !key.isEmpty && !key.hasPrefix("$(")
    }

    /// The feed override in `value`, if it's an http or https address on this Mac.
    static func feedOverride(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host()?.lowercased() else { return nil }
        let loopback = host == "localhost" || host == "::1" || host == "[::1]"
            || host.split(separator: ".").count == 4 && host.hasPrefix("127.") && host.split(separator: ".").allSatisfy { UInt8($0) != nil }
        return loopback ? url : nil
    }

    /// Reports to `update` and starts checking on Sparkle's schedule.
    func start(reportingTo update: SoftwareUpdate) {
        driver.update = update
        // Sparkle changes it on the main thread.
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak update] updater, _ in
            MainActor.assumeIsolated { update?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        do {
            try updater.start()
        } catch {
            NSLog("Axo couldn't start software updates: %@", error.localizedDescription)
        }
    }

    func checkForUpdates() { updater.checkForUpdates() }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    var includesBetaVersions: Bool {
        get { settings.bool(forKey: Self.includesBetasKey) }
        set { settings.set(newValue, forKey: Self.includesBetasKey) }
    }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }
}

extension SparkleUpdater: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        includesBetaVersions ? ["beta"] : []
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedOverride(settings.string(forKey: Self.feedOverrideKey))?.absoluteString
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard let update = driver.update else { return false }
        update.updaterWillInstallOnQuit(version: item.displayVersionString, installNow: immediateInstallHandler)
        // Axo says so itself: the notice and Restart to Update Axo.
        return true
    }
}

/// Sparkle's calls, passed to ``SoftwareUpdate`` in Axo's terms. Sparkle's protocols are
/// main-actor isolated, as is this.
final class SparkleUserDriver: NSObject {
    weak var update: SoftwareUpdate?

    /// Sparkle's answer for Axo's `choice`.
    static func sparkleChoice(_ choice: SoftwareUpdate.Choice) -> SPUUserUpdateChoice {
        switch choice {
        case .install: .install
        case .skip: .skip
        case .later: .dismiss
        }
    }

    /// Axo's offer for Sparkle's `item`.
    static func offer(for item: SUAppcastItem, state: SPUUserUpdateState) -> SoftwareUpdate.Offer {
        let notes: String? = if let description = item.itemDescription {
            SoftwareUpdate.releaseNotesText(description, format: item.itemDescriptionFormat)
        } else if item.releaseNotesURL != nil {
            // Sparkle downloads them, then calls showUpdateReleaseNotes.
            nil
        } else {
            ""
        }
        let stage: SoftwareUpdate.Stage = switch state.stage {
        case .downloaded: .downloaded
        case .installing: .installing
        default: .notDownloaded
        }
        return SoftwareUpdate.Offer(
            version: item.displayVersionString, releaseNotes: notes, isCritical: item.isCriticalUpdate,
            isInformational: item.isInformationOnlyUpdate, infoURL: item.infoURL, stage: stage,
            isUserInitiated: state.userInitiated)
    }
}

extension SparkleUserDriver: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Axo's Info.plist turns automatic checks on, so Sparkle shouldn't ask; if it does, the
        // answer matches (and sends nothing about this Mac).
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        update?.updaterStartedCheck(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let update else { return reply(.dismiss) }
        update.updaterFound(Self.offer(for: appcastItem, state: state)) { reply(Self.sparkleChoice($0)) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let encoding = downloadData.textEncodingName
            .map { CFStringConvertIANACharSetNameToEncoding($0 as CFString) }
            .flatMap { $0 == kCFStringEncodingInvalidId ? nil : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding($0)) }
            ?? .utf8
        let text = String(data: downloadData.data, encoding: encoding) ?? ""
        let format = downloadData.mimeType?.lowercased().hasPrefix("text/plain") == true ? "plain-text" : "html"
        update?.updaterLoadedReleaseNotes(SoftwareUpdate.releaseNotesText(text, format: format))
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        update?.updaterLoadedReleaseNotes("The release notes couldn’t be loaded.")
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard let update else { return acknowledgement() }
        let info = (error as NSError).userInfo
        let reason = SparkleErrors.noUpdateReason(
            code: (info[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue,
            latestVersion: (info[SPULatestAppcastItemFoundKey] as? SUAppcastItem)?.displayVersionString,
            minimumSystem: (info[SPULatestAppcastItemFoundKey] as? SUAppcastItem)?.minimumSystemVersion)
        update.updaterFoundNoUpdate(reason, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard let update else { return acknowledgement() }
        let error = error as NSError
        update.updaterFailed(SparkleErrors.failure(domain: error.domain, code: error.code, description: error.localizedDescription),
                             acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        update?.updaterStartedDownload(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        update?.updaterExpectsDownloadLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        update?.updaterReceivedDownloadData(length: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        update?.updaterStartedExtracting()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        update?.updaterExtracted(progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let update else { return reply(.dismiss) }
        update.updaterReadyToInstall { reply(Self.sparkleChoice($0)) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        update?.updaterInstalling(applicationTerminated: applicationTerminated, retry: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        guard let update else { return acknowledgement() }
        update.updaterInstalled(acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        update?.updaterShowsInFocus()
    }

    func dismissUpdateInstallation() {
        update?.updaterDismissed()
    }
}

/// Sparkle's errors in Axo's terms, by their domain and code, so tests need no Sparkle objects.
nonisolated enum SparkleErrors {
    /// Sparkle's error domain.
    static let domain = "SUSparkleErrorDomain"

    /// What went wrong, for the alert.
    static func failure(domain: String, code: Int, description: String) -> SoftwareUpdate.Failure {
        if domain == NSURLErrorDomain { return .couldNotCheck }
        guard domain == Self.domain else { return .other(description) }
        switch code {
        case 1000, 1002, 1004, 3, 4: // the feed couldn't be read or reached
            return .couldNotCheck
        case 1003, 1005: // running from the disk image, or translocated
            return .other("Axo can’t update itself while it runs from its disk image. Move Axo to your Applications folder, open it from there, then try again.")
        case 2000, 2001:
            return .couldNotDownload
        case 3000, 3001, 3002, 4009, 2:
            return .couldNotVerify
        case 4000...4012:
            return .couldNotInstall
        default:
            return .other(description)
        }
    }

    /// Why a check found nothing, from Sparkle's `SPUNoUpdateFoundReason`.
    static func noUpdateReason(code: Int?, latestVersion: String?, minimumSystem: String?) -> SoftwareUpdate.NoUpdateReason {
        switch code {
        case 2: .newerThanLatest
        case 3: .systemTooOld(version: latestVersion, minimumSystem: minimumSystem)
        case 4: .systemTooNew(version: latestVersion)
        case 5: .unsupportedHardware(version: latestVersion)
        default: .onLatestVersion
        }
    }
}

/// The updater in test runs: it never checks for updates. A check finds nothing, or, with
/// `AXO_UI_TESTING_UPDATE=available`, offers a version 99.0 that "downloads" and "installs"
/// without doing anything, so UI tests can walk Software Update's windows. The Testing menu's
/// Download an Update in the Background shows the notice and Restart to Update Axo.
final class StandInSoftwareUpdater: SoftwareUpdater {
    /// The stand-in's update's version.
    static let version = "99.0"

    weak var update: SoftwareUpdate? {
        didSet { update?.canCheckForUpdates = true }
    }
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = false
    var includesBetaVersions = false
    private(set) var lastUpdateCheckDate: Date?
    /// Whether a check offers an update.
    let offersUpdate: Bool
    /// How many times Restart to Update Axo asked to install, for tests.
    private(set) var restartRequests = 0
    private var session = 0

    init(offersUpdate: Bool) {
        self.offersUpdate = offersUpdate
    }

    func checkForUpdates() {
        guard let update else { return }
        session += 1
        let session = session
        update.canCheckForUpdates = false
        update.updaterStartedCheck { [weak self] in self?.end() }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.session == session, let update = self.update else { return }
            lastUpdateCheckDate = .now
            if offersUpdate {
                let offer = SoftwareUpdate.Offer(
                    version: Self.version,
                    releaseNotes: "New\n• Space themes: give each Space its own colors.\n\nFixed\n• Find in page counts matches as you type.")
                update.updaterFound(offer) { [weak self] choice in
                    if choice == .install { self?.download(session: session) } else { self?.end() }
                }
            } else {
                update.updaterFoundNoUpdate(.onLatestVersion) { [weak self] in self?.end() }
            }
        }
    }

    /// Reports an update that downloaded in the background.
    func downloadInBackground() {
        update?.updaterWillInstallOnQuit(version: Self.version) { [weak self] in self?.restartRequests += 1 }
    }

    private func download(session: Int) {
        guard let update else { return }
        update.updaterStartedDownload { [weak self] in self?.end() }
        update.updaterExpectsDownloadLength(4_000_000)
        Task { [weak self] in
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.session == session else { return }
                self.update?.updaterReceivedDownloadData(length: 1_000_000)
            }
            guard let self, self.session == session, let update = self.update else { return }
            update.updaterStartedExtracting()
            update.updaterExtracted(progress: 1)
            update.updaterReadyToInstall { [weak self] _ in
                // Nothing to install: the session just ends.
                self?.update?.updaterDismissed()
                self?.end()
            }
        }
    }

    private func end() {
        session += 1
        update?.canCheckForUpdates = true
    }
}
