import AppKit
import Foundation

/// Where a probe's window has to live: on no display at all.
///
/// Two of them were not. The hover probe built a real notch card — title, sentence, "Press Send?",
/// Allow and Not now — and ordered it front at (200, 200); the crash probe did the same at (100, 100).
/// Every gate run therefore put a fake Chunks card in the middle of his screen, and he read it the only
/// way it could be read: the app has lost its place. That is not a cosmetic slip. A probe that draws
/// over the desktop the user is working on is the 2026-10-11 lockup in a milder costume, and it makes
/// the gate something he cannot leave running.
///
/// `NSApp.sendEvent` routes by window number, and a window server composites a window that is outside
/// every display's frame, so a probe surface can be fully live for AppKit — laid out, hit-testable,
/// receiving dispatched events — and still never be seen. Anything that genuinely has to be visible to
/// be measured is the exception, and there is exactly one: `--probe-ink`, whose whole question is what
/// the display composite contains.
enum ProbeWindow {

    /// Moves the window below the lowest display and proves it intersects none.
    ///
    /// Returns false rather than showing anything when the maths does not work out: a probe that
    /// cannot make itself invisible should skip, not draw over his work to answer its own question.
    @discardableResult
    static func parkOffscreen(_ window: NSWindow, size: NSSize) -> Bool {
        guard !NSScreen.screens.isEmpty else {
            print("probe window: no screens to avoid — not showing anything")
            return false
        }
        let lowest = NSScreen.screens.map { $0.frame.minY }.min() ?? 0
        // 400 pt below the bottom of the lowest display: far enough that a menu-bar-height rounding
        // error still leaves the whole window off every screen, and the margin is checked below rather
        // than trusted.
        let frame = NSRect(x: 0, y: lowest - size.height - 400, width: size.width, height: size.height)
        let overlapping = NSScreen.screens.filter { $0.frame.intersects(frame) }
        guard overlapping.isEmpty else {
            print("probe window: the off-screen position still overlaps \(overlapping.count) display(s) "
                + "— refusing to draw on the desktop")
            return false
        }
        window.setFrame(frame, display: false)
        // Not on any Space's shelf either: a probe window that joins all Spaces would be composited
        // onto whichever one he is looking at.
        window.collectionBehavior = [.ignoresCycle, .stationary]
        return true
    }

    /// The assertion the gate reads. A probe that parked itself is allowed to order front; one that
    /// could not must exit before it does.
    static func reportParked(_ window: NSWindow) {
        let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        print("probe window: frame (\(Int(window.frame.minX)), \(Int(window.frame.minY)) "
            + "\(Int(window.frame.width))x\(Int(window.frame.height))) — "
            + (onAnyScreen ? "ON A DISPLAY, which is the bug" : "off every display"))
    }

    static func isParked(_ window: NSWindow) -> Bool {
        !NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }
}
