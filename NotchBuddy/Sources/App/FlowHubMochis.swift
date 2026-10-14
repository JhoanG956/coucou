#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Visible or not

private struct HubVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the Coucou window is on screen: the Mochis rest (no frame drawn) while it is hidden,
    /// minimized or covered.
    var hubVisible: Bool {
        get { self[HubVisibleKey.self] }
        set { self[HubVisibleKey.self] = newValue }
    }
}

/// Follows the Coucou window's occlusion, for `hubVisible`.
@MainActor
final class HubWindowState: ObservableObject {
    @Published private(set) var visible = true
    private var observers: [NSObjectProtocol] = []

    func watch(_ window: NSWindow) {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                          NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification,
                                          NSWindow.willCloseNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let closing = note.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let on = !closing && window.occlusionState.contains(.visible) && !window.isMiniaturized
                    if on != self.visible { self.visible = on }
                }
            }
        }
    }
}

// MARK: - A troupe of mini Mochis

/// One Mochi of a scene: its look, and whether it walks around.
struct HubMochiSpec: Hashable {
    var color: String
    /// The drawing's width in points (the body is about two thirds of it).
    var size: CGFloat
    var outfit: Outfit = .none
    var state: BotState = .idle
    /// Walks left and right, stops, looks around. Otherwise stays where it is.
    var roams = true
    /// Where it starts, from 0 (left of its area) to 1 (right).
    var start: CGFloat = 0.5
}

/// The Mochis of a scene, moved frame by frame.
@MainActor
final class HubMochiTroupe: ObservableObject {
    @MainActor final class Walker {
        let spec: HubMochiSpec
        let engine: BotEngine
        var x: CGFloat
        var target: CGFloat
        var speed: CGFloat = 0.06
        var restUntil: Double
        var hop: CGFloat = 0
        var lastHello: Double = 0

        init(spec: HubMochiSpec) {
            self.spec = spec
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(spec.color)
            if spec.outfit != .none { e.setOutfit(spec.outfit, animated: false) }
            if spec.state != .idle { e.setState(spec.state, force: true) }
            engine = e
            x = spec.start
            target = spec.start
            restUntil = CACurrentMediaTime() + Double.random(in: 0.5...3)
        }
    }

    private(set) var walkers: [Walker] = []
    private var last = CACurrentMediaTime()
    /// The part of the scene where they walk, from 0 to 1.
    var range: ClosedRange<CGFloat> = 0.05...0.95

    init(cast: [HubMochiSpec]) {
        walkers = cast.map { Walker(spec: $0) }
    }

    /// One frame: the walkers move, and stop now and then to do a little something.
    func step() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, max(0, now - last)))
        last = now
        for actor in walkers {
            MochiFrameClock.advance(actor.engine)
            guard actor.spec.roams else { continue }
            if now < actor.restUntil {
                actor.hop = max(0, actor.hop - dt * 4)
                continue
            }
            let distance = actor.target - actor.x
            if abs(distance) < 0.004 {
                arrive(actor, now: now)
                continue
            }
            let move = min(abs(distance), actor.speed * dt)
            actor.x += distance > 0 ? move : -move
            actor.hop += dt * 9
        }
    }

    private func arrive(_ actor: Walker, now: Double) {
        actor.hop = 0
        actor.restUntil = now + Double.random(in: 1.2...5)
        actor.target = CGFloat.random(in: range)
        actor.speed = CGFloat.random(in: 0.035...0.08)
        // A little something once there.
        switch Int.random(in: 0..<10) {
        case 0, 1: actor.engine.triggerEmote(.happy, silent: true)
        case 2:    actor.engine.triggerEmote(.wink, silent: true)
        case 3:    actor.engine.doRoll(duration: 900, turns: 1)
        default:   break
        }
        // Two Mochis meeting say hello.
        for other in walkers where other !== actor && abs(other.x - actor.x) < 0.09 && now - actor.lastHello > 12 {
            actor.lastHello = now
            other.lastHello = now
            actor.engine.triggerEmote(.love, silent: true)
            other.engine.triggerEmote(.happy, silent: true)
            break
        }
    }

    /// A click on a Mochi: it blushes and jumps.
    func poke(at point: CGPoint, in size: CGSize) {
        let hit = walkers.min { distance(point, $0, size) < distance(point, $1, size) }
        guard let hit, distance(point, hit, size) < hit.spec.size * 0.6 else { return }
        hit.engine.triggerEmote(.love, silent: true)
        hit.engine.squash()
        hit.restUntil = CACurrentMediaTime() + 2
    }

    private func distance(_ p: CGPoint, _ actor: Walker, _ size: CGSize) -> CGFloat {
        let center = CGPoint(x: xPosition(actor, width: size.width), y: size.height - actor.spec.size * 0.45)
        return hypot(p.x - center.x, p.y - center.y)
    }

    func xPosition(_ actor: Walker, width: CGFloat) -> CGFloat {
        let half = actor.spec.size / 2
        return half + actor.x * max(0, width - actor.spec.size)
    }

    func draw(_ context: inout GraphicsContext, size: CGSize) {
        // Back to front: the small ones behind.
        for actor in walkers.sorted(by: { $0.spec.size < $1.spec.size }) {
            let w = actor.spec.size
            let cx = xPosition(actor, width: size.width)
            let lift = actor.spec.roams ? abs(sin(actor.hop)) * w * 0.07 : 0
            // Its shadow on the floor (a scene, not a lone Mochi).
            if size.height > w * 1.05 || walkers.count > 1 {
                let shadow = CGRect(x: cx - w * 0.26, y: size.height - w * 0.12, width: w * 0.52, height: w * 0.09)
                context.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.28 - Double(lift / w))))
            }
            var c = context
            c.translateBy(x: cx - w / 2, y: size.height - w * 0.92 - lift)
            actor.engine.draw(context: c, size: CGSize(width: w, height: w))
        }
    }
}

