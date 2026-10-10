#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - VoiceCaptionState

/// Holds the two text lines shown in the caption capsule.
/// Mutated only from @MainActor (VoiceCaptionManager).
final class VoiceCaptionState: ObservableObject {
    @Published var userLine: String = ""
    @Published var responseLine: String = ""
    @Published var isVisible: Bool = false
}

// MARK: - VoiceCaptionManager
//
// Manages a borderless, non-activating NSPanel positioned below the notch center.
// Shows a compact capsule with:
//   – user transcript (gray, top line)
//   – AI response    (white, bottom line, streams in)
// Fades in/out in 0.2s. Auto-hides 2s after endConversation().
//
// Usage:
//   VoiceCaptionManager.shared.show(on: screen, notchHeight: 36)
//   VoiceCaptionManager.shared.setUserLine("Ajoute GitHub")
//   VoiceCaptionManager.shared.appendResponse("D'accord.")
//   VoiceCaptionManager.shared.endConversation()

@MainActor
final class VoiceCaptionManager {
    static let shared = VoiceCaptionManager()

    let state = VoiceCaptionState()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private let captionWidth:  CGFloat = 360
    private let captionHeight: CGFloat = 52
    private let notchGap:      CGFloat = 6

    private init() {}

    // MARK: - Show / hide

    func show(on screen: NSScreen, notchHeight: CGFloat) {
        guard VoiceSettings.captionEnabled else { return }
        hideTask?.cancel()
        hideTask = nil

        if panel == nil { _buildPanel() }
        _position(on: screen, notchHeight: notchHeight)

        guard let p = panel else { return }
        if !p.isVisible { p.alphaValue = 0; p.orderFrontRegardless() }

        state.isVisible = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self._fadeOut() }
        }
    }

    // MARK: - Content updates

    func setUserLine(_ text: String) {
        state.userLine = text
        state.responseLine = ""
    }

    func appendResponse(_ chunk: String) {
        if state.responseLine.isEmpty {
            state.responseLine = chunk
        } else {
            state.responseLine += " " + chunk
        }
    }

    func clearResponse() {
        state.responseLine = ""
    }

    /// Call when the conversation ends. Panel fades out after 2s.
    func endConversation() {
        hide(after: 2.0)
    }

    // MARK: - Private

    private func _buildPanel() {
        let view = NSHostingView(rootView: VoiceCaptionView(state: state))
        view.frame = NSRect(x: 0, y: 0, width: captionWidth, height: captionHeight)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: captionWidth, height: captionHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.contentView = view
        p.alphaValue = 0
        panel = p
    }

    private func _position(on screen: NSScreen, notchHeight: CGFloat) {
        guard let p = panel else { return }
        let sf = screen.frame
        let x = sf.midX - captionWidth / 2
        // AppKit origin is bottom-left; notch is at top of screen
        let y = sf.maxY - notchHeight - notchGap - captionHeight
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func _fadeOut() {
        state.isVisible = false
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in self.panel?.orderOut(nil) }
        })
    }
}

// MARK: - VoiceCaptionView

struct VoiceCaptionView: View {
    @ObservedObject var state: VoiceCaptionState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !state.userLine.isEmpty {
                Text(state.userLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !state.responseLine.isEmpty {
                Text(state.responseLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.88))
        )
        .frame(width: 360)
    }
}
#endif
