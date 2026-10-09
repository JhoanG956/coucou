import Foundation

@main
enum EnergyVADTests {

    static var failures = 0
    static var total    = 0

    static func main() {

        // MARK: 1. Calibration: no trigger during first 22 frames
        do {
            var vad = EnergyVAD()
            var triggered = false
            for _ in 0..<EnergyVAD.calibFrames {
                if vad.feed(1e-4) == .start { triggered = true }  // high power during calib
            }
            check("calibration: no trigger during first \(EnergyVAD.calibFrames) frames", !triggered)
        }

        // MARK: 2. After calibration, ambient never triggers
        do {
            var vad = EnergyVAD()
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(1e-5) }  // calibrate at ambient
            var triggered = false
            for _ in 0..<100 {
                if vad.feed(1e-5) == .start { triggered = true }  // ambient: should NOT trigger
            }
            check("ambient does not trigger after calibration", !triggered)
        }

        // MARK: 3. Speech above threshold → start
        do {
            var vad = EnergyVAD()
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(1e-5) }
            var startSeen = false
            for _ in 0..<10 {
                if vad.feed(1e-4) == .start { startSeen = true; break }
            }
            check("speech above threshold → start", startSeen)
        }

        // MARK: 4. Start then silence → end
        do {
            var vad = EnergyVAD()
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(1e-5) }
            // Trigger start
            while vad.feed(1e-4) != .start {}
            // Silence (below fallRatio * noisePower ≈ 2 * 1e-5 = 2e-5)
            var endSeen = false
            for _ in 0..<(EnergyVAD.silenceFrames + 5) {
                if vad.feed(1e-7) == .end { endSeen = true }
            }
            check("silence after speech → end", endSeen)
        }

        // MARK: 5. 10 cycles: speech→start, reset, speech→start again
        // Use 5e-4 (well above 8× ambient of 1e-5) so noise-floor drift doesn't prevent
        // the trigger even after the noisePower has crept up slightly from previous cycles.
        do {
            var vad = EnergyVAD()
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(1e-5) }
            var allOk = true
            for i in 0..<10 {
                // Trigger start
                var startSeen = false
                for _ in 0..<20 {
                    if vad.feed(5e-4) == .start { startSeen = true; break }
                }
                if !startSeen { allOk = false; print("  cycle \(i): no start"); break }
                vad.reset()
                if vad.isActive { allOk = false; print("  cycle \(i): still active after reset"); break }
            }
            check("10 cycles: speech→start, reset, repeat", allOk)
        }

        // MARK: 6. Max segment: 1300+ active frames → end
        do {
            var vad = EnergyVAD()
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(1e-5) }
            while vad.feed(1e-4) != .start {}
            var endSeen = false
            for _ in 0..<(EnergyVAD.maxActiveFrames + 5) {
                if vad.feed(1e-4) == .end { endSeen = true }
            }
            check("max segment (\(EnergyVAD.maxActiveFrames) frames) → forced end", endSeen)
        }

        // MARK: 7. Ambient that rises mid-session eventually falls (via max segment)
        do {
            var vad = EnergyVAD()
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(1e-5) }
            // Start with normal speech
            while vad.feed(1e-4) != .start {}
            // Now feed high ambient (simulates room noise rising): never reach silence threshold
            var endSeen = false
            for _ in 0..<(EnergyVAD.maxActiveFrames + 10) {
                if vad.feed(1e-3) == .end { endSeen = true; break }  // high ambient, no silence
            }
            check("ambient rise forces end via max segment", endSeen)
            check("inactive after forced end", !vad.isActive)
        }

        // Summary
        if failures == 0 { print("\n\(total)/\(total) tests passed.") }
        else { print("\n\(failures) test(s) FAILED."); exit(1) }
    }

    static func check(_ label: String, _ condition: Bool) {
        total += 1
        if condition { print("✓  \(label)") }
        else { print("✗  \(label)"); failures += 1 }
    }
}
