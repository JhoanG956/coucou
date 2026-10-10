#if !APPSTORE
import AVFoundation

// MARK: - VoiceSpeaker
//
// Gives Coucou a voice, sentence by sentence:
//   • macOS voices (AVSpeechSynthesizer), best installed voice for the language;
//   • ElevenLabs (Settings → Voice, the user's own API key), female or male.
//     Each queued sentence starts downloading right away, so the next one is usually
//     ready when the previous one ends. Any ElevenLabs failure falls back to the Mac
//     voice for that sentence: Coucou never goes silent.
// onDidFinish fires ~150 ms after the queue drains. All methods: @MainActor.
@MainActor
final class VoiceSpeaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate, @unchecked Sendable {
    static let shared = VoiceSpeaker()

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private(set) var isSpeaking = false
    private var currentUtterance: AVSpeechUtterance? = nil
    private var waitingForAudio = false

    private struct Item {
        let text: String
        let locale: Locale?
        let audio: Task<Data?, Never>?   // ElevenLabs download, started at enqueue time
    }
    private var queue: [Item] = []
    /// Bumped by stop()/speak(): late callbacks from an older utterance are ignored.
    private var generation = 0

    /// Called ~150 ms after the last queued sentence finishes.
    var onDidFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Public API

    /// Clears the queue, stops current speech, and speaks text now.
    func speak(_ text: String, locale: Locale?) {
        guard VoiceSettings.speakEnabled else { return }
        stopPlayback()
        enqueue(text, locale: locale)
    }

    /// Adds a sentence to the queue. Starts playing if nothing is playing.
    func enqueue(_ text: String, locale: Locale?) {
        guard VoiceSettings.speakEnabled else { return }
        let audio: Task<Data?, Never>? = ElevenLabsTTS.isActive
            ? Task { await ElevenLabsTTS.shared.audio(for: text) }
            : nil
        queue.append(Item(text: text, locale: locale, audio: audio))
        if !isSpeaking { playNext() }
    }

    func stop() { stopPlayback() }

    /// What the mic gate uses: what is actually playing or about to play, never a flag
    /// alone, so a missed callback cannot leave Coucou deaf.
    var isBusy: Bool {
        synth.isSpeaking || (player?.isPlaying ?? false) || waitingForAudio || !queue.isEmpty
    }

    // MARK: - Playback

    private func stopPlayback() {
        generation += 1
        for item in queue { item.audio?.cancel() }
        queue.removeAll()
        currentUtterance = nil
        waitingForAudio = false
        isSpeaking = false
        player?.stop()
        player = nil
        synth.stopSpeaking(at: .immediate)
    }

    private func playNext() {
        guard !queue.isEmpty else { finished(); return }
        let item = queue.removeFirst()
        isSpeaking = true
        guard let audio = item.audio else { speakSystem(item.text, locale: item.locale); return }
        let gen = generation
        waitingForAudio = true
        Task { @MainActor in
            let data = await audio.value
            guard gen == self.generation else { return }
            self.waitingForAudio = false
            if let data, let p = try? AVAudioPlayer(data: data) {
                p.delegate = self
                self.player = p
                if p.play() { return }
                self.player = nil
            }
            self.speakSystem(item.text, locale: item.locale)   // fallback: Mac voice
        }
    }

    private func speakSystem(_ text: String, locale: Locale?) {
        let utt = AVSpeechUtterance(string: text)
        utt.pitchMultiplier = 1.15
        utt.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utt.voice = _bestVoice(for: locale)
        currentUtterance = utt
        synth.speak(utt)
    }

    private func itemDone() {
        currentUtterance = nil
        player = nil
        playNext()
    }

    private func finished() {
        isSpeaking = false
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)  // 150 ms gap
            guard gen == self.generation, !self.isSpeaking else { return }
            self.onDidFinish?()
        }
    }

    /// Picks the best installed voice for the spoken locale: same region first
    /// (en-US before en-GB), then quality (.premium > .enhanced > default).
    /// Novelty voices and the user's Personal Voice are never used.
    private func _bestVoice(for locale: Locale?) -> AVSpeechSynthesisVoice? {
        guard let loc = locale else { return nil }
        let lang = loc.language.languageCode?.identifier ?? ""
        guard !lang.isEmpty else { return nil }
        let region = loc.region?.identifier
        let exact  = region.map { "\(lang)-\($0)" }

        let voices = AVSpeechSynthesisVoice.speechVoices().filter { v in
            (v.language == lang || v.language.hasPrefix(lang + "-"))
                && !v.voiceTraits.contains(.isNoveltyVoice)
                && !v.voiceTraits.contains(.isPersonalVoice)
        }
        guard !voices.isEmpty else { return AVSpeechSynthesisVoice(language: exact ?? lang) }

        func rank(_ v: AVSpeechSynthesisVoice) -> (Int, Int) {
            (v.language == exact ? 1 : 0, v.quality.rawValue)
        }
        return voices.max { rank($0) < rank($1) }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let curr = self.currentUtterance, ObjectIdentifier(curr) == id else { return }
            self.itemDone()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didCancel utterance: AVSpeechUtterance) {
        // stopPlayback() already reset everything; nothing to do for older utterances.
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(p)
        Task { @MainActor in
            guard let curr = self.player, ObjectIdentifier(curr) == id else { return }
            self.itemDone()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(p)
        Task { @MainActor in
            guard let curr = self.player, ObjectIdentifier(curr) == id else { return }
            self.itemDone()
        }
    }
}
#endif
