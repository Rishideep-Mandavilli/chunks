# Design

<!-- impeccable:design-schema 1 -->

Rewritten on 2026-10-23 for the physical bone/ink language, taken from the Ovio component library's
"physical" morphology (`ovioui.vercel.app`, MIT — the values and the recipe, ported; no code and no
art came across). The dark palette this replaces was inherited from clicky and had never been
chosen; this one is, and every colour in it is measured.

## Where the truth lives

| Thing | File |
|---|---|
| The palette, as hex strings | `Sources/ChunksKit/UI/Palette.swift` |
| The dots warm-paper tokens + the three fields | `Palette.Dots`, wired through `DS.Dots` |
| The drawn pen-hatch | `DS.Dots.HatchPattern`, applied with `.dotsHatched()` |
| Spacing, radius, elevation, motion, font tokens | `Sources/Chunks/Clicky/DesignSystem.swift` (`DS.*`) |
| The material — paper, wells, bevels, shadows | `Sources/Chunks/Clicky/PhysicalSurface.swift` (`.physical(...)`) |
| Whether a pair is readable | `Sources/ChunksKit/UI/ColorContrast.swift`, asserted in `ColorContrastTests` |
| The card's heights, fonts and line budgets | `Sources/ChunksKit/AnswerPanelLayout.swift` |
| What the card draws | `Sources/Chunks/HUD/NotchHUDView.swift` |
| What a turn is doing | `Sources/Chunks/HUD/NotchHUDModel.swift` |
| Panel structure and rows | `Sources/Chunks/Clicky/CompanionPanelView.swift` |
| What the panel says about each grant | `Sources/ChunksKit/Permissions/PermissionRow.swift` |
| A render of every card state, offscreen | `Sources/Chunks/UIRenderProbe.swift` (`--render-ui`, `--render-window`) |

**`Palette` is the source and `DS.Colors` builds from it**, so the contrast suite asserts the numbers
the app draws. A hex written straight into a view is invisible to that test, which is how the dark
palette got to a 4.0:1 grey in the first place.

## Palette

One ground — bone `#f5f4f0` — and everything else is a relationship to it. A raised sheet is lighter
than the ground and throws a shadow; a well is darker and takes an inner one; a pressed thing is
*darker than a hovered thing*, because pushing goes down.

| Role | Value | Used for |
|---|---|---|
| `ground` | `#f5f4f0` | the page under everything |
| `raised` | `#fbfaf7` | cards, the sidebar rail, chips, the composer bar |
| `sunken` | `#eceae4` | text fields, wells |
| `hover` / `pressed` | `#efece6` / `#e2dfd7` | a row with the pointer on it / a row chosen or pushed |
| `line` / `lineStrong` | `#dedbd3` / `#c9c5ba` | hairlines between sheets; the edge of a well |
| `lineControl` | `#847f74` | the outline of something you can act on — 3.3:1, WCAG 1.4.11 |
| `ink` | `#161614` | every word that must be read. 16.5:1 |
| `inkMuted` | `#4a4842` | detail and explanation. 8.3:1 |
| `inkFaint` | `#68655d` | timestamps and meta, measured on the *sunken* well (4.8:1), not on paper |
| `onInk` | `#d6d3cc` | bone text on an ink object — the primary action's label |
| `accent` | `#2a5bd7` | **work in flight**: the status dot, the meter, a link |
| `action` | `#161614` | the primary button. Ink, not blue |
| `warning` / `destructive` / `success` | `#a86208` / `#b3261e` / `#1a7f4b` | needs him / failed / done |

Colour is state and nothing else. The four above are the only saturated hues in the app, and the
primary action is deliberately *not* one of them: in a physical system the thing you press is the
darkest thing on the surface, and spending blue on a button would leave "in flight" with no colour.
Each `*Text` variant is the darker step, used wherever the fill would fall under 4.5:1 — the amber
that read on black measured 2.8:1 on bone.

## The dots reskin (2026-10-30)

The menu-bar panel, the history window and the first-run guide moved to a **warm paper** ground and
three flat fields measured off the Dots Studio reference image. The notch HUD card is **out of
scope** and still reads `DS.Colors` — which is why this is a *parallel* token set (`Palette.Dots`,
`DS.Dots`) rather than a mutation of the shared one: changing `ground`/`raised`/`sunken` would have
recoloured the card.

