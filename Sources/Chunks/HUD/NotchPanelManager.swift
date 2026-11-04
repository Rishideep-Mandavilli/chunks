//
//  NotchPanelManager.swift
//  Chunks
//
//  The notch-anchored HUD: a borderless, non-activating panel that grows out of the
//  display's cutout and hangs below it.
//
//  This is the surface Chunks answers on, and it deliberately does not steal focus: every
//  question is about whatever the user is already doing, so a HUD that activated the app
//  would take them out of that app at the moment they need to act on the answer.
//
//  On a Mac with no notch the same panel hangs below the menu bar instead, centered on the
//  display. That path is not a consolation prize — an external display with no cutout is the
//  common case for a docked laptop, and `NotchGeometry` decides which of the two applies.
//

import AppKit
import ChunksKit
import Combine
import SwiftUI

@MainActor
final class NotchPanelManager {

    /// Starts a new turn from a tapped suggestion. Wired up by the app once the answer
    /// pipeline can route a follow-up question.
    var onSelectAction: ((String) -> Void)?

    private let model: NotchHUDModel
    private var panel: NSPanel?
    private var hostingView: NSHostingView<NotchHUDView>?
    private var screen: NSScreen?
    private var geometry: NotchGeometry?
    private var screenChangeObserver: NSObjectProtocol?
    private var clickOutsideMonitor: Any?
    private var cancellable: AnyCancellable?

    /// Corner radius of the halo, shared with the view's clip shape. The top edge is square
    /// because it meets the top of the display; only the bottom rounds.
    private /// The view clips to `DS.CornerRadius.extraLarge`; this used to say 14 independently, and
    /// the two disagreed about the same corner.
    static let haloRadius: CGFloat = DS.CornerRadius.extraLarge

    init(model: NotchHUDModel) {
        self.model = model
        rebuildGeometry()

        // The panel's frame is derived from the content, and SwiftUI does not tell AppKit
        // how tall its host turned out to be, so a content change re-rolls the frame.
        //
        // Throttled because one streamed delta sets four published properties — headline,
        // speech, detail, chips — and each would otherwise resize the window and re-register
        // the global event monitor within it. `latest: true` is what keeps the final state
        // from being the one that gets dropped: the last change inside every window is applied.
        cancellable = model.objectWillChange
            .throttle(for: .milliseconds(40), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.refresh()
            }

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildGeometry()
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Visibility

    /// Bring the HUD in line with the model: shown when there is something to say, gone when
    /// there is not.
    ///
    /// The app code never calls this. It changes `NotchHUDModel`, and the subscription set up
    /// in `init` does the window work — two places remembering to update the panel is how a
    /// reply ends up streamed into a hidden window.
    func refresh() {
        guard model.isVisible else { hide(); return }
        if geometry == nil { rebuildGeometry() }
        createPanelIfNeeded()
        applyFrame()
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    func hide() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    // MARK: - Geometry

    /// Re-derive the anchor from the current display setup.
    ///
    /// Called at init and on every screen-parameter change: plugging in an external monitor
    /// can change which screen has the notch, and a panel left anchored to a display that no
    /// longer exists sits at a stale coordinate until the next interaction.
    private func rebuildGeometry() {
        guard let target = NotchAnchor.screen() else { return }
        screen = target
        geometry = NotchAnchor.geometry(for: target)
        model.notchHeight = geometry?.notchHeight ?? 0
        let width = min(NotchHUDModel.defaultCardWidth, target.frame.width)
        model.cardWidth = max(1, width)
    }

    // MARK: - Panel

    private func createPanelIfNeeded() {
        if panel != nil { return }

        let view = NotchHUDView(model: model, onSelectAction: { [weak self] action in
            self?.onSelectAction?(action)
        })
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.autoresizingMask = [.width, .height]

        let created = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: model.cardWidth, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Named for the crash breadcrumb. Both this panel and the menu-bar one are the same private
        // class, so a fault can only say "which surface" if the surfaces say so themselves.
        created.identifier = NSUserInterfaceItemIdentifier("notch-card")

        created.isFloatingPanel = true
        // Above the menu bar, so the halo can wrap the cutout. On a display with no notch
        // the panel sits below the menu bar and the level costs nothing.
        created.level = .statusBar
        created.isOpaque = false
        created.backgroundColor = .clear
        // The shadow is off because the panel's own black shape is the boundary; a shadow
        // around a rectangle that starts at the top of the screen draws a grey line across
        // the notch.
        // True now that the card is bone. On the black ground the shadow was invisible and the
        // window server's was a liability; a light sheet hanging off the notch has to be held down by
        // something, or it reads as a rectangle of dead pixels over the desktop.
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.isExcludedFromWindowsMenu = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        created.isMovable = false
        created.titleVisibility = .hidden
        created.contentView = hosting

        panel = created
        hostingView = hosting
    }

    /// Size and place the window from the model.
    ///
    /// The top edge is pinned: growing downward from a fixed top is what makes the card look
    /// like it emerged from the notch instead of dropping onto the screen.
    private func applyFrame() {
        guard model.isVisible, let panel, let geometry, let screen else {
            hide()
            return
        }

        let total = geometry.notchHeight + model.contentHeight
        let local = geometry.hudRect(width: model.cardWidth, height: total)
        let globalScreen = LogicalRect(x: screen.frame.origin.x, y: screen.frame.origin.y,
                                       width: screen.frame.width, height: screen.frame.height)
        let frame = NotchGeometry.appKitWindowFrame(local, globalScreen: globalScreen)

        panel.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                       display: true)
        hostingView?.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
    }

    // MARK: - Dismissal

    /// Click anywhere outside the card and it goes away.
    ///
    /// The panel cannot use `NSWindow`'s own transient behavior — a non-activating panel
    /// never becomes the app's active window, so there is no resignKey event to watch. A
    /// global monitor is what the vendored menu panel does for the same reason.
    private func installClickOutsideMonitor() {
        // Idempotent: `refresh` runs on every throttled content change, and tearing down and
        // re-adding a global monitor each time is how a click lands in the gap between them.
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            let click = NSEvent.mouseLocation
            if self.panel?.frame.contains(click) == true { return }
            Task { @MainActor [weak self] in self?.dismissForClickOutside() }
        }
    }

    private func dismissForClickOutside() {
        // A click in the menu-bar row next to the notch belongs to the system's own extras, so
        // dismissal is fine; nothing here needs the onboarding guard the menu panel uses, because
        // the HUD is never the surface that grants permissions.
        //
        // Click-away stays the way to close a card that has finished saying something. Making
        // `.result` click-proof was tried on 2026-10-09 and is worse: the click outside is the ONLY
        // way to close the card — no close button, no timeout, no key — so protecting it turned
        // every answer into furniture fixed under the notch.
        //
        // A *waiting* card is the opposite case. "Thinking" is the only proof Chunks is still
        // working, and a stray click that erased it left the user with no card to receive the
        // reply in and no way to tell whether anything was coming. So the wait survives a click
        // outside; the answer, the error and the hint all still close.
        switch model.phase {
        case .result, .status, .failed:
            model.dismiss(reason: "click outside the card")
            hide()
        case .thinking, .listening:
            Log.write("hud: click outside ignored while \(model.phase) — the wait stays on screen")
        case .idle:
            break
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

/// A borderless panel that can still become key, so its buttons take clicks without the app
/// activating.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
