import CoreGraphics
import Foundation

/// The chord that starts and stops circle-to-explain.
///
/// A hotkey rather than a menu item because the feature is meant to fire the moment someone
/// decides to point at something on screen — hunting a menu for it is a second interaction with
/// the thing you were already doing. It also means there is no button to miss when the overlay is
/// covering the screen.
///
/// Same shape as `PanelShortcut`: exact match on ⌃⌘ plus one letter. Command is what keeps
/// this clear of the talk key — ⌃⌥ is dictation, and ⌃⌥ plus a letter is macOS's dead-key pair,
/// which would type "∂" into the user's document at the moment the surface opened.
public enum CircleShortcut {

    /// 'd' for draw.
    public static let keyCode: UInt16 = 2

    public static let requiredFlags: CGEventFlags = [.maskControl, .maskCommand]

    public static let displayText = "ctrl + cmd + d"

    /// Exact match, so ⌃⌥⇧⌘D belongs to whatever app bound it and not to Chunks.
    public static func matches(keyCode candidate: UInt16, flags: CGEventFlags) -> Bool {
        guard candidate == keyCode else { return false }
        let clean = flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        return clean == requiredFlags
    }
}
