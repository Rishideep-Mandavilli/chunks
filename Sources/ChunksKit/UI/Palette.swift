import Foundation

/// The physical bone/ink palette, as hex strings.
///
/// Here rather than only inside `DS` because a colour has to be checkable to be trusted, and the
/// test target links the logic layer, not the UI one. `DS.Colors` builds every `Color` from these
/// constants, so the numbers the contrast suite asserts are the numbers the app draws — a palette
/// duplicated between a token file and a test file is a palette that drifts.
///
/// The language: one ground, paper that lifts off it, wells that sink into it, hairlines between
/// them, and ink for everything that must be read. Saturated colour is reserved for state.
public enum Palette {

    // MARK: Ground and elevation
    public static let ground = "#f5f4f0"
    public static let raised = "#fbfaf7"
    public static let sunken = "#eceae4"
    public static let hover = "#efece6"
    public static let pressed = "#e2dfd7"

    // MARK: Lines
    public static let line = "#dedbd3"
    public static let lineStrong = "#c9c5ba"
    public static let lineControl = "#847f74"

    // MARK: Ink
    public static let ink = "#161614"
    public static let inkMuted = "#4a4842"
    public static let inkFaint = "#68655d"
    public static let onInk = "#d6d3cc"
    public static let onAccent = "#ffffff"

    // MARK: State
    public static let accent = "#2a5bd7"
    public static let accentDeep = "#1f4bb8"

    /// The pointer trailer's blue, and the only colour in this file that is not drawn on our own
    /// paper. It flies over *other* apps — a dark IDE, a white document — where `accent` disappears,
    /// so it is a step brighter. It cannot carry a contrast pair, because the ground is somebody
    /// else's window; the glow around it is what makes it readable on either.
    public static let cursorTrail = "#3380FF"
    public static let action = "#161614"
    public static let actionHover = "#24241f"
    public static let destructive = "#b3261e"
    public static let destructiveDeep = "#8f1d16"
    public static let success = "#1a7f4b"
    public static let successDeep = "#14603a"
    public static let warning = "#a86208"
    public static let warningDeep = "#8a5300"

    /// The pairs a user reads, as the app actually combines them.
    ///
    /// Each one is a place a colour is used, not a theoretical combination — which is why
    /// `inkFaint` is checked against `sunken` rather than the ground. It is the smallest text in the
    /// system and it sits in the composer well, the hardest surface it appears on, and a value that
    /// passes on paper and fails in a well is a value that fails.
    public static let textPairs: [ColorContrast.Pair] = [
        ColorContrast.Pair("ink on ground", ink, on: ground),
        ColorContrast.Pair("ink on raised", ink, on: raised),
        ColorContrast.Pair("ink on sunken", ink, on: sunken),
        ColorContrast.Pair("ink on pressed", ink, on: pressed),
        ColorContrast.Pair("inkMuted on ground", inkMuted, on: ground),
        ColorContrast.Pair("inkMuted on raised", inkMuted, on: raised),
        ColorContrast.Pair("inkMuted on sunken", inkMuted, on: sunken),
        ColorContrast.Pair("inkFaint on ground", inkFaint, on: ground),
        ColorContrast.Pair("inkFaint on raised", inkFaint, on: raised),
        ColorContrast.Pair("inkFaint on sunken", inkFaint, on: sunken),
        ColorContrast.Pair("onInk on action", onInk, on: action),
        ColorContrast.Pair("onInk on actionHover", onInk, on: actionHover),
        ColorContrast.Pair("onAccent on accent", onAccent, on: accent),
        ColorContrast.Pair("accent as text on ground", accent, on: ground),
        ColorContrast.Pair("accent as text on raised", accent, on: raised),
        ColorContrast.Pair("warningText on ground", warningDeep, on: ground),
        ColorContrast.Pair("destructiveText on ground", destructiveDeep, on: ground),
        ColorContrast.Pair("successText on ground", successDeep, on: ground),
        ColorContrast.Pair("ink on hover", ink, on: hover),
    ]

