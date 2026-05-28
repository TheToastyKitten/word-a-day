import AVFoundation
import Foundation

/// On-device Russian TTS for dictionary headwords. Retains `AVSpeechSynthesizer` and
/// keeps UI state on the main actor.
@MainActor
final class RussianHeadwordSpeaker: NSObject, ObservableObject {
    @Published private(set) var isSpeaking: Bool = false
    /// Short description for accessibility (voice name + BCP-47 tag, or status text).
    @Published private(set) var voiceSummary: String = ""

    private let synthesizer = AVSpeechSynthesizer()
    private var activeNormalizedText: String?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Text passed to the engine: trimmed, whitespace collapsed, dash variants normalized.
    static func normalizedSpeechText(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let nbspToSpace = trimmed.replacingOccurrences(of: "\u{00A0}", with: " ")
        let dashNormalized = nbspToSpace
            .replacingOccurrences(of: "‑", with: " ")
            .replacingOccurrences(of: "–", with: " ")
            .replacingOccurrences(of: "—", with: " ")
        let parts = dashNormalized.split(whereSeparator: { $0.isWhitespace })
        return parts.map(String.init).joined(separator: " ")
    }

    static func preferredRussianVoice() -> AVSpeechSynthesisVoice? {
        let ru = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ru") }
        guard !ru.isEmpty else {
            return AVSpeechSynthesisVoice(language: "ru-RU")
        }
        return ru.max { qualityRank($0) < qualityRank($1) }
    }

    private static func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        case .default: return 1
        @unknown default: return 0
        }
    }

    /// If `true`, at least one Russian voice is listed for this device.
    static var hasListedRussianVoice: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { $0.language.hasPrefix("ru") }
    }

    /// **(0, 1]** → linear blend from minimum speech rate to `AVSpeechUtteranceDefaultSpeechRate`. Caller must skip at **≤ 0** (muted).
    static func utteranceRate(forUserScale scale: Float) -> Float {
        let s = min(1.0, max(Double(scale), Double.leastNonzeroMagnitude))
        let minR = Float(AVSpeechUtteranceMinimumSpeechRate)
        let defaultR = Float(AVSpeechUtteranceDefaultSpeechRate)
        return minR + Float(s) * (defaultR - minR)
    }

    func isSpeaking(text: String) -> Bool {
        guard isSpeaking else { return false }
        return activeNormalizedText == Self.normalizedSpeechText(from: text)
    }

    func toggleSpeaking(russianLemma: String, rateScale: Float) {
        let text = Self.normalizedSpeechText(from: russianLemma)
        guard !text.isEmpty else { return }

        if synthesizer.isSpeaking, activeNormalizedText == text {
            stopImmediately()
            return
        }

        haltEngineUtterance()

        guard rateScale > 0 else {
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Self.utteranceRate(forUserScale: rateScale)

        if let voice = Self.preferredRussianVoice() {
            utterance.voice = voice
            voiceSummary = "\(voice.name), \(voice.language)"
        } else if let fallback = AVSpeechSynthesisVoice(language: "ru-RU") {
            utterance.voice = fallback
            voiceSummary = "\(fallback.name), \(fallback.language)"
        } else {
            voiceSummary = "Russian voice unavailable; add Russian under Settings → Accessibility → Read & Speak or VoiceOver → Speech → Voices"
        }

        Self.activatePlaybackSessionForSpeech()

        utterance.volume = 1

        activeNormalizedText = text
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Stops speech and clears published UI helpers (e.g. when leaving the screen).
    func stopImmediately() {
        haltEngineUtterance()
        voiceSummary = ""
    }

    private func haltEngineUtterance() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        activeNormalizedText = nil
        Self.deactivatePlaybackSessionAfterSpeechIdle(synthesizer: synthesizer)
    }

    /// Real devices typically need an explicit playback session before `AVSpeechUtterance` is audible (Simulator often “just works”).
    private static func activatePlaybackSessionForSpeech() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try? session.setActive(true)
        }
    }

    private static func deactivatePlaybackSessionAfterSpeechIdle(synthesizer: AVSpeechSynthesizer) {
        guard !synthesizer.isSpeaking else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

extension RussianHeadwordSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synth: AVSpeechSynthesizer,
        didFinish _: AVSpeechUtterance
    ) {
        Task { @MainActor in
            isSpeaking = false
            activeNormalizedText = nil
            Self.deactivatePlaybackSessionAfterSpeechIdle(synthesizer: synth)
        }
    }

    nonisolated func speechSynthesizer(
        _ synth: AVSpeechSynthesizer,
        didCancel _: AVSpeechUtterance
    ) {
        Task { @MainActor in
            isSpeaking = false
            activeNormalizedText = nil
            Self.deactivatePlaybackSessionAfterSpeechIdle(synthesizer: synth)
        }
    }
}
