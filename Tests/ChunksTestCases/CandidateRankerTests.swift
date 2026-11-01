import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for which of the things on a page a person's words point at.
///
/// The named route scores an element's *own* title, so in web content — where Chromium publishes an
/// `AXGroup` with no name and an `AXStaticText` child that says the word — it refuses a control the
/// user can see. Ranking those children is only safe while three rules hold, and each has a measured
/// failure behind it: nearness never qualifies anything on its own (the wrong-row press of
/// 2026-10-05), a closed menu's rows are never a candidate (`Memora`, 2026-10-24), and the card's own
/// words must still be true of the element at the moment of the press.
public enum CandidateRankerTests {

    private static let window = CGRect(x: 0, y: 100, width: 1000, height: 900)

    /// What an app is allowed to own beyond that window: the union of its surfaces, which is the
    /// rectangle the on-screen veto actually uses. Chrome's reaches 114 points above the display, so
    /// this fixture's reaches the same distance above a window that starts at y = 100.
    private static let vetoWindow = CGRect(x: 0, y: -114, width: 1000, height: 1214)

    private static func box(_ x: CGFloat, _ y: CGFloat,
                            _ w: CGFloat = 90, _ h: CGFloat = 32) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// A web control as Chrome publishes one: no name of its own, a child that says the word.
    private static func drawn(_ words: String, at frame: CGRect?) -> CandidateElement {
        CandidateElement(role: "AXGroup", childrenText: [words], frame: frame)
    }

    /// A control the app itself named.
    private static func named(_ name: String, role: String = "AXButton", at frame: CGRect?,
                              children: [String] = []) -> CandidateElement {
        CandidateElement(role: role, ownNames: [name], childrenText: children, frame: frame)
    }

    private static func top(_ label: String, _ candidates: [CandidateElement],
                            aim: CGPoint? = nil, bounds: CGRect? = window) -> [RankedCandidate] {
        CandidateRanker.rank(label: label, aim: aim, windowBounds: bounds, candidates: candidates)
    }

