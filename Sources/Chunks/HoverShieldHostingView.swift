import AppKit
import SwiftUI

/// A hosting view SwiftUI's hover machinery can never reach.
///
/// The app has faulted three times inside Apple's hover dispatch, and the crash breadcrumb named the
/// surface twice: `NSHostingView.mouseEntered` → `sendHoverEvent` → `HoverEventDispatcher` → the hit
/// test → SwiftUI's own `MainActor.assumeIsolated` → `swift_getObjectType` on a freed object
/// (SIGSEGV, KERN_INVALID_ADDRESS at 0x220). The assertion is Apple's, not ours, so no grep in this
/// repo removes it; the only thing we own is whether a `mouseEntered` ever arrives at the view.
///
/// Hover tracking areas exist only to deliver enter/exit events, so this subclass strips every area
/// carrying `.mouseEnteredAndExited` the moment SwiftUI (re)installs them, and swallows the three
/// pointer-tracking messages as a second lock. Clicks, key status, gestures and layout are untouched:
/// a press is `mouseDown`, which no tracking area is involved in. Used by the two surfaces that float
/// over his work while he moves the pointer — the notch card and the menu-bar panel — where a hover
/// tint was the only thing the tracking bought.
final class HoverShieldHostingView<Content: View>: NSHostingView<Content> {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.options.contains(.mouseEnteredAndExited) {
            removeTrackingArea(area)
        }
    }

    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
}
