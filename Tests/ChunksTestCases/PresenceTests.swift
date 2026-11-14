import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Presence (3.6): the mood mapping is total and honest (every turn state has exactly one mood), and
/// the owner-editable identity falls back safely so a deleted file never silences the companion.
public enum PresenceTests {

    static func register() {
        TestRunner.currentSuite = "Presence"

        test("every turn state maps to exactly one mood, and the set is ~10") {
            for state in PresenceState.allCases {
                let mood = NotchMood.mood(for: state)
                expect(NotchMood.allCases.contains(mood), "a state must map to a real mood")
            }
            expect(NotchMood.allCases.count >= 9 && NotchMood.allCases.count <= 12,
                   "the face has about ten moods, not one nor fifty")
            expect(NotchMood.mood(for: .listening) == .attentive, "open mic is attentive")
            expect(NotchMood.mood(for: .thinking) == .pondering, "waiting on the model is pondering")
            expect(NotchMood.mood(for: .acting) == .focused, "doing an act is focused")
            expect(NotchMood.mood(for: .waiting) == .patient, "waiting on the user is patient")
            expect(NotchMood.mood(for: .answered) == .happy, "an answer is happy")
            expect(NotchMood.mood(for: .failed) == .sad, "a failure is sad, never happy")
        }

        test("earcons and tints are semantic, and only the transitions worth hearing have sound") {
            expect(NotchMood.attentive.earcon != nil, "listening gets an earcon")
            expect(NotchMood.happy.earcon != nil, "answering gets an earcon")
            expect(NotchMood.sad.earcon != nil, "failing gets an earcon")
            expect(NotchMood.calm.earcon == nil, "idle is quiet")
            expect(NotchMood.pondering.earcon == nil, "thinking is quiet")
            expect(NotchMood.happy.tintName == "success", "happy uses the success tint")
            expect(NotchMood.sad.tintName == "destructive", "sad uses the failure tint")
            expect(NotchMood.asleep.eyesClosed, "asleep closes the eyes")
        }

        test("identity parses the name and persona, and falls back when files are empty") {
            let id = PresenceIdentity.parse(identity: "# Chunks\n\nBolt\n", soul: "warm and brief")
            expectEqual(id.name, "Bolt", "the first non-heading line is the name")
            expectEqual(id.persona, "warm and brief", "the soul body is the persona")
            let empty = PresenceIdentity.parse(identity: nil, soul: nil)
            expectEqual(empty.name, PresenceIdentity.defaultName, "a missing name falls back")
            expectEqual(empty.persona, PresenceIdentity.defaultPersona, "a missing soul falls back")
            expect(empty.promptLine.contains("Bolt") == false, "fallback name is used, not a stale one")
            let long = PresenceIdentity.parse(identity: String(repeating: "n", count: 200),
                                              soul: String(repeating: "s", count: 900))
            expect(long.name.count <= 40 && long.persona.count <= 400, "identity is bounded")
        }
    }
}