**Measured, not eyeballed — twice.** The first pass sampled the sailboat reference image. He then
supplied two skin mockups and said the result was 80% right, so those were sampled too (patch modes
and hue-family modes), and **they do not agree with the reference or with each other** — they are
generated art. Each surface therefore takes the value its own mockup shows, and the two seas and two
skies below are deliberate, not drift.

| Role | Value | Where |
|---|---|---|
| `Dots.paper` | `#F7F3E9` | the detail pane, the ground under the cards |
| `Dots.raised` / `sunken` | `#FCF9F2` / `#EFEAE0` | derived: paper lifted / pressed |
| `Dots.hover` / `pressed` | `#F2EDE3` / `#E7E1D5` | derived, same lift/press rule |
| `Dots.line` / `lineStrong` | `#DED8CB` / `#C9C2B2` | hairlines, the meter track |
| `Dots.sea` | `#C7EDE7` | panel ground, routines card, footer |
| `Dots.seaDeep` | `#A6E3D9` | window question wells, the chosen thread, the rail's foot |
| `Dots.sky` | `#A2C0FD` | panel header band, the section tags |
| `Dots.skyRail` | `#BDD1FC` | window sidebar |
| `Dots.sand` / `sandTag` | `#FAEBD1` / `#FDD99C` | reading and warmth / the MEMORY tag |
| `Dots.teal` | `#1B9794` | toggle track, memory meter, the chosen thread's bar |
| `Dots.link` | `#0038E8` | the mockup's own link blue |
| `Dots.ink` / `hull` | `#16181C` / `#583629` | every word / the one warm dark |

**Cards are dashed; controls are solid.** This is the distinction the first all-dashed pass lost and
the one that made it feel off. `DS.Dots.Dash` (1 pt, six on / four off, ink at 22%) draws every card
edge, row separator and footer column. A **solid** edge (`controlEdge`, ink at 55%) draws the things
you press — the model pill, the section tags, the close button, the answer cards, the composer — and
`sheetEdge` (ink at 80%, 1.5 pt) draws the outer panel. Dashing a control makes it read as decoration.

**What lifts, what is cut.** The panel's sheet and its routines block are the **sea field**; the
window's rail is **skyRail** and ends in a strip of **seaDeep** at its foot, with the clouds resting
on that strip's top edge. The window's detail header is **cream paper with a large sand cloud mass
hanging from its top-right corner** — a `CloudBand` flipped vertically, because a shoreline band
along the bottom is a different picture from a sky full of cloud. Paper (`Dots.raised`) is what a
*thing you operate* is made of: the settings card, the answer cards, the composer pill, the
history/API sheet, and the **paper sub-card inset in the memory card** that holds the facts under its
sand header strip. The window's **question wells are seaDeep**, so his words and Chunks' answer are
two different materials. Sand is for reading and warmth: the privacy copy, the memory header, the
live-stage strip, the setup guide's step bands. The chosen thread is a seaDeep fill with a **teal**
leading bar, and the toggles and the memory meter are teal — the mockup's control colour, not the
system blue.

**The dashed rule is the only separator.** `DS.Dots.Dash` — 1 pt, six on / four off, ink at 22% — is
used for every card edge, every row separator, the footer's column divisions and the composer pill.
A solid `Divider` inside an all-dashed sheet reads as a second system, so `DotsDashRule` replaced
them. It is one value in one place for the same reason the panel once grew five greys.

**The clouds are drawn, and they must be in the same layer as their sky.** `DS.Dots.CloudBand` fills
a cumulus silhouette in sand from a fixed radius list, so a rebuild gives the same sky. Two failures
found by rendering, not by reading the code: as an `.overlay` the clouds painted *across* the
subtitle line, and as a second `.background` they vanished behind the opaque sky fill — a later
`.background` sits behind the earlier one. Sky fields are therefore one `ZStack` background: sky,
clouds on its bottom edge, hatch over both.

**Where colour is allowed.** Re-measured against the mockups' lighter values, and the rule loosened
where the numbers actually allow it: **ink (9.73–16.04) and inkMuted (5.00–8.25) are legal on all six
fields** — the darker first-pass palette could not manage muted on sky. `inkFaint` clears on paper,
raised, sea and sand (4.63–5.54) but not on the two skies, the deep sea or the strong sand tag
(3.19–4.32), and those four are asserted as failures in `Palette.Dots.illegalOnFields`. The mockup's
own link blue `#0038E8` clears 4.5:1 everywhere it is used (5.01–7.31) **except sky at 4.21**, so a
link on sky is ink. `teal` is a control fill: it clears the 3:1 graphic floor on paper, raised and
sand (3.03–3.38) and fails on every sea and sky, so it is never a mark on a field — also asserted.
The fields are never marks on paper and never carry reversed text. `inkFaint` on a `pressed` row is
4.47:1 and stays illegal, asserted.

