import AVFoundation

/// Speaks text aloud, for the page menu's Speech items (#173). Tests use a fake.
@MainActor
public protocol SelectionSpeaking: AnyObject {
    /// Whether it's speaking now.
    var isSpeaking: Bool { get }
    /// Speaks `text`, after stopping anything it was saying.
    func speak(_ text: String)
    /// Stops speaking.
    func stop()
}

/// The system's speech synthesizer, in the person's spoken content voice, made on first use.
@MainActor
final class SystemSelectionSpeech: SelectionSpeaking {
    private lazy var synthesizer = AVSpeechSynthesizer()
    private var hasSpoken = false

    var isSpeaking: Bool { hasSpoken && synthesizer.isSpeaking }

    func speak(_ text: String) {
        hasSpoken = true
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        // The voice and rate the person chose in System Settings › Accessibility › Spoken Content.
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
    }

    func stop() {
        guard hasSpoken else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }
}
