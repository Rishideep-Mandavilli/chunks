import ChunksKit
import ChunksTestHarness

/// The contrast suite for the bone/ink palette.
///
/// This is the test that makes a reskin safe to do in one pass. The dark palette had already been
/// caught once by a colour that measured 4.0:1 on pure black, and a light ground inverts every one of
/// those judgements — a grey that was legible on black can be invisible on bone, and no unit test
/// about behaviour would ever notice. So the numbers are asserted here, from the same constants the
/// app draws with (`Palette` is the single source; `DS.Colors` builds from it).
public enum ColorContrastTests {

    public static func register() {
        TestRunner.currentSuite = "Colour contrast"

        test("every text pair clears WCAG AA") {
            let failures = ColorContrast.failures(Palette.textPairs)
            expect(failures.isEmpty,
                   "unreadable text on a real surface:\n    " + failures.joined(separator: "\n    "))
        }

        test("every state mark clears the graphic floor") {
            let failures = ColorContrast.failures(Palette.graphicPairs)
            expect(failures.isEmpty,
                   "a state nobody can see is not a state:\n    "
                   + failures.joined(separator: "\n    "))
        }

        test("the maths agrees with the standard's worked examples") {
            // Black on white is the definition of the maximum, and identical colours are the
            // definition of the minimum. If either of these moves, the ratios above mean nothing.
            expectEqual(ColorContrast.ratio(foreground: "#000000", background: "#ffffff"), 21,
                        "the ratio scale is wrong, so every floor is wrong")
            expectEqual(ColorContrast.ratio(foreground: "#777777", background: "#777777"), 1)
            expectEqual(ColorContrast.ratio(foreground: "#fff", background: "#000"), 21,
                        "three-digit shorthand has to read as the same colour as six-digit")
            expectEqual(ColorContrast.ratio(foreground: "#FFF", background: "#ffffff"), 1,
                        "case has to be irrelevant — and this pair is white on white")
            expect(ColorContrast.legible(foreground: "#161614", background: "#f5f4f0"))
            expect(!ColorContrast.legible(foreground: "#f5f4f0", background: "#fbfaf7"),
                   "bone on bone was called legible, which is how a disabled button disappears")
        }

        test("a large-text pair is allowed less contrast, and only a little") {
            let pair = ColorContrast.Pair("big", Palette.accent, on: Palette.sunken, large: true)
            expect(ColorContrast.failures([pair]).isEmpty,
                   "the activity blue should clear 3:1 as a large label")
            let same = ColorContrast.Pair("body", Palette.accent, on: Palette.sunken)
            expect(ColorContrast.ratio(foreground: Palette.accent, background: Palette.sunken) >= 4.5,
                   "if this ever drops below 4.5 the body-text use has to move to accentDeep — "
                   + "the exemption is for large type only")
        }

        // MARK: Dots Studio reskin

        test("dots: every text pair clears WCAG AA on the warm paper and the three fields") {
            let failures = ColorContrast.failures(Palette.Dots.textPairs)
            expect(failures.isEmpty,
                   "unreadable text on a dots surface:\n    " + failures.joined(separator: "\n    "))
        }

        test("dots: every state mark clears the graphic floor on warm paper") {
            let failures = ColorContrast.failures(Palette.Dots.graphicPairs)
            expect(failures.isEmpty,
                   "a state nobody can see on the new ground:\n    "
                   + failures.joined(separator: "\n    "))
        }

        test("dots: the three fields are fill-only — none may be a mark on paper") {
            // This asserts a *limitation*, not a pass. The fields read 1.16–1.70:1 on paper, far
            // below the 3:1 graphic floor, so a sea/sky/sand dot, bar or rule on paper is invisible.
            // If a future edit brightens one enough to pass, this test fails on purpose: the colour
            // would then be a different colour from the one measured off the reference image.
            for field in Palette.Dots.fillOnlyFields {
                let ratio = ColorContrast.ratio(foreground: field, background: Palette.Dots.paper)
                expect(ratio < ColorContrast.graphicMinimum,
                       "field \(field) now reads \(String(format: "%.2f", ratio)):1 on paper — it was "
                       + "measured as a fill, and a mark this colour is a state nobody can see")
            }
        }

        test("dots: paper text on a field is never legal, at any size the app uses") {
            for field in Palette.Dots.fillOnlyFields {
                expect(!ColorContrast.legible(foreground: Palette.Dots.paper, background: field),
                       "bone-on-\(field) was called legible; reversed text on a pastel is how a "
                       + "label disappears exactly where the section is loudest")
                expect(!ColorContrast.legible(foreground: Palette.Dots.paper, background: field,
                                              large: true),
                       "even the large-text exemption cannot rescue bone on a pastel")
            }
        }

        test("dots: faint text is illegal on a pressed row, and the suite says so") {
            // Measured 4.45:1 — under the 4.5 body floor. Not nudged into a pass: a pressed row must
            // use muted or ink, never faint. Asserting the failure keeps anyone from adding it later.
            let ratio = ColorContrast.ratio(foreground: Palette.inkFaint,
                                            background: Palette.Dots.pressed)
            expect(ratio < ColorContrast.bodyMinimum,
                   "faint-on-pressed now passes; if that is intentional the rule changed, so update "
                   + "the rule and the views together, not just this number")
        }

        test("dots: a field carries ink or muted only — faint and bright accent stay illegal") {
            // The nautical ground puts whole sections on sea and sky, so this is the pair list that
            // decides whether a reskin is readable. `inkFaint` measures 3.11–4.56 and the bright
            // activity blue 3.14–4.60 on a field, both under the body floor at the 11 pt this app
            // uses for meta and links. Asserted as failures so the fix is to move the text to muted
            // or the block to paper — never to brighten the field until a test goes quiet.
            for pair in Palette.Dots.illegalOnFields {
                let measured = ColorContrast.ratio(foreground: pair.foreground,
                                                   background: pair.background)
                expect(measured < ColorContrast.bodyMinimum,
                       "\(pair.name) now reads \(String(format: "%.2f", measured)):1 — if a field was "
                       + "darkened to pass, the measured reference colour was the point")
            }
        }
    }
}