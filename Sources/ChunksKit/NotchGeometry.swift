import CoreGraphics
import Foundation

// MARK: - Raw measurements

/// Everything a caller must read off a display in order to place a notch-anchored HUD.
///
/// This is a plain data struct rather than a function over `NSScreen` on purpose: the
/// rules below are the part that can be wrong and the part that can be tested, and neither
/// wants a live window server. The AppKit side (`NotchPanelManager`) is a handful of
/// property reads; all the geometry decisions live here.
///
/// Coordinate system: **screen-local, top-left origin, y grows downward**. That is the
/// space `CGDisplayBounds`, `safeAreaInsets` and the auxiliary areas all speak, and it is
/// the space a reader can reason about when the shape sits *at* the top of the screen.
/// AppKit's bottom-left global space is only entered at the last step, in
/// `appKitWindowFrame(_:globalScreen:)`.
public struct ScreenTopProbe: Equatable, Sendable {

    /// The display's own bounds in screen-local top-left coordinates. Its origin is
    /// `(0, 0)` for the display being probed; `width`/`height` are what matter.
    public var screenBounds: LogicalRect

    /// `NSScreen.safeAreaInsets.top`. Non-zero on notched Macs, and the authoritative
    /// notch height.
    public var safeAreaTop: Double

    /// `NSScreen.auxiliaryTopLeftArea` — the strip of menu bar left of the notch.
    /// `nil` when there is no notch.
    public var leftAuxiliary: LogicalRect?

    /// `NSScreen.auxiliaryTopRightArea` — the strip right of the notch. `nil` likewise.
    public var rightAuxiliary: LogicalRect?

    /// Height of the menu bar strip the HUD would otherwise sit on top of. Used only on
    /// the non-notch path, to drop the HUD below the menu bar instead of covering the
    /// clock and menu extras. Derive it from the display, not from a constant: it changes
    /// with display scaling and with the menu bar auto-hiding.
    public var menuBarHeight: Double

    public init(screenBounds: LogicalRect,
                safeAreaTop: Double,
                leftAuxiliary: LogicalRect?,
                rightAuxiliary: LogicalRect?,
                menuBarHeight: Double) {
        self.screenBounds = screenBounds
        self.safeAreaTop = safeAreaTop
        self.leftAuxiliary = leftAuxiliary
        self.rightAuxiliary = rightAuxiliary
        self.menuBarHeight = menuBarHeight
    }
}

// MARK: - The notch model

/// Where a HUD can anchor on a given display, and the one place that decides it.
///
/// ## Why this is not just "put it at the top center"
///
/// A notch is not a hole in the coordinate system — anything drawn there is invisible
/// behind the bezel. Two failure modes follow, and both are silent:
///
/// * Content laid out *across* the notch loses whatever falls in the cutout. A status
///   pill 24 pt tall starting at `y = 0` has its top ~32 pt eaten, so it reads as a
///   clipped rectangle or as nothing at all.
/// * Content anchored *beside* the notch at a guessed offset drifts. The notch width is
///   not constant across models (and changed again with the narrower notch), so a
///   hard-coded `x` lands in the bulge on one Mac and over the menu extras on another.
///
/// The correct geometry comes from the system: the two auxiliary strips are the menu bar
/// on either side of the cutout, so the gap between them **is** the notch, and the height
/// it needs is `safeAreaInsets.top`. Absent a notch, those areas are `nil` and the HUD
/// falls back to hanging below the menu bar, horizontally centered on the display.
///
/// ## The shape rule
///
/// When notched, the HUD's top edge sits flush with the top of the screen and is at least
/// as wide as the cutout. A card narrower than the notch makes the notch appear to bite a
/// chunk out of the panel; a card starting below the notch height looks detached. Given
/// those two invariants the panel reads as one continuous shape growing out of the notch,
/// which is the whole visual trick.
public struct NotchGeometry: Equatable, Sendable {

    public let hasNotch: Bool

    /// Cutout width. Zero on non-notch displays.
    public let notchWidth: Double

