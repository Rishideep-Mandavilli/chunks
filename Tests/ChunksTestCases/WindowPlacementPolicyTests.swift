import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for putting a window where a person named it.
///
/// This is the slice `AGENTS.md` deferred on purpose, and the reason is invariant 1: moving a window is
/// the only act in this app that *writes a rectangle*, and every past instance of that mistake produced a
/// plausible number rather than an error — a click at double the intended offset on Retina, a window half
/// off the edge of a secondary display, a fraction treated as a pixel. So the cases here are mostly about
/// the numbers, and the property that matters most is that **the same screen described at 1x, 2x or 3x
/// produces the same rectangle**, because the maths is in points and never looks at a scale factor.
public enum WindowPlacementPolicyTests {

    /// A 1710x1107 display with a 34 pt menu bar and a 60 pt Dock — the machine this was written on,
    /// in the space Accessibility uses: global, top-left, logical points.
    static func main(_ index: Int = 1, origin: CGPoint = .zero) -> WindowPlacementPolicy.Surface {
        let global = CGRect(origin: origin, size: CGSize(width: 1710, height: 1107))
        let usable = CGRect(x: global.minX, y: global.minY + 34,
                            width: global.width, height: global.height - 34 - 60)
        return WindowPlacementPolicy.Surface(index: index, name: "Built-in",
                                             isMain: index == 1,
                                             globalFrame: global, usableFrame: usable)
    }

    /// A smaller external display, to the left of the main one, which is where a negative origin comes
    /// from on a real Mac — and the case that turns a "looks fine on my screen" bug into a test.
    static func external(origin: CGPoint = CGPoint(x: -1536, y: 0)) -> WindowPlacementPolicy.Surface {
        let global = CGRect(origin: origin, size: CGSize(width: 1536, height: 900))
        let usable = CGRect(x: global.minX, y: global.minY + 34,
                            width: global.width, height: global.height - 34)
        return WindowPlacementPolicy.Surface(index: 2, name: "External", isMain: false,
                                             globalFrame: global, usableFrame: usable)
    }

