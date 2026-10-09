#if !APPSTORE
import AVFoundation

// MARK: - VoiceAudio

/// Wraps AVAudioEngine to deliver a low-level audio tap for voice detection.
/// Computes per-buffer RMS energy and drives a simple adaptive VAD (voice activity
/// detector): the recognizer only runs while someone is actually speaking, keeping
/// CPU near 0 % during silence.
///
/// Thread model: `start()` / `stop()` are called on the main thread.
/// `onVoiceStart`, `onVoiceEnd` are dispatched to the main thread.
/// `onBuffer` is called **on the audio tap thread** — its closure must be thread-safe.
final class VoiceAudio: @unchecked Sendable {

    private let engine      = AVAudioEngine()
    private var tapInstalled = false

    // Adaptive VAD — state read/written only on the audio tap thread.
    private var noisePower: Double = 1e-7    // background power estimate (exponential avg)
    private var vadActive  = false
    private var silentBufs = 0               // consecutive below-threshold buffers

    /// Voice starts when instantaneous power exceeds noisePower × this ratio.
    private static let riseRatio: Double = 8.0
    /// Voice ends when power stays below noisePower × this ratio for `silenceFrames`.
    private static let fallRatio: Double = 2.0
    /// Number of consecutive quiet buffers required to declare end-of-voice.
    /// At bufferSize=1024 and ~44 kHz the tap fires ~43 times/s → ~6 ≈ 140 ms.
    private static let silenceFrames = 6

    // MARK: Callbacks

    /// Fired on the main thread when voice activity starts.
    var onVoiceStart: (() -> Void)?
    /// Fired on the main thread when voice activity ends.
    var onVoiceEnd: (() -> Void)?
    /// Fired on the **audio tap thread** with each PCM buffer during voice activity.
    /// The closure must be thread-safe (do not access main-actor state).
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
        if vadActive {
            vadActive = false
            DispatchQueue.main.async { [weak self] in self?.onVoiceEnd?() }
        }
    }

    // MARK: - Tap processing (audio thread)

    private func processTap(_ buf: AVAudioPCMBuffer, time: AVAudioTime) {
        let power = buf.meanSquarePower

        if !vadActive {
            // Update noise floor only during silence (speech would inflate it)
            noisePower = noisePower * 0.995 + power * 0.005
            if power > noisePower * Self.riseRatio {
                vadActive   = true
                silentBufs  = 0
                DispatchQueue.main.async { [weak self] in self?.onVoiceStart?() }
            }
        } else {
            // Feed buffer to the active consumer (spotter or command recognizer)
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
    /// Mean of squared samples across all frames and channels.
    var meanSquarePower: Double {
        guard let data = floatChannelData, frameLength > 0 else { return 0 }
        let frames = Int(frameLength)
        let chans  = Int(format.channelCount)
        var sum: Double = 0
        for ch in 0..<chans {
            let p = data[ch]
            for i in 0..<frames {
                let s = Double(p[i])
                sum += s * s
            }
        }
        return sum / Double(frames * max(1, chans))
    }
}
#endif