**The pen-hatch is drawn, not a bitmap.** `DS.Dots.HatchPattern` is a Canvas of short horizontal
dashes — 1 pt stroke on a 16 pt pitch, 7.5 pt dash with a 2.5 pt gap, alternate rows offset half a
period — in ink at 5%, the reference's 2/33/15/5 px geometry scaled ×0.5 and dropped to paper-grain
contrast. It survives a rebuild and scales with the view, and it rides the flat fields only: the
panel sheet, the rail, the sky bands, the sand and sea cards. Never over the transcript he reads,
never over the notch card.

**Not copied from the mockup: the traffic lights.** The panel mockup draws three of them, but the
menu-bar panel is a borderless status panel and circles that do nothing are a lie about what the
surface can do. The ⌃A window has real ones.

## Type

One family — the system sans — at four voices, and no fifth grey. The dark palette had a micro label
at 3.3:1 on bone; it is gone rather than re-tuned, because a label that must be squinted at should
not be small and grey in the first place.

- `DS.Fonts.headline` 14 semibold — what a surface calls itself.
- `DS.Fonts.label` 12 medium — a control's own words.
- `DS.Fonts.meta` 11 — explanations, outcomes, elapsed.
- `DS.Fonts.micro` 10 medium — counters and key caps, always `inkMuted` or darker.

The card adds `AnswerPanelLayout.speechFont` 15 medium and `detailFont` 12; the window's transcript
is 13, because that surface is read rather than glanced at. Numbers that count are
`monospacedDigit()`.

## Shape and rhythm