    /// Cutout depth, i.e. how far it eats into the screen from the top edge.
    public let notchHeight: Double

    /// `y` of the HUD's top edge, screen-local top-left coordinates.
    public let hudTop: Double

    /// `x` the HUD is centered on. The notch's own center when notched — never the
    /// display center, which is only equal to it on a perfectly symmetric cutout.
    public let hudCenterX: Double

    /// Widest the HUD may be before it runs off this display.
    public let maxWidth: Double

    public init(_ probe: ScreenTopProbe) {
        let notch = NotchGeometry.cutout(in: probe)

        hasNotch = notch != nil
        notchWidth = notch?.width ?? 0
        notchHeight = notch?.height ?? 0

        if let notch {
            // Flush with the top edge so the panel and the cutout merge into one shape.
            hudTop = 0
            hudCenterX = notch.midX
        } else {
            hudTop = max(0, probe.menuBarHeight)
            hudCenterX = probe.screenBounds.midX
        }
        maxWidth = probe.screenBounds.width
    }

    /// The cutout, or `nil` when this display has none.
    ///
    /// Both strips must exist, have real width, and leave a positive gap between them.
    /// The gap is then checked against half the screen width: a "notch" wider than that
    /// is not a cutout but a misread (a single-sided strip, or an external display
    /// reporting odd auxiliary areas), and treating it as a notch would push the HUD into
    /// the middle of the screen. Failing that check degrades to the menu-bar path, which
    /// always has somewhere to draw.
    private static func cutout(in probe: ScreenTopProbe) -> LogicalRect? {
        guard let left = probe.leftAuxiliary, let right = probe.rightAuxiliary else { return nil }
        guard left.width > 0, right.width > 0 else { return nil }

        let x0 = left.maxX
        let x1 = right.minX
        let width = x1 - x0
        guard width > 0 else { return nil }
        guard width < probe.screenBounds.width / 2 else { return nil }

        // safeAreaInsets.top is the documented depth; the strip heights are the fallback
        // for a display that reports the strips but a zero inset.
        let height = max(probe.safeAreaTop, max(left.height, right.height))
        guard height > 0 else { return nil }

        return LogicalRect(x: x0, y: 0, width: width, height: height)
    }

    /// The HUD rect for a card of the given size, clamped to stay on this display.
    ///
    /// `height` is expected to come from `AnswerPanelLayout` — this type deliberately does
    /// not know anything about content, so the two sources of layout truth stay separate.
    ///
    /// Width is floored at `notchWidth` when notched, for the shape rule above. It is
    /// *not* floored at any particular height: a collapsed pill legitimately hides inside
    /// the notch region, and forcing it taller than the cutout would draw a black bar over
    /// the menu bar.
    public func hudRect(width: Double, height: Double) -> LogicalRect {
        let clampedWidth = min(max(width, hasNotch ? notchWidth : 0), maxWidth)
        let x = hudCenterX - clampedWidth / 2
        let originX = min(max(0, x), max(0, maxWidth - clampedWidth))
        return LogicalRect(x: originX, y: hudTop, width: clampedWidth, height: max(0, height))
    }

    /// Convert a screen-local top-left rect into the global bottom-left rect `NSPanel`
    /// wants.
    ///
    /// The flip is the entire reason this function exists. AppKit window frames are
    /// bottom-left origin with global coordinates; the probe is top-left origin and
    /// screen-local. Getting the sign wrong does not throw — it puts the panel at the
    /// *bottom* of the screen, which looks like a bug in the panel code and is one of the
    /// classic mistakes in this space. So the flip lives here, tested, rather than inline
    /// at each call site.
    ///
    /// `globalScreenFrame` is the same display's frame in global AppKit coordinates
    /// (`NSScreen.frame`).
    public static func appKitWindowFrame(_ local: LogicalRect, globalScreen: LogicalRect) -> LogicalRect {
        LogicalRect(x: globalScreen.minX + local.minX,
                    y: globalScreen.maxY - (local.minY + local.height),
                    width: local.width,
                    height: local.height)
    }
}
