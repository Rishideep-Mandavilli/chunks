import Foundation

/// Choosing which voice Chunks speaks with, as pure logic over a list of descriptors.
///
/// Two facts about `AVSpeechSynthesisVoice` make this worth a type of its own. It has no gender,
/// so "a young female voice" can only be answered by a name list a person can read and correct.
/// And on the neural premium voices the API's own `name` is literally "Voice 1" and "Voice 2" —
/// measured on this machine, where the two best voices it has are
/// `com.apple.ttsbundle.gryphon-neural_Riya_en-IN_premium` and
/// `com.apple.ttsbundle.gryphon-neural_Simone_en-US_premium`. Anything that ranks by `name`
/// therefore ranks the good ones last, which is how a spoken answer ends up sounding like a
/// satnav from 2012 while the machine is holding a neural voice it never uses.
public enum SpeechVoices {

    public struct Voice: Equatable, Sendable {
        public var identifier: String
        public var name: String
        public var language: String
        /// 0 default, 1 enhanced, 2 premium — the order `AVSpeechSynthesisVoiceQuality` uses.
        public var quality: Int

        public init(identifier: String, name: String, language: String, quality: Int) {
            self.identifier = identifier
            self.name = name
            self.language = language
            self.quality = quality
        }
    }

    /// Female English voices, nicest first. Matched inside the *identifier*, because `name` is a
    /// placeholder exactly on the voices at the top of this list.
    ///
    /// Order is a taste judgement the user can overrule, so it is one list rather than a score:
    /// Indian and American English first because they are the accents he hears all day, and the
    /// strong-regional and character voices (Moira, Karen, Tessa, Zarvox) late — an Irish compact
    /// voice outranking a plain American one is how "make it sweeter" went wrong once already.
    public static let preferredEnglish: [String] = [
        "Riya", "Simone", "Ava", "Zoe", "Nicky", "Serena", "Sara", "Tara", "Allison", "Nora",
        "Samantha", "Alexandra", "Fiona", "Victoria", "Tessa", "Karen", "Moira",
    ]

    /// English voices, best-sounding first: quality before name, because a premium voice that is
    /// not on the list still beats a compact one that is.
    public static func ranked(_ voices: [Voice], language: String = "en") -> [Voice] {
        voices.filter { $0.language.hasPrefix(language) }.sorted { left, right in
            if left.quality != right.quality { return left.quality > right.quality }
            let preference = preferredIndex(left) - preferredIndex(right)
            if preference != 0 { return preference < 0 }
            let byName = displayName(for: left).localizedCaseInsensitiveCompare(
                displayName(for: right))
            if byName != .orderedSame { return byName == .orderedAscending }
            // Two entries for the same person — `compact.en-IE.Moira` and
            // `super-compact.en-IE.Moira` both exist on this Mac — tie on everything the user can
            // see, and without this last comparison the choice flips between two turns of the same
            // conversation, which sounds like the app getting worse.
            return left.identifier < right.identifier
        }
    }

    static func preferredIndex(_ voice: Voice) -> Int {
        preferredEnglish.firstIndex(where: { voice.identifier.contains($0) })
            ?? preferredEnglish.count + 1
    }

    /// The name to show the user: the human name out of the identifier when the API's own `name`
    /// is "Voice 1".
    public static func displayName(for voice: Voice) -> String {
        let name = voice.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && !name.lowercased().hasPrefix("voice ") { return name }
        if let match = preferredEnglish.first(where: { voice.identifier.contains($0) }) {
            return match
        }
        // `com.apple.ttsbundle.gryphon-neural_Simone_en-US_premium` → "Simone".
        for piece in voice.identifier.split(separator: "_") where piece.contains(where: { $0.isUppercase }) {
            let candidate = piece.replacingOccurrences(of: "-", with: " ")
            if candidate.count >= 3, !candidate.lowercased().hasPrefix("en") { return candidate }
        }
        return name.isEmpty ? voice.identifier : name
    }

    /// The voice to speak with, given what the machine has and what the user last chose.
    ///
    /// A stored identifier that has stopped existing is not an error worth showing: the user
    /// deleted a voice in System Settings, and the answer is the best remaining one, not silence.
    public static func pick(from voices: [Voice], storedIdentifier: String? = nil,
                            language: String = "en") -> Voice? {
        let candidates = ranked(voices, language: language)
        if let storedIdentifier,
           let stored = candidates.first(where: { $0.identifier == storedIdentifier }) {
            return stored
        }
        return candidates.first
    }
}