    /// The non-text marks whose state he has to read: dots, bars, rules that mean something.
    public static let graphicPairs: [ColorContrast.Pair] = [
        ColorContrast.Pair("activity dot", accent, on: ground, graphic: true),
        ColorContrast.Pair("waiting dot", warning, on: ground, graphic: true),
        ColorContrast.Pair("failed dot", destructive, on: ground, graphic: true),
        ColorContrast.Pair("done dot", success, on: ground, graphic: true),
        ColorContrast.Pair("meter bar", accent, on: ground, graphic: true),
        ColorContrast.Pair("control outline on the well", lineControl, on: sunken, graphic: true),
        ColorContrast.Pair("control outline on the ground", lineControl, on: ground, graphic: true),
    ]

    // MARK: - Dots Studio reskin (2026-10-30)

    /// The warm-paper language for the menu-bar panel, the history window and the first-run guide.
    ///
    /// A *parallel* set, deliberately: the notch HUD card reads `ground`/`raised`/`sunken`/`line`
    /// above and is out of scope for this reskin, so mutating those would recolour it. These tokens
    /// are read only by the three surfaces that moved, through `DS.Colors.dots…`.
    ///
    /// The three fields and the ink were **measured from the reference image**, not eyeballed:
    /// sea #B3E5DB (274,700 px), sky #A7BCFA (186,891 px), sand #FAE1AF (100,579 px),
    /// ink #1A1A1A (the hatch). Paper #F5F4EF is the sail-cloth tone, cross-checked against the
    /// live site's own ground #F5F4F1. The elevations below are *derived* from that paper by the
    /// same lift/press rule the bone system uses, and are labelled as such.
    public enum Dots {
        // Measured off the two skin mockups he supplied (patch modes and hue-family modes, not
        // eyeballed). The mockups disagree with each other and with the original sailboat reference
        // — they are generated art — so each surface takes the value its own mockup shows, and the
        // two seas and two skies are deliberate, not drift.
        public static let sea = "#C7EDE7"      // panel ground, routines card, footer
        public static let seaDeep = "#A6E3D9"  // window question wells, chosen thread
        public static let sky = "#A2C0FD"      // panel header band, section tags
        public static let skyRail = "#BDD1FC"  // window sidebar
        public static let sand = "#FAEBD1"     // privacy copy, memory header, setup bands
        public static let sandTag = "#FDD99C"  // the MEMORY tag itself
        public static let ink = "#16181C"
        public static let hull = "#583629"
        public static let paper = "#F7F3E9"
        /// The toggle track, the memory meter and the chosen thread's leading bar. A control colour,
        /// not a field: it clears 3:1 on paper and sand and fails on every sea and sky, so it is
        /// never a mark on a field.
        public static let teal = "#1B9794"
        /// The mockup's link blue. Saturated enough to clear 4.5:1 on every ground except sky
        /// (4.21 there), which is why a link on sky is ink.
        public static let link = "#0038E8"

        // Derived elevations — paper lifted toward white, pressed toward ink.
        public static let raised = "#FCF9F2"
        public static let sunken = "#EFEAE0"
        public static let hover = "#F2EDE3"
        public static let pressed = "#E7E1D5"
        public static let line = "#DED8CB"
        public static let lineStrong = "#C9C2B2"

        /// The fields are grounds, not marks. Each carries ink text legally (9.3–13.6:1) but none
        /// reaches the 3:1 graphic floor on paper, so a sea/sky/sand dot or bar on paper is invisible
        /// to the contrast rule and is forbidden. Asserted as a limitation, not nudged into a pass.
        public static let fillOnlyFields = [sea, sky, sand]

