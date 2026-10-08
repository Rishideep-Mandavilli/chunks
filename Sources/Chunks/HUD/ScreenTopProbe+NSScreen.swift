import AppKit
import ChunksKit

extension ScreenTopProbe {

    /// Read a live display into the pure geometry model.
    ///
    /// Only the strips' **widths and heights** are used, never their origins. Their `y` is
    /// *not* in the space the rest of the HUD works in: measured on a notch MacBook Air,
    /// `auxiliaryTopLeftArea` is `(0, 1073.5, 762.5, 33.5)` on an 1107 pt tall display —
    /// bottom-left origin, screen-local. Reconstructing the strips from their widths and
    /// placing them at `y = 0` keeps the derivation convention-free, and the cutout then
    /// falls out of `display width - left strip - right strip` rather than a subtraction of
    /// two x origins.
    init(screen: NSScreen) {
        let frame = screen.frame
        let leftWidth = screen.auxiliaryTopLeftArea.map { max(0, $0.width) } ?? 0
        let rightWidth = screen.auxiliaryTopRightArea.map { max(0, $0.width) } ?? 0
        let stripHeight = max(screen.auxiliaryTopLeftArea?.height ?? 0,
                              screen.auxiliaryTopRightArea?.height ?? 0)

        // Screen-local, top-left origin: what `NotchGeometry` works in.
        let left = screen.auxiliaryTopLeftArea == nil ? nil
            : LogicalRect(x: 0, y: 0, width: leftWidth, height: stripHeight)
        let right = screen.auxiliaryTopRightArea == nil ? nil
            : LogicalRect(x: frame.width - rightWidth, y: 0, width: rightWidth, height: stripHeight)

        self.init(
            screenBounds: LogicalRect(x: 0, y: 0, width: frame.width, height: frame.height),
            safeAreaTop: screen.safeAreaInsets.top,
            leftAuxiliary: left,
            rightAuxiliary: right,
            // On the notch-free path the HUD hangs under the menu bar rather than over the
            // clock; with the menu bar auto-hidden this is 0 and the HUD goes flush.
            menuBarHeight: max(0, frame.maxY - screen.visibleFrame.maxY)
        )
    }
}

enum NotchAnchor {

    /// The display the HUD attaches to: the built-in cutout if one exists, otherwise the
    /// display that owns the menu bar (`NSScreen.screens[0]`).
    static func screen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    static func geometry(for screen: NSScreen) -> NotchGeometry {
        NotchGeometry(ScreenTopProbe(screen: screen))
    }
}
