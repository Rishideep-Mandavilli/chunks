import ChunksKit
import ChunksTestHarness
import CoreGraphics

/// Tests for the ⌃⌘C chord that opens and closes the panel.
///
/// This is a global shortcut installed by an event tap, so a wrong match has two failure
/// modes and neither shows an error: too loose and Chunks steals another app's keystroke
/// mid-typing, too tight and the panel has no keyboard route at all — which matters more
/// than usual here, because the notch pill is the only surface during a turn.
public enum PanelShortcutTests {

    /// Control and Command. Option is deliberately absent: it is the talk modifier, so a chord
    /// that needed it would fire in the middle of a spoken question — and a chord that dropped
    /// Command instead would type "∂" into whatever the user is writing.
    private static let chord: CGEventFlags = [.maskControl, .maskCommand]

    public static func register() {
        TestRunner.currentSuite = "Panel shortcut"

        test("ctrl + cmd + c opens the panel") {
            expect(PanelShortcut.matches(keyCode: 8, flags: chord),
                   "the documented chord must reach the panel without the mouse")
        }

        test("dropping either modifier does not fire") {
            // ⌘C is copy and ⌃C is bound in terminals and editors. A matcher that treated the set
            // as "contains" would toggle a panel in the middle of someone's clipboard.
            let missingOne: [CGEventFlags] = [
                [.maskCommand],
                [.maskControl],
                [.maskAlternate, .maskCommand],
                [.maskControl, .maskAlternate],
            ]
            for flags in missingOne {
                expect(!PanelShortcut.matches(keyCode: 8, flags: flags),
                       "fired for \(flags.rawValue) without the full chord")
            }
        }

        test("shift added to the chord does not fire") {
            expect(!PanelShortcut.matches(keyCode: 8, flags: chord.union([.maskShift])),
                   "⌃⌘⇧C belongs to someone else; Chunks must not open a panel over it")
        }

        test("the four-key chord this used to answer to is retired") {
            // One chord per feature. Leaving ⌃⌘C live as well would keep two ways to do the same
            // thing, which is what the user asked to stop pressing.
            expect(!PanelShortcut.matches(keyCode: 8,
                                          flags: [.maskControl, .maskAlternate, .maskCommand]),
                   "the longer chord still works, so the shortcut was never actually shortened")
        }

        test("a different key with the right modifiers does not fire") {
            // keyCode 8 is 'c'. 0 is 'a', 49 is space — the hold-to-talk key, which must
            // never be read as a panel toggle or a recording would start under the panel.
            for keyCode: UInt16 in [0, 1, 49, 34] {
                expect(!PanelShortcut.matches(keyCode: keyCode, flags: chord),
                       "matched keyCode \(keyCode), which is not 'c'")
            }
        }

        test("the hold-to-talk chord never matches the panel chord") {
            // ⌃ alone is push-to-talk. If this ever matched, holding the talk key would
            // toggle a panel underneath the recording.
            let talkFlags: CGEventFlags = [.maskControl, .maskAlternate]
            expect(!PanelShortcut.matches(keyCode: PanelShortcut.keyCode, flags: talkFlags),
                   "push-to-talk and the panel toggle fired on the same chord")
        }

        test("unrelated modifier bits are ignored") {
            // Caps Lock, numeric pad and device-dependent bits ride along in a real CGEvent.
            // Ignoring them is what makes the chord work with Caps Lock on.
            let flags: CGEventFlags = chord.union([.maskAlphaShift, .maskSecondaryFn,
                                                   .maskNumericPad])
            expect(PanelShortcut.matches(keyCode: PanelShortcut.keyCode, flags: flags),
                   "Caps Lock or Fn on the keyboard broke the panel shortcut")
        }

        test("the advertised text describes the key the code actually matches") {
            // Copy and behavior drift apart silently: 'c' is keyCode 8, and a future key
            // change would leave the tooltip telling users a chord that does nothing.
            expectEqual(PanelShortcut.keyCode, 8, "the displayed shortcut says C")
            expect(PanelShortcut.displayText.contains("c"),
                   "displayText no longer mentions the key it matches")
            expect(!PanelShortcut.displayText.contains("option"),
                   "the panel copy still advertises option, which no longer opens it")
        }
    }
}
