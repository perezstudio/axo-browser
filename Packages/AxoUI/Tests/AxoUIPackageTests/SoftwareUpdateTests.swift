#if os(macOS)
import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Software Update (#180): the updater's states in Axo's wording, each reply sent back exactly
/// once, the window shown and closed, Settings' switches, and the update-ready notice and Restart
/// to Update Axo. A fake updater stands in for Sparkle, reporting what Sparkle's user driver
/// would.
@MainActor
struct SoftwareUpdateTests {
    @MainActor final class FakeUpdater: SoftwareUpdater {
        var checks = 0
        var automaticallyChecksForUpdates = true
        var automaticallyDownloadsUpdates = false
        var includesBetaVersions = false
        var lastUpdateCheckDate: Date?
        func checkForUpdates() { checks += 1 }
    }

    @MainActor final class FakeWindow: SoftwareUpdatePresenting {
        var shows: [Bool] = []
        var closes = 0
        var isOpen = false
        func show(activate: Bool) { shows.append(activate); isOpen = true }
        func close() { closes += 1; isOpen = false }
    }

    /// Every reply the update sent back, in order.
    @MainActor final class Replies {
        var choices: [SoftwareUpdate.Choice] = []
        var cancellations = 0
        var acknowledgements = 0
        var retries = 0
        var installs = 0
    }

    let updater = FakeUpdater()
    let window = FakeWindow()
    let replies = Replies()
    let update: SoftwareUpdate

    init() {
        update = SoftwareUpdate(currentVersion: "1.0.3", updater: updater)
        update.presenter = window
        update.canCheckForUpdates = true
    }

    private func offer(_ version: String = "1.1", isCritical: Bool = false, isInformational: Bool = false,
                       stage: SoftwareUpdate.Stage = .notDownloaded, userInitiated: Bool = true) {
        let replies = replies
        update.updaterFound(
            SoftwareUpdate.Offer(version: version, releaseNotes: "Notes", isCritical: isCritical, isInformational: isInformational,
                                 infoURL: URL(string: "https://example.com/1.1"), stage: stage, isUserInitiated: userInitiated)
        ) { replies.choices.append($0) }
    }

    private func startCheck() {
        let replies = replies
        update.updaterStartedCheck { replies.cancellations += 1 }
    }

    // MARK: Checking

    @Test func checkingAsksTheUpdaterOnlyWhenItCan() {
        update.checkForUpdates()
        #expect(updater.checks == 1)

        update.canCheckForUpdates = false
        update.checkForUpdates()
        #expect(updater.checks == 1, "Not while a session is under way")
    }

    @Test func aCheckShowsTheStatusWindowAndCancelStopsIt() {
        startCheck()
        #expect(update.phase == .checking)
        #expect(window.shows == [true], "A check the person asked for brings Axo forward")
        #expect(update.status?.title == "Checking for updates…")

        update.cancel()
        update.cancel()
        #expect(replies.cancellations == 1, "Cancelled once")
        #expect(update.phase == .idle)
        #expect(!window.isOpen)
    }

    @Test func checkingAgainDuringASessionShowsItsWindow() {
        startCheck()
        update.canCheckForUpdates = false
        update.checkForUpdates()
        #expect(window.shows == [true, true])
        #expect(updater.checks == 0)
    }

    @Test func closingTheWindowWhileCheckingCancels() {
        startCheck()
        update.windowClosed()
        #expect(replies.cancellations == 1)
        #expect(update.phase == .idle)
    }

    // MARK: An offer

    @Test func installUpdateRepliesInstallAndKeepsTheWindowForTheDownload() {
        startCheck()
        offer()
        #expect(update.phase == .found(.init(version: "1.1", releaseNotes: "Notes", infoURL: URL(string: "https://example.com/1.1"))))

        update.install()
        update.install()
        #expect(replies.choices == [.install], "Sent once")
        #expect(window.isOpen, "The download shows next, in the same window")
        #expect(replies.cancellations == 0, "Moving on from the check doesn't cancel it")
    }

    @Test func skipAndRemindLaterReplyAndClose() {
        offer()
        update.skipVersion()
        #expect(replies.choices == [.skip])
        #expect(update.phase == .idle)
        #expect(window.closes == 1)

        offer()
        update.remindLater()
        #expect(replies.choices == [.skip, .later])
        #expect(update.pendingRestart == nil, "Nothing downloaded, so nothing to restart for")
    }

    @Test func closingTheOfferRemindsLater() {
        offer()
        update.windowClosed()
        #expect(replies.choices == [.later])
    }

    @Test func aCriticalUpdateCantBeSkipped() {
        offer(isCritical: true)
        update.skipVersion()
        #expect(replies.choices.isEmpty)
        #expect(update.phase != .idle)
    }

    @Test func anInformationalUpdateOpensItsPageInsteadOfInstalling() {
        var opened: [URL] = []
        update.openURL = { opened.append($0) }
        offer(isInformational: true)
        update.install()
        #expect(opened == [URL(string: "https://example.com/1.1")!])
        #expect(replies.choices == [.later], "Nothing to install")
    }

    @Test func anUpdateFoundInTheBackgroundDoesntBringAxoForward() {
        offer(userInitiated: false)
        #expect(window.shows == [false])
    }

    @Test func releaseNotesArriveLater() {
        update.updaterFound(.init(version: "1.1")) { _ in }
        update.updaterLoadedReleaseNotes("Fixed things.")
        guard case .found(let offer) = update.phase else { Issue.record("Not an offer"); return }
        #expect(offer.releaseNotes == "Fixed things.")
    }

    @Test func theCheckboxTurnsOnAutomaticUpdates() {
        update.automaticallyDownloadsUpdates = true
        #expect(updater.automaticallyDownloadsUpdates)
    }

    // MARK: Downloading, unpacking, installing

    @Test func aDownloadCountsItsBytesAndCancels() {
        let replies = replies
        update.updaterStartedDownload { replies.cancellations += 1 }
        #expect(update.status?.detail == SoftwareUpdate.downloadDetail(received: 0, expected: nil))
        update.updaterExpectsDownloadLength(1_000_000)
        update.updaterReceivedDownloadData(length: 250_000)
        update.updaterReceivedDownloadData(length: 250_000)
        #expect(update.phase == .downloading(received: 500_000, expected: 1_000_000))
        #expect(update.status?.detail == SoftwareUpdate.downloadDetail(received: 500_000, expected: 1_000_000))
        #expect(update.status?.detail.contains(" of ") == true)

        update.windowClosed()
        #expect(replies.cancellations == 1)
        #expect(update.phase == .idle)
    }

    @Test func aDownloadLargerThanPromisedGrowsTheTotal() {
        update.updaterStartedDownload {}
        update.updaterExpectsDownloadLength(100)
        update.updaterReceivedDownloadData(length: 150)
        #expect(update.phase == .downloading(received: 150, expected: 150))
    }

    @Test func unpackingCantBeCancelledAndClosingOnlyHidesIt() {
        update.updaterStartedExtracting()
        update.updaterExtracted(progress: 1.5)
        #expect(update.phase == .extracting(progress: 1))
        update.cancel()
        update.windowClosed()
        #expect(update.phase == .extracting(progress: 1))
    }

    @Test func readyInstallsAndRelaunches() {
        let replies = replies
        update.updaterReadyToInstall { replies.choices.append($0) }
        #expect(update.status?.title == "Ready to Install")
        update.install()
        #expect(replies.choices == [.install])

        update.updaterInstalling(applicationTerminated: false) { replies.retries += 1 }
        #expect(update.phase == .installing(canRetry: true))
        update.install()
        update.install()
        #expect(replies.retries == 1, "Asks Axo to quit again, once")

        update.updaterInstalling(applicationTerminated: true) { replies.retries += 1 }
        update.install()
        #expect(replies.retries == 1, "Nothing to retry once Axo has quit")

        update.updaterInstalled { replies.acknowledgements += 1 }
        #expect(replies.acknowledgements == 1)
        #expect(update.phase == .idle)
    }

    @Test func puttingOffAReadyUpdateOffersRestartToUpdateWhichResumesIt() {
        offer("1.2")
        update.install()
        let replies = replies
        update.updaterReadyToInstall { replies.choices.append($0) }
        update.windowClosed()
        #expect(replies.choices == [.install, .later])
        #expect(update.pendingRestart?.version == "1.2")

        update.restartToUpdate()
        #expect(updater.checks == 1, "Checking again resumes the update")
        #expect(update.pendingRestart == nil)
    }

    // MARK: Nothing new, or a failure

    @Test func upToDateSaysSoAndOKAcknowledges() {
        let replies = replies
        update.updaterFoundNoUpdate(.onLatestVersion) { replies.acknowledgements += 1 }
        #expect(update.alertTitle == "You’re up to date!")
        #expect(update.alertMessage == "Axo 1.0.3 is currently the newest version available.")
        update.acknowledge()
        update.acknowledge()
        #expect(replies.acknowledgements == 1)
        #expect(!window.isOpen)
    }

    @Test(arguments: [
        (SoftwareUpdate.NoUpdateReason.newerThanLatest, "You’re up to date!", "Axo 1.0.3 is newer than the newest version available."),
        (.systemTooOld(version: "2.0", minimumSystem: "28.0"), "This Mac can’t install the newest Axo", "Axo 2.0 needs macOS 28.0 or later."),
        (.systemTooOld(version: nil, minimumSystem: nil), "This Mac can’t install the newest Axo", "The newest Axo needs a newer version of macOS."),
        (.systemTooNew(version: "2.0"), "This Mac can’t install the newest Axo", "Axo 2.0 doesn’t run on this version of macOS."),
        (.unsupportedHardware(version: "2.0"), "This Mac can’t install the newest Axo", "Axo 2.0 doesn’t run on this Mac’s processor."),
    ])
    func whyNothingInstalls(reason: SoftwareUpdate.NoUpdateReason, title: String, message: String) {
        update.updaterFoundNoUpdate(reason) {}
        #expect(update.alertTitle == title)
        #expect(update.alertMessage == message)
    }

    @Test func aFailedCheckSaysSoAndTryAgainChecksAgain() {
        let replies = replies
        update.updaterFailed(.couldNotCheck) { replies.acknowledgements += 1 }
        #expect(update.alertTitle == "Couldn’t check for updates")
        #expect(update.alertMessage.contains("Check your internet connection"))

        update.tryAgain()
        #expect(replies.acknowledgements == 1)
        #expect(updater.checks == 1)
    }

    @Test(arguments: [
        (SoftwareUpdate.Failure.couldNotDownload, "The update didn’t download. Check your internet connection, then try again."),
        (.couldNotVerify, "The update couldn’t be verified, so Axo didn’t install it. You still have Axo 1.0.3."),
        (.couldNotInstall, "The update couldn’t be installed. You still have Axo 1.0.3."),
        (.other("Something odd."), "Something odd."),
    ])
    func failuresSayWhatHappened(failure: SoftwareUpdate.Failure, message: String) {
        update.updaterFailed(failure) {}
        #expect(update.alertTitle == "Couldn’t update Axo")
        #expect(update.alertMessage == message)
    }

    @Test func closingAnAlertAcknowledgesIt() {
        let replies = replies
        update.updaterFailed(.couldNotCheck) { replies.acknowledgements += 1 }
        update.windowClosed()
        #expect(replies.acknowledgements == 1)
        #expect(updater.checks == 0, "Closing isn't Try Again")
    }

    // MARK: The updater moving on

    @Test func dismissingTheSessionClosesWithoutReplying() {
        offer()
        update.updaterDismissed()
        #expect(update.phase == .idle)
        #expect(!window.isOpen)
        update.install()
        update.remindLater()
        #expect(replies.choices.isEmpty, "Sparkle no longer waits for an answer")
    }

    @Test func aNewStateDropsTheOldOnesReply() {
        startCheck()
        offer()
        update.cancel()
        #expect(replies.cancellations == 0, "The check's cancellation went with the check")
    }

    @Test func showInFocusBringsAnOpenWindowForward() {
        update.updaterShowsInFocus()
        #expect(window.shows.isEmpty, "Nothing to show")
        offer(userInitiated: false)
        update.updaterShowsInFocus()
        #expect(window.shows == [false, true])
    }

    // MARK: Settings

    @Test func settingsWriteThroughToTheUpdater() {
        update.automaticallyChecksForUpdates = false
        update.includesBetaVersions = true
        #expect(!updater.automaticallyChecksForUpdates)
        #expect(updater.includesBetaVersions)
    }

    @Test func settingsReadTheUpdaterAgain() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        updater.lastUpdateCheckDate = date
        updater.automaticallyDownloadsUpdates = true
        update.refreshSettings()
        #expect(update.lastUpdateCheckDate == date)
        #expect(update.automaticallyDownloadsUpdates)
    }

    @Test func lastCheckedSaysWhen() {
        #expect(SoftwareUpdateSettings.lastChecked(nil) == "Not checked yet")
        let text = SoftwareUpdateSettings.lastChecked(.now, locale: Locale(identifier: "en_US"))
        #expect(text.hasPrefix("Last checked Today at"))
    }

    // MARK: Release notes

    @Test func plainTextNotesStayAsTheyAre() {
        #expect(SoftwareUpdate.releaseNotesText("  New\n• <b>Themes</b>  ", format: "plain-text") == "New\n• <b>Themes</b>")
    }

    @Test func htmlNotesBecomeTextWithoutRunningAnything() {
        let html = """
        <h2>Axo 1.1</h2><ul><li>Space themes</li><li>Swipes &amp; more</li></ul>
        <script>alert(1)</script><p>Fixed<br>bugs</p><img src="https://example.com/x.png">
        """
        #expect(SoftwareUpdate.releaseNotesText(html, format: nil) == "Axo 1.1\n\n• Space themes\n• Swipes & more\n\nFixed\nbugs")
    }

    // MARK: In the background

    @Test func anUpdateReadyOnQuitPostsANoticeAndRestartToUpdateInstallsIt() async throws {
        let pool = WebViewPool(engine: FakeEngine())
        pool.reportsScreenTimeUsage = false
        let model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        var announced: [String] = []
        model.announce = { announced.append($0) }
        model.noticeSleep = { _ in }
        model.softwareUpdate = update

        let replies = replies
        update.updaterWillInstallOnQuit(version: "1.1") { replies.installs += 1 }
        #expect(update.pendingRestart?.version == "1.1")
        let notice = try #require(model.notice)
        #expect(notice.message == "Axo 1.1 is ready. It installs the next time Axo quits.")
        #expect(notice.actionTitle == "Restart Now")
        #expect(announced.last == "Axo 1.1 is ready. It installs the next time Axo quits. Restart Now is available.")

        await model.undoNotice()
        #expect(replies.installs == 1, "Restart Now installs it")
        #expect(update.pendingRestart == nil)
        update.restartToUpdate()
        #expect(replies.installs == 1, "Once")
        #expect(updater.checks == 0)
    }
}
#endif
