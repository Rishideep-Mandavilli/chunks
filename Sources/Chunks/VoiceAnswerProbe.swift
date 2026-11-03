import ChunksKit
import Foundation

/// `--probe-voice-answer "yes"` — read-only: what a spoken sentence would do to the open card.
///
/// Nothing here answers anything. It prints the verdict for one utterance, or for a fixed table of them
/// when no argument is given, and the table doubles as the gate's fixture: the case that would matter on
/// his machine is a **false yes** — a sentence that is really a new question being read as consent — and
/// that is only catchable by a check that asserts what must *not* be an answer. A unit test can assert it
/// too, and does; this is the version that runs against the installed bundle, so a wording change in the
/// shipped app is caught by the shipped app.
enum VoiceAnswerProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-voice-answer") }

    /// The utterances the gate walks. Chosen to be the shapes real transcripts arrive in — a curly
    /// apostrophe, a trailing full stop, a question that starts with "yes" and is not an answer.
    static let fixtures: [(text: String, expected: String)] = [
        ("yes", "allow"),
        ("Yes.", "allow"),
        ("go ahead", "allow"),
        ("do it", "allow"),
        ("no", "deny"),
        ("not now", "deny"),
        ("Don’t do it.", "deny"),
        ("cancel", "deny"),
        ("yes and close the other tab", "not an answer"),
        ("what is this", "not an answer"),
        ("no wait open chrome", "not an answer"),
        ("maybe later", "not an answer"),
        ("", "not an answer"),
    ]

    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let asked = argumentAfterFlag("--probe-voice-answer")
        var failures = 0

        if let asked {
            print("voice: \"\(asked)\" → \(describe(VoiceAnswer.decide(asked)))")
            print("voice: nothing was answered, and no act was allowed")
            exit(0)
        }

        print("voice: \(fixtures.count) utterance(s), read-only — the card is not open here")
        for fixture in fixtures {
            let verdict = describe(VoiceAnswer.decide(fixture.text))
            let mark = verdict == fixture.expected ? "ok  " : "FAIL"
            print("  \(mark) \"\(fixture.text)\" → \(verdict)"
                  + (verdict == fixture.expected ? "" : " (expected \(fixture.expected))"))
            if verdict != fixture.expected { failures += 1 }
            // The invariant the whole feature rests on, checked on every phrase rather than once:
            // no utterance may reach the standing permission by voice.
            if VoiceAnswer.outcome(for: fixture.text) == .alwaysAllowed {
                print("  FAIL \"\(fixture.text)\" would stop asking about the whole app")
                failures += 1
            }
        }
        if failures > 0 {
            print("voice: FAIL — \(failures) utterance(s) answered differently than the rule says")
            exit(1)
        }
        print("voice: PASS — \(fixtures.count) verdicts, and no phrase can grant the standing permission")
        exit(0)
    }

    private static func describe(_ decision: VoiceAnswer.Decision) -> String {
        switch decision {
        case .allow: return "allow"
        case .deny: return "deny"
        case .notAnAnswer: return "not an answer"
        }
    }

    private static func argumentAfterFlag(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        let value = CommandLine.arguments[index + 1]
        return value.hasPrefix("--") ? nil : value
    }
}
