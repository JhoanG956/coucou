#if !APPSTORE
import Foundation
import AppKit
import Combine

// MARK: - Music Controller

/// Observes Apple Music state via distributed notifications and provides playback controls.
/// Singleton, @MainActor, GitHub build only.
/// Nothing runs on a timer: state arrives with Music's notification, the card extrapolates the position.
@MainActor
final class MusicController: ObservableObject {
    static let shared = MusicController()
    nonisolated static let bundleId = "com.apple.Music"

    enum RepeatMode: String, Sendable { case off, all, one }

    @Published var trackTitle: String?
    @Published var artist: String?
    @Published var album: String?
    @Published private(set) var duration: Double = 0
    /// Position (seconds) at `positionDate`; while playing, the real position runs on from there.
    @Published private(set) var positionAnchor: Double = 0
    @Published private(set) var positionDate = Date()
    @Published private(set) var shuffling = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var volume: Int = 50
    /// nil when Music can't favorite this track (radio, some streams).
    @Published private(set) var favorited: Bool?
    @Published private(set) var artwork: NSImage?

    nonisolated private static let grantedKey = "coucou.musicAutomationGranted"

    private var notifTokens: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.music")
    private var artworkCache: [String: NSImage] = [:]
    private var artworkCacheOrder: [String] = []
    private var artworkLoadingKey: String?
    private var pendingVolume: Int?
    private var volumeTask: Task<Void, Never>?

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains("integration_music")
    }

    private var automationGranted: Bool {
        UserDefaults.standard.bool(forKey: Self.grantedKey)
    }

    /// Same track = same title, artist and album (the notification and AppleScript IDs differ in format).
    private var trackKey: String? {
        guard let trackTitle else { return nil }
        return [trackTitle, artist ?? "", album ?? ""].joined(separator: "\u{1F}")
    }

    /// Where playback is now, extrapolated from the last anchor.
    func position(at date: Date) -> Double {
        let elapsed = AppState.shared.musicPlaying ? date.timeIntervalSince(positionDate) : 0
        let p = positionAnchor + max(0, elapsed)
        return duration > 0 ? min(p, duration) : p
    }

    private init() {
        // playerInfo fires whenever Music state changes (play/pause/track change).
        // Extract Sendable values before crossing into @MainActor.
        let tok1 = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let info        = notif.userInfo
            let playerState = info?["Player State"] as? String
            let name        = info?["Name"]          as? String
            let artist      = info?["Artist"]        as? String
            let album       = info?["Album"]         as? String
            let totalTimeMs = (info?["Total Time"]   as? NSNumber)?.doubleValue
            Task { @MainActor [weak self] in
                self?.handlePlayerInfo(playerState: playerState, name: name, artist: artist,
                                       album: album, totalTimeMs: totalTimeMs)
            }
        }
        notifTokens.append(tok1)

        // Track Music launch — read current state only if granted and pill active
        let tok2 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard bundleId == MusicController.bundleId else { return }
            Task { @MainActor [weak self] in
                guard let self, self.automationGranted else { return }
                self.refresh()
            }
        }
        notifTokens.append(tok2)

        // Clear state when Music quits
        let tok3 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard bundleId == MusicController.bundleId else { return }
            Task { @MainActor [weak self] in self?.clearState() }
        }
        notifTokens.append(tok3)

        // Observe activeIntegrations — pill activated → initial read; deactivated → clear
        AppState.shared.$activeIntegrations
            .sink { [weak self] integrations in
                guard let self else { return }
                if integrations.contains("integration_music") {
                    if self.automationGranted {
                        // The publisher fires before the property is set: read once it is
                        Task { @MainActor [weak self] in self?.refresh() }
                    }
                } else {
                    self.clearState()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Private helpers

    private func isMusicRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleId }
    }

    // MARK: - Metadata cleaners

    private static func shortTitle(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw
        // Cut at first " - "
        if let r = s.range(of: " - ") {
            s = String(s[..<r.lowerBound])
        }
        // Strip trailing (...) or [...] groups repeatedly
        var changed = true
        while changed {
            changed = false
            let t = s.trimmingCharacters(in: .whitespaces)
            guard let last = t.last, (last == ")" || last == "]") else { break }
            let open: Character = last == ")" ? "(" : "["
            if let idx = t.lastIndex(of: open) {
                let candidate = String(t[..<idx]).trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty { s = candidate; changed = true }
            } else { break }
        }
        let result = s.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? raw : result
    }

    private static func shortArtist(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let lower = raw.lowercased()
        for tag in [" feat.", " ft."] {
            if let r = lower.range(of: tag) {
                let result = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                return result.isEmpty ? raw : result
            }
        }
        return raw
    }

    // MARK: - State

    private func handlePlayerInfo(playerState: String?, name: String?, artist inputArtist: String?,
                                  album inputAlbum: String?, totalTimeMs: Double?) {
        guard isPillActive else { return }
        if playerState == "Stopped" { clearState(); return }

        if let name {
            setTrack(title: name, artist: inputArtist ?? "", album: inputAlbum ?? "",
                     duration: (totalTimeMs ?? 0) / 1000)
        }
        setPlaying(playerState == "Playing")

        // The notification carries no position, shuffle, repeat, volume or artwork: read them
        // when we may, otherwise look the cover up in Apple's public catalog.
        if automationGranted {
            refresh()
        } else if artwork == nil {
            loadArtwork(localData: nil)
        }
    }

    private func setTrack(title: String, artist inputArtist: String, album inputAlbum: String, duration: Double) {
        let oldKey = trackKey
        trackTitle = Self.shortTitle(title).nilIfEmpty
        artist     = Self.shortArtist(inputArtist).nilIfEmpty
        album      = inputAlbum.nilIfEmpty
        if duration > 0 { self.duration = duration }
        if trackKey != oldKey {
            artwork = trackKey.flatMap { artworkCache[$0] }
            favorited = nil
        }
        syncTaskName()
    }

    private func setPlaying(_ playing: Bool) {
        let wasPlaying = AppState.shared.musicPlaying
        if playing != wasPlaying {
            // Freeze or restart the clock at the current position
            anchor(position(at: Date()))
        }
        AppState.shared.musicPlaying = playing
        // Reveal only on transition from not-playing → playing
        if playing && !wasPlaying {
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    private func anchor(_ position: Double) {
        positionAnchor = max(0, position)
        positionDate = Date()
    }

    private func clearState() {
        trackTitle = nil; artist = nil; album = nil
        duration = 0
        artwork = nil
        favorited = nil
        anchor(0)
        AppState.shared.musicPlaying = false
        syncTaskName()
    }

    private func syncTaskName() {
        guard let idx = AppState.shared.tasks.firstIndex(where: { $0.id == "integration_music" }) else { return }
        let title = trackTitle ?? ""
        AppState.shared.tasks[idx].name = title.isEmpty
            ? (PillCatalog.definition(for: "integration_music")?.name ?? "Apple Music")
            : title
    }

    // MARK: - Reading Music

    /// Reads track, position, shuffle, repeat, volume and favorite. Never launches Music.
    /// The first call is what makes macOS ask for Automation.
    func refresh() {
        guard isPillActive, isMusicRunning() else { return }
        Task {
            let result = await runAppleScript("""
                tell application id "com.apple.Music"
                    set ps to player state as string
                    if ps is "stopped" then return {ps}
                    try
                        set tr to current track
                        set n to name of tr
                    on error
                        return {"stopped"}
                    end try
                    set ar to ""
                    set al to ""
                    set du to 0
                    set pp to 0
                    set fv to "unknown"
                    try
                        set ar to artist of tr
                    end try
                    try
                        set al to album of tr
                    end try
                    try
                        set du to duration of tr
                    end try
                    try
                        set pp to player position
                    end try
                    try
                        set fv to favorited of tr as string
                    end try
                    return {ps, n, ar, al, du, pp, shuffle enabled, song repeat as string, sound volume, fv}
                end tell
            """)
            guard case .success(let v) = result, let ps = v.first?.text else { return }
            guard isPillActive else { return }
            if ps == "stopped" || v.count < 10 { clearState(); return }

            let oldKey = trackKey
            setTrack(title: v[1].text, artist: v[2].text, album: v[3].text, duration: v[4].number)
            anchor(v[5].number)
            setPlaying(ps == "playing")
            shuffling  = v[6].flag
            repeatMode = RepeatMode(rawValue: v[7].text) ?? .off
            if pendingVolume == nil { volume = Int(v[8].number.rounded()) }
            favorited  = v[9].text == "true" ? true : v[9].text == "false" ? false : nil
            if artwork == nil || trackKey != oldKey { fetchArtwork() }
        }
    }

    // MARK: - Artwork

    /// The cover Music has for the track; streamed tracks without one fall back to Apple's catalog.
    private func fetchArtwork() {
        guard let key = trackKey, artworkCache[key] == nil, artworkLoadingKey != key else {
            if let key = trackKey, let cached = artworkCache[key] { artwork = cached }
            return
        }
        Task {
            let result = await runAppleScript("""
                tell application id "com.apple.Music"
                    try
                        return raw data of artwork 1 of current track
                    on error
                        return ""
                    end try
                end tell
            """)
            guard trackKey == key else { return }
            if case .success(let v) = result, let data = v.first?.data {
                loadArtwork(localData: data)
            } else {
                loadArtwork(localData: nil)
            }
        }
    }

    private func loadArtwork(localData: Data?) {
        guard let key = trackKey else { return }
        if let cached = artworkCache[key] { artwork = cached; return }
        if let localData, let image = NSImage(data: localData) {
            cacheArtwork(image, for: key)
            artwork = image
            return
        }
        guard artworkLoadingKey != key else { return }
        artworkLoadingKey = key
        let term = [artist, album ?? trackTitle].compactMap { $0 }.joined(separator: " ")
        Task {
            defer { if artworkLoadingKey == key { artworkLoadingKey = nil } }
            guard let url = await Self.catalogArtworkURL(term: term),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { return }
            cacheArtwork(image, for: key)
            if trackKey == key { artwork = image }
        }
    }

    private func cacheArtwork(_ image: NSImage, for key: String) {
        artworkCache[key] = image
        artworkCacheOrder.removeAll { $0 == key }
        artworkCacheOrder.append(key)
        while artworkCacheOrder.count > 12 {
            artworkCache[artworkCacheOrder.removeFirst()] = nil
        }
    }

    /// Apple's public iTunes Search API: no account, just "artist album".
    nonisolated private static func catalogArtworkURL(term: String) async -> URL? {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let small = first["artworkUrl100"] as? String,
              // Only Apple's image CDN: the URL comes from a web response
              let art = safeWebURL(small.replacingOccurrences(of: "100x100bb", with: "300x300bb")),
              art.scheme == "https",
              art.host?.lowercased().hasSuffix(".mzstatic.com") == true else { return nil }
        return art
    }

    // MARK: - Playback controls

    func playPause() {
        guard isMusicRunning() else { return }
        setPlaying(!AppState.shared.musicPlaying)   // optimistic; Music's notification confirms
        command("playpause")
    }

    func nextTrack() {
        guard isMusicRunning() else { return }
        command("next track")
    }

    func previousTrack() {
        guard isMusicRunning() else { return }
        command("back track")
    }

    func seek(to seconds: Double) {
        guard isMusicRunning(), duration > 0 else { return }
        let target = min(max(0, seconds), max(0, duration - 1))
        anchor(target)
        command("set player position to \(Int(target.rounded()))", refreshAfter: false)
    }

    func setShuffling(_ on: Bool) {
        guard isMusicRunning() else { return }
        shuffling = on
        command("set shuffle enabled to \(on)", refreshAfter: false)
    }

    /// off → all → one → off, like the Music app.
    func cycleRepeat() {
        guard isMusicRunning() else { return }
        let next: RepeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off
        repeatMode = next
        command("set song repeat to \(next.rawValue)", refreshAfter: false)
    }

    func toggleFavorite() {
        guard isMusicRunning(), let current = favorited else { return }
        favorited = !current
        Task {
            let result = await runAppleScript(
                #"tell application id "com.apple.Music" to set favorited of current track to \#(!current)"#)
            // Some tracks can't be favorited: put the heart back
            if case .success = result {} else { favorited = current }
        }
    }

    /// Coalesced: a slider drag sends at most one Apple Event every 120 ms.
    func setVolume(_ value: Int) {
        guard isMusicRunning() else { return }
        let v = min(100, max(0, value))
        volume = v
        pendingVolume = v
        guard volumeTask == nil else { return }
        volumeTask = Task {
            while let v = pendingVolume {
                pendingVolume = nil
                await runAppleScript(#"tell application id "com.apple.Music" to set sound volume to \#(v)"#)
                try? await Task.sleep(for: .milliseconds(120))
            }
            volumeTask = nil
        }
    }

    private func command(_ verb: String, refreshAfter: Bool = true) {
        Task {
            let result = await runAppleScript(#"tell application id "com.apple.Music" to \#(verb)"#)
            guard refreshAfter, case .success = result else { return }
            // Let Music settle on the new track before reading it back
            try? await Task.sleep(for: .milliseconds(350))
            refresh()
        }
    }

    func openMusic() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.bundleId }) {
            app.activate()
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - AppleScript runner

    /// One item of an AppleScript result, read the ways callers may expect it.
    struct ScriptValue: Sendable {
        let text: String
        let number: Double
        let flag: Bool
        let data: Data?
    }

    enum ScriptResult: Sendable { case success([ScriptValue]), denied, error }

    @discardableResult
    private func runAppleScript(_ source: String) async -> ScriptResult {
        let grantedKey = Self.grantedKey
        let result: ScriptResult = await withCheckedContinuation { cont in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    cont.resume(returning: .error); return
                }
                var errDict: NSDictionary?
                let desc = script.executeAndReturnError(&errDict)
                if let errDict {
                    let code = (errDict[NSAppleScript.errorNumber] as? Int) ?? 0
                    cont.resume(returning: code == -1743 ? .denied : .error)
                    return
                }
                // Extract values on this queue (NSAppleEventDescriptor isn't Sendable)
                func value(_ d: NSAppleEventDescriptor?) -> ScriptValue {
                    let text = d?.stringValue ?? ""
                    // Only binary results (artwork) carry data; text comes back through `text`
                    let binary = d.map { $0.stringValue == nil && !$0.data.isEmpty } ?? false
                    return ScriptValue(text: text, number: d?.doubleValue ?? 0,
                                       flag: d?.booleanValue ?? false, data: binary ? d?.data : nil)
                }
                let count = desc.numberOfItems
                let values = count > 0 ? (1...count).map { value(desc.atIndex($0)) } : [value(desc)]
                cont.resume(returning: .success(values))
            }
        }
        switch result {
        case .success:
            UserDefaults.standard.set(true, forKey: grantedKey)
            AppState.shared.musicAutomationDenied = false
        case .denied:
            UserDefaults.standard.set(false, forKey: grantedKey)
            AppState.shared.musicAutomationDenied = true
        case .error:
            break
        }
        return result
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
