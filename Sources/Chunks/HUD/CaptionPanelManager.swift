import AppKit
import ChunksKit
import SwiftUI

/// The caption window: Chunks' own words, at the bottom of the screen, while it speaks.
///
/// Three rules, all of them inherited from the lesson the annotation overlay cost eleven rounds to
/// learn — that **keyboard follows key-window status and mouse follows app activation**, and that a
/// surface of an app which never activates can be frontmost over a point and still never receive a
/// click. A caption is the opposite of that overlay: it must receive *nothing*. It is a thing you read
/// while you keep working, so:
///
/// - **it never activates the app** — `_setPreventsActivation` is set to true, and `NSApp.activate` is
///   not called anywhere in this file. A caption that raised Chunks would take the menu bar away from
///   the app he is in, mid-sentence, which is the exact behaviour the overlay was rebuilt to stop.
/// - **it is click-through** — `ignoresMouseEvents`, so a click at the caption lands on whatever is
///   behind it. A caption that ate a click would be a new way to lose work.
/// - **it sits above the Dock, not behind it** — placed inside `visibleFrame`, because a caption the
///   Dock covers is a caption that silently stopped working on the machines with the Dock at the bottom.
///
/// The window is created once and ordered in and out, rather than rebuilt per sentence: a caption that
/// flickers because a new panel is constructed for every clause is worse than no caption, and it makes
/// the screen jump while he is reading it.
@MainActor
final class CaptionPanelManager {

    /// How far above the usable bottom edge the caption sits.
    static let bottomGap: CGFloat = 28
    static let maxWidth: CGFloat = 720

    private var panel: NSPanel?
    private let model = CaptionModel()

    /// Show one sentence, shaped by `CaptionLine`. Nil or empty hides it.
    func show(_ text: String) {
        guard let line = CaptionLine.shaped(text) else {
            hide()
            return
        }
        model.text = line
        guard let screen = NSScreen.main else { return }
        let panel = ensurePanel()
        // The hosting view is built once, in `ensurePanel`; a new one per sentence is the flicker
        // this file's own header promises against (AUDIT.md E-06). `CaptionView` observes the model,
        // so the words above are all that changes here.
        position(panel, on: screen)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        model.text = ""
        panel?.orderOut(nil)
    }

    /// Whether a caption is on screen. Used by the render probe and by the safety contract.
    var isShowing: Bool { panel?.isVisible == true }

    /// The measured state of the private flag on the live panel.
    ///
    /// Read back rather than trusted, because this app's own safety contract asserted a property that
    /// the code setting it had in fact never applied — the call threw an `NSUnknownKeyException` first,
    /// AppKit swallowed it, and the gate's grep passed either way. A property this load-bearing is only
    /// worth having if something runs the surface and asks it.
    var measuredPreventsActivation: Bool? {
        guard let panel else { return nil }
        return Self.preventsActivationFlag(panel)
    }

    /// The other three properties of this surface, read off the live panel rather than off the file.
    var measuredIgnoresMouseEvents: Bool? { panel?.ignoresMouseEvents }
    var measuredCanBecomeKey: Bool? { (panel as? CaptionPanel)?.canBecomeKey }

    /// Asking a private getter for a `Bool` without letting `perform` reinterpret a scalar as a
    /// pointer. `perform(_:)` hands back an `Unmanaged` wrapping the *value*, and taking that
    /// unretained faults — measured here with exit 139 — so the IMP is called through its real C
    /// signature instead.
    static func preventsActivationFlag(_ panel: NSPanel) -> Bool? {
        let selector = NSSelectorFromString("_preventsActivation")
        guard panel.responds(to: selector),
              let imp = class_getMethodImplementation(type(of: panel), selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: Getter.self)(panel, selector)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = CaptionPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.maxWidth, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        // Below the notch card and the panel, above ordinary windows: the caption is a restatement of
        // what those already say, and it must never cover a question he has to answer.
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The one line that keeps this app's menu bar from changing hands. Not public API, and the
        // only reason the overlay works at all — see `AGENTS.md`.
        //
        // It used to be `panel.setValue(true, forKey: "_setPreventsActivation")`, and that call
        // **raises `NSUnknownKeyException`** — measured on this machine: KVC looks for a key, and
        // `_setPreventsActivation` is a setter name, so `-[NSObject setValue:forKey:]` falls through
        // to `setValue:forUndefinedKey:` and throws. Two things followed, and both were invisible:
        // the value never landed, so this surface's central property has never actually been set;
        // and the throw unwound through the Swift Concurrency frames of the job that called it
        // (`speakCaptioned` → `captions.show`), where AppKit's run loop swallowed it and resumed.
        // That is the poison behind the SIGSEGVs: the thread-local "current executor" slot is left
        // holding garbage, and the next `MainActor.assumeIsolated` SwiftUI performs — in a hit test,
        // a hover dispatch or a button gesture — dereferences it and dies in `swift_getObjectType`.
        // Every one of the four real crash reports on 2026-11-04 carries AppKit's own marker for a
        // swallowed exception, and none of the deliberate `--probe-crash` reports does.
        let preventsActivation = NSSelectorFromString("_setPreventsActivation:")
        if panel.responds(to: preventsActivation) {
            panel.perform(preventsActivation, with: NSNumber(value: true))
        }
        // Said out loud once per process, because the last time this line was wrong the only evidence
        // was four crash reports and a green gate.
        if Self.preventsActivationFlag(panel) != true {
            Log.write("caption: prevents-activation did NOT land on the panel — this surface can "
                      + "take the menu bar, and the call that sets it may have thrown")
            Log.flush()
        }
        // Built once, here, and never again: the panel is reused across sentences and so is its
        // content view, which observes `model` for the words (AUDIT.md E-06).
        panel.contentView = NSHostingView(rootView: CaptionView(model: model))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let width = min(Self.maxWidth, visible.width - 48)
        let height: CGFloat = 60
        panel.setFrame(NSRect(x: visible.midX - width / 2,
                              y: visible.minY + Self.bottomGap,
                              width: width, height: height),
                       display: true)
    }
}

/// A panel that can never become key or main. `canBecomeKey` false is the half that keeps focus where
/// it is; the rest is done by `_setPreventsActivation` and `ignoresMouseEvents` above.
@MainActor
final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CaptionModel: ObservableObject {
    @Published var text: String = ""
}

struct CaptionView: View {
    @ObservedObject var model: CaptionModel

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(model.text)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(DS.Colors.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.ground)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .strokeBorder(DS.Colors.line, lineWidth: 0.5)
                        )
                        .shadow(color: DS.Shadow.contactColor, radius: DS.Shadow.contactRadius,
                                x: 0, y: DS.Shadow.contactY)
                        .shadow(color: DS.Shadow.liftColor, radius: DS.Shadow.liftRadius,
                                x: 0, y: DS.Shadow.liftY)
                )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityLabel("Chunks is saying")
        .accessibilityValue(model.text)
    }
}
