import Foundation

/// The turn state the face reacts to, as a pure value so the mood mapping is testable without AppKit.
/// The shell maps its `NotchHUDModel.Phase`/`Stage` onto this; nothing here knows about windows.
public enum PresenceState: String, CaseIterable, Sendable {
    case idle, listening, transcribing, thinking, answering, acting, waiting, answered, failed, speaking
}

/// One of the notch face's moods (3.6 / plan P10). A mood is a pair of eyes and a mouth plus a tint
/// and an optional earcon — never a desktop pet, never a window of its own; it lives only in the notch.
public enum NotchMood: String, CaseIterable, Sendable {
    case calm        // idle, resting but awake
    case asleep      // long idle / hidden
    case attentive   // microphone open
    case curious     // reading the transcript back
    case pondering   // waiting on the model
    case focused     // doing an act
    case patient     // waiting for the user to answer a card
    case happy       // answered
    case sad         // failed
    case talking     // speaking / streaming

    /// The mood for a turn state. Pure and total: every state has exactly one mood.
    public static func mood(for state: PresenceState) -> NotchMood {
        switch state {
        case .idle: return .calm
        case .listening: return .attentive
        case .transcribing: return .curious
        case .thinking: return .pondering
        case .answering, .speaking: return .talking
        case .acting: return .focused
        case .waiting: return .patient
        case .answered: return .happy
        case .failed: return .sad
        }
    }

    /// A semantic tint name the view resolves against the design system (never a raw colour here).
    public var tintName: String {
        switch self {
        case .happy: return "success"
        case .sad: return "destructive"
        case .patient: return "warning"
        case .attentive, .curious, .pondering, .focused, .talking: return "accent"
        case .calm, .asleep: return "ink"
        }
    }

    /// A subtle system earcon for the transitions worth hearing; nil for the quiet moods.
    /// The names are macOS built-in sounds, so nothing is bundled or fetched.
    public var earcon: String? {
        switch self {
        case .attentive: return "Tink"
        case .happy: return "Glass"
        case .sad: return "Basso"
        case .patient: return "Pop"
        default: return nil
        }
    }

    /// Whether the eyes are closed (asleep) — the view draws a line instead of a dot.
    public var eyesClosed: Bool { self == .asleep }
}

/// The owner-editable persona (3.6). `IDENTITY.md` holds the name, `SOUL.md` the tone; both live beside
/// memory.md and are plain markdown the user can edit. Parsing is pure; the shell supplies the text.
public struct PresenceIdentity: Equatable, Sendable {
    public let name: String
    public let persona: String

    public static let defaultName = "Chunks"
    public static let defaultPersona = "a calm, concise companion who explains the screen and helps act on it"

    public init(name: String, persona: String) {
        self.name = name
        self.persona = persona
    }

    /// Read the name from IDENTITY.md (first non-empty, non-heading line) and the persona from SOUL.md
    /// (the whole trimmed body, capped). Empty or missing files fall back to the defaults, so a deleted
    /// file never silences the companion.
    public static func parse(identity: String?, soul: String?) -> PresenceIdentity {
        let name = firstLine(identity) ?? defaultName
        let persona = (soul ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return PresenceIdentity(
            name: String(name.prefix(40)),
            persona: persona.isEmpty ? defaultPersona : String(persona.prefix(400)))
    }

    static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            return t
        }
        return nil
    }

    /// The one line injected into the prompt so the model answers in the owner's chosen persona.
    public var promptLine: String {
        "your name is \(self.name); be \(persona)."
    }
}