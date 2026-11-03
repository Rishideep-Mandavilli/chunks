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
        panel.contentView = NSHostingView(rootView: CaptionView(model: model))
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
        panel.setValue(true, forKey: "_setPreventsActivation")
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
