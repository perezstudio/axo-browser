import AppKit
import AxoWeb
import SwiftUI

/// The toolbar button that opens the downloads list. It appears once there's a download.
struct DownloadsButton: View {
    @Bindable var model: BrowserModel

    var body: some View {
        let downloads = model.pool.downloads
        Button {
            model.isShowingDownloads.toggle()
        } label: {
            Label("Downloads", systemImage: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .help(downloads.activeCount > 0 ? "Downloads (\(downloads.activeCount) in progress)" : "Downloads")
        .accessibilityValue(downloads.activeCount > 0 ? "\(downloads.activeCount) in progress" : "")
        .accessibilityIdentifier("downloadsButton")
        .popover(isPresented: $model.isShowingDownloads, arrowEdge: .bottom) {
            DownloadsList(downloads: downloads)
        }
    }
}

/// The list of downloads, newest first.
struct DownloadsList: View {
    let downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear") { downloads.clearInactive() }
                    .disabled(downloads.items.allSatisfy(\.isActive))
                    .accessibilityIdentifier("clearDownloadsButton")
            }
            .padding(12)
            Divider()
            if downloads.items.isEmpty {
                Text("No downloads")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(downloads.items) { item in
                            DownloadRow(item: item, downloads: downloads)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Downloads")
        .accessibilityIdentifier("downloadsList")
    }
}

/// One download: the file's icon and name, its status, and actions.
struct DownloadRow: View {
    let item: DownloadItem
    let downloads: DownloadManager

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.isActive {
                    ProgressView(value: item.fractionCompleted)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(Self.status(for: item))
                    .font(.caption)
                    .foregroundStyle(statusStyle)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // One element for VoiceOver, with the buttons as its actions.
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if item.isActive {
                Button("Cancel Download") { downloads.cancel(item) }
            } else if item.state == .finished, let destination = item.destination {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            }
        }
        .accessibilityIdentifier("downloadRow")
    }

    @ViewBuilder
    private var actions: some View {
        if item.isActive {
            Button("Cancel", systemImage: "xmark.circle.fill") { downloads.cancel(item) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Cancel download")
        } else if item.state == .finished, let destination = item.destination {
            Button("Show in Finder", systemImage: "magnifyingglass.circle.fill") {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
    }

    private var icon: NSImage {
        if let destination = item.destination, FileManager.default.fileExists(atPath: destination.path) {
            return NSWorkspace.shared.icon(forFile: destination.path)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private var statusStyle: AnyShapeStyle {
        if case .failed = item.state { return AnyShapeStyle(.red) }
        return AnyShapeStyle(.secondary)
    }

    /// The status line: bytes so far while running, the size when done, or what went wrong.
    static func status(for item: DownloadItem) -> String {
        let format = ByteCountFormatStyle(style: .file)
        switch item.state {
        case .inProgress:
            let done = item.completedBytes.formatted(format)
            if let total = item.totalBytes { return "\(done) of \(total.formatted(format))" }
            return done
        case .finished:
            return item.totalBytes.map { $0.formatted(format) } ?? "Done"
        case .failed(let message):
            return "Failed: \(message)"
        case .cancelled:
            return "Cancelled"
        }
    }
}
