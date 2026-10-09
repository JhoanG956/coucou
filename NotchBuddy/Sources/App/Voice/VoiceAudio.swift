#if !APPSTORE
import AVFoundation

// MARK: - VoiceAudio

/// Wraps AVAudioEngine to deliver a low-level audio tap for voice detection.
///
/// Thread model:
/// - `start()` / `stop()` / `resetVAD()` called on the main thread.
/// - `onVoiceStart`, `onVoiceEnd`, `onMicLevel` dispatched to the main thread.
/// - `onBuffer` called **on the audio tap thread** — its closure must be thread-safe.
///
/// VAD modes:
/// - Normal (wake): EnergyVAD drives `onVoiceStart`/`onVoiceEnd`.
/// - Bypass (`bypassVAD = true`): every buffer is delivered via `onBuffer` regardless of
///   silence; `onMicLevel` fires at ~20 Hz with a smoothed level.
final class VoiceAudio: @unchecked Sendable {

    private let engine       = AVAudioEngine()
    private var tapInstalled = false

    // VAD — read/written only on the audio tap thread.
    private var vad = EnergyVAD()

    // Smoothed mic level during bypass mode — audio tap thread.
    private var smoothedLevel: Double = 0
    private var levelFrameCount = 0

    // Pre-roll circular buffer (~500 ms).
    // Read on main (via `drainPreroll()`), written on audio tap thread.
    private let prerollLock     = NSLock()
    private var prerollBuffers: [AVAudioPCMBuffer] = []
    private static let prerollCapacity = 22   // ~500 ms at 43 Hz

    /// When true, every audio buffer is delivered via `onBuffer` regardless of VAD.
    /// Written on the main thread; read on the audio tap thread.
    nonisolated(unsafe) var bypassVAD: Bool = false

    // MARK: Callbacks

    /// Fired on the main thread when voice activity starts (VAD rise).
    var onVoiceStart: (() -> Void)?
    /// Fired on the main thread when voice activity ends (VAD fall, only when bypassVAD is false).
    var onVoiceEnd: (() -> Void)?
    /// Fired on the **audio tap thread** with each PCM buffer.
    /// Normal mode: only during voice activity.  Bypass mode: every buffer.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    /// Fired on the main thread at ~20 Hz during bypass mode with smoothed mic level (0…1 approx).
    /// Nil or 0 when not in bypass mode.
    var onMicLevel: ((Double) -> Void)?

    // MARK: - Control

    func start() throws {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let fmt   = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, time in
            self?.processTap(buf, time: time)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        guard tapInstalled else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        prerollLock.withLock { prerollBuffers.removeAll() }
        if vad.isActive {
            vad.reset()
            DispatchQueue.main.async { [weak self] in self?.onVoiceEnd?() }
        }
    }

    /// Hard-reset the VAD to inactive state; preserves the learned noise floor.
    /// Call from the main thread after a command ends so the next speech restarts cleanly.
    func resetVAD() {
        // vad is audio-tap-thread state, but we write it under no lock since resetVAD
        // is called synchronously on main thread after bypassVAD has been cleared — the
        // tap will not read vad until the next buffer, which is always after this returns.
        vad.reset()
        smoothedLevel = 0
        levelFrameCount = 0
    }

    /// Return a snapshot of the pre-roll ring buffer and clear it.
    /// Called on the main thread just before `WakeSpotter.beginWindow`.
    func drainPreroll() -> [AVAudioPCMBuffer] {
        prerollLock.withLock {
            let snap = prerollBuffers
            prerollBuffers.removeAll()
            return snap
        }
    }

    // MARK: - Tap processing (audio thread)

    private func processTap(_ buf: AVAudioPCMBuffer, time: AVAudioTime) {
        // Always maintain the pre-roll ring buffer.
        prerollLock.withLock {
            if prerollBuffers.count >= Self.prerollCapacity { prerollBuffers.removeFirst() }
            prerollBuffers.append(buf)
        }

        if bypassVAD {
            onBuffer?(buf, time)
            // Smoothed mic level for Mochi animation (~20 Hz).
            let power = buf.meanSquarePower
            smoothedLevel = smoothedLevel * 0.6 + power * 0.4
            levelFrameCount += 1
            if levelFrameCount % 2 == 0 {
                let level = min(1.0, smoothedLevel * 2000)   // rough normalisation to 0…1
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

        if vad.isActive {
            onBuffer?(buf, time)
        }
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
