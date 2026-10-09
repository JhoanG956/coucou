#if !APPSTORE
import AVFoundation
import Speech

// MARK: - WakeSpotter
//
// Runs a single SFSpeechRecognizer window to detect the "OK Coucou" wake phrase,
// then switches to command mode in the same recognition session so words spoken
// immediately after the wake phrase are not lost.
//
// Thread model: `beginWindow`, `endWindow` called on the main actor.
// `feed(_:)` may be called from any thread (audio tap thread).
// Recognition callbacks arrive on an internal Apple thread.
// All shared state is protected by a single NSLock.
//
// Logging (to nb.log):
//   [WakeSpotter] task start
//   [WakeSpotter] task refused (already active)
//   [WakeSpotter] task refused (unavailable)
//   [WakeSpotter] task end: final, partials N
//   [WakeSpotter] task end: error <domain>/<code>, partials N
final class WakeSpotter: @unchecked Sendable {

    // MARK: - Callbacks (all delivered on the main thread)

    var onWake:           ((String) -> Void)?
    var onCommandUpdate:  ((String) -> Void)?
    var onCommandEnd:     (() -> Void)?
    /// Fired when the session ends in wake phase (no command captured).
    /// `wasError` is true when the session ended with an error (not a clean final result).
    var onWakeWindowEnded: ((Bool) -> Void)?

    // MARK: - State (all guarded by `lock`)

    private let lock = NSLock()
    private var recognizer:   SFSpeechRecognizer?
    private var request:      SFSpeechAudioBufferRecognitionRequest?
    private var task:         SFSpeechRecognitionTask?
    private var active        = false
    private var phase:        Phase = .wake
    private var partialCount  = 0

    private enum Phase { case wake, command }

    // MARK: - Public API

    var isInCommandPhase: Bool { lock.withLock { phase == .command } }

    /// Open a wake+command recognition window.
    /// Returns `true` if the underlying recognition task was successfully started.
    @discardableResult
    func beginWindow(locale: Locale, preroll: [AVAudioPCMBuffer] = []) -> Bool {
        enum Refusal { case alreadyActive, unavailable }
        var refusal: Refusal? = nil
        var rSnap: SFSpeechRecognizer?
        var reqSnap: SFSpeechAudioBufferRecognitionRequest?

        lock.withLock {
            guard !active else { refusal = .alreadyActive; return }
            guard let r = SFSpeechRecognizer(locale: locale),
                  r.supportsOnDeviceRecognition,
                  r.isAvailable else { refusal = .unavailable; return }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults  = true
            req.requiresOnDeviceRecognition = true
            req.contextualStrings = ["Coucou", "OK Coucou", "okay Coucou", "hey Coucou"]
            preroll.forEach { req.append($0) }

            recognizer   = r
            request      = req
            active       = true
            phase        = .wake
            partialCount = 0
            rSnap   = r
            reqSnap = req
        }

        if let refusal {
            switch refusal {
            case .alreadyActive:
                appendAppLog("nb.log", "[WakeSpotter] task refused (already active)")
            case .unavailable:
                appendAppLog("nb.log", "[WakeSpotter] task refused (unavailable)")
            }
            return false
        }

        guard let r = rSnap, let req = reqSnap else { return false }

        appendAppLog("nb.log", "[WakeSpotter] task start")
        let t = r.recognitionTask(with: req) { [weak self] result, error in
            self?.handleResult(result, error: error)
        }
        lock.withLock { task = t }
        return true
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request }?.append(buffer)
    }

    func endWindow() {
        lock.withLock {
            request?.endAudio()
            task?.cancel()
            request      = nil
            task         = nil
            recognizer   = nil
            active       = false
            phase        = .wake
            partialCount = 0
        }
    }

    // MARK: - Recognition callback

    private enum RecogAction {
        case woke(String)
        case commandUpdate(String)
        case commandEnd
        case wakeWindowEnded(wasError: Bool)
    }

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        var logMsg: String? = nil

        let action: RecogAction? = lock.withLock { () -> RecogAction? in
            guard active else { return nil }

            if let transcript = result?.bestTranscription.formattedString {
                partialCount += 1
                switch phase {
                case .wake:
                    let r = WakePhrase.split(transcript)
                    if r.matched {
                        phase = .command
                        return .woke(transcript)
                    }
                case .command:
                    let r = WakePhrase.split(transcript)
                    return .commandUpdate(r.matched ? r.command : transcript)
                }
            }

            if result?.isFinal == true || error != nil {
                let wasCommand = phase == .command
                let n          = partialCount
                let wasError   = error != nil
                request      = nil
                task         = nil
                recognizer   = nil
                active       = false
                phase        = .wake
                partialCount = 0
                if let err = error as NSError? {
                    logMsg = "[WakeSpotter] task end: error \(err.domain)/\(err.code), partials \(n)"
                } else {
                    logMsg = "[WakeSpotter] task end: final, partials \(n)"
                }
                return wasCommand ? .commandEnd : .wakeWindowEnded(wasError: wasError)
            }
            return nil
        }

        if let msg = logMsg { appendAppLog("nb.log", msg) }
        guard let action else { return }

        switch action {
        case .woke(let t):
            DispatchQueue.main.async { [weak self] in self?.onWake?(t) }
        case .commandUpdate(let s):
            DispatchQueue.main.async { [weak self] in self?.onCommandUpdate?(s) }
        case .commandEnd:
            DispatchQueue.main.async { [weak self] in self?.onCommandEnd?() }
        case .wakeWindowEnded(let wasError):
            DispatchQueue.main.async { [weak self] in self?.onWakeWindowEnded?(wasError) }
        }
    }
}
#endif
