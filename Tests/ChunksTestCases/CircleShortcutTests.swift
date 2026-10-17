import ChunksTestHarness
import CoreGraphics
import Foundation
@testable import ChunksKit

/// Tests for the circle-to-explain chord.
///
/// A global shortcut has two failure modes and both are user-visible in someone else's app: a
/// superset match steals a chord another app bound, and a loose match fires while the user is
/// only holding the talk keys.
public enum CircleShortcutTests {

    static let chord: CGEventFlags = [.maskControl, .maskCommand]

    public static func register() {
        TestRunner.currentSuite = "Circle chord"

        test("ctrl-cmd-d opens the drawing surface") {
            expect(CircleShortcut.matches(keyCode: 2, flags: chord),
                   "the chord is the only way in — there is deliberately no menu item to hunt for")
        }

        // The reason Command stays in the chord: Control+Option+letter is macOS's dead-key pair,
        // so a two-modifier chord without Command would type "\u{2202}" into whatever the user is
        // writing at the same moment the surface opened.
        test("the talk keys alone never open it") {
            expect(!CircleShortcut.matches(keyCode: 2, flags: [.maskControl, .maskAlternate]),
                   "\u{2303}\u{2325} is dictation; if D during a hold armed the overlay, drawing would start mid-sentence")
            expect(!CircleShortcut.matches(keyCode: 2, flags: [.maskControl]),
                   "\u{2303}D on its own would fire in every terminal and editor that binds it")
        }

        test("a fifth modifier belongs to another app") {
            expect(!CircleShortcut.matches(keyCode: 2, flags: [.maskControl, .maskCommand, .maskShift]),
                   "an exact match is what keeps Chunks from opening a surface inside someone else's shortcut")
        }

        test("the longer chord this used to answer to is retired, not still live") {
            expect(!CircleShortcut.matches(keyCode: 2, flags: [.maskControl, .maskAlternate, .maskCommand]),
                   "two chords for one feature is the thing the user asked to stop pressing")
        }

        test("the two chords cannot both fire on one key press") {
            expect(PanelShortcut.matches(keyCode: 8, flags: chord)
                    && !CircleShortcut.matches(keyCode: 8, flags: chord),
                   "\u{2303}\u{2318}C is the panel and must stay the panel")
            expect(CircleShortcut.matches(keyCode: 2, flags: chord)
                    && !PanelShortcut.matches(keyCode: 2, flags: chord),
                   "\u{2303}\u{2318}D is the drawing surface and must stay that")
        }
    }
}