        public static let textPairs: [ColorContrast.Pair] = [
            ColorContrast.Pair("dots ink on paper", ink, on: paper),
            ColorContrast.Pair("dots ink on raised", ink, on: raised),
            ColorContrast.Pair("dots ink on sunken", ink, on: sunken),
            ColorContrast.Pair("dots ink on hover", ink, on: hover),
            ColorContrast.Pair("dots ink on pressed", ink, on: pressed),
            ColorContrast.Pair("dots muted on paper", inkMuted, on: paper),
            ColorContrast.Pair("dots muted on raised", inkMuted, on: raised),
            ColorContrast.Pair("dots muted on sunken", inkMuted, on: sunken),
            ColorContrast.Pair("dots faint on paper", inkFaint, on: paper),
            ColorContrast.Pair("dots faint on raised", inkFaint, on: raised),
            ColorContrast.Pair("dots faint on sunken", inkFaint, on: sunken),
            ColorContrast.Pair("dots faint on hover", inkFaint, on: hover),
            // The fields. With the mockups' lighter values, ink *and* muted clear on all six —
            // 9.73–16.04 and 5.00–8.25 — which the darker first-pass palette could not manage.
            ColorContrast.Pair("dots ink on sea", ink, on: sea),
            ColorContrast.Pair("dots ink on seaDeep", ink, on: seaDeep),
            ColorContrast.Pair("dots ink on sky", ink, on: sky),
            ColorContrast.Pair("dots ink on skyRail", ink, on: skyRail),
            ColorContrast.Pair("dots ink on sand", ink, on: sand),
            ColorContrast.Pair("dots ink on sandTag", ink, on: sandTag),
            ColorContrast.Pair("dots muted on sea", inkMuted, on: sea),
            ColorContrast.Pair("dots muted on seaDeep", inkMuted, on: seaDeep),
            ColorContrast.Pair("dots muted on sky", inkMuted, on: sky),
            ColorContrast.Pair("dots muted on skyRail", inkMuted, on: skyRail),
            ColorContrast.Pair("dots muted on sand", inkMuted, on: sand),
            ColorContrast.Pair("dots muted on sandTag", inkMuted, on: sandTag),
            ColorContrast.Pair("dots faint on sea", inkFaint, on: sea),
            ColorContrast.Pair("dots faint on sand", inkFaint, on: sand),
            // The mockup's own link blue, legal everywhere it is used. Sky is the one exception.
            ColorContrast.Pair("dots link on paper", link, on: paper),
            ColorContrast.Pair("dots link on raised", link, on: raised),
            ColorContrast.Pair("dots link on sea", link, on: sea),
            ColorContrast.Pair("dots link on seaDeep", link, on: seaDeep),
            ColorContrast.Pair("dots link on skyRail", link, on: skyRail),
            ColorContrast.Pair("dots link on sand", link, on: sand),
            ColorContrast.Pair("dots link on sandTag", link, on: sandTag),
            ColorContrast.Pair("dots hull on paper", hull, on: paper),
            ColorContrast.Pair("dots hull on sea", hull, on: sea),
            ColorContrast.Pair("dots hull on sky", hull, on: sky),
            ColorContrast.Pair("dots hull on sand", hull, on: sand),
        ]

        /// Pairs that must **stay** illegal, asserted so nobody reintroduces them by reaching for the
        /// usual token. Faint clears on paper, sea and sand but not on the two skies, the deep sea or
        /// the strong sand tag; the link blue clears everywhere except sky; teal is a control fill
        /// and is not a mark on any field.
        public static let illegalOnFields: [ColorContrast.Pair] = [
            ColorContrast.Pair("faint on sky", inkFaint, on: sky),
            ColorContrast.Pair("faint on skyRail", inkFaint, on: skyRail),
            ColorContrast.Pair("faint on seaDeep", inkFaint, on: seaDeep),
            ColorContrast.Pair("faint on sandTag", inkFaint, on: sandTag),
            ColorContrast.Pair("link on sky", link, on: sky),
            ColorContrast.Pair("teal mark on sea", teal, on: sea),
            ColorContrast.Pair("teal mark on sky", teal, on: sky),
        ]

        public static let graphicPairs: [ColorContrast.Pair] = [
            ColorContrast.Pair("dots activity dot", accent, on: paper, graphic: true),
            ColorContrast.Pair("dots waiting dot", warning, on: paper, graphic: true),
            ColorContrast.Pair("dots failed dot", destructive, on: paper, graphic: true),
            ColorContrast.Pair("dots done dot", success, on: paper, graphic: true),
            ColorContrast.Pair("dots hull mark", hull, on: paper, graphic: true),
            // The toggle track, the meter and the chosen thread's bar. Legal on the paper cards and
            // the sand header; `illegalOnFields` holds the other half of that rule.
            ColorContrast.Pair("dots toggle track", teal, on: paper, graphic: true),
            ColorContrast.Pair("dots meter on raised", teal, on: raised, graphic: true),
            ColorContrast.Pair("dots meter on sand", teal, on: sand, graphic: true),
            ColorContrast.Pair("dots control outline on well", lineControl, on: sunken, graphic: true),
            ColorContrast.Pair("dots control outline on ground", lineControl, on: paper, graphic: true),
        ]
    }
}
