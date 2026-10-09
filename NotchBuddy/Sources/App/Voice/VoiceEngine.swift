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
/// - Wake window restarts every 20 s of continuous speech to bound recognition cost.
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

    private var screenLocked    = false
    private var screenSleeping  = false
    private var lowPowerMode    = false
    private var dictationActive = 0    // reference count: MacDictation instances currently recording

    var isPaused: Bool { screenLocked || screenSleeping || lowPowerMode || dictationActive > 0 }

    // MARK: - Audio pipeline (main-thread owned)

    private var audio:   VoiceAudio?
    private var spotter: WakeSpotter?
    private var locale:  Locale?

    /// True while the VAD has detected voice activity (VAD rose, hasn't fallen yet).
    private var voiceSegmentActive = false

    // Command session timers and state
    private var silenceWork:      DispatchWorkItem?
    private var commandMaxWork:   DispatchWorkItem?
    private var wakeWindowWork:   DispatchWorkItem?   // 20 s window-restart timer
    private var lastWordCount     = 0

    /// Time to start speaking after the wake phrase before the session times out.
    private static let initialTimeout:  TimeInterval = 3.0
    /// Silence duration that ends a command once speaking has started.
    private static let silenceTimeout:  TimeInterval = 1.2
    private static let commandMaxTime:  TimeInterval = 10.0
    /// Restart the wake recognition window every N seconds of continuous speech.
    private static let wakeWindowMax:   TimeInterval = 20.0

    private static let cancelPhrases = ["annule", "annuler", "cancel", "laisse tomber", "never mind"]

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
        guard let loc = suitableLocale() else {
            recognizerUnavailable = true
            return
        }
        recognizerUnavailable = false
        audioError = nil
        locale = loc

        let a = VoiceAudio()
        let s = WakeSpotter()

        s.onWake = { [weak self] transcript in
            self?.wakeDetected(transcript: transcript)
        }

        s.onCommandUpdate = { [weak self] command in
            self?.commandUpdate(command)
        }

        s.onCommandEnd = { [weak self] in
            self?.endCommand(postFinished: true)
        }

        // Wake window ended naturally (final result in wake phase) — reopen if voice is still active.
        s.onWakeWindowEnded = { [weak self] in
            guard let self, !isListeningForCommand, voiceSegmentActive else { return }
            let preroll = a.drainPreroll()
            s.beginWindow(locale: loc, preroll: preroll)
            scheduleWakeWindowRestart(audio: a, spotter: s, locale: loc)
        }

        a.onVoiceStart = { [weak self] in
            guard let self else { return }
            voiceSegmentActive = true
            let preroll = a.drainPreroll()
            s.beginWindow(locale: loc, preroll: preroll)
            scheduleWakeWindowRestart(audio: a, spotter: s, locale: loc)
        }

        a.onVoiceEnd = { [weak self] in
            guard let self else { return }
            voiceSegmentActive = false
            wakeWindowWork?.cancel(); wakeWindowWork = nil
            // Only close the wake window if we're not already in command mode.
            // isInCommandPhase is lock-protected and safe to check on main before
            // isListeningForCommand is set (race with onWake dispatch).
            if !isListeningForCommand && !s.isInCommandPhase {
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
        wakeWindowWork?.cancel(); wakeWindowWork = nil
        audio?.stop()
        audio   = nil
        spotter = nil
        locale  = nil
        voiceSegmentActive = false
    }

    // MARK: - 20-second wake-window restart

    private func scheduleWakeWindowRestart(audio: VoiceAudio, spotter: WakeSpotter, locale: Locale) {
        wakeWindowWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !isListeningForCommand else { return }
            let preroll = audio.drainPreroll()
            spotter.endWindow()
            spotter.beginWindow(locale: locale, preroll: preroll)
            scheduleWakeWindowRestart(audio: audio, spotter: spotter, locale: locale)
        }
        wakeWindowWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeWindowMax, execute: item)
    }

    // MARK: - Wake detection

    private func wakeDetected(transcript: String) {
        // FIX: reset spotter if we're going to ignore this wake, so the window doesn't
        // stay permanently in command phase and block future wake detections.
        guard isEnabled, !isPaused else {
            spotter?.endWindow()
            return
        }
        guard !isListeningForCommand else {
            spotter?.endWindow()
            return
        }
        guard !shouldIgnoreWake() else {
            spotter?.endWindow()
            return
        }
        wakeWindowWork?.cancel(); wakeWindowWork = nil
        isListeningForCommand = true
        commandTranscript     = ""
        lastWordCount         = 0
        audio?.bypassVAD      = true
        NotificationCenter.default.post(name: .voiceWoke, object: nil)
        // Initial timeout: 3 s to start speaking, then 1.2 s silence to finish.
        resetSilenceTimer()
        let maxItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.endCommand(postFinished: true) }
        }
        commandMaxWork = maxItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandMaxTime, execute: maxItem)
    }

    private func commandUpdate(_ command: String) {
        commandTranscript = command
        let wc = command.split(separator: " ").count
        if wc > lastWordCount {
            lastWordCount = wc
            resetSilenceTimer()
            // Cancel only when the ENTIRE command is a cancel phrase (not a substring).
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            if Self.cancelPhrases.contains(trimmed) {
                endCommand(postFinished: true)
            }
        }
    }

    // MARK: - Command session management

    private func resetSilenceTimer() {
        silenceWork?.cancel()
        // Use the longer initial timeout before any words are spoken;
        // switch to the shorter silence timeout once speaking has begun.
        let timeout = lastWordCount > 0 ? Self.silenceTimeout : Self.initialTimeout
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.endCommand(postFinished: true) }
        }
        silenceWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
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
