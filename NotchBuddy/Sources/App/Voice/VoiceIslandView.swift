#if !APPSTORE
import SwiftUI

// MARK: - VoiceListeningView

/// Content of the island while the voice engine is listening for a command.
/// Shown when `AppState.view == .listening`.
///
/// Layout mirrors other 160-pt views: Mochi (BotPlacement) occupies the left ~110 pt;
/// the card fills the remaining space to the right.
struct VoiceListeningView: View {
    @ObservedObject private var voice = VoiceEngine.shared

    var body: some View {
        ZStack {
            CardBackground(wash: .cyan)

            HStack(spacing: 0) {
                // Reserve space for BotPlacement (injected by IslandContainer)
                Spacer().frame(width: 110)

                VStack(alignment: .leading, spacing: 6) {
                    // Status row: pulsing mic dot + "À l'écoute…" label
                    HStack(spacing: 7) {
                        MicDotView()
                        Text("À l'écoute…")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                    }

                    // Live transcript (empty until user starts speaking)
                    if voice.commandTranscript.isEmpty {
                        Text("Dites votre commande")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#8E939C"))
                    } else {
                        Text(voice.commandTranscript)
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#C8CBD0"))
                            .lineLimit(2)
                            .animation(.easeOut(duration: 0.1), value: voice.commandTranscript)
                    }
                }
                .padding(.trailing, 18)

                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - MicDotView

/// A pulsing microphone-indicator dot (matches macOS orange recording dot convention).
private struct MicDotView: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color(hex: "#F97316"))   // warm orange
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing ? 1.35 : 1.0)
            .opacity(pulsing ? 0.65 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
            .onDisappear { pulsing = false }
    }
}
#endif
