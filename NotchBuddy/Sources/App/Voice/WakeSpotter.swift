#if !APPSTORE
import AVFoundation
import Speech

// MARK: - WakeSpotter

/// Runs a single SFSpeechRecognizer window to detect the "OK Coucou" wake phrase,
/// then switches to command mode in the same recognition session so words spoken
/// immediately after the wake phrase are not lost.
///
/// Wake detection uses `WakePhrase.split` which searches anywhere in the transcript
/// at a word boundary, not just the start ("euh ok coucou…" matches).
///
/// Thread model: `beginWindow`, `endWindow` are called on the main actor.
/// `feed(_:)` may be called from any thread (the audio tap thread).
/// Recognition callbacks arrive on an internal Apple thread.
/// All shared state is protected by a single `NSLock`.
final class WakeSpotter: @unchecked Sendable {

    // MARK: - Callbacks (all delivered on the main thread)

    /// Called once when the wake phrase is detected. Receives the raw partial transcript.
    var onWake: ((String) -> Void)?
    /// Called during the command phase with the command portion of the transcript (normalised).
    var onCommandUpdate: ((String) -> Void)?
    /// Called when the recognition session ends naturally (final result or error)
    /// while in command phase.
    var onCommandEnd: (() -> Void)?
    /// Called when the recognition session ends in wake phase (no command captured).
    /// VoiceEngine uses this to reopen the window immediately if the VAD is still active.
    var onWakeWindowEnded: (() -> Void)?

    // MARK: - State (all guarded by `lock`)

    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request:    SFSpeechAudioBufferRecognitionRequest?
    private var task:       SFSpeechRecognitionTask?
    private var active      = false
    private var phase:      Phase = .wake

    private enum Phase { case wake, command }

    // MARK: - Public API

    /// True when the session has advanced to command phase (thread-safe).
    var isInCommandPhase: Bool { lock.withLock { phase == .command } }

    /// Begin a recognition window for the given locale.
    /// Pre-roll buffers (audio captured before VAD fired) are injected first.
    func beginWindow(locale: Locale, preroll: [AVAudioPCMBuffer] = []) {
        var recognizerSnap: SFSpeechRecognizer?
        var requestSnap:    SFSpeechAudioBufferRecognitionRequest?

        lock.withLock {
            guard !active else { return }
            guard let r = SFSpeechRecognizer(locale: locale),
                  r.supportsOnDeviceRecognition,
                  r.isAvailable else { return }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults  = true
            req.requiresOnDeviceRecognition = true
            req.contextualStrings           = ["Coucou", "OK Coucou", "okay Coucou",
                                               "hey Coucou"]
            preroll.forEach { req.append($0) }

            recognizer = r
            request    = req
            active     = true
            phase      = .wake
            recognizerSnap = r
            requestSnap    = req
        }

        guard let r = recognizerSnap, let req = requestSnap else { return }

        // Start the task outside the lock (Apple's callback is always async).
        let t = r.recognitionTask(with: req) { [weak self] result, error in
            self?.handleResult(result, error: error)
        }
        lock.withLock { task = t }
    }

    /// Append an audio buffer (audio tap thread).
    func feed(_ buffer: AVAudioPCMBuffer) {
        // Get the request reference under lock; append outside (append is thread-safe).
        lock.withLock { request }?.append(buffer)
    }

    /// Close the window without firing any callback.
    func endWindow() {
        lock.withLock {
            request?.endAudio()
            task?.cancel()
            request    = nil
            task       = nil
            recognizer = nil
            active     = false
            phase      = .wake
        }
    }

    // MARK: - Recognition callback

    private enum Action {
        case woke(String)
        case commandUpdate(String)
        case commandEnd
        case wakeWindowEnded
    }

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        let action: Action? = lock.withLock { () -> Action? in
            guard active else { return nil }

            if let transcript = result?.bestTranscription.formattedString {
                switch phase {
                case .wake:
                    let r = WakePhrase.split(transcript)
                    if r.matched {
                        phase = .command
                        return .woke(transcript)
                    }
                case .command:
                    let r = WakePhrase.split(transcript)
                    // In command phase, split always finds the wake prefix; fall back to full transcript.
                    return .commandUpdate(r.matched ? r.command : transcript.lowercased())
                }
            }

            if result?.isFinal == true || error != nil {
                let wasCommand = phase == .command
                request    = nil
                task       = nil
                recognizer = nil
                active     = false
                phase      = .wake
                return wasCommand ? .commandEnd : .wakeWindowEnded
            }
            return nil
        }

        guard let action else { return }
        switch action {
        case .woke(let t):
            DispatchQueue.main.async { [weak self] in self?.onWake?(t) }
        case .commandUpdate(let s):
            DispatchQueue.main.async { [weak self] in self?.onCommandUpdate?(s) }
        case .commandEnd:
            DispatchQueue.main.async { [weak self] in self?.onCommandEnd?() }
        case .wakeWindowEnded:
            DispatchQueue.main.async { [weak self] in self?.onWakeWindowEnded?() }
        }
    }
}
#endif
