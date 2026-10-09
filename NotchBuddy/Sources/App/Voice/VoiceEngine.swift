#if !APPSTORE
import AppKit
import AVFoundation
import Speech

// MARK: - VoiceEngine

/// Coordinator for the «OK Coucou» voice feature.
///
/// - Uses VoiceAudio (energy VAD) and WakeSpotter (on-device recognition).
/// - WakeSpotter handles both wake detection and command transcription in one session.
/// - After wake: VoiceAudio.bypassVAD = true so the command receives continuous audio.
/// - Fires island notifications (.voiceWoke / .voiceFinished) on the main thread.
/// - Auto-pauses on: screen lock, screen sleep, system sleep, Low Power Mode,
///   MacDictation active.
@MainActor
final class VoiceEngine: ObservableObject {
    static let shared = VoiceEngine()

    // MARK: - Published state

    @Published var isEnabled: Bool = VoiceSettings.isEnabled {
        didSet { VoiceSettings.isEnabled = isEnabled; handleEnabledChanged() }
    }
    @Published private(set) var isListeningForCommand: Bool = false
    @Published private(set) var commandTranscript: String = ""
    @Published private(set) var recognizerUnavailable: Bool = false
    @Published private(set) var audioError: String? = nil

    // MARK: - Pause reasons

    private var screenLocked   = false
    private var screenSleeping = false
    private var lowPowerMode   = false
    private var dictationActive = 0   // reference count: MacDictation instances recording

    var isPaused: Bool { screenLocked || screenSleeping || lowPowerMode || dictationActive > 0 }

    // MARK: - Audio pipeline (main-thread owned)

    private var audio:   VoiceAudio?
    private var spotter: WakeSpotter?

    // Command session timers and state
    private var silenceWork:    DispatchWorkItem?
    private var commandMaxWork: DispatchWorkItem?
    private var lastWordCount   = 0

    private static let silenceTimeout: TimeInterval = 1.2
    private static let commandMaxTime: TimeInterval = 10.0
    private static let cancelPhrases = ["annule", "annuler", "cancel", "laisse tomber"]

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

    /// Called by IslandWindowController when listening is dismissed externally.
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
        audioError = nil

        let a = VoiceAudio()
        let s = WakeSpotter()

        s.onWake = { [weak self] transcript in
            self?.wakeDetected(transcript: transcript, locale: locale)
        }

        s.onCommandUpdate = { [weak self] stripped in
            self?.commandUpdate(stripped)
        }

        s.onCommandEnd = { [weak self] in
            self?.endCommand(postFinished: true)
        }

        a.onVoiceStart = { [weak self] in
            guard let self else { return }
            let preroll = a.drainPreroll()
            s.beginWindow(locale: locale, preroll: preroll)
        }

        a.onVoiceEnd = { [weak self] in
            guard let self else { return }
            // Only close the wake window if we're not already in command mode.
            // `isInCommandPhase` is lock-protected and safe to check on main before
            // `isListeningForCommand` is set (race with onWake dispatch).
            if !self.isListeningForCommand && !s.isInCommandPhase {
                s.endWindow()
            }
        }

        a.onBuffer = { buf, _ in
            s.feed(buf)
        }

        do {
            try a.start()
            audio   = a
            spotter = s
        } catch {
            audioError = error.localizedDescription
        }
    }

    private func stopAudioPipeline() {
        endCommand(postFinished: false)
        audio?.stop()
        audio   = nil
        spotter = nil
    }

    // MARK: - Wake detection

    private func wakeDetected(transcript: String, locale: Locale) {
        guard isEnabled, !isPaused, !isListeningForCommand else { return }
        guard !shouldIgnoreWake() else { return }
        isListeningForCommand = true
        commandTranscript     = ""
        lastWordCount         = 0
        audio?.bypassVAD      = true
        NotificationCenter.default.post(name: .voiceWoke, object: nil)
        // Silence and max-duration timers
        resetSilenceTimer()
        let maxItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.endCommand(postFinished: true) }
        }
        commandMaxWork = maxItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandMaxTime, execute: maxItem)
    }

    private func commandUpdate(_ stripped: String) {
        commandTranscript = stripped
        let wc = stripped.split(separator: " ").count
        if wc > lastWordCount {
            lastWordCount = wc
            resetSilenceTimer()
            let lower = stripped.lowercased()
            if Self.cancelPhrases.contains(where: { lower.contains($0) }) {
                endCommand(postFinished: true)
            }
        }
    }

    // MARK: - Command session management

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
        audio?.bypassVAD = false
        spotter?.endWindow()
        isListeningForCommand = false
        if postFinished {
            let cmd = commandTranscript
            NotificationCenter.default.post(name: .voiceFinished,
                                            object: cmd.isEmpty ? nil : cmd as NSString)
        }
    }

    // MARK: - Helpers

    /// Returns true when the island is showing an approval, question, or chat prompt —
    /// wake detection is suppressed in those states to avoid interrupting the user.
    private func shouldIgnoreWake() -> Bool {
        let v = AppState.shared.view
        return v == .approval || v == .question || v == .prompt
            || AppState.shared.pendingApproval != nil
    }

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

    // MARK: - System event observers

    private func observeSystemEvents() {
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked = true;  self?.updatePause() }
        }
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked = false; self?.updatePause() }
        }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenSleeping = true;  self?.updatePause() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenSleeping = false; self?.updatePause() }
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenSleeping = true;  self?.updatePause() }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenSleeping = false; self?.updatePause() }
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

        // Pause while chat dictation is active.
        NotificationCenter.default.addObserver(
            forName: .dictationDidStart, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dictationActive += 1
                self?.updatePause()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .dictationDidEnd, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dictationActive = max(0, (self?.dictationActive ?? 0) - 1)
                self?.updatePause()
            }
        }
    }
}

// MARK: - Voice notification names

extension Notification.Name {
    static let voiceWoke     = Notification.Name("notchBuddy.voiceWoke")
    static let voiceFinished = Notification.Name("notchBuddy.voiceFinished")
    // dictationDidStart / dictationDidEnd are defined in MacDictation.swift
}
#endif
