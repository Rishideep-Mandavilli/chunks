import CoreGraphics
import Foundation

/// The chord that opens and closes the Chunks panel.
///
/// Raw modifier bits rather than `NSEvent.ModifierFlags` so the match lives with the rest of
/// the pure logic and can be unit-tested: a global event tap hands over a `CGEventFlags`, and
/// a wrong match here either steals another app's shortcut or leaves the panel unreachable.
public enum PanelShortcut {

    /// 'c' for companion.
    public static let keyCode: UInt16 = 8

    /// Control, Option, Command — and nothing else.
    ///
    /// A superset of the hold-to-talk chord (⌃⌥), so the two can never fire together: hold
    /// ⌃⌥ and Chunks listens, add ⌘ and press C and the panel moves.
    public static let requiredFlags: CGEventFlags = [.maskControl, .maskCommand]

    public static let displayText = "ctrl + cmd + c"

    /// Exact match, not `contains`.
    ///
    /// `contains` would fire for ⌃⌥⌘⇧C and for any app that binds a fifth modifier to the
    /// same three-key base, which means Chunks opening a panel in the middle of someone
    /// else's shortcut. Shift is tested explicitly because it is the one modifier users add
    /// by accident while reaching for a letter.
    public static func matches(keyCode candidate: UInt16, flags: CGEventFlags) -> Bool {
        guard candidate == keyCode else { return false }
        let clean = flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        return clean == requiredFlags
    }
}