/// A strip where a few mini Mochis live: drawn in one canvas, at the display's rate while the
/// window shows, still otherwise. Click one to say hello.
struct HubMochiScene: View {
    @StateObject private var troupe: HubMochiTroupe
    @Environment(\.hubVisible) private var visible

    init(cast: [HubMochiSpec], range: ClosedRange<CGFloat> = 0.05...0.95) {
        _troupe = StateObject(wrappedValue: {
            let t = HubMochiTroupe(cast: cast)
            t.range = range
            return t
        }())
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: !visible)) { timeline in
                let frame = timeline.date
                Canvas { context, size in
                    _ = frame
                    troupe.step()
                    troupe.draw(&context, size: size)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in troupe.poke(at: location, in: geo.size) }
        }
    }
}

/// One Mochi that stays where it is (the logo, the empty pages).
struct HubLiveMochi: View {
    var color = "#F5F6F8"
    /// Width of the body; the drawing around it is larger.
    var size: CGFloat = 28
    var state: BotState = .idle
    var outfit: Outfit = .none

    var body: some View {
        HubMochiScene(cast: [HubMochiSpec(color: color, size: size / 0.68, outfit: outfit, state: state, roams: false)])
            .frame(width: size / 0.68, height: size / 0.68)
            .frame(width: size, height: size * 0.75)
    }
}

// MARK: - The top of each page

/// A page's colour and its Mochis.
struct HubHeroTheme {
    var color: Color
    var cast: [HubMochiSpec]