    public static func register() {
        TestRunner.currentSuite = "Window placement"

        test("every place a person can name parses, and only those") {
            let spellings: [(String, WindowPlacementPolicy.Slot)] = [
                ("left", .left), ("right", .right), ("top", .top), ("bottom", .bottom),
                ("top-left", .topLeft), ("topright", .topRight),
                ("bottom-left", .bottomLeft), ("bottom right", .bottomRight),
                ("full", .full), ("maximise", .full), ("centre", .centre), ("middle", .centre),
            ]
            for (word, slot) in spellings {
                expectEqual(WindowPlacementPolicy.parseTarget(word), .slot(slot),
                            "\"\(word)\" is a place he says out loud")
            }
            expectEqual(WindowPlacementPolicy.parseTarget("display=2"), .display(index: 2))
            expectEqual(WindowPlacementPolicy.parseTarget("screen=3"), .display(index: 3),
                        "he may call it a screen, and mean the same thing")
            expectEqual(WindowPlacementPolicy.parseTarget("main"), .main)
            expectEqual(WindowPlacementPolicy.parseTarget("second"), .second)
            expectEqual(WindowPlacementPolicy.parseTarget("LEFT"), .slot(.left),
                        "the tag arrives from a model that capitalises whatever it likes")
        }

        test("a coordinate is refused, not guessed at — the rule that keeps a model honest") {
            // The whole reason this verb takes a word instead of a number. A vision model asked to move a
            // window will happily invent `400,220` from a picture it is guessing about, and unlike a
            // wrong press, a wrong position is something he then fixes by hand.
            for rejected in ["400,220", "x=400", "0.5", "0.25,0.75", "100", "tidy", "somewhere nice",
                             "left-ish", ""] {
                expect(WindowPlacementPolicy.parseTarget(rejected) == nil,
                       "\"\(rejected)\" must not become a placement — a word we do not have is a "
                            + "refusal that teaches, not a guess")
            }
        }

        test("the halves and quarters are exact fractions of the usable area, never of the whole screen") {
            let surface = main()
            let usable = surface.usableFrame
            expectEqual(WindowPlacementPolicy.frame(for: .slot(.left), on: surface,
                                                    currentSize: .zero),
                        CGRect(x: usable.minX, y: usable.minY,
                               width: usable.width / 2, height: usable.height),
                        "left means the left half of what a window may occupy — the menu bar and the "
                            + "Dock are not places")
            expectEqual(WindowPlacementPolicy.frame(for: .slot(.topRight), on: surface,
                                                    currentSize: .zero),
                        CGRect(x: usable.midX, y: usable.minY,
                               width: usable.width / 2, height: usable.height / 2))
            // A rectangle that leaves the usable frame is invariant 1's bug in a new costume: it puts a
            // window under the Dock, which reads as the move having failed.
            for slot in WindowPlacementPolicy.Slot.allCases {
                guard let rect = WindowPlacementPolicy.frame(for: .slot(slot), on: surface,
                                                             currentSize: CGSize(width: 900,
                                                                                 height: 600))
                else { expect(false, "\(slot) produced no frame on a full-size display"); continue }
                expect(usable.contains(rect),
                       "\(slot) landed outside the usable frame: \(rect) vs \(usable)")
            }
        }

        test("centre keeps the window's size, because moving is not resizing") {
            let surface = main()
            let size = CGSize(width: 900, height: 600)
            guard let rect = WindowPlacementPolicy.frame(for: .slot(.centre), on: surface,
                                                         currentSize: size) else {
                expect(false, "centre produced no frame"); return
            }
            expectEqual(rect.size, size,
                        "\"move it to the middle\" is about where, and silently making his editor "
                            + "full-screen is a second act he never asked for")
            expect(abs(rect.midX - surface.usableFrame.midX) < 0.001,
                   "centre is not centred horizontally: \(rect)")
            expect(abs(rect.midY - surface.usableFrame.midY) < 0.001,
                   "centre is not centred vertically: \(rect)")
        }

        test("the same screen at 1x, 2x and 3x places the window in the identical rectangle") {
            // Invariant 1's required coverage, stated the way this code can actually be wrong. Placement
            // is computed in logical points, so the backing scale must not appear in the answer at all —
            // and the bug it guards against is the one this repo already fell into twice, where
            // `CGDisplayPixelsWide` returned points and every offset doubled on Retina.
            let points = CGSize(width: 1710, height: 1107)
            for scale in [1.0, 2.0, 3.0] {
                let global = CGRect(origin: .zero, size: points)
                let usable = CGRect(x: 0, y: 34, width: points.width,
                                    height: points.height - 34 - 60)
                let surface = WindowPlacementPolicy.Surface(
                    index: 1, name: "Built-in \(scale)x", isMain: true,
                    globalFrame: global, usableFrame: usable)
                let rect = WindowPlacementPolicy.frame(for: .slot(.bottomRight), on: surface,
                                                       currentSize: .zero)
                // usable = (0, 34, 1710, 1013), so bottom-right = (855, 540.5, 855, 506.5) at every
                // scale. Written out rather than computed in the test, because a test that recomputes
                // the formula it is checking only proves the formula agrees with itself.
                expectEqual(rect, CGRect(x: 855, y: 540.5, width: 855, height: 506.5),
                            "a 3x panel must not place the window three times further down "
                                + "(scale \(scale))")
            }
        }

        test("a display to the left of the main one keeps its negative origin") {
            // The shape a multi-monitor Mac actually has, and the shape a rect built from
            // `NSScreen.frame` alone gets wrong: a negative coordinate is not an error to clamp away.
            let external = self.external()
            guard let rect = WindowPlacementPolicy.frame(for: .slot(.left), on: external,
                                                         currentSize: .zero) else {
                expect(false, "no frame on the external display"); return
            }
            expectEqual(rect.minX, -1536,
                        "the left edge of the second display is negative, and a placement that "
                            + "normalised it to zero would park the window on the wrong screen")
            expect(rect.maxX <= external.usableFrame.maxX + 0.001)
        }

        test("a cross-display move keeps the size and shrinks only when the new screen is smaller") {
            let big = main()
            let small = external()
            let wide = CGSize(width: 1800, height: 800)
            guard let moved = WindowPlacementPolicy.frame(for: .display(index: 2), on: small,
                                                          currentSize: wide) else {
                expect(false, "no frame"); return
            }
            expect(moved.width <= small.usableFrame.width,
                   "a 1800-wide window moved onto a 1536 display without shrinking puts half of it "
                        + "off the edge, which reads as the move having failed")
            expect(moved.width >= WindowPlacementPolicy.minWindowSize.width,
                   "and it must not be shrunk past anything a person can type into")
            expect(abs(moved.midX - small.usableFrame.midX) < 0.001,
                   "centred on the screen it arrived on, not on the one it left: \(moved)")
            expect(big.usableFrame.width > small.usableFrame.width, "the fixture is the right way round")
        }

        test("a display too small for any window is a refusal, not a tiny rectangle") {
            let postage = WindowPlacementPolicy.Surface(
                index: 1, name: "Tiny", isMain: true,
                globalFrame: CGRect(x: 0, y: 0, width: 400, height: 260),
                usableFrame: CGRect(x: 0, y: 200, width: 400, height: 60))
            expect(WindowPlacementPolicy.frame(for: .slot(.left), on: postage,
                                               currentSize: .zero) == nil,
                   "half of a 60pt-tall usable area is a window nobody can use — refuse it")
        }

        test("which display he means is decided from the list, and a missing one is refused") {
            let both = [main(), external()]
            let only = [main()]
            let current = main()
            expectEqual(WindowPlacementPolicy.surface(for: .second, among: both,
                                                      current: current)?.index, 2)
            expect(WindowPlacementPolicy.surface(for: .second, among: only,
                                                 current: current) == nil,
                   "one screen plugged in means there is no second one — and that is a sentence, not a "
                        + "silent move to the same display")
            expect(WindowPlacementPolicy.surface(for: .display(index: 7), among: both,
                                                 current: current) == nil,
                   "a display number that does not exist is refused rather than clamped to the "
                        + "last one, which would move his window somewhere he never said")
            expectEqual(WindowPlacementPolicy.surface(for: .main, among: both,
                                                      current: current)?.isMain, true)
            // A slot is on the window's own display, so the current one is the answer.
            expectEqual(WindowPlacementPolicy.surface(for: .slot(.left), among: both,
                                                      current: current)?.index, 1)
        }

        test("the card and the report both name the place") {
            let candidate = WindowAct.Candidate(pid: 1, appName: "Safari", title: "Inbox",
                                                frame: CGRect(x: 0, y: 34, width: 900, height: 600))
            expectEqual(WindowPlacementPolicy.question(target: .slot(.left), candidate: candidate),
                        "Move \"Inbox\" in Safari to the left half?",
                        "a question about a window he can check, with the place in it")
            expectEqual(WindowPlacementPolicy.question(target: .display(index: 2), candidate: candidate),
                        "Move \"Inbox\" in Safari to display 2?")
            expectEqual(WindowPlacementPolicy.outcomeLine(target: .slot(.topRight),
                                                          candidate: candidate, succeeded: true),
                        "Moved Inbox to the top-right corner.",
                        "with asking off this line is the only record that anything happened")
            expect(WindowPlacementPolicy.outcomeLine(target: .slot(.left), candidate: candidate,
                                                     succeeded: false)
                        .contains("did not move"),
                   "and a move the app refused is not reported as a success")
            let sameName = WindowAct.Candidate(pid: 1, appName: "Qoder", title: "Qoder", frame: .zero)
            expectEqual(WindowPlacementPolicy.question(target: .slot(.full), candidate: sameName),
                        "Move Qoder to the whole display?",
                        "a window named after its app is named once, the rule the close card learned")
        }

        test("decide refuses a window Chunks cannot reach, in the same words as a close") {
            let off = WindowAct.Candidate(pid: 30147, appName: "Google Chrome", title: "GVPCE",
                                          frame: CGRect(x: 0, y: 122, width: 1710, height: 985),
                                          isReachable: false)
            let decision = WindowPlacementPolicy.decide(
                target: .slot(.left), app: "Chrome", title: "GVPCE",
                resolution: .unreachable(off), surfaces: [main()])
            guard case .refused(let reason) = decision else {
                expect(false, "an unreachable window must never produce a frame: \(decision)")
                return
            }
            expect(reason.contains("reach"),
                   "the reason is that there is no element to write to: \(reason)")
            expect(decision.frame == nil, "and no rectangle is decided")
        }

        test("decide refuses two equal answers by naming both, and never by choosing one") {
            let left = WindowAct.Candidate(pid: 1, appName: "Mail", title: "Inbox",
                                           frame: CGRect(x: 0, y: 34, width: 900, height: 600))
            let right = WindowAct.Candidate(pid: 1, appName: "Mail", title: "Inbox",
                                            frame: CGRect(x: 950, y: 34, width: 900, height: 600))
            let decision = WindowPlacementPolicy.decide(
                target: .slot(.left), app: "Mail", title: "Inbox",
                resolution: .ambiguous([left, right]), surfaces: [main()])
            guard case .refused(let reason) = decision else {
                expect(false, "two windows called Inbox are not a choice Chunks makes for him")
                return
            }
            expect(reason.contains("Say which one"),
                   "an ambiguity that does not ask is indistinguishable from a refusal: \(reason)")
            expect(decision.frame == nil,
                   "and the fact that one of them is further left is not a reason to pick it")
        }

        test("decide places a resolved window and hands back the exact rectangle") {
            let candidate = WindowAct.Candidate(pid: 1, appName: "Safari", title: "Inbox",
                                                frame: CGRect(x: 100, y: 100,
                                                              width: 900, height: 600))
            let decision = WindowPlacementPolicy.decide(
                target: .slot(.bottom), app: "Safari", title: "Inbox",
                resolution: .one(candidate), surfaces: [main()])
            guard case .place(let placed, let surface, let rect) = decision else {
                expect(false, "a resolved window on a real display must place: \(decision)")
                return
            }
            expectEqual(placed.title, "Inbox")
            expectEqual(surface.index, 1, "a slot is on the display the window is already on")
            expectEqual(rect, WindowPlacementPolicy.frame(for: .slot(.bottom), on: main(),
                                                          currentSize: candidate.frame.size),
                        "the probe prints this exact rectangle, so the card and the act cannot disagree")
        }

        test("a move is not permanent, so asking off does not block it") {
            let request = DoRequest.moveWindow(app: "Safari", title: "Inbox", to: .slot(.left))
            expect(!ToolLayer.alwaysAsks(request),
                   "tidying a window is exactly the routine act \"don't ask\" was chosen for — and "
                        + "it is undone by one drag")
            expect(request.invalidatesTheScreen,
                   "but it does change the screen, so a plan whose next step is a pixel waits for a "
                        + "fresh capture instead of aiming at the layout that just moved")
            expect(DoRequest.parse("move_window:Safari|Inbox|left") == request,
                   "the tag the model writes is the request the shell runs")
            expect(DoRequest.parse("move_window:Safari|Inbox|400,220") == nil,
                   "and the same tag with a pixel in it never reaches the disk of the machine")
        }

        test("a title containing a pipe still leaves the place in the right hand") {
            guard let parsed = DoRequest.windowPlacement(in: "Safari|Inbox|Draft|left") else {
                expect(false, "a window called \"Inbox|Draft\" is a real thing a browser can title"); return
            }
            expectEqual(parsed.title, "Inbox|Draft",
                        "everything before the last field is the title, or a title with a pipe in it "
                            + "would turn the place into part of the name")
            expectEqual(parsed.target, .slot(.left))
        }
    }
}
