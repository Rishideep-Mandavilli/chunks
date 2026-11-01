import CoreGraphics
import Foundation

/// The chord that opens and closes the app window.
///
/// Same shape as `PanelShortcut` and `CircleShortcut`: ⌃⌘ plus one letter, exact match. 'a' for
/// assistant, matching the third surface of the products this one is modelled on (`⌘⇧A` opens
/// their assistant panel) while staying out of `⌘A`, which every text app uses for Select All.
public enum WindowShortcut {

    /// 'a' for assistant.
    public static let keyCode: UInt16 = 0

    public static let requiredFlags: CGEventFlags = [.maskControl, .maskCommand]

    public static let displayText = "ctrl + cmd + a"

    /// Exact match, so ⌃⌘⇧A belongs to whatever app bound it and not to Chunks.
    public static func matches(keyCode candidate: UInt16, flags: CGEventFlags) -> Bool {
        guard candidate == keyCode else { return false }
        let clean = flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        return clean == requiredFlags
    }
}
