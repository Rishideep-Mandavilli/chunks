import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for the keyboard vocabulary and its judgement.
///
/// Two things here are worth the space they take. The first is the table: the key codes are not
/// alphabetical (K is 40, I is 34, the digits are scattered), so a parse that silently picks the wrong
/// entry presses a letter nobody said — the plausible-wrong-number failure invariant 1 exists for,
/// with a keystroke instead of a coordinate. The second is the classification, because a key is one
/// event away from effects no `[ACT:]` can reach: ⌘Q closes the app he is working in, ⌃C stops the
/// build running in his terminal, and a Return in a one-line composer is a sent message.
public enum KeyActionTests {

    public static func register() {
        TestRunner.currentSuite = "Full keyboard access"

        test("the names a person says resolve to the codes the SDK uses") {
            // Spot-checked against `Carbon.HIToolbox` on this machine, not against memory.
            let cases: [(String, UInt16)] = [
                ("a", 0), ("s", 1), ("k", 40), ("i", 34), ("m", 46), ("l", 37),
                ("1", 18), ("5", 23), ("6", 22), ("0", 29),
                ("return", 36), ("tab", 48), ("space", 49), ("escape", 53),
                ("left", 123), ("right", 124), ("down", 125), ("up", 126),
                ("f5", 96), ("f12", 111),
            ]
            for (name, code) in cases {
                let combo = KeyAction.parse(name)
                expect(combo != nil, "expected `\(name)` to parse")
                expectEqual(combo?.keyCode, code,
                            "`\(name)` must post key code \(code), not whatever a typed table said")
            }
        }

        test("the aliases he will actually speak fold onto the SDK's names") {
            expectEqual(KeyAction.parse("backspace")?.keyCode, 51,
                        "Apple's Delete key IS backspace")
            expectEqual(KeyAction.parse("del")?.keyCode, 117,
                        "`delete` forward is a different key from backspace and must not share its code")
            expectEqual(KeyAction.parse("enter")?.key, "return")
            expectEqual(KeyAction.parse("esc")?.key, "escape")
            expectEqual(KeyAction.parse("page down")?.key, "pagedown")
        }

        test("the keys that live on the function row are marked, so the driver holds fn") {
            for name in ["home", "end", "pageup", "pagedown", "forwarddelete"] {
                expect(KeyAction.parse(name)?.needsFunction == true,
                       "`\(name)` is only honoured by AppKit with the function modifier set")
            }
            expect(KeyAction.parse("down")?.needsFunction == false,
                   "the arrow itself is not a function-row key")
        }

        test("modifiers and repetition are read, not guessed") {
            let save = KeyAction.parse("cmd+s")
            expect(save?.modifiers.contains(.command) == true, "⌘S must carry command")
            expectEqual(save?.key, "s")
            let select = KeyAction.parse("shift+down x3")
            expectEqual(select?.modifiers, [.shift])
            expectEqual(select?.key, "down")
            expectEqual(select?.times, 3,
                        "a selection is a repeated key; losing the count leaves one line selected")
            let chained = KeyAction.parse("ctrl+option+delete")
            expect(chained?.modifiers.contains([.control, .option]) == true,
                   "all three modifiers must survive the split")
        }

        test("a repetition is capped rather than obeyed") {
            let combo = KeyAction.parse("backspace x100000")
            expectEqual(combo?.times, KeyAction.maxRepeat,
                        "an unbounded loop is a freeze with a voice attached")
        }

        test("what is not a key is refused at the parse, not posted as something close") {
            // Each of these would otherwise press a real key the user never named.
            expect(KeyAction.parse("cmd") == nil, "a bare modifier posts nothing and would report success")
            expect(KeyAction.parse("cmd++") == nil, "a plus inside the key name is not a key")
            expect(KeyAction.parse("excel") == nil,
                   "`excel` is a name, not the letter e with a count of 'll'")
            expect(KeyAction.parse("hypnotic") == nil, "an unknown key must fail to parse")
            expect(KeyAction.parse("") == nil)
            expect(KeyAction.parse("backspace x0") == nil,
                   "zero repetitions is a no-op reported as an act")
        }

        test("plain editing is routine: it runs with asking off") {
            for body in ["a", "return", "space", "backspace x10", "shift+down x4",
                         "option+right", "tab", "home", "delete"] {
                let combo = KeyAction.parse(body)
                expect(combo != nil, "`\(body)` should parse")
                expectEqual(KeyAction.classify(combo!, focusedRole: "AXTextArea"), .routine,
                            "`\(body)` is caret and text editing — the routine class this switch is for")
            }
        }

        test("a command combination is asked whatever the switch says") {
            // ⌘S writes to disk, ⌘P opens a palette that runs anything, ⌃C stops a process. None of
            // them is "routine navigation", which is the only thing "don't ask" was ever meant to cover.
            for body in ["cmd+s", "cmd+shift+p", "cmd+n", "ctrl+c", "cmd+option+right"] {
                let combo = KeyAction.parse(body)
                expect(combo != nil, "`\(body)` should parse")
                if case .command = KeyAction.classify(combo!, focusedRole: "AXTextArea") {
                    // expected
                } else {
                    expect(false, "`\(body)` must be asked about, not run silently")
                }
            }
        }

        test("quitting and force-quitting are refused, because a verb already owns them") {
            for body in ["cmd+q", "cmd+option+escape", "capslock"] {
                let combo = KeyAction.parse(body)
                expect(combo != nil, "`\(body)` should parse")
                if case .refused = KeyAction.classify(combo!, focusedRole: "AXTextArea") {
                    // expected
                } else {
                    expect(false, "`\(body)` must be refused: it changes his session, not his file")
                }
            }
        }

        test("return submits in a one-line field and is asked about when the focus is unknown") {
            let enter = KeyAction.parse("return")!
            expectEqual(KeyAction.classify(enter, focusedRole: "AXTextArea"), .routine,
                        "a multiline editor takes a newline, which is what he asked for")
            if case .command = KeyAction.classify(enter, focusedRole: "AXTextField") {
                // expected: in a composer, Return is Send.
            } else {
                expect(false, "return in a single-line field is a submission and must be asked")
            }
            // The Electron case is the common one, not an edge: the editor publishes no tree, so
            // "unknown" must fail toward asking — the rule PolicyGate already applies to a role it
            // cannot read.
            if case .command = KeyAction.classify(enter, focusedRole: nil) {
                // expected
            } else {
                expect(false, "an unreadable focus must not be treated as safe")
            }
        }

        test("the card says which app receives the keystroke, in words and in symbols") {
            let combo = KeyAction.parse("cmd+shift+p")!
            let question = KeyAction.question(for: combo, appName: "Qoder")
            expect(question.contains("⇧⌘P"),
                   "the symbol form is what he recognises on the card, in menu order with the "
                   + "letter uppercase, as every macOS menu shows it: \(question)")
            expect(question.contains("Qoder"),
                   "a keystroke lands wherever the caret is, so the app is the thing being approved: \(question)")
            let outcome = KeyAction.outcome(for: KeyAction.parse("backspace x5")!, appName: "Terminal")
            expectEqual(outcome, "Pressed backspace ×5 in Terminal.",
                        "the count belongs in the report; five keys pressed silently is a different act")
            expect(KeyAction.parse("cmd+s").map { $0.display } == "⌘S",
                   "⌘s and ⌘S are the same key to us and two different keys to a man reading a menu")
            expect(KeyAction.parse("cmd+s").map { "\($0.modifiers.spoken) \($0.key)" } == "command s",
                   "VoiceOver gets words, not glyphs")
        }

        test("the table is complete enough to be believed about the whole keyboard") {
            // A missing entry is a refusal the model cannot predict, so the coverage of the keys this
            // feature exists for is itself the assertion.
            let required = ["a", "z", "0", "return", "tab", "space", "delete", "forwarddelete",
                            "escape", "left", "right", "up", "down", "home", "end", "pageup",
                            "pagedown", "f1", "f12", ";", "'", "[", "]", ",", ".", "/", "-", "=",
                            "\\", "`"]
            for key in required {
                expect(KeyAction.keyCodes[key] != nil,
                       "`\(key)` is in the table the prompt tells the model it may use")
            }
        }
    }
}
