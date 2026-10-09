#if !APPSTORE
import AVFoundation

// MARK: - VoiceAudio
//
// Wraps AVAudioEngine to deliver a low-level audio tap for voice detection.
//
// Thread model:
// - `start()` / `stop()` / `resetVAD()` called on the main thread.
// - `onVoiceStart`, `onVoiceEnd`, `onMicLevel`, `onConfigChange` dispatched to the main thread.
// - `onBuffer` called on the audio tap thread — its closure must be thread-safe.
//
// VAD modes:
// - Normal (wake): EnergyVAD drives `onVoiceStart`/`onVoiceEnd`.
// - Bypass (`bypassVAD = true`): every buffer is delivered via `onBuffer` regardless of
//   silence; `onMicLevel` fires at ~20 Hz with a smoothed level.
//
// AEC: `setVoiceProcessingEnabled(true)` is applied on macOS 14+ to remove
// acoustic echo (Mac speakers → mic feedback). Does NOT duck other apps' audio.
final class VoiceAudio: @unchecked Sendable {

    private let engine         = AVAudioEngine()
    private var tapInstalled   = false
    private var configObserver: NSObjectProtocol? = nil

    // VAD — read/written only on the audio tap thread.
    private var vad = EnergyVAD()

    // Smoothed mic level during bypass mode — audio tap thread.
    private var smoothedLevel:  Double = 0
    private var levelFrameCount = 0

    // Pre-roll circular buffer (~500 ms).
    // Read on main (via `drainPreroll()`), written on audio tap thread.
    private let prerollLock    = NSLock()
    private var prerollBuffers: [AVAudioPCMBuffer] = []
    private static let prerollCapacity = 22   // ~500 ms at 43 Hz

    /// Last time a buffer was processed in the tap (audio tap thread).
    /// Read on main for stall detection — nonisolated for cross-thread access.
    nonisolated(unsafe) private(set) var lastBufferTime: Date = .distantPast

    /// When true, every audio buffer is delivered via `onBuffer` regardless of VAD.
    nonisolated(unsafe) var bypassVAD: Bool = false

    /// Set on the main thread after a command ends; consumed by the audio tap thread.
    nonisolated(unsafe) private var pendingVADReset: Bool = false

    // MARK: Callbacks

    var onVoiceStart:   (() -> Void)?
    var onVoiceEnd:     (() -> Void)?
    /// Called on the audio tap thread.
    var onBuffer:       ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var onMicLevel:     ((Double) -> Void)?
    /// Fired on the main thread when AVAudioEngine reports a configuration change
    /// (headphone connect/disconnect, sample-rate change, etc.).
    var onConfigChange: (() -> Void)?

    // MARK: - Control

    func start() throws {
        guard !tapInstalled else { return }
        let input = engine.inputNode

        // AEC: remove echo of Mac speakers from the mic signal (macOS 14+).
        // Does NOT duck other apps' audio — music stays at full volume.
        if #available(macOS 14, *) {
            do {
                try input.setVoiceProcessingEnabled(true)
                appendAppLog("nb.log", "[VoiceAudio] AEC enabled")
            } catch {
                appendAppLog("nb.log", "[VoiceAudio] AEC unavailable: \(error.localizedDescription)")
            }
        }

        let fmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, time in
            self?.processTap(buf, time: time)
        }
        tapInstalled = true

        // Rebuild on device change (headphones, sample-rate switch…).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.onConfigChange?()
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        guard tapInstalled else { return }
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        prerollLock.withLock { prerollBuffers.removeAll() }
        if vad.isActive {
            vad.reset()
            DispatchQueue.main.async { [weak self] in self?.onVoiceEnd?() }
        }
    }

    func resetVAD() { pendingVADReset = true }

    func drainPreroll() -> [AVAudioPCMBuffer] {
        prerollLock.withLock {
            let snap = prerollBuffers
            prerollBuffers.removeAll()
            return snap
        }
    }

    // MARK: - Tap processing (audio thread)

    private func processTap(_ buf: AVAudioPCMBuffer, time: AVAudioTime) {
        lastBufferTime = Date()

        if pendingVADReset {
            pendingVADReset = false
            vad.reset()
            smoothedLevel   = 0
            levelFrameCount = 0
        }

        prerollLock.withLock {
            if prerollBuffers.count >= Self.prerollCapacity { prerollBuffers.removeFirst() }
            prerollBuffers.append(buf)
        }

        if bypassVAD {
            onBuffer?(buf, time)
            let power = buf.meanSquarePower
            smoothedLevel = smoothedLevel * 0.6 + power * 0.4
            levelFrameCount += 1
            if levelFrameCount % 2 == 0 {
                let level = min(1.0, smoothedLevel * 2000)
                DispatchQueue.main.async { [weak self] in self?.onMicLevel?(level) }
            }
            return
        }

        let power = buf.meanSquarePower
        let event = vad.feed(power)

        switch event {
        case .start:
            DispatchQueue.main.async { [weak self] in self?.onVoiceStart?() }
        case .end:
            DispatchQueue.main.async { [weak self] in self?.onVoiceEnd?() }
        case .none:
            break
        }

        if vad.isActive { onBuffer?(buf, time) }
    }
}

// MARK: - AVAudioPCMBuffer mean-square power

private extension AVAudioPCMBuffer {
    var meanSquarePower: Double {
        guard let data = floatChannelData, frameLength > 0 else { return 0 }
        let frames = Int(frameLength)
        let chans  = Int(format.channelCount)
        var sum: Double = 0
        for ch in 0..<chans {
            let p = data[ch]
            for i in 0..<frames { let s = Double(p[i]); sum += s * s }
        }
        return sum / Double(frames * max(1, chans))
    }
}
#endif
