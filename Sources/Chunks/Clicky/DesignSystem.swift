//
//  DesignSystem.swift
//  leanring-buddy
//
//  Centralized design system using a blue accent palette on dark surfaces,
//  with a unified button style system. All colors, button styles, and
//  interaction states are defined here as the single source of truth.
//

import ChunksKit
import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Ground and elevation ─────────────────────────────────────
        // A physical system reads depth two ways at once: a raised sheet is *lighter* than the
        // ground and carries a shadow, and a well is *darker* and carries an inner one. So "higher"
        // no longer means "lighter" everywhere — pressed is deliberately darker than hover, which is
        // what makes a row feel pushed rather than lit.

        /// The ground. Every window, panel and card sits on this.
        static let ground = Color(hex: Palette.ground)

        /// A sheet of paper — cards, the sidebar rail, the composer bar.
        static let raised = Color(hex: Palette.raised)

        /// A well cut into the paper: text fields, input wells.
        static let sunken = Color(hex: Palette.sunken)

        /// A row with the pointer over it.
        static let hover = Color(hex: Palette.hover)

        /// A row that is selected or being pressed.
        static let pressed = Color(hex: Palette.pressed)

        // ── Borders ──────────────────────────────────────────────────

        /// The hairline between two sheets. Decorative by WCAG's own reading: it is never the only
        /// thing identifying a control, so it is not held to 3:1.
        static let line = Color(hex: Palette.line)

        /// A stronger rule, for the edge of a well.
        static let lineStrong = Color(hex: Palette.lineStrong)

        /// The outline of a control you can act on.
        static let lineControl = Color(hex: Palette.lineControl)

        // ── Legacy names, kept because 26 call sites read them ───────
        // Aliases, not a second system: change a role and every view written against the dark
        // palette follows it. `background` is the ground; `surface1…4` are the elevations in the
        // old order.

        static var background: Color { ground }
        static var surface1: Color { raised }
        static var surface2: Color { sunken }
        static var surface3: Color { hover }
        static var surface4: Color { pressed }
        static var borderSubtle: Color { line }
        static var borderStrong: Color { lineStrong }

        // ── Ink ──────────────────────────────────────────────────────
        // Three weights of text and no more. The dark palette had a fourth grey for micro labels; it
        // measured 3.3:1 on bone, so it is gone rather than re-tuned — a label that has to be
        // squinted at is a label that should not be small and grey in the first place.

        /// Body text, titles, anything read for more than a glance. 16.5:1 on the ground.
        static let ink = Color(hex: Palette.ink)

        /// Detail and explanation. 8.3:1.
        static let inkMuted = Color(hex: Palette.inkMuted)

        /// Timestamps and meta at the smallest size the system uses. 4.8:1 measured on the *sunken*
        /// well, which is the hardest ground it appears on and the one that decides the value.
        static let inkFaint = Color(hex: Palette.inkFaint)

        /// Bone text on an ink object — the primary button's label. 12.1:1.
        static let onInk = Color(hex: Palette.onInk)

        static var textPrimary: Color { ink }
        static var textSecondary: Color { inkMuted }
        static var textTertiary: Color { inkFaint }

        /// Text on the activity blue. White measures 5.9:1; bone only reaches 3.9, which is a large
        /// text pass and not a body one.
        static let textOnAccent = Color(hex: Palette.onAccent)

        // The Tailwind blue ramp this file carried is deleted. All eleven steps were
        // unreferenced after the bone/ink swap, and a palette with two ways to say
        // "blue" is a palette where the next colour goes into the wrong one.

        // ── Activity, and the four states ────────────────────────────
        // Colour is state here and nothing else. The primary action is *not* one of them — it is an
        // ink object (see `action`), because in a physical system the thing you press is the darkest
        // thing on the surface, and saving blue for "work in flight" keeps the one saturated hue in
        // the app meaning exactly one thing.

        /// In-flight blue: the status dot, the meter, a link, a focus ring.
        static let accent = Color(hex: Palette.accent)

        /// Pressed/hover variant of the activity blue.
        static let accentHover = Color(hex: Palette.accentDeep)

        /// Accent used as text. Same value as the fill — on bone there is no need for a brighter
        /// variant, which is what the dark palette's `blue400` was compensating for.
        static let accentText = Color(hex: Palette.accent)

        /// A tint of the activity colour behind a selected row or a current step.
        ///
        /// Built from `Palette.accent` rather than a second copy of the hex: a value typed twice is
        /// a value that drifts, and this one already escaped the contrast suite once.
        static let accentSubtle = Color(hex: Palette.accent).opacity(0.10)

        /// The primary action's surface: ink. The label on it is `onInk`.
        static let action = Color(hex: Palette.action)

        /// A pressed primary action — the same object catching less light as it goes into the paper.
        static let actionHover = Color(hex: Palette.actionHover)

        /// Destructive — a turn that failed, and the rare delete.
        static let destructive = Color(hex: Palette.destructive)

        static let destructiveHover = Color(hex: Palette.destructiveDeep)

        /// Destructive as text: the darker step, because #b3261e on the sunken well is a 5.4 pass
        /// but on a pressed row it is not.
        static let destructiveText = Color(hex: Palette.destructiveDeep)

        /// Done. Independent of the activity blue so "finished" cannot be misread as "working".
        static let success = Color(hex: Palette.success)

        static let successText = Color(hex: Palette.successDeep)

        /// Waiting on him. #a86208 rather than the dark palette's #FFB224: an amber that bright
        /// disappears into bone at 2.8:1, and a dot nobody sees is not a state.
        static let warning = Color(hex: Palette.warning)

        static let warningText = Color(hex: Palette.warningDeep)



        // ── Overlay Cursor ───────────────────────────────────────────

        /// The blue the pointer trailer and its bubbles are drawn in.
        ///
        /// `Palette.cursorTrail`, and the reason it is in the palette file is that it is the one
        /// colour here with no fixed ground: it flies over other apps' windows, so no contrast pair
        /// can be asserted against it and a literal in this file would be invisible to every check.
        static let overlayCursorBlue = Color(hex: Palette.cursorTrail)

        // ── Disabled State ───────────────────────────────────────────
        // Following Material Design 3's disabled pattern:
        // Container: onSurface at 12% opacity
        // Content: onSurface at 38% opacity

        /// Disabled button/container background.
        static var disabledBackground: Color {
            ink.opacity(0.07)
        }

        /// Disabled text/icon color.
        static var disabledText: Color {
            ink.opacity(0.34)
        }
    }

    // MARK: - Dots Studio reskin (2026-10-30)

    /// The warm-paper language for the panel, the history window and the first-run guide.
    ///
    /// Parallel to `Colors`, not a replacement: the notch HUD reads `Colors.ground/raised/sunken`
    /// and is out of scope, so the three reskinned surfaces read these instead. Every value comes
    /// from `Palette.Dots`, which is where the contrast suite asserts them.
    enum Dots {
        static let paper = Color(hex: Palette.Dots.paper)
        static let raised = Color(hex: Palette.Dots.raised)
        static let sunken = Color(hex: Palette.Dots.sunken)
        static let hover = Color(hex: Palette.Dots.hover)
        static let pressed = Color(hex: Palette.Dots.pressed)
        static let line = Color(hex: Palette.Dots.line)
        static let lineStrong = Color(hex: Palette.Dots.lineStrong)
        static let ink = Color(hex: Palette.Dots.ink)
        static let hull = Color(hex: Palette.Dots.hull)

        /// The three measured fields. Grounds with ink on them — never marks on paper, never
        /// reversed. `Palette.Dots.fillOnlyFields` and the contrast suite hold that line.
        static let sea = Color(hex: Palette.Dots.sea)
        static let seaDeep = Color(hex: Palette.Dots.seaDeep)
        static let sky = Color(hex: Palette.Dots.sky)
        static let skyRail = Color(hex: Palette.Dots.skyRail)
        static let sand = Color(hex: Palette.Dots.sand)
        static let sandTag = Color(hex: Palette.Dots.sandTag)
        /// The control colour: toggle track, memory meter, the chosen thread's leading bar.
        static let teal = Color(hex: Palette.Dots.teal)
        /// The mockup's link blue — legal on every ground except sky.
        static let link = Color(hex: Palette.Dots.link)

        /// A **solid** edge, for a control. The mockups draw cards with a dashed rule and controls
        /// (the model pill, the section tags, the close button, the outer sheet) with a solid one;
        /// dashing everything made the controls read as decoration rather than as things to press.
        static var controlEdge: Color { Color(hex: Palette.Dots.ink).opacity(0.55) }
        static var sheetEdge: Color { Color(hex: Palette.Dots.ink).opacity(0.80) }

        /// The pen-hatch, measured off the reference image's sea: 2 px stroke on a 33 px pitch,
        /// 15 px dash with a 5 px gap, 1.6% ink coverage. Scaled ×0.5 into points (1 pt stroke,
        /// 16 pt pitch, 7.5 pt dash, 2.5 pt gap) and dropped to a very low opacity so it reads as
        /// paper grain, not a pattern. Drawn, not a bitmap: it survives a rebuild and scales with
        /// the view. Applied only to flat field fills.
        enum Hatch {
            static let pitch: CGFloat = 16
            static let dash: CGFloat = 7.5
            static let gap: CGFloat = 2.5
            static let lineWidth: CGFloat = 1
            static let opacity: Double = 0.05
        }

        /// The dashed rule — the reference's signature edge treatment. Decorative by WCAG's own
        /// reading (it is never the only thing identifying a control), so it is held to no ratio,
        /// but it is held to *one* value: six on, four off, one point, ink at a fifth. A dashed
        /// border drawn at three different weights across two surfaces is how the old panel ended
        /// up with five greys.
        enum Dash {
            static let lineWidth: CGFloat = 1
            static let on: CGFloat = 6
            static let off: CGFloat = 4
            static var style: StrokeStyle {
                StrokeStyle(lineWidth: lineWidth, dash: [on, off])
            }
            static var color: Color { Color(hex: Palette.Dots.ink).opacity(0.22) }
        }

        /// A cumulus band in sand, sitting on the bottom edge of a sky band.
        ///
        /// Drawn from a fixed bump-radius list rather than a random one, so the same panel renders
        /// the same clouds on every launch and every rebuild — a bitmap would not scale, and a
        /// seeded-by-time shape would make the surface flicker between runs.
        struct CloudBand: View {
            /// Radii in points, cycled along the baseline. Varied on purpose: equal bumps read as a
            /// gear, not a cloud.
            var radii: [CGFloat] = [22, 34, 15, 28, 40, 18, 31, 24]
            /// Horizontal squeeze, so the same band can be a wide header cloud or a narrow corner one.
            var squash: CGFloat = 1.0

            var body: some View {
                Canvas { context, size in
                    let base = size.height
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: base))
                    var x: CGFloat = 0
                    var index = 0
                    while x < size.width + 40 {
                        let r = radii[index % radii.count] * squash
                        path.addArc(center: CGPoint(x: x + r, y: base), radius: r,
                                    startAngle: .degrees(180), endAngle: .degrees(0),
                                    clockwise: false)
                        x += 2 * r
                        index += 1
                    }
                    path.addLine(to: CGPoint(x: size.width, y: base))
                    path.closeSubpath()
                    context.fill(path, with: .color(Color(hex: Palette.Dots.sand)))
                }
                .allowsHitTesting(false)
            }
        }

        /// A card on the nautical ground: one field or paper fill, a dashed edge, and the hatch
        /// riding the flat fill. Used by the panel and the window; never by the notch card.
        struct DotsCard: ViewModifier {
            var fill: Color
            var radius: CGFloat = DS.CornerRadius.large
            var hatched: Bool = true

            func body(content: Content) -> some View {
                content
                    .background(fill)
                    .overlay {
                        if hatched {
                            DS.Dots.HatchPattern()
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Dash.color, style: Dash.style))
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
        }

        /// The hatch as a vector overlay. Alternate rows are offset half a period so the dashes do
        /// not stack into columns, which is what makes it read as hand-hatching rather than a grid.
        struct HatchPattern: View {
            var body: some View {
                Canvas { context, size in
                    let ink = Color(hex: Palette.Dots.ink).opacity(Hatch.opacity)
                    var y = Hatch.pitch / 2
                    var row = 0
                    while y < size.height {
                        var x = row.isMultiple(of: 2) ? 0 : (Hatch.dash + Hatch.gap) / 2
                        while x < size.width {
                            let rect = CGRect(x: x, y: y,
                                              width: Hatch.dash, height: Hatch.lineWidth)
                            context.fill(Path(rect), with: .color(ink))
                            x += Hatch.dash + Hatch.gap
                        }
                        y += Hatch.pitch
                        row += 1
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Spacing (for reference, not enforced)

    /// The panel's type voices, named once.
    ///
    /// There were none, so every row typed its own point size and the panel ended up with 10, 11,
    /// 12, 13 and 14 pt text in no order — four weights of the same label, none of them chosen.
    /// Four voices is the whole vocabulary: what a panel is called, what a control is called, what
    /// the row's own explanation says, and the counter or key in the corner.
    enum Fonts {
        static let headline = Font.system(size: 14, weight: .semibold)
        static let label = Font.system(size: 12, weight: .medium)
        static let meta = Font.system(size: 11)
        static let micro = Font.system(size: 10, weight: .medium)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii

    enum CornerRadius {
        /// Small elements like tags and badges.
        static let small: CGFloat = 8
        /// Buttons, input fields, rows.
        static let medium: CGFloat = 12
        /// Cards, dialogs, chat bubbles.
        static let large: CGFloat = 16
        /// Large panels — the notch card, the window's sheets.
        static let extraLarge: CGFloat = 20
        /// Pill-shaped buttons (the continue button).
        static let pill: CGFloat = .infinity
    }

    // MARK: - Animation Durations

    /// Durations, kept as numbers because the call sites compose them into `.easeOut(...)` and
    /// `.linear(...)`. The *shape* of the motion lives in `DS.Motion`.
    enum Animation {
        /// Quick state changes — hover in/out, press feedback.
        static let fast: Double = 0.15
        /// Standard transitions — content reveal, button state changes.
        static let normal: Double = 0.25
        /// Slower, more dramatic — fade-ins, celebration screen elements.
        static let slow: Double = 0.4
    }

    // MARK: - Motion

    /// Springs, because a physical object does not ease out of a move — it settles into one.
    ///
    /// `SwiftUI.Animation` spelled out, because inside `DS` the bare name resolves to the
    /// duration enum above.
    ///
    /// The reference's knob runs `{stiffness: 380, damping: 40}`: quick, with a hint of overshoot.
    /// SwiftUI's `response`/`dampingFraction` pair is a different parameterisation of the same
    /// curve, and these are the values that match it closely enough to feel the same under a finger.
    enum Motion {
        /// A press, a hover, a toggle. Fast enough to feel connected to the click.
        static let tap = SwiftUI.Animation.spring(response: 0.22, dampingFraction: 0.72)
        /// A row selecting, a sheet arriving.
        static let settle = SwiftUI.Animation.spring(response: 0.32, dampingFraction: 0.72)
        /// The card growing out of the notch.
        static let unfold = SwiftUI.Animation.spring(response: 0.45, dampingFraction: 0.80)
    }

    // MARK: - Elevation

    /// The two-layer shadow that makes a sheet look like an object.
    ///
    /// One tight dark shadow reads as contact with the surface; one wide soft one reads as height
    /// above it. Either alone looks like a screenshot effect — the contact shadow without the lift
    /// is a sticker, and the lift without the contact is a hover state that never ends.
    enum Shadow {
        /// The tight layer: `0 1px 2px rgba(0,0,0,.04)`.
        static let contactColor = Color.black.opacity(0.05)
        static let contactRadius: CGFloat = 1
        static let contactY: CGFloat = 1

        /// The lift layer: `0 10px 24px -14px rgba(0,0,0,.22)`. SwiftUI has no negative spread, so
        /// the radius carries it: a wide, low-opacity blur offset well below the sheet.
        static let liftColor = Color.black.opacity(0.14)
        static let liftRadius: CGFloat = 12
        static let liftY: CGFloat = 7

        /// A pressed object sits lower, so it throws less.
        static let pressedLiftColor = Color.black.opacity(0.08)
        static let pressedLiftRadius: CGFloat = 5
        static let pressedLiftY: CGFloat = 2

        /// The top edge of a sheet catches light. Without it a raised rectangle reads as a flat
        /// colour change rather than an object with thickness.
        static let edgeHighlight = Color.white.opacity(0.75)
    }

    // MARK: - State Layer Opacities
    // Based on Material Design 3's state layer system.
    // A "state layer" overlays the button's content color at these opacities.

    enum StateLayer {
        /// Hover: subtle highlight to indicate interactivity.
        static let hover: Double = 0.08
        /// Focus: keyboard navigation indicator (slightly stronger than hover).
        static let focus: Double = 0.12
        /// Pressed: active press feedback (same strength as focus).
        static let pressed: Double = 0.12
        /// Dragged: strongest overlay (rarely used).
        static let dragged: Double = 0.16
    }
}

// MARK: - Button Styles
/// The primary action: an ink object pressed into the paper.
///
/// Not blue. In a physical system the thing you push is the darkest thing on the surface, and
/// saving the activity blue for "work in flight" keeps the one saturated colour in the app meaning
/// exactly one thing.
///
/// The dark palette's version swelled to 1.03 on hover and breathed a coloured glow on a 2.5 s loop
/// while the pointer sat on it. Both are gone: motion here has a cause. Hover darkens the object a
/// step, press sinks it — less shadow, one point down, on a spring — and nothing moves on its own.
struct DSPrimaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(DS.Colors.onInk)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 11)
            .padding(.horizontal, isFullWidth ? 0 : 18)
            .physical(pressed ? DS.Colors.actionHover
                              : (isHovered ? DS.Colors.actionHover : DS.Colors.action),
                      radius: DS.CornerRadius.medium,
                      elevation: pressed ? .pressed : .raised,
                      edge: DS.Colors.ink)
            .offset(y: pressed ? 1 : 0)
            .animation(DS.Motion.tap, value: pressed)
            .animation(DS.Motion.tap, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// Secondary button — supporting actions, less visual weight than primary.
/// Surface-colored background with primary text. Used for: action buttons
/// (download, open link), embedded element buttons.
struct DSSecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(DS.Motion.tap, value: configuration.isPressed)
            .animation(DS.Motion.tap, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}

/// Tertiary/ghost button — low-emphasis actions with subtle hover background.
/// Transparent at rest, shows surface fill on hover. Used for: navigation
/// links, sidebar items, medium-low emphasis actions.
struct DSTertiaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.accentHover
                    : isHovered
                        ? DS.Colors.accentText
                        : DS.Colors.textSecondary
            )
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(DS.Motion.tap, value: configuration.isPressed)
            .animation(DS.Motion.tap, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return Color.clear
        }
    }
}

/// Text button — the lowest-emphasis button style. No background on any
/// state, not even hover. Only the text color changes. Used for: "restart",
/// "skip", "cancel", and other truly minimal inline actions where a
/// background would add too much visual weight.
struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 14

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textTertiary
            )
            .animation(DS.Motion.tap, value: configuration.isPressed)
            .animation(DS.Motion.tap, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// Outlined button — medium emphasis, used where a border helps define
/// the button's bounds. Used for: display selector, copy prompt.
struct DSOutlinedButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(DS.Motion.tap, value: configuration.isPressed)
            .animation(DS.Motion.tap, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return DS.Colors.surface1
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle
        }
    }
}