    public static func register() {
        TestRunner.currentSuite = "Candidates"

        test("a control whose only words are drawn inside it still reaches the card") {
            let ranked = top("Run", [drawn("Run", at: box(120, 160))])
            expectEqual(ranked.count, 1,
                        "the whole point of the route: a button with an empty title is not a button "
                        + "that does not exist")
            let only = ranked[0]
            expectEqual(only.evidence, .childText,
                        "the app never named this control, and the card may not imply that it did")
            expectEqual(only.matchedText, "Run")
            expect(only.textScore >= CandidateRanker.minTextScore)
        }

        test("the card says which kind of words won, in words a person can check") {
            let byName = top("Run", [named("Run", at: box(120, 160))])[0]
            let byChild = top("Run", [drawn("Run", at: box(120, 160))])[0]
            let nameQuestion = CandidateRanker.question(for: byName, app: "Chrome",
                                                       windowBounds: window)
            let childQuestion = CandidateRanker.question(for: byChild, app: "Chrome",
                                                         windowBounds: window)
            expectEqual(nameQuestion, "Press the button \"Run\" at the top-left in Chrome?",
                        "a control the app named is asked about by its name: \(nameQuestion)")
            expectEqual(childQuestion, "Press the area that says \"Run\" at the top-left in Chrome?",
                        "a control with no name is asked about by the words drawn on it, and the "
                        + "card has to admit it is an area: \(childQuestion)")
        }

        test("the smallest thing carrying the words wins over the region containing them") {
            let page = CandidateElement(role: "AXGroup", ownNames: ["Docs – Google Chrome"],
                                        childrenText: ["Run", "Deploy", "Settings"], frame: window)
            let button = drawn("Run", at: box(640, 500))
            let ranked = top("Run", [page, button], aim: CGPoint(x: 100, y: 200))
            expectEqual(ranked.first?.element.frame, button.frame,
                        "a page-wide group contains every word a user might say, and it is not the "
                        + "control — even when the aim is nowhere near the button")
        }

        test("nearness alone never qualifies a control") {
            let target = drawn("Run", at: box(120, 160))
            let neighbour = drawn("Deploy", at: box(122, 162))
            let ranked = top("Run", [neighbour, target], aim: CGPoint(x: 123, y: 163))
            expectEqual(ranked.count, 1,
                        "the aim is inside both boxes, but only one of them answers the words — a "
                        + "press on the other is the wrong-row bug with extra confidence")
            expectEqual(ranked.first?.matchedText, "Run")
        }

        test("one shared word is not enough to press something") {
            let ranked = top("claude code", [named("the claude thing", at: box(10, 110))])
            expect(ranked.isEmpty,
                   "one shared token scores a 1, and with no pixel to corroborate it the bar stays "
                   + "where the named route puts it")
        }

        test("a menu row is never a candidate, however exactly it is named") {
            let ranked = top("Memora", [named("Memora", role: "AXMenuItem", at: box(0, 100, 200, 22))])
            expect(ranked.isEmpty,
                   "measured 2026-10-24: a row of a closed menu matched the name, was pressed, and "
                   + "opened a Finder window for a folder of that name")
        }

        test("a control outside the window the user is looking at is not a candidate") {
            let ranked = top("Run", [named("Run", at: CGRect(x: 900, y: -80, width: 120, height: 24))])
            expect(ranked.isEmpty,
                   "an omnibox suggestion row from a dropdown that had already closed sat at y = −82 "
                   + "and was pressable — the on-screen veto is not optional for a route with no pixel")
        }

        test("two rows that answer the words equally are refused, not chosen") {
            let first = drawn("Run", at: box(120, 160))
            let second = drawn("Run", at: box(120, 200))
            let ranked = top("Run", [first, second])
            expectEqual(ranked.count, 2)
            expect(CandidateRanker.tiedTop(ranked),
                   "the card's sentence would describe both, so it describes neither")
            let aimed = top("Run", [first, second], aim: CGPoint(x: 160, y: 210))
            expect(!CandidateRanker.tiedTop(aimed),
                   "with a point to aim at, the nearer of two identical rows is the one he meant")
            expectEqual(aimed.first?.element.frame, second.frame)
        }

        test("a control the app calls a button beats a region that merely answers a press") {
            let region = drawn("Run", at: box(120, 160))
            let button = named("Run", at: box(120, 160))
            let ranked = top("Run", [region, button])
            expectEqual(ranked.first?.element.role, "AXButton",
                        "same words, same box: the thing the app says is a control is the control")
            expect(!CandidateRanker.tiedTop(ranked))
        }

        test("an element that publishes no frame cannot win") {
            let framed = drawn("Run", at: box(120, 160))
            let ranked = top("Run", [drawn("Run", at: nil), framed])
            expectEqual(ranked.first?.element.frame, framed.frame,
                        "a card cannot describe where an unlocatable control is, so it cannot be the "
                        + "one he is asked about")
        }

        test("the re-read refuses a box whose words changed under the card") {
            let approved = top("Run", [drawn("Run", at: box(120, 160))])[0]
            let sameBoxNowSaysStop = drawn("Stop", at: box(120, 160))
            expect(!CandidateRanker.stillAnswers(approved, now: sameBoxNowSaysStop),
                   "ACCEPTANCE: the card quoted the words drawn on an unnamed control, so those words "
                   + "are the only identity it has — a press on whatever now says \"Stop\" in the same "
                   + "place is not what he approved")
        }

        test("the re-read refuses a control that moved or stopped advertising the verb") {
            let approved = top("Run", [drawn("Run", at: box(120, 160))])[0]
            expect(!CandidateRanker.stillAnswers(approved, now: drawn("Run", at: box(120, 192))),
                   "a relayout that slides the row down is the page saying something else lives where "
                   + "the card pointed")
            let nowOpens = CandidateElement(role: "AXGroup", childrenText: ["Run"],
                                           frame: box(120, 160), pressVerb: "AXOpen")
            expect(!CandidateRanker.stillAnswers(approved, now: nowOpens),
                   "the verb on the card is the verb that was approved")
            expect(CandidateRanker.stillAnswers(approved, now: drawn("Run", at: box(120, 160))),
                   "and the same control read back the same way must still be pressable, or this "
                   + "route would refuse every press it makes")
        }

        test("the re-read of a named control checks the app's own name, not its children") {
            let approved = top("Run", [named("Run", at: box(120, 160),
                                            children: ["Running…"])])[0]
            expectEqual(approved.evidence, .publishedName)
            let titleGone = CandidateElement(role: "AXButton", childrenText: ["Run"],
                                            frame: box(120, 160))
            expect(!CandidateRanker.stillAnswers(approved, now: titleGone),
                   "the card quoted the app's own name; a child happening to carry the word is "
                   + "different evidence and must not be treated as the same control")
        }

        test("a position phrase is only printed when both the control and the window are known") {
            let noBounds = top("Run", [drawn("Run", at: box(120, 160))], bounds: nil)[0]
            expectEqual(CandidateRanker.cardDescription(for: noBounds),
                        "the area that says \"Run\"",
                        "without the window there is no proportion to state, and \"at the top-left\" "
                        + "of an unknown frame would be a guess about his screen")
            let noFrame = top("Run", [named("Run", at: nil)])[0]
            expectEqual(CandidateRanker.cardDescription(for: noFrame, windowBounds: window),
                        "the button \"Run\"")
        }

        test("a long name is capped the way every other control name on this card is") {
            let long = String(repeating: "run ", count: 40).trimmingCharacters(in: .whitespaces)
            let ranked = top("run", [named(long, at: box(120, 160))])
            expect(!ranked.isEmpty, "the opening tokens still answer the words")
            let description = CandidateRanker.cardDescription(for: ranked[0], windowBounds: window)
            expect(description.count <= 80,
                   "the question row is measured at one line of 12 pt type; a card that grows past "
                   + "it is a card nobody reads before tapping Allow (\(description.count) chars)")
            expect(description.contains("…\""),
                   "and the truncation has to be visible, not a silent cut: \(description)")
        }

        test("two nodes at one frame are one control, not a coin toss") {
            // Placed inside `window`, because the on-screen veto runs before any of this: measured
            // 2026-10-28 in a live Chrome tab, where a web control is published twice — a wrapper
            // `AXGroup` and the `AXButton` inside it at the identical frame.
            let wrapper = drawn("Mute (m)", at: box(84, 800, 40, 40))
            let inner = named("Mute (m)", at: box(84, 800, 40, 40))
            expect(!CandidateRanker.tiedTop(top("Mute", [wrapper, inner])),
                   "a wrapper and the control inside it are not two things he could have meant, and "
                   + "treating them as two would refuse every control on the page")
            expect(!CandidateRanker.tiedTop(top("Mute", [inner, wrapper])),
                   "and the answer cannot depend on which of the pair the walk reached first")
            let bothUnnamed = [drawn("Mute (m)", at: box(84, 800, 40, 40)),
                               drawn("Mute (m)", at: box(84, 800, 40, 40))]
            expect(!CandidateRanker.tiedTop(top("Mute", bothUnnamed)),
                   "same box, same words, same role: still one box")
            let twoPlaces = [drawn("Mute (m)", at: box(84, 800, 40, 40)),
                             drawn("Mute (m)", at: box(900, 800, 40, 40))]
            expect(CandidateRanker.tiedTop(top("Mute", twoPlaces)),
                   "two different boxes answering the same words with no aim to choose between them "
                   + "is the ambiguity the rule exists for")
        }

        test("a control whose coordinates are outside the window gets no location claim") {
            // Measured 2026-10-28: Chrome publishes its own toolbar at y = −91 while the page under it
            // reports frames from y = 34. The veto rectangle — everything the app owns, which is what
            // decides whether a control may be considered at all — reaches y = −114 and covers it; the
            // window the user is looking at starts at y = 34 and does not. Rounding the negative
            // proportion into "the top-left" would claim a place he cannot check, and the display veto
            // that tried to fix this by dropping such candidates broke every toolbar button in Chrome.
            let toolbar = named("Reload", at: CGRect(x: 88, y: -99, width: 14, height: 16))
            let ranked = top("Reload", [toolbar], bounds: vetoWindow)
            expectEqual(ranked.count, 1,
                        "it is a real, pressable control on his screen, so the generous veto keeps it")
            // `first` rather than a subscript, twice over: a failed `expect` in this harness reports
            // and carries on, so indexing an empty list here would end the whole run instead of
            // failing one case.
            if let only = ranked.first {
                expectEqual(CandidateRanker.cardDescription(for: only, windowBounds: window),
                            "the button \"Reload\"",
                            "and the card names it without saying where")
            }
            let inside = top("Reload", [named("Reload", at: box(120, 160))], bounds: vetoWindow)
            if let first = inside.first {
                expect(CandidateRanker.cardDescription(for: first, windowBounds: window)
                        .contains("at the top-left"),
                       "a control whose coordinates do sit in the window still gets its place stated")
            }
        }

        test("the bar this route shares with the named route is one number, not two") {
            expectEqual(CandidateRanker.minTextScore, SemanticTarget.minNameScore,
                        "two bars drift, and the weaker one becomes what a press actually needs")
        }
    }
}
