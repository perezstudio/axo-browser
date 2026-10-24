import AxoCore
import Foundation
import Observation

/// The state of a download.
public enum DownloadState: Equatable, Sendable {
    /// Bytes are still arriving.
    case inProgress
    /// The file is complete at ``DownloadItem/destination``.
    case finished
    /// The download stopped with an error, described for display.
    case failed(String)
    /// Someone cancelled the download.
    case cancelled
}

/// One download, observable for the downloads list.
@MainActor
@Observable
public final class DownloadItem: Identifiable {
    /// A stable identifier for lists.
    public let id = UUID()
    /// The URL the file came from, if known.
    public let sourceURL: URL?
    /// The tab that started the download, if any.
    public let sourceTabID: Tab.ID?
    /// The file name, known once the engine suggests one.
    public internal(set) var filename: String
    /// Where the file is being saved, once chosen.
    public internal(set) var destination: URL?
    /// Where the download stands.
    public internal(set) var state: DownloadState = .inProgress
    /// Progress from 0 to 1, or `nil` while the total size is unknown.
    public internal(set) var fractionCompleted: Double?
    /// Bytes received so far.
    public internal(set) var completedBytes: Int64 = 0
    /// The expected size in bytes, or `nil` if the server didn't say.
    public internal(set) var totalBytes: Int64?

    /// Stops the engine's download.
    @ObservationIgnored private let cancelDownload: @MainActor () -> Void
    @ObservationIgnored weak var manager: DownloadManager?

    init(sourceURL: URL?, sourceTabID: Tab.ID?, manager: DownloadManager, cancel: @escaping @MainActor () -> Void) {
        self.sourceURL = sourceURL
        self.sourceTabID = sourceTabID
        self.manager = manager
        self.cancelDownload = cancel
        self.filename = sourceURL?.lastPathComponent.nilIfEmpty ?? "Download"
    }

    /// Whether the download is still running.
    public var isActive: Bool {
        state == .inProgress
    }

    // MARK: Reporting, for engines

    /// Chooses where the file goes: a unique name for `suggestedFilename` in the manager's
    /// folder. Returns `nil`, failing the download, if the folder can't be created or the
    /// download already stopped. Engines call it once, when they know the file's name.
    public func chooseDestination(suggestedFilename: String, expectedLength: Int64?) -> URL? {
        guard isActive, let manager else { return nil }
        do {
            try FileManager.default.createDirectory(at: manager.directory, withIntermediateDirectories: true)
        } catch {
            reportFailed("Axo couldn't create the Downloads folder.")
            return nil
        }
        let destination = DownloadManager.uniqueDestination(for: suggestedFilename, in: manager.directory)
        filename = destination.lastPathComponent
        self.destination = destination
        if let expectedLength, expectedLength > 0 {
            totalBytes = expectedLength
        }
        return destination
    }

    /// Reports bytes received so far, and the total when known (`0` or less if not).
    public func reportProgress(completedBytes completed: Int64, totalBytes total: Int64) {
        guard isActive else { return }
        completedBytes = completed
        if total > 0 {
            totalBytes = total
            fractionCompleted = Double(completed) / Double(total)
        }
    }

    /// Reports that the file is complete at ``destination``. Quarantines it on the Mac.
    public func reportFinished() {
        guard isActive else { return }
        state = .finished
        fractionCompleted = 1
        if let destination {
            DownloadManager.markQuarantined(destination, sourceURL: sourceURL)
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                completedBytes = Int64(size)
                totalBytes = Int64(size)
            }
        }
        manager?.onEnd?(self)
    }

    /// Reports that the download stopped with an error, described for display.
    public func reportFailed(_ message: String) {
        guard isActive else { return }
        state = .failed(message)
        manager?.onEnd?(self)
    }

    /// Cancels the engine's download. Called by ``DownloadManager/cancel(_:)``.
    func cancelForPerson() {
        guard isActive else { return }
        state = .cancelled
        cancelDownload()
        manager?.onEnd?(self)
    }
}

/// Tracks every download in the app and decides where files go.
///
/// Engines start downloads with ``begin(sourceURL:sourceTabID:cancel:)`` and report on the item
/// it returns, so the list doesn't depend on which engine made a download.
///
/// Files are saved in ``directory`` with unique, Finder-style names. Finished files get the
/// macOS quarantine attribute, so Gatekeeper checks them before they first open, as it does
/// for downloads from Safari.
@MainActor
@Observable
public final class DownloadManager {
    /// Downloads, newest first.
    public private(set) var items: [DownloadItem] = []
    /// Called when a download stops: finished, failed, or cancelled. The app uses it to tell
    /// VoiceOver users.
    @ObservationIgnored public var onEnd: ((DownloadItem) -> Void)?

    /// The folder files are saved in.
    @ObservationIgnored public let directory: URL

    /// Creates a manager that saves into `directory`, the user's Downloads folder by default.
    public init(directory: URL = .downloadsDirectory) {
        self.directory = directory
    }

    /// The number of downloads still running.
    public var activeCount: Int {
        items.filter(\.isActive).count
    }

    /// Adds a download an engine started, newest first, and returns the item the engine reports
    /// to. `cancel` stops the engine's download when the person cancels it.
    public func begin(sourceURL: URL?, sourceTabID: Tab.ID?, cancel: @escaping @MainActor () -> Void) -> DownloadItem {
        let item = DownloadItem(sourceURL: sourceURL, sourceTabID: sourceTabID, manager: self, cancel: cancel)
        items.insert(item, at: 0)
        return item
    }

    /// Cancels a running download and removes its partial file. Does nothing otherwise.
    public func cancel(_ item: DownloadItem) {
        guard item.isActive else { return }
        item.cancelForPerson()
        if let destination = item.destination {
            try? FileManager.default.removeItem(at: destination)
        }
    }

    /// Removes a download from the list. A running download is cancelled first. The file stays.
    public func remove(_ item: DownloadItem) {
        cancel(item)
        items.removeAll { $0 === item }
    }

    /// Removes every download that isn't running. Files stay where they are.
    public func clearInactive() {
        items.removeAll { !$0.isActive }
    }

    // MARK: Helpers

    /// A destination in `directory` that doesn't exist yet: `name.ext`, then `name 2.ext`, and
    /// so on, like Finder. Path separators and leading dots are removed from the suggested name.
    nonisolated static func uniqueDestination(for suggestedFilename: String, in directory: URL) -> URL {
        var name = suggestedFilename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Download" }

        let candidate = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        while true {
            let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let url = directory.appending(path: numbered)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }

    /// Adds the quarantine attribute that marks `file` as downloaded from the web by Axo, so
    /// Gatekeeper checks it. (iOS has no quarantine; its sandbox covers downloads.)
    nonisolated static func markQuarantined(_ file: URL, sourceURL: URL?) {
        #if os(macOS)
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Axo",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let sourceURL, let scheme = sourceURL.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            properties[kLSQuarantineDataURLKey as String] = sourceURL
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var file = file
        try? file.setResourceValues(values)
        #endif
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
