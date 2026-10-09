#if !APPSTORE
import AVFoundation
import Speech

// MARK: - WakeSpotter

/// Runs a single SFSpeechRecognizer window to detect the "OK Coucou" wake phrase.
///
/// Rules:
/// - `requiresOnDeviceRecognition = true`; never falls back to a server recognizer.
///   If the device has no on-device model for the locale, the window silently closes.
/// - Audio and transcriptions are never written to disk or to any log.
/// - `matchesWake(_:)` is a pure function: testable in isolation.
///
/// Thread model: `beginWindow`, `endWindow`, and the `onWake` callback all run on the
/// thread of the caller. `feed(_:)` may be called from any thread (the audio tap thread).
final class WakeSpotter: @unchecked Sendable {

    /// Called when the wake phrase is detected. Receives the raw transcript (may include
    /// words spoken after the wake phrase — those become the command).
    var onWake: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var request:    SFSpeechAudioBufferRecognitionRequest?
    private var task:       SFSpeechRecognitionTask?
    private var active      = false

    // MARK: - Recognition window lifecycle

    /// Begin a recognition window, listening for the wake phrase in `locale`.
    /// No-op if a window is already active. If the locale has no on-device model,
    /// the window is not opened (never falls back to server).
    func beginWindow(locale: Locale) {
        guard !active else { return }
        guard let r = SFSpeechRecognizer(locale: locale),
              r.supportsOnDeviceRecognition,
              r.isAvailable else { return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults   = true
        req.requiresOnDeviceRecognition  = true
        req.contextualStrings            = ["Coucou", "OK Coucou", "okay Coucou",
                                            "hey Coucou"]
        active     = true
        recognizer = r
        request    = req

        task = r.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let transcript = result?.bestTranscription.formattedString,
               Self.matchesWake(transcript) {
                let text = transcript
                DispatchQueue.main.async { self.onWake?(text) }
                self.endWindow()
                return
            }
            if result?.isFinal == true || error != nil {
                self.endWindow()
            }
        }
    }

    /// Append an audio buffer to the current window. Thread-safe.
    func feed(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    /// Close the current recognition window without firing `onWake`.
    func endWindow() {
        request?.endAudio()
        task?.cancel()
        request    = nil
        task       = nil
        recognizer = nil
        active     = false
    }

    // MARK: - Wake phrase matching (pure — no side effects)

    /// Returns `true` when `raw` contains one of the recognised wake patterns.
    ///
    /// Accepted patterns (case-insensitive, after phonetic normalisation):
    /// - "coucou" — exactly that word alone (not mid-sentence, not "coucou ça va")
    /// - "ok coucou" and its variants: "okay coucou", "ok cuckoo", "ok kuku" …
    /// - "hey coucou", "dis coucou"
    ///
    /// The match may be followed by command words (e.g. "ok coucou add GitHub").
    static func matchesWake(_ raw: String) -> Bool {
        // 1. Lower-case and strip punctuation
        var text = raw.lowercased()
            .components(separatedBy: .punctuationCharacters)
            .joined()
            .trimmingCharacters(in: .whitespaces)

        // 2. Normalise common phonetic / OCR variants
        text = text
            .replacingOccurrences(of: "cuckoo",   with: "coucou")
            .replacingOccurrences(of: "kuku",     with: "coucou")
            .replacingOccurrences(of: "kucou",    with: "coucou")
            .replacingOccurrences(of: "cou cou",  with: "coucou")
            .replacingOccurrences(of: "okay",     with: "ok")
            .replacingOccurrences(of: "o k ",     with: "ok ")
        // Remove internal double spaces that normalisation may introduce
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }

        // 3. Standalone "coucou" — the entire transcript is just "coucou".
        //    "coucou ça va" or "dis coucou à Marie" must NOT trigger.
        if text == "coucou" { return true }

        // 4. Prefix-based patterns (may be followed by a command).
        // "dis coucou" is excluded: in French it also means "say hello to [person]" and
        // creates too many false positives (e.g. "dis coucou à Marie"). Added in a later phase.
        let wakePrefixes = ["ok coucou", "hey coucou"]
        for prefix in wakePrefixes {
            if text == prefix              { return true }
            if text.hasPrefix(prefix + " ") { return true }
        }

        return false
    }
}
#endif
