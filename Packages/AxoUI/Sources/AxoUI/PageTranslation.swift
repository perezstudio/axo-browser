import AxoCore
import AxoWeb
import NaturalLanguage
import SwiftUI
import Translation

/// A page Axo translated, so the window can offer to show the original.
public struct TranslatedPage: Equatable, Sendable {
    /// The address that was translated. Loading another page drops the translation.
    public var url: URL?
    /// The language the page was in, if Axo could tell.
    public var source: Locale.Language?
    /// The language it was translated into.
    public var target: Locale.Language
}

/// Translation waiting for the window's translation session.
struct PendingTranslation {
    var tabID: AxoCore.Tab.ID
    var url: URL?
    var segments: [String]
    var source: Locale.Language?
    var target: Locale.Language
}

extension BrowserModel {
    /// The selected tab's translation, if it's showing one.
    public var selectedTranslation: TranslatedPage? {
        selectedTabID.flatMap { translatedPages[$0] }
    }

    /// Whether Translate Page can run now.
    public var canTranslatePage: Bool {
        selectedTabID != nil && selectedTranslation == nil && pendingTranslation == nil
    }

    /// The language a page's text is written in, if it's clear enough to tell.
    nonisolated static func dominantLanguage(of segments: [String]) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(segments.prefix(200).joined(separator: "\n"))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// Translates the selected page's text into ``translationTarget`` on this Mac, with Apple's
    /// Translation framework. macOS may first offer to download the languages.
    public func translateSelectedPage() async {
        guard let tab = selectedTab, canTranslatePage else { return }
        let segments: [String]
        do {
            segments = try await pool.pageTextSegments(in: tab.id)
        } catch {
            alertMessage = "Axo couldn't read this page's text to translate it."
            return
        }
        guard !segments.isEmpty else {
            alertMessage = "This page has no text to translate."
            return
        }
        let source = Self.dominantLanguage(of: segments)
        if let source, source.languageCode == translationTarget.languageCode {
            alertMessage = "This page is already in \(Self.languageName(translationTarget))."
            return
        }
        pendingTranslation = PendingTranslation(tabID: tab.id, url: selectedPage?.url ?? tab.url, segments: segments, source: source, target: translationTarget)
        let configuration = TranslationSession.Configuration(source: source, target: translationTarget)
        if translationConfiguration == configuration {
            // The same languages again: invalidating runs the translation task once more.
            translationConfiguration?.invalidate()
        } else {
            translationConfiguration = configuration
        }
    }

    /// The texts waiting to be translated, in page order.
    var pendingTranslationSegments: [String]? {
        pendingTranslation?.segments
    }

    /// Finishes the waiting translation with `translate`, which turns the page's texts into
    /// translated texts in the same order.
    func completeTranslation(using translate: ([String]) async throws -> [String]) async {
        guard let segments = pendingTranslationSegments else { return }
        do {
            await completeTranslation(with: .success(try await translate(segments)))
        } catch {
            await completeTranslation(with: .failure(error))
        }
    }

    /// Finishes the waiting translation with the translated texts, or the error that stopped it.
    func completeTranslation(with result: Result<[String], any Error>) async {
        guard let pending = pendingTranslation else { return }
        defer { pendingTranslation = nil }
        do {
            let translated = try result.get()
            guard translated.count == pending.segments.count else {
                alertMessage = "Axo couldn't translate this page."
                return
            }
            try await pool.replacePageText(translated, in: pending.tabID)
            translatedPages[pending.tabID] = TranslatedPage(url: pending.url, source: pending.source, target: pending.target)
            announce("Page translated into \(Self.languageName(pending.target))")
        } catch is CancellationError {
            // The person closed the language download sheet.
        } catch {
            alertMessage = "Axo couldn't translate this page. \(error.localizedDescription)"
        }
    }

    /// Puts the selected page's original text back.
    public func showOriginalPage() async {
        guard let tabID = selectedTabID, translatedPages[tabID] != nil else { return }
        try? await pool.restorePageText(in: tabID)
        translatedPages[tabID] = nil
        announce("Showing the original page")
    }

    /// Forgets a tab's translation once it loads a different page.
    func forgetTranslation(ifPageChangedIn tabID: AxoCore.Tab.ID, to url: URL) {
        guard let translated = translatedPages[tabID], translated.url != url else { return }
        translatedPages[tabID] = nil
    }

    /// A language's name in the person's language, such as "Spanish".
    nonisolated static func languageName(_ language: Locale.Language) -> String {
        language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) } ?? language.minimalIdentifier
    }

    /// Translates texts with a session, keeping their order.
    ///
    /// Nonisolated because `TranslationSession` isn't `Sendable`: the session stays with the
    /// translation task that SwiftUI handed it to, and only strings cross to the main actor.
    nonisolated static func translate(_ texts: [String], with session: TranslationSession) async throws -> [String] {
        let requests = texts.enumerated().map { index, text in
            TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        var translated = texts
        for response in try await session.translations(from: requests) {
            if let index = response.clientIdentifier.flatMap(Int.init) { translated[index] = response.targetText }
        }
        return translated
    }
}

/// Runs the window's translations: when the model asks for one, SwiftUI provides a translation
/// session (offering to download languages first if needed).
struct PageTranslationTask: ViewModifier {
    let model: BrowserModel

    func body(content: Content) -> some View {
        content.translationTask(model.translationConfiguration) { @Sendable session in
            await Self.run(session, for: model)
        }
    }

    /// Translates the model's waiting texts with `session`, off the main actor.
    private nonisolated static func run(_ session: TranslationSession, for model: BrowserModel) async {
        guard let texts = await model.pendingTranslationSegments else { return }
        let result: Result<[String], any Error>
        do {
            result = .success(try await BrowserModel.translate(texts, with: session))
        } catch {
            result = .failure(error)
        }
        await model.completeTranslation(with: result)
    }
}

/// The bar above a translated page: what it was translated from, and Show Original.
struct TranslationBar: View {
    let model: BrowserModel
    let translation: TranslatedPage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "translate")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .accessibilityIdentifier("translationMessage")
            Spacer()
            Button("Show Original") {
                Task { await model.showOriginalPage() }
            }
            .controlSize(.small)
            .accessibilityIdentifier("showOriginalButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("translationBar")
    }

    private var message: String {
        let target = BrowserModel.languageName(translation.target)
        guard let source = translation.source else { return "Translated into \(target)" }
        return "Translated from \(BrowserModel.languageName(source)) into \(target)"
    }
}
