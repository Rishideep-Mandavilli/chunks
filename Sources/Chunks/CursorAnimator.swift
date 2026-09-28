import AppKit
import ChunksKit

/// Moves the pointer, and flies it when the user asks to see something.
///
/// Uses posted `CGEvent`s rather than `NSCursor`. `NSCursor` only swaps the cursor image;
/// the pointer's actual location is unchanged, so nothing the user sees moves. A posted
/// `mouseMoved` genuinely relocates it.
@MainActor
enum CursorAnimator {

    /// Park the pointer. No click — ever.
    ///
    /// Chunks pointing is not Chunks acting. Clicking is a separate, separately-confirmed
    /// action behind the consent gate, and conflating the two would make "show me where
    /// that is" silently become "click that", which is the exact failure the no-click-
    /// without-asking rule exists to prevent.
    static func move(to point: LogicalPoint) {
        post(.mouseMoved, to: point)
    }

    /// Glide the pointer to `point` over `duration`.
    ///
    /// Interpolated rather than teleported because a jump reads as a glitch, while a
    /// movement reads as Chunks indicating something. The easing is ease-in-out so it
    /// accelerates away and settles in, which is what makes the target feel deliberate.
    static func fly(to point: LogicalPoint, duration: TimeInterval = 0.45) {
        guard let start = currentPointerLocation() else {
            move(to: point)
            return
        }
        // A jump over ~1500 points is a cut, not a glide; no animation reads better.
        let distance = hypot(point.x - start.x, point.y - start.y)
        guard distance > 80 else {
            move(to: point)
            return
        }

        let steps = max(12, min(40, Int(distance / 24)))
        let stepDelay = duration / Double(steps)

        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let x = start.x + (point.x - start.x) * eased
            let y = start.y + (point.y - start.y) * eased

            DispatchQueue.main.asyncAfter(deadline: .now() + stepDelay * Double(step)) {
                post(.mouseMoved, to: LogicalPoint(x: x, y: y))
            }
        }
    }

    private static func post(_ type: CGEventType, to point: LogicalPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        // `combinedSessionState` would attribute the movement to Chunks; `hidSystemState`
        // attributes it to the hardware, so apps that ignore synthetic events (most of
        // them) still highlight under the cursor.
        _ = source
        guard let event = CGEvent(mouseEventSource: nil,
                                  mouseType: type,
                                  mouseCursorPosition: CGPoint(x: point.x, y: point.y),
                                  mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    /// Where the pointer is now, in the global logical space Chunks uses.
    ///
    /// `NSEvent.mouseLocation` is **bottom-left** origin, and the global display space is
    /// **top-left**, so a raw read would put the pointer at a mirrored position and the
    /// flight would start from the wrong place. Converted properly here rather than at the
    /// call site, because this is the only place both conventions meet.
    static func currentPointerLocation() -> LogicalPoint? {
        guard let event = CGEvent(source: nil) else { return nil }
        return LogicalPoint(x: Double(event.location.x), y: Double(event.location.y))
    }
}
