import AxoCore
import Foundation
import Observation
import WebKit

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
    /// The file name, known once WebKit suggests one.
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

    @ObservationIgnored let download: WKDownload?
    @ObservationIgnored var progressObservations: [NSKeyValueObservation] = []

    init(download: WKDownload?, sourceURL: URL?, sourceTabID: Tab.ID?) {
        self.download = download
        self.sourceURL = sourceURL
        self.sourceTabID = sourceTabID
        self.filename = sourceURL?.lastPathComponent.nilIfEmpty ?? "Download"
    }

    /// Whether the download is still running.
    public var isActive: Bool {
        state == .inProgress
    }
}

/// Tracks every download in the app and decides where files go.
///
/// Files are saved in ``directory`` with unique, Finder-style names. Finished files get the
/// macOS quarantine attribute, so Gatekeeper checks them before they first open, as it does
/// for downloads from Safari.
@MainActor
@Observable
public final class DownloadManager: NSObject, WKDownloadDelegate {
    /// Downloads, newest first.
    public private(set) var items: [DownloadItem] = []
    /// Called when a download stops: finished, failed, or cancelled. The app uses it to tell
    /// VoiceOver users.
    @ObservationIgnored public var onEnd: ((DownloadItem) -> Void)?

    /// The folder files are saved in.
    @ObservationIgnored public let directory: URL

    @ObservationIgnored private var itemsByDownload: [ObjectIdentifier: DownloadItem] = [:]

    /// Creates a manager that saves into `directory`, the user's Downloads folder by default.
    public init(directory: URL = .downloadsDirectory) {
        self.directory = directory
    }

    /// The number of downloads still running.
    public var activeCount: Int {
        items.filter(\.isActive).count
    }

    /// Starts tracking a download that WebKit created for a navigation.
    func track(_ download: WKDownload, sourceTabID: Tab.ID?) {
        let item = DownloadItem(download: download, sourceURL: download.originalRequest?.url, sourceTabID: sourceTabID)
        download.delegate = self
        itemsByDownload[ObjectIdentifier(download)] = item
        items.insert(item, at: 0)
        observeProgress(of: download, for: item)
    }

    /// Cancels a running download and removes its partial file. Does nothing otherwise.
    public func cancel(_ item: DownloadItem) {
        guard item.isActive else { return }
        item.state = .cancelled
        item.download?.cancel { _ in }
        finish(item)
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

    // MARK: WKDownloadDelegate

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        guard let item = itemsByDownload[ObjectIdentifier(download)], item.isActive else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            item.state = .failed("Axo couldn't create the Downloads folder.")
            finish(item)
            return nil
        }
        let destination = Self.uniqueDestination(for: suggestedFilename, in: directory)
        item.filename = destination.lastPathComponent
        item.destination = destination
        if response.expectedContentLength > 0 {
            item.totalBytes = response.expectedContentLength
        }
        return destination
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let item = itemsByDownload[ObjectIdentifier(download)] else { return }
        item.state = .finished
        item.fractionCompleted = 1
        if let destination = item.destination {
            Self.markQuarantined(destination, sourceURL: item.sourceURL)
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                item.completedBytes = Int64(size)
                item.totalBytes = Int64(size)
            }
        }
        finish(item)
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = itemsByDownload[ObjectIdentifier(download)], item.isActive else { return }
        item.state = .failed(error.localizedDescription)
        finish(item)
    }

    // MARK: Helpers

    private func observeProgress(of download: WKDownload, for item: DownloadItem) {
        // Progress may report on any thread, so hop to the main actor before touching the item.
        item.progressObservations = [
            download.progress.observe(\.fractionCompleted, options: [.new]) { [weak item] progress, _ in
                let completed = progress.completedUnitCount
                let total = progress.totalUnitCount
                Task { @MainActor in
                    guard let item, item.isActive else { return }
                    item.completedBytes = completed
                    if total > 0 {
                        item.totalBytes = total
                        item.fractionCompleted = Double(completed) / Double(total)
                    }
                }
            },
        ]
    }

    private func finish(_ item: DownloadItem) {
        defer { onEnd?(item) }
        item.progressObservations.forEach { $0.invalidate() }
        item.progressObservations = []
        if let download = item.download {
            itemsByDownload[ObjectIdentifier(download)] = nil
        }
    }

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
