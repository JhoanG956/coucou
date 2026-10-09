#if !APPSTORE
import AVFoundation

// MARK: - VoiceAudio

/// Wraps AVAudioEngine to deliver a low-level audio tap for voice detection.
///
/// Thread model:
/// - `start()` / `stop()` called on the main thread.
/// - `onVoiceStart`, `onVoiceEnd` dispatched to the main thread.
/// - `onBuffer` called **on the audio tap thread** — its closure must be thread-safe.
///
/// VAD modes:
/// - Normal (wake): energy VAD drives `onVoiceStart`/`onVoiceEnd`; ~800 ms silence to end.
/// - Bypass (`bypassVAD = true`): every buffer is delivered via `onBuffer` regardless of
///   silence, so the command recognizer receives continuous audio. Set by VoiceEngine after
///   a wake event, cleared after command ends.
final class VoiceAudio: @unchecked Sendable {

    private let engine       = AVAudioEngine()
    private var tapInstalled = false

    // Adaptive VAD — read/written only on the audio tap thread.
    private var noisePower: Double = 1e-7
    private var vadActive  = false
    private var silentBufs = 0

    private static let riseRatio: Double  = 8.0
    private static let fallRatio: Double  = 2.0
    /// ~800 ms at 44 100 Hz / 1 024 frames ≈ 34.9 → 35 frames.
    private static let silenceFrames      = 35

    // Pre-roll circular buffer (~500 ms).
    // Read on main (via `drainPreroll()`), written on audio tap thread.
    private let prerollLock     = NSLock()
    private var prerollBuffers: [AVAudioPCMBuffer] = []
    private static let prerollCapacity = 22   // ~500 ms at 43 Hz

    /// When true, every audio buffer is delivered via `onBuffer` regardless of VAD.
    /// Written on the main thread before the next tap fires; read on the audio tap thread.
    /// Safe to use `nonisolated(unsafe)` because the write is always ordered before the read
    /// (main sets it before the next tap period, audio tap reads it on the next cycle).
    nonisolated(unsafe) var bypassVAD: Bool = false

    // MARK: Callbacks

    /// Fired on the main thread when voice activity starts (VAD rise).
    var onVoiceStart: (() -> Void)?
    /// Fired on the main thread when voice activity ends (VAD fall, only when bypassVAD is false).
    var onVoiceEnd: (() -> Void)?
    /// Fired on the **audio tap thread** with each PCM buffer.
    /// In normal mode: only during voice activity.
    /// In bypass mode: every buffer.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

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
        if vadActive {
            vadActive = false
            DispatchQueue.main.async { [weak self] in self?.onVoiceEnd?() }
        }
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
            // Command mode: deliver every buffer, skip VAD logic.
            onBuffer?(buf, time)
            return
        }

        let power = buf.meanSquarePower

        if !vadActive {
            noisePower = noisePower * 0.995 + power * 0.005
            if power > noisePower * Self.riseRatio {
                vadActive  = true
                silentBufs = 0
                DispatchQueue.main.async { [weak self] in self?.onVoiceStart?() }
            }
        } else {
            onBuffer?(buf, time)
            if power < noisePower * Self.fallRatio {
                silentBufs += 1
                if silentBufs >= Self.silenceFrames {
                    vadActive  = false
                    silentBufs = 0
                    DispatchQueue.main.async { [weak self] in self?.onVoiceEnd?() }
                }
            } else {
                silentBufs = 0
            }
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