Radii 8 (chips, buttons) / 12 (rows, fields) / 16 (cards) / 20 (the notch card, the window's sheets),
999 only for a true capsule. Spacing from `DS.Spacing` (4/8/12/16/20/24/32).

**Elevation is two shadows, always together.** `DS.Shadow` is the reference's recipe: a tight contact
layer (`0 1 2 · 5%`) and a wide lift layer (`0 7 12 · 14%`). Contact without lift is a sticker; lift
without contact is a hover state that never ends. A pressed object throws less and offsets one point
down. Sheets catch light along their top inside edge — `LightEdge`, one point of 75% white — because
without it a raised rectangle reads as a colour change rather than something with thickness. (That
band has to be pinned to `.top`; centred, it drew a line through the middle of the Allow button's
label, which is what the first render showed.)

**Motion is springs** — `DS.Motion.tap` 0.22 / `.settle` 0.32 / `.unfold` 0.45 response, damping ~0.72,
which is the reference's `{stiffness 380, damping 40}` in SwiftUI's parameterisation. Nothing eases
out of a move; things settle into one. No motion without a cause: the inherited primary button swelled
to 1.03 on hover and breathed a coloured glow on a 2.5 s loop. Both are gone.

## The notch card


360 pt wide, capped at 420, transient: it dismisses on click-away once an answer exists, and
refuses to while he is talking or a turn is in flight.

**It is bone now, and that was a decision rather than a default.** The card used to be pure black so
the seam into the physical cutout disappeared; it is now the same paper as the rest of the app, which
means it reads as a sheet hanging off the hardware instead of a hole in it. The band behind the notch
stays empty so the bezel itself is still what you see at the cutout, the halo keeps the silhouette
square along the display edge, and the window throws a real shadow because a light rectangle with no
shadow over a bright desktop is invisible. Top-down, in the order a turn happens:

1. **Stage row** — 7 pt state dot, the phase in words ("Asking the model", "Doing it", or the
   `<DONE_TITLE>` once there is one), and right-aligned elapsed seconds. Past the 60 s the chain is
   budgeted to, the figure is drawn in `destructiveText`: a number in the same grey as "4s" asks him
   to know the ceiling by heart, and a turn past it is not slow, it is the promise failing.
2. **The question he spoke**, up to two lines, tail-truncated. His own words are the least
   replaceable text on the surface, so they get the second line — middle truncation deleted the
   object out of the one sentence he knows precisely and did not type.
3. **Speech** — what is also said aloud, budgeted at 200 characters. The voice says all of it; the
   card is bounded, because an unbounded `<SAY>` did not make the card taller — `measure` clamps at
   420 — it pushed the chips, the Allow row and the footnote off the bottom edge.
4. **Detail** — the expansion, budgeted at 420 characters.
5. **The plan record** — up to 4 outcome lines, each a 2 pt rule + what happened + `step/total`,
   older ones folded into "+N earlier".
6. **Chips** — point targets, then suggested next actions. A capsule hugs its own words (max 240 pt,
   then truncate) inside a full-width row: a bar across the card with nine characters in it reads as
   a table row, not an offer. The tappable ones carry the `lineControl` hairline, because `raised` on
   the card's ground is a 1.05:1 difference and a shadow is not an affordance. A point chip is *not*
   tappable and must not look it.
7. **The Ask block** — a `sunken` well holding the labelled ordinal ("Step 6 of 6"), the question
   naming the control the hit test found, then Allow / Not now at half the card's width each. Wide
   targets, because mis-tapping "Not now" is the failure worth designing against, and because since
   2026-10-18 a permanent act (Send, Pay, Delete, Confirm) always reaches this row even with asking
   switched off.
8. **The memory footnote**, two lines.
9. **The way back** — on a failed card only, one full-width `Ask again` in the same object as Allow,
   because it is the same kind of thing: the primary action of the card the card is waiting on.

**Two orders, not one.** A turn that is *telling* him reads top-down in the order it happened — the
list above. A turn that is *asking* moves the block to position 2 and folds the plan record and the
chips away, because it has exactly one job and the moment that can change his machine was the sixth
thing he reached: at 405 of the 420 pt ceiling, one more line of answer prose and Allow was
unclickable. The step travels as data, never spliced into the sentence — "Press Send in WhatsApp?
(step 5 of 5)" stated the plan's position twice in two shapes, one of them a parenthetical inside the
question he is answering.

## The listening meter

Nine 2 pt bars, 1 pt apart, 12 pt tall, centred in the pill where the status dot sits while
`.listening`. Each bar is one 45 ms window of the microphone's own level, so the row is ~400 ms of
history and reads as *when* he spoke, not as a spinner.

- The gain (2.85), the curve (0.76) and the silence floor (0.008) are the numbers
  `BlueCursorWaveformView` already uses, so one sound is one height on both surfaces. Two mappings of
  one level is how two views end up disagreeing about whether he is being heard.
- **No idle pulse.** The cursor's row adds a sine of wall-clock time; this one does not. Motion has
  to be earned by audio, and a pill that breathes in a quiet room is the fake-ready state this
  project already rejects elsewhere.
- **A quiet room is one hairline, not nine stubs.** Nine 2 pt squares at a 1 pt pitch rendered as a
  dotted rule — which is the exact "…" doubt the meter exists to answer. So the whole row collapses
  to a 1 pt `lineStrong` rail across the same width while nothing is heard, and the bars appear with
  the sound that makes them; inside a live row, a bar that caught nothing stays in the hairline tone
  so the row shows the room as well as the voice.
- Flat fill, no glow: a shadow halo is banned on this surface.
- The meter stops with the microphone. Outside `.listening` the dot returns and the buffer resets, so
  nothing on screen can be mistaken for audio nobody is capturing.
- `accessibilityHidden`: it restates in pixels what the caption and the stage line already say.

The reason it exists is the 1.7 s before the first partial transcript, where "…" is
indistinguishable from a microphone that never opened.

## The menu-bar panel

320 pt on the ground, its own sheet lifted off the desktop by the same two layers everything else
uses — the dark palette's 50%-black 20 pt blur would read as a smudge on bone. Rows are `hover`
fills with no border; the status dot has no glow, because a halo on bone is a smudge and the palette
bans one.

**The five permission rows are one row, five times.** `PermissionState.rows(for:)` in ChunksKit
decides the title, the mark, the one-line purpose, the state word (`Granted` / `Needed`) and the
buttons — `Grant` as ink, `Restart` and `Find App` as paper. They were five hand-written views of
about seventy lines each and had already drifted: two offered Restart and three did not, the granted
tick was two different greens, and the helper meant to unify them was never called. Restart appears
only where macOS applies the grant on the next launch, because a button that would not help teaches
the user to press things that do nothing.

The privacy paragraph used to be red. It is a promise, not a failure, and in this language a
saturated colour means one of four states.

The scroll area fades to `ground` over its last 22 pt. At 380 pt tall the panel ends mid-row, and a
`Grant` pill sliced in half reads as a broken control rather than as a list that continues; the fade
says *there is more* and `allowsHitTesting(false)` keeps it from swallowing the tap on the row under
it.

320 pt, settings and keys only — no answers, no history. Header (dot, name, status, dismiss) and
footer (Quit, replay the intro) are pinned; everything between them scrolls, because the window is
380 pt and the permission state — guaranteed on a first run — overflowed it, which made the API key
row unreachable rather than merely off-screen.

## The window

860 × 560, resizable, pinned to the **light** appearance rather than left to follow macOS: there are
no dark variants any more, so Dark Mode would give it a black titlebar over bone content — the same
mismatch as before, inverted. HeyClicky's Home is the shape — thread list, transcript, one composer —
drawn with these tokens, not a second language.

- **Sidebar 292 pt** on `raised` paper over the ground, and it is a tree, not a list: a sitting heads the group, the
  threads inside it hang off a 1 pt `line` rule with a 12 pt step, and the chosen one carries a 2 pt
  `accent` bar on its leading edge. Selection is a `pressed` fill *plus* that bar, never a coloured
  border — the fill alone is a 1.28:1 difference from the paper it sits on, which is a surface and not
  a signal. An indent with no rule was measured at 9 pt and read as a list with stray spaces.
- **Session header** in micro: an accent dot on the open one, then "Today 09:14 · started when the
  Mac woke · 4 chats". The *why* is the load-bearing word — a gap in the middle of a list with no
  explanation reads as the history being broken, and he has to be able to tell that the boundary was
  his.
- **Thread row**: its title (label, one line, tail) then "2 exchanges · 22:45–22:49 · 4 acts" in
  micro. The title is the first exchange's `<DONE_TITLE>` — the words he already read, not a summary
  invented for a list row.
- **The detail pane shows a whole thread**, not the row he clicked. That is the point of the middle
  level: "what does the second line mean" is nothing on its own and obvious under the question it
  follows.
- **An exchange is quieter above than below**: his question at 12 pt `label` in `textSecondary`, the
  answer at **13 pt `textPrimary`**, then the act lines with the card's 2 pt rules and the source as
  a `sunken` micro chip. Two voices the same size, weight and colour made the transcript unreadable
  as a conversation — the only thing telling them apart was a right-aligned time.
- **Markdown is rendered, never printed.** The model answers with `` `localhost:5173` `` and
  `**bold**` because that is how it was trained; the transcript runs SwiftUI's inline-only markdown,
  so the backticks become a monospace run and the newlines survive. A transcript that shows the
  markers is a debug view.
- **Composer** pinned across the bottom on `raised`, the field a `sunken` well with a `lineControl`
  outline and a `inkFaint` prompt (the system's placeholder grey measured under the floor). Ask is
  ink with a bone label when there is a question, and a `sunken` well with `inkFaint` when there is
  not — the disabled label used to be white on bone, which meant it simply vanished.
- **While a turn runs** the detail column carries one line: the HUD's stage and its elapsed seconds.
  No progress bar, no shimmer, and no mirrored stream — the answer stays on the notch and the row
  lands when it is finished.

Verified with `.build/debug/Chunks --render-window /tmp/window.png`, which draws both states
offscreen. That check found the empty sidebar floating mid-column, a double ellipsis on every
preview, the answer at 11 pt grey, and one WhatsApp task split into two threads.

## Banned here

A hex written into a view instead of `Palette` — it escapes the contrast suite. Grey small text
below 4.5:1 on whatever ground it actually sits on (a well is not paper). A single shadow layer, or
a lift with no contact: that is a sticker or a permanent hover. A coloured border on a row — state
is a fill and a shadow, never a hue on an edge. Any motion without a cause: no breathing glow, no
pulse while the room is quiet, no progress bar standing in for the stage, no shimmer pretending an
answer is nearly ready. Saturated colour on an inactive control. A second type family. Glass on a
tooltip or a card — a surface that lets the desktop through it is unreadable wherever it lands. Any
remote asset: nothing in this app fetches or plays one, and that is a product rule, not a style
choice.

Added with the dots reskin: a sea/sky/sand **mark on paper** (a dot, bar or rule in a field colour is
1.16–1.70:1 and invisible — the fields are grounds, not marks); **paper text on a field** at any size;
`inkFaint` on a `pressed` row; the hatch over a reading surface or over the notch card; and mutating
the shared `DS.Colors` ground/raised/sunken to reskin a surface, because the notch reads them and is
out of scope.