/// Destructive button — for dangerous/irreversible actions (close session, delete).
/// Red-tinted background that intensifies on hover and press.
struct DSDestructiveButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            // Was `.white` while hovered or pressed. The fill is `destructive.opacity(0.30)` over
            // bone, so white measured ~1.6:1 — the label disappeared exactly when he was aiming at
            // it. The destructive *text* step is the one that survives both fills.
            .foregroundColor(DS.Colors.destructiveText)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(DS.Motion.tap, value: configuration.isPressed)
            .animation(DS.Motion.tap, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.destructive.opacity(0.40)
        } else if isHovered {
            return DS.Colors.destructive.opacity(0.30)
        } else {
            return DS.Colors.destructive.opacity(0.10)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.destructive.opacity(0.40)
        } else {
            return DS.Colors.destructive.opacity(0.15)
        }
    }
}

/// Icon-only button — compact circular button for utility actions.
/// Used for: close button (x), send message, small toolbar actions.
struct DSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isDestructiveOnHover: Bool = false
    var tooltipText: String? = nil

    /// Controls horizontal alignment of the tooltip relative to the button.
    /// Use `.leading` for buttons near the left edge of the window (tooltip extends right),
    /// `.trailing` for buttons near the right edge (tooltip extends left),
    /// and `.center` for buttons in the middle.
    var tooltipAlignment: Alignment = .center

    @State private var isHovered = false
    @State private var isTooltipVisible = false
    @State private var tooltipShowWorkItem: DispatchWorkItem? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundColor(iconColor(isPressed: configuration.isPressed))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(circleBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Circle()
                    .stroke(circleBorderColor(isPressed: configuration.isPressed), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(DS.Motion.tap, value: configuration.isPressed)
            .animation(DS.Motion.tap, value: isHovered)
            .contentShape(Circle())
            // Cursor change via AppKit cursor rects — more reliable than NSCursor.push/pop
            // because cursor rects are managed at the window level and don't conflict
            // with SwiftUI's internal cursor handling.
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
                // Show the tooltip after a delay (like native tooltips), hide immediately
                tooltipShowWorkItem?.cancel()
                if hovering {
                    let workItem = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isTooltipVisible = true
                        }
                    }
                    tooltipShowWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        isTooltipVisible = false
                    }
                }
            }
            // Custom styled tooltip — positioned above the button with enough gap
            // to not overlap the button. Horizontally aligned based on tooltipAlignment
            // so tooltips near window edges don't clip outside the visible area.
            // Uses .allowsHitTesting(false) so the tooltip doesn't interfere
            // with the button's hover state.
            .overlay(
                Group {
                    if isTooltipVisible, let text = tooltipText, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            // Was a glass tooltip: a translucent dark fill with two white hairlines
                            // and a 42%-black blur. Every one of those layers is invisible on bone, so
                            // the tooltip now uses the same material as everything else that lifts off
                            // the paper — and it is opaque, because a tooltip that lets the desktop
                            // through it is unreadable wherever it lands.
                            .physical(DS.Colors.raised, radius: DS.CornerRadius.small,
                                      elevation: .raised)
                            .fixedSize()
                            .offset(y: -(size / 2 + 20))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                },
                alignment: tooltipAlignment
            )
    }

    private func iconColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            // The fill goes solid red under it, so the icon is bone-on-ink rather than the white
            // that only ever worked on the dark palette's opaque red.
            return DS.Colors.onInk
        }
        if isPressed {
            return DS.Colors.textPrimary
        } else if isHovered {
            return DS.Colors.textPrimary
        } else {
            return DS.Colors.textSecondary
        }
    }

    private func circleBackgroundColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover {
            if isPressed {
                return DS.Colors.destructive.opacity(0.40)
            } else if isHovered {
                return DS.Colors.destructive.opacity(0.30)
            } else {
                return DS.Colors.surface2
            }
        }
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }

    private func circleBorderColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return DS.Colors.destructive.opacity(0.30)
        }
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle.opacity(0.5)
        }
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// Applies the primary button style (accent-colored CTA).
    func dsPrimaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSPrimaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the secondary button style (surface-colored supporting action).
    func dsSecondaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSSecondaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the tertiary/ghost button style (subtle hover background).
    func dsTertiaryButtonStyle() -> some View {
        self.buttonStyle(DSTertiaryButtonStyle())
    }

    /// Applies the text-only button style (no background ever, just color change).
    func dsTextButtonStyle(fontSize: CGFloat = 14) -> some View {
        self.buttonStyle(DSTextButtonStyle(fontSize: fontSize))
    }

    /// Applies the outlined button style (bordered, medium emphasis).
    func dsOutlinedButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSOutlinedButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the destructive button style (red-tinted danger action).
    func dsDestructiveButtonStyle() -> some View {
        self.buttonStyle(DSDestructiveButtonStyle())
    }

    /// Applies the icon-only button style (compact circle).
    /// `tooltipAlignment` controls where the tooltip sits horizontally relative to the button:
    /// `.leading` for left-edge buttons, `.trailing` for right-edge buttons, `.center` for middle.
    func dsIconButtonStyle(size: CGFloat = 28, isDestructiveOnHover: Bool = false, tooltip: String? = nil, tooltipAlignment: Alignment = .center) -> some View {
        self.buttonStyle(DSIconButtonStyle(size: size, isDestructiveOnHover: isDestructiveOnHover, tooltipText: tooltip, tooltipAlignment: tooltipAlignment))
    }

    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - I-Beam Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show an I-beam (text selection) cursor.
