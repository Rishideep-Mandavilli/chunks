import AppKit
import ChunksKit
import SwiftUI

/// The one real window Chunks owns: history on the left, the answer on the right, a composer
/// along the bottom.
///
/// AppKit rather than a SwiftUI `Window` scene because this app is an accessory (`LSUIElement`):
/// it has no main menu, no dock icon and its `body` is an empty `Settings` scene. A scene would
/// need a menu and a default-window story before it worked, and the pattern every other surface in
/// this app already uses is an `NSHostingView` inside a window this type builds.
///
/// Unlike the panel and the notch card, this window *does* activate the app. That is the point: it
/// is the surface he goes to, so it has to take keyboard focus and hold it — and the reason the
/// other two are non-activating is that they must not move the menu bar while he is still working
/// in the app he was pointing at.
@MainActor
final class AppWindowManager {
    private var window: NSWindow?
    private let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    /// Show if hidden, hide if showing — from the chord and from the panel row, which must not
    /// drift into two definitions of "open".
    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        if window == nil { window = makeWindow() }
        guard let window else { return }
        companionManager.refreshHistory()
        window.makeKeyAndOrderFront(nil)
        // An accessory app has no dock icon to click, so without this the window appears behind the
        // frontmost app and the text field cannot be typed in — the field needs the app to be
        // active, not merely the window to be key.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow? {
        let manager = companionManager
        let view = CompanionWindowView(model: manager.windowModel,
                                       hud: manager.hud,
                                       ask: { question in
                                           manager.ask(text: question, source: .typed)
                                       },
                                       forget: { id in manager.forgetTurn(id: id) },
                                       beginSession: {
                                           manager.startNewSession(starting: .manual)
                                       })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 860, height: 560)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Chunks"
        // The content runs under the traffic lights, and the title text goes, because a bar of
        // chrome above a sidebar that already says "Chunks" is a second heading for the same thing.
        // The strip is still the draggable region; the view leaves its height clear at the top of both
        // columns rather than putting a button under a cursor.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        // Pinned to the light appearance rather than left to follow the system: the palette has no
        // dark variant any more, so a macOS Dark Mode would give this window a black titlebar over
        // bone content — the same mismatch, inverted, that the dark palette had in Light Mode.
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 720, height: 460)
        // Remembered by the system, so the window opens where he left it. `setFrameAutosaveName`
        // answers false when nothing has been saved yet, which is the only time centre is right.
        if !window.setFrameAutosaveName("ChunksMainWindow") { window.center() }
        return window
    }
}
