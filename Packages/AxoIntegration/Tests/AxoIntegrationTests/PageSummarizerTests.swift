import Foundation
import FoundationModels
import Testing
@testable import AxoIntegration

struct PageSummarizerTests {
    @Test func availabilityIsExplainedPlainly() {
        #expect(PageSummarizer.availability(from: .available) == .available)
        #expect(PageSummarizer.availability(from: .unavailable(.appleIntelligenceNotEnabled)) == .appleIntelligenceOff)
        #expect(PageSummarizer.availability(from: .unavailable(.deviceNotEligible)) == .deviceNotEligible)
        #expect(PageSummarizer.availability(from: .unavailable(.modelNotReady)) == .modelNotReady)
        #expect(PageSummarizer.Availability.available.message == nil)
        #expect(PageSummarizer.Availability.appleIntelligenceOff.message?.contains("System Settings") == true)
    }

    @Test func promptsCarryThePageAndAreTrimmed() {
        let prompt = PageSummarizer.prompt(title: "News", url: URL(string: "https://example.com/a"), text: String(repeating: "x", count: 10_000))
        #expect(prompt.hasPrefix("Title: News\nAddress: https://example.com/a\n\n"))
        #expect(prompt.count < PageSummarizer.textLimit + 100)
    }

    @Test func emptyPagesAreReportedWithoutAskingTheModel() async {
        let summarizer = PageSummarizer()
        await #expect(throws: PageSummaryError.self) {
            try await summarizer.summarize(title: "Empty", url: nil, text: "   ")
        }
    }

    /// Runs the real on-device model, only when asked (`AXO_SUMMARIES=1`) and available.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AXO_SUMMARIES"] != nil && PageSummarizer().availability == .available))
    func theOnDeviceModelSummarizes() async throws {
        let text = "Axolotls are salamanders that keep their larval features into adulthood. They live in lakes near Mexico City and can regrow limbs, spinal cord, and even parts of their brain."
        let summary = try await PageSummarizer().summarize(title: "Axolotls", url: nil, text: text)
        #expect(!summary.isEmpty)
    }
}