/// Same approach as PointerCursorView — cursor rects are managed at the window level
/// and don't conflict with SwiftUI's internal cursor handling.
/// Unlike NSCursor.push()/pop() in .onHover, this avoids cursor stack imbalance
/// when the mouse moves quickly between views.
private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Pass through all mouse events so the TextField underneath still receives
    /// focus, clicks, and text selection. Cursor rects are registered with the
    /// window (via resetCursorRects) and work independently of hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return IBeamCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Native Tooltip

/// Uses AppKit's `NSView.toolTip` to show a tooltip on hover.
/// SwiftUI's `.help()` conflicts with `.onHover` tracking areas, so
/// this bridges directly to AppKit's tooltip system which works independently.
private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    /// Attaches a native macOS tooltip that works even alongside `.onHover`.
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }

    /// The dots pen-hatch over a flat field fill. Only ever applied to a solid `DS.Dots` field —
    /// never over text, never over the notch card.
    func dotsHatched() -> some View {
        overlay(DS.Dots.HatchPattern())
    }
}

// MARK: - Color Utilities

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// Returns a lighter version of this color by blending toward white.
    /// `fraction` is 0.0 (no change) to 1.0 (pure white).
    func blendedWithWhite(fraction: Double) -> Color {
        // Convert to NSColor to access RGB components for blending
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }
}

