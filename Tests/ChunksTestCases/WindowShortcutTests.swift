import ChunksKit
import ChunksTestHarness
import CoreGraphics

/// Tests for the ⌃⌘A chord that opens the app window.
///
/// The three chords Chunks installs share one modifier pair and differ only by letter, so the
/// valuable assertion is not "does A match" but "does A match *instead of* C or D" — a chord that
/// overlaps another opens two surfaces from one keystroke, and a chord that is too loose eats
/// Select All in the user's editor.
public enum WindowShortcutTests {

    private static let chord: CGEventFlags = [.maskControl, .maskCommand]

    public static func register() {
        TestRunner.currentSuite = "Window shortcut"

        test("ctrl + cmd + a opens the window") {
            expect(WindowShortcut.matches(keyCode: 0, flags: chord),
                   "the documented chord must reach the window without the mouse")
        }

        test("cmd + a is still Select All") {
            expect(!WindowShortcut.matches(keyCode: 0, flags: [.maskCommand]),
                   "Chunks stole Select All")
            expect(!WindowShortcut.matches(keyCode: 0, flags: [.maskControl]),
                   "Chunks fired on a control-only key press")
        }

        test("one keystroke opens exactly one surface") {
            // The three chords share ⌃ and differ only by letter, so the property that matters is
            // not "A matches" but "A, D and C are never true for the same event" — a keystroke that
            // opened the window and the panel at once would look like a glitch and be a race.
            // (An earlier version of this test compared each matcher against *its own* key and so
            // asserted the opposite of what it meant.)
            let matchers: [(UInt16, CGEventFlags) -> Bool] =
                [WindowShortcut.matches, CircleShortcut.matches, PanelShortcut.matches]
            for keyCode in [WindowShortcut.keyCode, CircleShortcut.keyCode, PanelShortcut.keyCode] {
                let fired = matchers.filter { $0(keyCode, chord) }.count
                expect(fired == 1, "keyCode \(keyCode) opened \(fired) surfaces, not one")
            }
        }

        test("a fourth letter with the same modifiers opens nothing") {
            // 's' is ⌘S in every app on the machine. The family must not be a prefix match.
            expect(!WindowShortcut.matches(keyCode: 1, flags: chord))
            expect(!CircleShortcut.matches(keyCode: 1, flags: chord))
            expect(!PanelShortcut.matches(keyCode: 1, flags: chord))
        }

        test("shift added to the chord does not fire") {
            expect(!WindowShortcut.matches(keyCode: 0, flags: chord.union([.maskShift])),
                   "⌃⌘⇧A belongs to someone else; Chunks must not open a window over it")
        }

        test("the hold-to-talk chord never opens the window") {
            expect(!WindowShortcut.matches(keyCode: WindowShortcut.keyCode,
                                           flags: [.maskControl, .maskAlternate]),
                   "holding the talk key would open a window under the recording")
        }

        test("unrelated modifier bits are ignored") {
            let flags: CGEventFlags = chord.union([.maskAlphaShift, .maskSecondaryFn])
            expect(WindowShortcut.matches(keyCode: WindowShortcut.keyCode, flags: flags),
                   "Caps Lock or Fn on the keyboard broke the window shortcut")
        }

        test("the advertised text describes the key the code matches") {
            expectEqual(WindowShortcut.keyCode, 0, "the displayed shortcut says A")
            expect(WindowShortcut.displayText.contains("a"),
                   "displayText no longer mentions the key it matches")
        }
    }
}
