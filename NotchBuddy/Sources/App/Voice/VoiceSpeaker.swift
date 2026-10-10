#if !APPSTORE
import AVFoundation

// MARK: - VoiceSpeaker
//
// Gives Mochi a voice: wraps AVSpeechSynthesizer with a Mochi-like pitch.
// Semi-duplex: VoiceEngine pauses recognition while this is speaking.
// Setting: VoiceSettings.speakEnabled (default on).
//
// All methods: @MainActor.
@MainActor
final class VoiceSpeaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = VoiceSpeaker()

    private let synth = AVSpeechSynthesizer()
    private(set) var isSpeaking = false

    /// Called ~300 ms after the utterance finishes. VoiceEngine uses this to resume listening.
    var onDidFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, locale: Locale?) {
        guard VoiceSettings.speakEnabled else { return }
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
        let utt        = AVSpeechUtterance(string: text)
        utt.pitchMultiplier = 1.25
        utt.rate            = AVSpeechUtteranceDefaultSpeechRate * 1.05
        if let loc = locale {
            let lang = loc.language.languageCode?.identifier ?? ""
            if !lang.isEmpty { utt.voice = AVSpeechSynthesisVoice(language: lang) }
        }
        isSpeaking = true
        synth.speak(utt)
    }

    func stop() {
        guard isSpeaking else { return }
        synth.stopSpeaking(at: .immediate)
        // isSpeaking set to false in didCancel/didFinish delegate callbacks
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300 ms gap
            self.onDidFinish?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
#endif