// MARK: - Nautical surface helpers

extension View {
    /// Wraps a block in the dots card treatment: a fill, the hatch, and one dashed edge.
    func dotsCard(_ fill: Color, radius: CGFloat = DS.CornerRadius.large,
                  hatched: Bool = true) -> some View {
        modifier(DS.Dots.DotsCard(fill: fill, radius: radius, hatched: hatched))
    }

    /// A dashed edge on its own, for a block that already carries its own fill.
    func dotsDashBorder(radius: CGFloat = DS.CornerRadius.large) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(DS.Dots.Dash.color, style: DS.Dots.Dash.style))
    }

    /// A solid edge, for a control or the outer sheet. Cards are dashed; the things you press are
    /// not — that distinction is what the mockups draw and what the first all-dashed pass lost.
    func dotsSolidBorder(radius: CGFloat = DS.CornerRadius.small,
                         _ color: Color = DS.Dots.controlEdge,
                         width: CGFloat = 1) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(color, lineWidth: width))
    }
}

/// A dashed rule — the separator between rows and between the footer's three actions on the
/// nautical surfaces. A `Divider` is a solid hairline, and one solid rule inside an all-dashed
/// sheet reads as a different system.
struct DotsDashRule: View {
    var vertical: Bool = false

    var body: some View {
        Canvas { context, size in
            var path = Path()
            if vertical {
                path.move(to: CGPoint(x: size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            } else {
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }
            context.stroke(path, with: .color(DS.Dots.Dash.color), style: DS.Dots.Dash.style)
        }
        .frame(width: vertical ? DS.Dots.Dash.lineWidth : nil,
               height: vertical ? nil : DS.Dots.Dash.lineWidth)
        .allowsHitTesting(false)
    }
}
