#if !APPSTORE
import AVFoundation
import Speech

// MARK: - VoiceSettings

/// Persisted voice feature settings and permission helpers.
enum VoiceSettings {
    static let enabledKey      = "voiceEnabled"
    static let speakEnabledKey = "voiceSpeakEnabled"
    static let captionEnabledKey = "voiceCaptionEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Coucou responds aloud after each command. Default: on.
    static var speakEnabled: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: speakEnabledKey) == nil { return true }   // default on
            return d.bool(forKey: speakEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: speakEnabledKey) }
    }

    /// Show caption capsule below notch during voice. Default: on.
    static var captionEnabled: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: captionEnabledKey) == nil { return true }  // default on
            return d.bool(forKey: captionEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: captionEnabledKey) }
    }

    /// Language Coucou listens and answers in: "en" (default) or "fr".
    static var language: String {
        get { UserDefaults.standard.string(forKey: "voiceLanguage") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceLanguage") }
    }

    /// Voice used to answer: "system" (macOS voices) or "elevenlabs" (user's API key).
    static var ttsEngine: String {
        get { UserDefaults.standard.string(forKey: "voiceTTSEngine") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceTTSEngine") }
    }
    /// ElevenLabs voice: "female" (default) or "male".
    static var elevenGender: String {
        get { UserDefaults.standard.string(forKey: "voiceElevenGender") ?? "female" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceElevenGender") }
    }

    /// Weather by voice (Open-Meteo, no key). Off by default: network only when the user
    /// turned it on and set a city.
    static var weatherEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceWeatherEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceWeatherEnabled") }
    }
    static var weatherCity: String {
        get { UserDefaults.standard.string(forKey: "voiceWeatherCity") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceWeatherCity") }
    }

    // MARK: - Permissions

    enum PermissionStatus { case granted, denied, undetermined }

    static var micStatus: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:              return .granted
        case .denied, .restricted:     return .denied
        case .notDetermined:           return .undetermined
        @unknown default:              return .undetermined
        }
    }

    static var speechStatus: PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:              return .granted
        case .denied, .restricted:     return .denied
        case .notDetermined:           return .undetermined
        @unknown default:              return .undetermined
        }
    }

    /// Request microphone then speech recognition. Returns true if both granted.
    @MainActor
    static func requestPermissions() async -> Bool {
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { return false }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}
#endif
