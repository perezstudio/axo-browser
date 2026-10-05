import AxoCore
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Returns a fixed summary, or fails, without the on-device model.
private struct FakeSummarizer: PageSummarizing {
    var unavailableReason: String?
    var error: PageSummaryFailure?

    func summarize(title: String, url: URL?, text: String) async throws -> String {
        if let error { throw error }
        return "\(title): \(text)"
    }
}

private struct PageSummaryFailure: LocalizedError {
    var errorDescription: String? { "The model couldn't finish." }
}

@MainActor
struct PageTranslationAndSummaryTests {
    let store: TabStore
    let model: BrowserModel
    var announcements: [String] { recorded.messages }
    private let recorded = Recorded()

    private final class Recorded {
        var messages: [String] = []
    }

    init() async throws {
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.translationTarget = Locale.Language(identifier: "en")
        let recorded = recorded
        model.announce = { recorded.messages.append($0) }
        await model.start()
    }

    /// Opens and selects a page made from `body`, and waits for it to load.
    private func open(title: String, body: String) async throws -> AxoCore.Tab.ID {
        let html = "<meta charset=utf-8><title>\(title)</title><body>\(body)</body>"
        let url = URL(string: "data:text/html;charset=utf-8," + html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
        let tab = try await store.openTab(url: url, in: try #require(model.space).id)
        try await waitUntil { model.tabs.contains { $0.id == tab.id } }
        model.select(tab.id)
        try await waitUntil { model.selectedPage?.title == title && model.selectedPage?.isLoading == false }
        return tab.id
    }

    private func pageText() async throws -> String {
        try await model.pool.readablePageText(in: try #require(model.selectedTabID))
    }

    @Test func translatingReplacesTheTextAndShowOriginalPutsItBack() async throws {
        let tabID = try await open(title: "Hola", body: "<p>Buenos días a todos los vecinos del barrio.</p><p>La biblioteca abre mañana temprano.</p>")
        #expect(model.canTranslatePage)

        await model.translateSelectedPage()
        #expect(model.translationConfiguration?.source?.languageCode == "es")
        #expect(model.translationConfiguration?.target?.languageCode == "en")
        #expect(!model.canTranslatePage, "One translation at a time")

        await model.completeTranslation { texts in texts.map { "EN: \($0)" } }
        #expect(try await pageText().hasPrefix("EN: Buenos días"))
        #expect(model.translatedPages[tabID]?.source?.languageCode == "es")
        #expect(model.selectedTranslation != nil)
        #expect(announcements.last == "Page translated into English")
        #expect(model.availableActions.contains(.showOriginalPage))
        #expect(!model.availableActions.contains(.translatePage))

        await model.showOriginalPage()
        #expect(try await pageText().hasPrefix("Buenos días"))
        #expect(model.selectedTranslation == nil)
        #expect(model.canTranslatePage)
    }

    @Test func pagesAlreadyInTheTargetLanguageAreNotTranslated() async throws {
        _ = try await open(title: "Hello", body: "<p>Good morning to everyone in the neighborhood.</p><p>The library opens early tomorrow.</p>")
        await model.translateSelectedPage()
        #expect(model.translationConfiguration == nil)
        #expect(model.alertMessage == "This page is already in English.")
    }

    @Test func failedTranslationsLeaveThePageAloneAndSayWhy() async throws {
        let tabID = try await open(title: "Hola", body: "<p>Buenos días a todos los vecinos del barrio.</p>")
        await model.translateSelectedPage()
        await model.completeTranslation { _ in throw PageSummaryFailure() }
        #expect(model.translatedPages[tabID] == nil)
        #expect(model.alertMessage?.hasPrefix("Axo couldn't translate this page.") == true)
        #expect(model.canTranslatePage, "The person can try again")
        #expect(try await pageText().hasPrefix("Buenos días"))
    }

    @Test func loadingAnotherPageDropsTheTranslation() async throws {
        let tabID = try await open(title: "Hola", body: "<p>Buenos días a todos los vecinos del barrio.</p>")
        await model.translateSelectedPage()
        await model.completeTranslation { $0 }
        let translatedURL = try #require(model.translatedPages[tabID]?.url)
        model.forgetTranslation(ifPageChangedIn: tabID, to: translatedURL)
        #expect(model.translatedPages[tabID] != nil, "Title changes on the same page keep it")
        model.forgetTranslation(ifPageChangedIn: tabID, to: URL(string: "http://127.0.0.1:9/next")!)
        #expect(model.translatedPages[tabID] == nil)
    }

    @Test func languagesAreDetected() {
        #expect(BrowserModel.dominantLanguage(of: ["Bonjour à tous, la bibliothèque ouvre demain matin."])?.languageCode == "fr")
        #expect(BrowserModel.dominantLanguage(of: []) == nil)
    }

    @Test func summariesNeedASummarizer() async throws {
        _ = try await open(title: "Story", body: "<p>Axolotls regrow limbs.</p>")
        #expect(!model.canSummarizePage)
        #expect(!model.availableActions.contains(.summarizePage))
        await model.summarizeSelectedPage()
        #expect(!model.isShowingSummary)
    }

    @Test func summariesUseThePageText() async throws {
        model.pageSummarizer = FakeSummarizer()
        _ = try await open(title: "Story", body: "<p>Axolotls   regrow\nlimbs.</p><script>ignored()</script>")
        #expect(model.availableActions.contains(.summarizePage))
        await model.summarizeSelectedPage()
        #expect(model.isShowingSummary)
        #expect(model.pageSummary == .ready("Story: Axolotls regrow limbs."))
        #expect(announcements.last == "Summary ready")
    }

    @Test func unavailableSummariesSayWhyPlainly() async throws {
        model.pageSummarizer = FakeSummarizer(unavailableReason: "Turn on Apple Intelligence in System Settings to summarize pages.")
        _ = try await open(title: "Story", body: "<p>Text</p>")
        await model.summarizeSelectedPage()
        #expect(model.pageSummary == .failed("Turn on Apple Intelligence in System Settings to summarize pages."))

        model.pageSummarizer = FakeSummarizer(error: PageSummaryFailure())
        await model.summarizeSelectedPage()
        #expect(model.pageSummary == .failed("The model couldn't finish."))
    }
}
