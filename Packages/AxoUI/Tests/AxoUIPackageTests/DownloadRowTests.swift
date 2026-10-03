import AxoCore
import Foundation
import Testing
import WebKit
@testable import AxoUI
@testable import AxoWeb

@MainActor
struct DownloadRowTests {
    private func item(_ state: DownloadState, completed: Int64 = 0, total: Int64? = nil) -> DownloadItem {
        let item = DownloadItem(download: nil, sourceURL: URL(string: "https://example.com/file.zip"), sourceTabID: nil)
        item.state = state
        item.completedBytes = completed
        item.totalBytes = total
        return item
    }

    @Test func statusShowsProgressSizeOrProblem() {
        let format = ByteCountFormatStyle(style: .file)
        let mb = Int64(1_000_000)
        #expect(DownloadRow.status(for: item(.inProgress, completed: 2 * mb, total: 10 * mb))
            == "\((2 * mb).formatted(format)) of \((10 * mb).formatted(format))")
        #expect(DownloadRow.status(for: item(.inProgress, completed: 2 * mb)) == (2 * mb).formatted(format))
        #expect(DownloadRow.status(for: item(.finished, total: 10 * mb)) == (10 * mb).formatted(format))
        #expect(DownloadRow.status(for: item(.finished)) == "Done")
        #expect(DownloadRow.status(for: item(.failed("The network connection was lost."))) == "Failed: The network connection was lost.")
        #expect(DownloadRow.status(for: item(.cancelled)) == "Cancelled")
    }

    @Test func itemsNameThemselvesFromTheirSourceUntilWebKitSuggestsAName() {
        #expect(item(.inProgress).filename == "file.zip")
        let unnamed = DownloadItem(download: nil, sourceURL: nil, sourceTabID: nil)
        #expect(unnamed.filename == "Download")
    }
}
