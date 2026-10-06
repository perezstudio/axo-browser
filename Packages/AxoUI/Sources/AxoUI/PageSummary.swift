import AxoCore
import AxoWeb
import SwiftUI

/// Writes short page summaries on this Mac. AxoIntegration's `PageSummarizer` provides the
/// real implementation, with the on-device Apple Intelligence model.
public protocol PageSummarizing: Sendable {
    /// Why summaries can't be made right now, in plain words, or `nil` when they can.
    var unavailableReason: String? { get }
    /// Summarizes a page from its title, address, and text.
    func summarize(title: String, url: URL?, text: String) async throws -> String
}

/// The summary popover's state.
public enum PageSummaryState: Equatable, Sendable {
    /// The summary is being written.
    case loading
    /// The finished summary.
    case ready(String)
    /// Why there's no summary, in plain words.
    case failed(String)
}

extension BrowserModel {
    /// Whether Summarize Page can run now.
    public var canSummarizePage: Bool {
        pageSummarizer != nil && selectedTabID != nil
    }

    /// Opens the summary popover and summarizes the selected page.
    public func summarizeSelectedPage() async {
        guard let summarizer = pageSummarizer, let tab = shownTab else { return }
        isShowingSummary = true
        if let reason = summarizer.unavailableReason {
            pageSummary = .failed(reason)
            return
        }
        pageSummary = .loading
        let result: PageSummaryState
        do {
            let text = try await pool.readablePageText(in: tab.id)
            let title = selectedPage?.title ?? tab.title
            let summary = try await summarizer.summarize(title: title, url: selectedPage?.url ?? tab.url, text: text)
            result = .ready(summary)
        } catch {
            result = .failed(error.localizedDescription)
        }
        // A newer request, or switching tabs, replaces this one.
        guard selectedTabID == tab.id, pageSummary == .loading else { return }
        pageSummary = result
        if case .ready = result { announce("Summary ready") }
    }
}

/// The toolbar button that summarizes the page, with the summary in a popover.
struct SummaryButton: View {
    @Bindable var model: BrowserModel

    var body: some View {
        Button {
            Task { await model.summarizeSelectedPage() }
        } label: {
            Label("Summarize Page", systemImage: "text.line.3.summary")
        }
        .disabled(!model.canSummarizePage)
        .help("Summarize this page")
        .accessibilityIdentifier("summarizeButton")
        .popover(isPresented: $model.isShowingSummary, arrowEdge: .bottom) {
            PageSummaryView(state: model.pageSummary ?? .loading)
        }
    }
}

/// A page summary, or why there isn't one.
struct PageSummaryView: View {
    let state: PageSummaryState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            switch state {
            case .loading:
                ProgressView("Summarizing…")
                    .controlSize(.small)
                    .accessibilityIdentifier("summaryProgress")
            case .ready(let summary):
                Text(summary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("summaryText")
                Text("Written on this Mac by Apple Intelligence. Check important details on the page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("summaryMessage")
            }
        }
        .padding()
        .frame(width: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summaryPopover")
    }
}