    static func of(_ page: HubPage) -> HubHeroTheme {
        func m(_ color: String, _ size: CGFloat, _ start: CGFloat, outfit: Outfit = .none,
               state: BotState = .idle, roams: Bool = true) -> HubMochiSpec {
            HubMochiSpec(color: color, size: size, outfit: outfit, state: state, roams: roams, start: start)
        }
        switch page {
        case .dictation:
            return .init(color: Color(hex: "#FB923C"), cast: [m("#F5F6F8", 66, 0.2), m("#FB923C", 52, 0.65), m("#F472B6", 44, 0.95, outfit: .bow)])
        case .notes:
            return .init(color: Color(hex: "#3B9EFF"), cast: [m("#3B9EFF", 58, 0.1, outfit: .roundGlasses), m("#34D399", 50, 0.5), m("#A78BFA", 46, 0.9)])
        case .insights:
            return .init(color: Color(hex: "#34D399"), cast: [m("#F7B32B", 62, 0.3, outfit: .crown), m("#34D399", 48, 0.75), m("#F5F6F8", 40, 1)])
        case .dictionary:
            return .init(color: Color(hex: "#A78BFA"), cast: [m("#A78BFA", 60, 0.2, outfit: .roundGlasses), m("#F5F6F8", 48, 0.8, outfit: .beanie)])
        case .snippets:
            return .init(color: Color(hex: "#F7B32B"), cast: [m("#F7B32B", 56, 0.15, state: .working), m("#FB923C", 46, 0.6), m("#F5F6F8", 40, 0.95)])
        case .styles:
            return .init(color: Color(hex: "#F472B6"), cast: [m("#F472B6", 60, 0.25, outfit: .sunglasses), m("#F5F6F8", 48, 0.7, outfit: .bow), m("#22D3EE", 42, 1, outfit: .partyHat)])
        case .settings:
            return .init(color: Color(hex: "#8E939C"), cast: [m("#F5F6F8", 56, 0.3), m("#8E939C", 46, 0.95, state: .sleeping, roams: false)])
        case .general:
            return .init(color: Color(hex: "#8E939C"), cast: [m("#F5F6F8", 60, 0.4, outfit: .scarf), m("#FB923C", 46, 0.85)])
        case .pills:
            return .init(color: Color(hex: "#F5A524"), cast: [m("#F5A524", 44, 0.05), m("#3B9EFF", 44, 0.3), m("#34D399", 44, 0.55),
                                                               m("#E07950", 44, 0.8), m("#A78BFA", 44, 1)])
        case .agents:
            return .init(color: Color(hex: "#3B9EFF"), cast: [m("#3B9EFF", 56, 0.1, state: .working, roams: false),
                                                               m("#E07950", 50, 0.5, state: .thinking, roams: false),
                                                               m("#34D399", 50, 0.9)])
        case .chat:
            return .init(color: Color(hex: "#E07950"), cast: [m("#E07950", 58, 0.3, state: .thinking, roams: false), m("#F5F6F8", 48, 0.85)])
        case .integrations:
            return .init(color: Color(hex: "#7C5CFF"), cast: [m("#7C5CFF", 54, 0.15), m("#22D3EE", 46, 0.55), m("#F7B32B", 42, 0.95)])
        case .voice:
            return .init(color: Color(hex: "#F97316"), cast: [m("#F97316", 60, 0.3), m("#F5F6F8", 48, 0.85, outfit: .roundGlasses)])
        case .shortcuts:
            return .init(color: Color(hex: "#6366F1"), cast: [m("#6366F1", 56, 0.2, outfit: .sunglasses), m("#F5F6F8", 46, 0.8)])
        }
    }
}

/// The top of a page: a coloured band with the title, a line, an action, and the page's Mochis
/// walking on its floor.
struct HubHero<Trailing: View>: View {
    let page: HubPage
    let title: String
    var subtitle: String?
    var compact = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let theme = HubHeroTheme.of(page)
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [theme.color.opacity(0.20), theme.color.opacity(0.05), Color.white.opacity(0.015)],
                                     startPoint: .topTrailing, endPoint: .bottomLeading))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(RadialGradient(colors: [theme.color.opacity(0.28), .clear], center: .topTrailing,
                                     startRadius: 0, endRadius: 320))
            HubSparkles(color: theme.color)
                .allowsHitTesting(false)
            HubMochiScene(cast: theme.cast, range: 0...1)
                .id(page)
                .frame(width: compact ? 280 : 340, height: compact ? 92 : 128)
                .padding(.trailing, 18)
                .padding(.bottom, 6)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: compact ? 24 : 30, weight: .bold))
                        .tracking(-0.6)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#B7BBC2"))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 420, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    trailing()
                }
                .padding(compact ? 20 : 26)
                Spacer(minLength: compact ? 290 : 350)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: compact ? 116 : 170)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.color.opacity(0.22)))
    }
}

extension HubHero where Trailing == EmptyView {
    init(page: HubPage, title: String, subtitle: String? = nil, compact: Bool = false) {
        self.page = page
        self.title = title
        self.subtitle = subtitle
        self.compact = compact
        self.trailing = { EmptyView() }
    }
}

/// A few still sparkles in the band's colour.
private struct HubSparkles: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var rng = SeededRandom(seed: 7)
            for _ in 0..<26 {
                let x = rng.next() * size.width
                let y = rng.next() * size.height
                let r = 0.6 + rng.next() * 1.6
                let alpha = 0.10 + rng.next() * 0.35
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                             with: .color(color.opacity(alpha)))
            }
        }
    }
}

/// Always the same sparkles, so they do not move when the page redraws.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }
}

/// An empty page: a Mochi asleep, and a line.
struct HubEmptyState: View {
    let text: String
    var state: BotState = .sleeping
    var color = "#F5F6F8"

    var body: some View {
        VStack(spacing: 10) {
            HubLiveMochi(color: color, size: 54, state: state)
                .frame(height: 54)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundColor(HubTheme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}
#endif
