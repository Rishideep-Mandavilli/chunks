import Foundation

/// Which speech engine a dictation should run on.
///
/// Lives here rather than in the shell because the *decision* is logic and the engines are not:
/// `SpeechAnalyzer` is macOS 26+, `SFSpeechRecognizer` is everything since 15.2, and the rule for
/// choosing between them has to be testable without a microphone, a signed bundle, or a Mac
/// running one specific system version.
///
/// The fallback always lands on the engine that exists, never on silence — the same principle as
/// never sending an image to a model that cannot see images.
public enum SpeechEngineChoice: String, Equatable, CaseIterable {
    case legacyRecognizer
    case analyzerDictation
    case analyzerTranscription

    /// The shipping default: Apple's on-device dictation model.
    ///
    /// Measured on the user's own voice through `--probe-stt` on 2026-10-09, one 125-buffer
    /// recording into three engines. Dictation heard his show's name as "Star Mahila" where the
    /// recogniser heard "Star Mahina", at the same 1.75s to first partial; the general
    /// transcription model added a "Hi" he never said and was slower, so it is not the default.
    /// How close the two winners were elsewhere is the honest caveat: they appear to share a
    /// model, so this switch buys proper nouns, not a new level of accuracy.
    public static let defaultChoice: SpeechEngineChoice = .analyzerDictation

    /// The engine a preference string asks for, ignoring whether this Mac can run it.
    ///
    /// Split out because "did the user ask for something unavailable" is a different question
    /// from "what should run", and conflating them is how a fallback ends up silent.
    public static func requested(preference: String?) -> SpeechEngineChoice? {
        guard let raw = preference?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "dictation", "analyzer", "speechanalyzer", "analyzerdictation": return .analyzerDictation
        case "transcription", "transcribe", "analyzertranscription": return .analyzerTranscription
        case "legacy", "sfspeech", "legacyrecognizer": return .legacyRecognizer
        default: return nil
        }
    }

    /// Map the stored preference onto an engine this machine can actually run.
    ///
    /// A value that is empty, unrecognised, or names an unavailable engine resolves to legacy:
    /// the switch is a debugging surface, and a typo in it must not cost the user dictation.
    public static func resolve(preference: String?, analyzerAvailable: Bool) -> SpeechEngineChoice {
        let wanted = requested(preference: preference) ?? defaultChoice
        if wanted == .legacyRecognizer { return .legacyRecognizer }
        return analyzerAvailable ? wanted : .legacyRecognizer
    }

    /// What to say when the preference asked for an engine this machine does not have.
    public static func degradationNotice(preference: String?, analyzerAvailable: Bool) -> String? {
        guard let requested = requested(preference: preference),
              requested != .legacyRecognizer,
              !analyzerAvailable else { return nil }
        return "you asked for the newer speech engine, but this macOS does not have it — "
            + "still using the older recogniser."
    }
}
