import Foundation
import FoundationModels

/// Summarizes web pages with the on-device Apple Intelligence model. Nothing leaves the Mac.
public struct PageSummarizer: Sendable {
    /// Whether summaries can be made, and if not, why.
    public enum Availability: Equatable, Sendable {
        case available
        /// This Mac can't run Apple Intelligence.
        case deviceNotEligible
        /// Apple Intelligence is turned off in System Settings.
        case appleIntelligenceOff
        /// The model is still downloading or getting ready.
        case modelNotReady
        /// Some other reason.
        case unavailable

        /// A plain explanation for people, or `nil` when summaries are available.
        public var message: String? {
            switch self {
            case .available: nil
            case .deviceNotEligible: "This Mac can't make summaries. They need Apple Intelligence."
            case .appleIntelligenceOff: "Turn on Apple Intelligence in System Settings to summarize pages."
            case .modelNotReady: "Apple Intelligence is still getting ready. Try again in a little while."
            case .unavailable: "Summaries aren't available right now."
            }
        }
    }

    /// The most page text sent to the model, which has a limited context.
    public static let textLimit = 6_000

    public init() {}

    /// Whether the on-device model can make summaries now.
    public var availability: Availability {
        Self.availability(from: SystemLanguageModel.default.availability)
    }

    static func availability(from availability: SystemLanguageModel.Availability) -> Availability {
        switch availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceOff
        case .unavailable(.modelNotReady): .modelNotReady
        case .unavailable: .unavailable
        }
    }

    /// The instructions for the model.
    static let instructions = """
        You summarize web pages for the person reading them. Write three to five short bullet \
        points, each starting with "• ", covering the page's main points. Use the page's \
        language. Don't add facts that aren't on the page, and don't mention that you're \
        summarizing.
        """

    /// The prompt for a page: its title, address, and text (trimmed to ``textLimit``).
    static func prompt(title: String, url: URL?, text: String) -> String {
        let trimmed = text.count > textLimit ? String(text.prefix(textLimit)) : text
        return """
            Title: \(title)
            Address: \(url?.absoluteString ?? "")

            \(trimmed)
            """
    }

    /// Summarizes a page.
    ///
    /// - Throws: An error with ``Availability/message`` if summaries aren't available, or the
    ///   model's error.
    public func summarize(title: String, url: URL?, text: String) async throws -> String {
        if let message = availability.message { throw PageSummaryError(message: message) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PageSummaryError(message: "This page has no text to summarize.")
        }
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(to: Self.prompt(title: title, url: url, text: text))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Why a summary couldn't be made, in plain words.
public struct PageSummaryError: LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
}
