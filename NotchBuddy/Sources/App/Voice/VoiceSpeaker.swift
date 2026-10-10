#if !APPSTORE
import AVFoundation

// MARK: - VoiceSpeaker
//
// Gives Mochi a voice: wraps AVSpeechSynthesizer with a sentence queue.
// Sentence queue: enqueue(text:locale:) adds to queue, playback starts automatically
// and continues through the queue. onDidFinish fires when the queue drains.
//
// All methods: @MainActor.
@MainActor
final class VoiceSpeaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = VoiceSpeaker()

    private let synth = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    private var currentUtterance: AVSpeechUtterance? = nil
    private var queue: [(text: String, locale: Locale?)] = []

    /// Called ~150 ms after the last queued utterance finishes.
    var onDidFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Public API

    /// Clears the queue, stops current speech, and speaks text immediately.
    func speak(_ text: String, locale: Locale?) {
        guard VoiceSettings.speakEnabled else { return }
        queue.removeAll()
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
        currentUtterance = nil
        _enqueueAndPlay(text: text, locale: locale)
    }

    /// Adds text to the end of the playback queue. Starts playing if not already.
    func enqueue(_ text: String, locale: Locale?) {
        guard VoiceSettings.speakEnabled else { return }
        if isSpeaking {
            queue.append((text, locale))
        } else {
            _enqueueAndPlay(text: text, locale: locale)
        }
    }

    func stop() {
        queue.removeAll()
        guard isSpeaking else { return }
        synth.stopSpeaking(at: .immediate)
    }

    // MARK: - Private

    private func _enqueueAndPlay(text: String, locale: Locale?) {
        let utt = AVSpeechUtterance(string: text)
        utt.pitchMultiplier = 1.15
        utt.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utt.voice = _bestVoice(for: locale)
        currentUtterance = utt
        isSpeaking = true
        synth.speak(utt)
    }

    /// Picks the highest quality installed voice for the given locale.
    /// Falls back to .premium → .enhanced → default language voice.
    private func _bestVoice(for locale: Locale?) -> AVSpeechSynthesisVoice? {
        guard let loc = locale else { return nil }
        let lang = loc.language.languageCode?.identifier ?? ""
        guard !lang.isEmpty else { return nil }

        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(lang)
        }
        if voices.isEmpty { return AVSpeechSynthesisVoice(language: lang) }

        // Sort by quality descending (.premium > .enhanced > default)
        let sorted = voices.sorted { $0.quality.rawValue > $1.quality.rawValue }
        return sorted.first ?? AVSpeechSynthesisVoice(language: lang)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let curr = self.currentUtterance, ObjectIdentifier(curr) == id else { return }
            self.currentUtterance = nil
            if self.queue.isEmpty {
                self.isSpeaking = false
                try? await Task.sleep(nanoseconds: 150_000_000)  // 150 ms gap
                self.onDidFinish?()
            } else {
                let next = self.queue.removeFirst()
                self._enqueueAndPlay(text: next.text, locale: next.locale)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let curr = self.currentUtterance, ObjectIdentifier(curr) == id else { return }
            self.isSpeaking = false
            self.currentUtterance = nil
            self.queue.removeAll()
        }
    }
}
#endif
