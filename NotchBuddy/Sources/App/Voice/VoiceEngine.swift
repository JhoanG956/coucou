#if !APPSTORE
import AppKit
import AVFoundation
import Speech

// MARK: - VoiceEngine

/// Coordinator for the «OK Coucou» voice feature.
///
/// Responsibilities:
/// - Manages VoiceAudio (energy VAD) and WakeSpotter (on-device recognition).
/// - Routes audio buffers to the wake spotter or, after a wake event, to the
///   command recognizer.
/// - Fires island notifications (.voiceWoke / .voiceFinished) so
///   IslandWindowController keeps the FSM in sync.
/// - Auto-pauses on: screen lock/sleep, Low Power Mode, voice disabled.
///
/// Audio transcriptions are never logged beyond the per-session command
/// transcript held in `commandTranscript` (in-memory only).
@MainActor
final class VoiceEngine: ObservableObject {
    static let shared = VoiceEngine()

    // MARK: - Published state

    @Published var isEnabled: Bool = VoiceSettings.isEnabled {
        didSet {
            VoiceSettings.isEnabled = isEnabled
            handleEnabledChanged()
        }
    }
    /// True while the engine is actively listening for a command (after wake detection).
    @Published private(set) var isListeningForCommand: Bool = false
    /// Live command transcript (in-memory only, never written to disk or logs).
    @Published private(set) var commandTranscript: String = ""
    /// True when no on-device speech model is available for any supported locale.
    @Published private(set) var recognizerUnavailable: Bool = false

    // MARK: - Pause reasons

    private var screenLocked   = false
    private var screenSleeping = false
    private var lowPowerMode   = false

    var isPaused: Bool { screenLocked || screenSleeping || lowPowerMode }

    // MARK: - Audio pipeline (main-thread owned)

    private var audio:   VoiceAudio?
    private var spotter: WakeSpotter?

    // Command recognition
    private var commandRecognizer: SFSpeechRecognizer?
    private var commandTask:       SFSpeechRecognitionTask?
    private var silenceWork:       DispatchWorkItem?
    private var commandMaxWork:    DispatchWorkItem?
    private var lastWordCount      = 0

    // Lock protecting tap-thread-accessible references
    private let tapLock = NSLock()
    nonisolated(unsafe) private var tapSpotter:    WakeSpotter?
    nonisolated(unsafe) private var tapCommandReq: SFSpeechAudioBufferRecognitionRequest?
    nonisolated(unsafe) private var tapMode:       TapMode = .wake

    private enum TapMode { case wake, command }

    // Timing constants
    private static let silenceTimeout:  TimeInterval = 1.2
    private static let commandMaxTime:  TimeInterval = 10.0
    private static let cancelPhrases  = ["annule", "annuler", "cancel", "laisse tomber"]

    // MARK: - Init

    private init() {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        observeSystemEvents()
        if isEnabled && !isPaused { startAudioPipeline() }
    }

    // MARK: - Enable / pause

    private func handleEnabledChanged() {
        if isEnabled && !isPaused { startAudioPipeline() }
        else                      { stopAudioPipeline() }
    }

    private func updatePause() {
        if isPaused { stopAudioPipeline() }
        else if isEnabled { startAudioPipeline() }
    }

    /// Called by IslandWindowController when the listening island is dismissed by
    /// a user action (Escape, external collapse) so the command session ends cleanly.
    func cancelListening() {
        endCommand(postFinished: false)
    }

    // MARK: - Audio pipeline

    private func startAudioPipeline() {
        guard audio == nil else { return }
        guard let locale = suitableLocale() else {
            recognizerUnavailable = true
            return
        }
        recognizerUnavailable = false

        let a = VoiceAudio()
        let s = WakeSpotter()

        // Give spotter access to the tap-thread-safe slot
        tapLock.withLock {
            tapSpotter    = s
            tapCommandReq = nil
            tapMode       = .wake
        }

        s.onWake = { [weak self] transcript in
            // Already dispatched to main by WakeSpotter
            self?.wakeDetected(transcript: transcript, locale: locale)
        }

        a.onVoiceStart = { [weak self] in
            s.beginWindow(locale: locale)
        }

        a.onVoiceEnd = { [weak self] in
            guard let self else { return }
            // VAD ended without wake → close the recognition window
            tapLock.withLock {
                if tapMode == .wake { s.endWindow() }
            }
        }

        // Audio tap → spotter or command recognizer (audio thread)
        a.onBuffer = { [weak self] buf, _ in
            guard let self else { return }
            self.tapLock.withLock {
                switch self.tapMode {
                case .wake:    self.tapSpotter?.feed(buf)
                case .command: self.tapCommandReq?.append(buf)
                }
            }
        }

        do {
            try a.start()
            audio   = a
            spotter = s
        } catch {
            // Microphone unavailable or permission denied
        }
    }

    private func stopAudioPipeline() {
        endCommand(postFinished: false)
        audio?.stop()
        audio   = nil
        spotter = nil
        tapLock.withLock {
            tapSpotter    = nil
            tapCommandReq = nil
            tapMode       = .wake
        }
    }

    // MARK: - Wake detection

    private func wakeDetected(transcript: String, locale: Locale) {
        guard isEnabled, !isPaused, !isListeningForCommand else { return }
        isListeningForCommand = true
        commandTranscript     = ""
        lastWordCount         = 0
        NotificationCenter.default.post(name: .voiceWoke, object: nil)
        startCommandRecognizer(locale: locale)
    }

    // MARK: - Command recognition

    private func startCommandRecognizer(locale: Locale) {
        guard let r = SFSpeechRecognizer(locale: locale),
              r.supportsOnDeviceRecognition,
              r.isAvailable else {
            endCommand(postFinished: true)
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults  = true
        req.requiresOnDeviceRecognition = true

        commandRecognizer = r
        tapLock.withLock {
            tapCommandReq = req
            tapMode       = .command
        }

        commandTask = r.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let text = result?.bestTranscription.formattedString {
                    let stripped = Self.stripWakePhrase(text)
                    self.commandTranscript = stripped
                    let wc = stripped.split(separator: " ").count
                    if wc > self.lastWordCount {
                        self.lastWordCount = wc
                        self.resetSilenceTimer()
                        // Check for cancel phrase
                        let lower = stripped.lowercased()
                        if Self.cancelPhrases.contains(where: { lower.contains($0) }) {
                            self.endCommand(postFinished: true)
                            return
                        }
                    }
                }
                if result?.isFinal == true || error != nil {
                    self.endCommand(postFinished: true)
                }
            }
        }

        // Hard cap on command duration
        let maxItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.endCommand(postFinished: true) }
        }
        commandMaxWork = maxItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandMaxTime, execute: maxItem)

        // Initial silence timer (fires if nothing is said after wake)
        resetSilenceTimer()
    }

    private func resetSilenceTimer() {
        silenceWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.endCommand(postFinished: true) }
        }
        silenceWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silenceTimeout, execute: item)
    }

    private func endCommand(postFinished: Bool) {
        silenceWork?.cancel();    silenceWork    = nil
        commandMaxWork?.cancel(); commandMaxWork = nil

        tapLock.withLock {
            tapCommandReq?.endAudio()
            tapCommandReq = nil
            tapMode       = .wake
        }
        commandTask?.cancel()
        commandTask       = nil
        commandRecognizer = nil
        isListeningForCommand = false

        if postFinished {
            let cmd = commandTranscript
            NotificationCenter.default.post(name: .voiceFinished, object: cmd.isEmpty ? nil : cmd as NSString)
        }
    }

    // MARK: - Helpers

    /// Returns the first locale whose SFSpeechRecognizer supports on-device recognition.
    private func suitableLocale() -> Locale? {
        var candidates = MacDictation.automaticLocales()
        candidates += [Locale(identifier: "fr-FR"), Locale(identifier: "en-US")]
        for locale in candidates {
            if let r = SFSpeechRecognizer(locale: locale),
               r.supportsOnDeviceRecognition, r.isAvailable {
                return locale
            }
        }
        return nil
    }

    /// Strip the wake phrase from the start of a transcript.
    private static func stripWakePhrase(_ raw: String) -> String {
        let lower = raw.lowercased()
        let phrases = ["ok coucou", "okay coucou", "ok cuckoo", "ok kuku",
                       "hey coucou", "dis coucou", "coucou"]
        for phrase in phrases where lower.hasPrefix(phrase) {
            return String(raw.dropFirst(phrase.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    // MARK: - System event observers

    private func observeSystemEvents() {
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.screenLocked = true
                self?.updatePause()
            }
        }
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.screenLocked = false
                self?.updatePause()
            }
        }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = true
                self?.updatePause()
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = false
                self?.updatePause()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.updatePause()
            }
        }
    }
}

// MARK: - Voice notification names (defined alongside the engine that posts them)

extension Notification.Name {
    /// Posted (main thread) when the wake phrase is detected. Island opens in .listening.
    static let voiceWoke     = Notification.Name("notchBuddy.voiceWoke")
    /// Posted (main thread) when listening ends (silence, cancel, max time, or user dismiss).
    /// `object` is the command String if any words were captured, nil otherwise.
    static let voiceFinished = Notification.Name("notchBuddy.voiceFinished")
}
#endif
