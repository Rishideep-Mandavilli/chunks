import ChunksTestHarness
import ApplicationServices
import CoreGraphics
import Foundation
@testable import ChunksKit

/// Covers the pieces of the permissioned-act path that can be tested without a screen: parsing
/// `[ACT:…]` and `[DO:…]`, resolving image pixels to a real display point, the policy rules, the
/// consent state machine, and the halves of the tool runner that touch neither disk nor audio.
///
/// The thread running through these cases is that **the model cannot cause a press or a tool run
/// by talking**. Every step that could act has a rule here that refuses, asks, or degrades to
/// visible text.
public enum ActionTests {

    static func acts(_ events: [ReplyEvent]) -> [ActionRequest] {
        events.compactMap { if case .act(let a) = $0 { return a }; return nil }
    }
    static func tools(_ events: [ReplyEvent]) -> [DoRequest] {
        events.compactMap { if case .tool(let d) = $0 { return d }; return nil }
    }
    static func texts(_ events: [ReplyEvent]) -> String {
        events.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
    }

    static func request(_ x: Double, _ y: Double, _ label: String) -> ActionRequest {
        ActionRequest(target: PointTarget(x: x, y: y, label: label))
    }

    /// A window-list entry shaped like the ones `CGWindowListCopyWindowInfo` returns, so the
    /// filtering rules can be tested without a screen or a window server.
    static func entry(pid: Int, layer: Int, x: Double, y: Double,
                      w: Double, h: Double, owner: String = "Highlight") -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowOwnerName as String: owner,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h],
        ]
    }

    /// The dev machine's built-in display: 1710x1107 logical points at origin (0, 0).
    static let primary = CGRect(x: 0, y: 0, width: 1710, height: 1107)

    public static func register() {
        TestRunner.currentSuite = "Action"

        // MARK: Parsing [ACT:…]

        test("an [ACT:x,y,label] becomes one press proposal, not text") {
            let p = ResponseParser()
            let ev = p.feed("[ACT:820,540,Run button]") + p.finish()
            expectEqual(acts(ev).count, 1, "act tag did not become an ActionRequest")
            expectEqual(acts(ev).first?.target.x ?? -1, 820)
            expectEqual(acts(ev).first?.target.y ?? -1, 540)
            expectEqual(acts(ev).first?.label ?? "", "Run button")
            expectEqual(texts(ev), "", "the tag leaked into visible text")
        }

        test("a request defaults to press, the only verb Chunks has") {
            let p = ResponseParser()
            let ev = p.feed("[ACT:10,20,OK]")
            expectEqual(acts(ev).first?.verb ?? .press, ActionRequest.Verb.press)
        }

        test("an [ACT] split across two deltas still parses as one request") {
            let p = ResponseParser()
            var ev: [ReplyEvent] = []
            ev += p.feed("look here [ACT:12")
            expectEqual(acts(ev).count, 0, "half a tag emitted an act")
            expect(!texts(ev).contains("[ACT"), "partial tag leaked to the card while streaming")
            ev += p.feed("34,50,Run]") + p.finish()
            expectEqual(acts(ev).count, 1)
            expectEqual(acts(ev).first?.target.x ?? -1, 1234, "split delta truncated x")
            expectEqual(acts(ev).first?.target.y ?? -1, 50)
            expectEqual(acts(ev).first?.label ?? "", "Run")
        }

        test("character-by-character streaming yields exactly one act and no markup") {
            let p = ResponseParser()
            var ev: [ReplyEvent] = []
            for ch in "<SAY>pressing it now</SAY>\n[ACT:100,200,Send]" {
                ev += p.feed(String(ch))
            }
            ev += p.finish()
            expectEqual(acts(ev).count, 1, "a tag arriving one character at a time must parse once")
            expect(!texts(ev).contains("ACT"), "markup reached the visible transcript")
        }

        test("a malformed [ACT] is shown as text rather than swallowed") {
            let p = ResponseParser()
            let ev = p.feed("[ACT:somewhere,over]") + p.finish()
            expect(acts(ev).isEmpty, "garbage parsed into a press")
            expect(texts(ev).contains("[ACT:somewhere,over]"),
                   "fail-open: an unparseable act must be visible, not silently dropped")
        }

        test("[ACT:none] is consumed quietly, the same escape [POINT:none] has") {
            let p = ResponseParser()
            let ev = p.feed("[ACT:none]") + p.finish()
            expect(acts(ev).isEmpty)
            expectEqual(texts(ev), "", "\"[ACT:none]\" must not reach the card")
        }

        test("ACT and POINT in one reply stay separate constructs") {
            let p = ResponseParser()
            let ev = p.feed("[POINT:10,20,fly here] then [ACT:30,40,press this]") + p.finish()
            let points = ev.compactMap { if case .point(let q) = $0 { return q }; return nil }
            expectEqual(points.count, 1, "the point was lost")
            expectEqual(acts(ev).count, 1, "the act was lost")
            expectEqual(points.first?.label ?? "", "fly here")
            expectEqual(acts(ev).first?.label ?? "", "press this")
        }

        test("a label containing commas and colons survives, as it does for POINT") {
            let p = ResponseParser()
            let ev = p.feed("[ACT:5,6,OK: yes, do it]") + p.finish()
            expectEqual(acts(ev).first?.label ?? "", "OK: yes, do it")
        }

        test("the screen suffix on an ACT selects that display") {
            let p = ResponseParser()
            let ev = p.feed("[ACT:5,6,Send:screen2]") + p.finish()
            expectEqual(acts(ev).first?.target.display ?? 0, 2)
            expectEqual(acts(ev).first?.label ?? "", "Send")
        }

        // MARK: AnswerStreamer

        test("the streamer collects acts without polluting the shown detail") {
            let s = AnswerStreamer()
            s.push("<SAY>Pressing send</SAY>\n[ACT:820,540,Send]")
            s.finish()
            expectEqual(s.actionRequests.count, 1)
            expect(!s.detail.contains("ACT"), "the act tag showed up in the transcript")
        }

        test("two acts in one turn are both kept, in order") {
            let s = AnswerStreamer()
            s.push("[ACT:1,2,first] [ACT:3,4,second]")
            s.finish()
            expectEqual(s.actionRequests.count, 2, "a second proposal must not replace the first unseen")
            expectEqual(s.actionRequests.map(\.label), ["first", "second"])
        }

        // MARK: ScreenshotGeometry: the aim -> display mapping

        test("the middle of the grid is the middle of the display") {
            let got = ScreenshotGeometry.appKitGlobalPoint(x: 500, y: 500,
                                                           imageWidth: 1280, imageHeight: 829,
                                                           displayFrame: primary)
            expectEqual(got?.x ?? -1, 855)
            expectEqual(got?.y ?? -1, 553.5, "image Y runs from the top; AppKit Y from the bottom")
        }

        test("the top of the grid is the top of the display, not the bottom") {
            let top = ScreenshotGeometry.appKitGlobalPoint(x: 0, y: 0,
                                                           imageWidth: 1280, imageHeight: 829,
                                                           displayFrame: primary)
            let bottom = ScreenshotGeometry.appKitGlobalPoint(x: 0, y: 1000,
                                                              imageWidth: 1280, imageHeight: 829,
                                                              displayFrame: primary)
            expectEqual(top?.y ?? -1, 1106.5, "Y is inverted exactly once")
            expectEqual(bottom?.y ?? -1, 0.5)
        }

        test("the send button the model aimed at three times now lands on the send button") {
            // Measured 2026-10-04 in the live log, against a 1280x829 image of a 1710x1107
            // display: `[ACT:955,975:"send button"]`, `[ACT:955,977]`, `[ACT:956,974]`, each one
            // answering `nothing found at (1275.8, 1107.0)`. The button was at AX point
            // (1651, 1086). Divided by the image size the aim was 118% down the screen and clamped
            // onto a row no window owns; divided by the 0–1000 grid the model actually answers in
            // it lands on the button.
            let aim = ScreenshotGeometry.appKitGlobalPoint(x: 955, y: 975,
                                                           imageWidth: 1280, imageHeight: 829,
                                                           displayFrame: primary)
            let ax = aim.map { ScreenshotGeometry.axGlobalPoint(appKitGlobalPoint: $0,
                                                                primaryScreenHeight: 1107) }
            guard let resolved = ax else { expect(false, "the aim did not map at all"); return }
            expect(abs(resolved.x - 1651) < 25,
                   "x landed at \(resolved.x), 25 pt or more off the control the user named")
            expect(abs(resolved.y - 1086) < 25,
                   "y landed at \(resolved.y) — the row the user asked about is at 1086")
        }

        test("an aim over 1000 is the model answering in pixels, and is read that way") {
            // A 0–1000 answer cannot exceed 1000, so a bigger number is unambiguous: the model
            // used the dimensions in the image label. Both axes move together, or the aim shears.
            let pixels = ScreenshotGeometry.appKitGlobalPoint(x: 2400, y: 1500,
                                                              imageWidth: 3420, imageHeight: 2214,
                                                              displayFrame: primary)
            expectEqual(pixels?.x ?? -1, 1200)
            expectEqual(pixels?.y ?? -1, 357)
            expectEqual(ScreenshotGeometry.aimSpace(x: 2400, y: 1500), .imagePixels)
            expectEqual(ScreenshotGeometry.aimSpace(x: 955, y: 975), .grid,
                        "a grid answer in the left half was read as pixels and sheared")
        }

        test("the grid makes the capture's resolution irrelevant, and the fallback stays exact") {
            // The grid is the reason a resized screenshot cannot skew an aim: the numbers say a
            // fraction, so 1280 or 3420 wide maps to the same point. The pixel fallback can only be
            // recognised when a value exceeds 1000 — a 1x answer under 1000 is genuinely
            // ambiguous, and reading it as the grid is the documented choice, not an oversight.
            let anchor = ScreenshotGeometry.appKitGlobalPoint(x: 250, y: 750,
                                                              imageWidth: 1280, imageHeight: 829,
                                                              displayFrame: primary)
            expectEqual(anchor?.x ?? -1, 427.5)
            expectEqual(anchor?.y ?? -1, 276.75)

            for scale in [2.0, 3.0] {
                let w = primary.width * scale
                let h = primary.height * scale
                let pixels = ScreenshotGeometry.appKitGlobalPoint(x: w * 0.25, y: h * 0.75,
                                                                  imageWidth: w, imageHeight: h,
                                                                  displayFrame: primary)
                expect(ScreenshotGeometry.aimSpace(x: w * 0.25, y: h * 0.75) == .imagePixels,
                       "a \(scale)x pixel answer was read as the grid")
                expect(abs((pixels?.x ?? 0) - 427.5) < 0.01, "the pixel fallback drifted at \(scale)x")
                expect(abs((pixels?.y ?? 0) - 276.75) < 0.01, "the pixel fallback drifted at \(scale)x")
            }
        }

        test("an aim at the very edge of the screen stays inside a window") {
            // `CGWindowListCopyWindowInfo` bounds and the AX hit test are exclusive at the far
            // edge, so a point *on* the bottom row resolves to no window at all — which is how a
            // visible input bar answered "that app did not expose a control".
            let left = ScreenshotGeometry.appKitGlobalPoint(x: -500, y: -500,
                                                            imageWidth: 1280, imageHeight: 829,
                                                            displayFrame: primary)
            let right = ScreenshotGeometry.appKitGlobalPoint(x: 1500, y: 4000,
                                                             imageWidth: 1280, imageHeight: 829,
                                                             displayFrame: primary)
            expectEqual(left?.x ?? -1, 0.5, "a negative aim must not press off-screen")
            expectEqual(left?.y ?? -1, 1106.5)
            expectEqual(right?.x ?? -1, 1709.5)
            expectEqual(right?.y ?? -1, 0.5)
            expect(primary.contains(right!), "the mapped aim has to be inside the display it maps to")
        }

        test("a zero-size image returns nil rather than NaN") {
            expect(ScreenshotGeometry.appKitGlobalPoint(x: 10, y: 10,
                                                        imageWidth: 0, imageHeight: 0,
                                                        displayFrame: primary) == nil,
                   "dividing by a zero-width screenshot gives NaN, which lands nowhere")
        }

        test("a secondary display's origin is added, not assumed to be zero") {
            let second = CGRect(x: 1710, y: 0, width: 1600, height: 1000)
            let got = ScreenshotGeometry.appKitGlobalPoint(x: 500, y: 500,
                                                           imageWidth: 1280, imageHeight: 829,
                                                           displayFrame: second)
            expectEqual(got?.x ?? -1, 2510, "offset display frames lost their origin")
            expectEqual(got?.y ?? -1, 500)
        }

        test("the label next to the image states the grid, not just the pixel size") {
            let note = ScreenshotGeometry.coordinateSpaceNote(imageWidth: 1280, imageHeight: 829)
            expect(note.contains("1280") && note.contains("829"),
                   "the model is shown a resized image and has to know which one it is looking at")
            expect(note.contains("0–1000"),
                   "the space to answer in has to be said at the picture, not only in the prompt")
            expect(note.contains("not in pixels"),
                   "the measured failure was answering in the pixel size that appears in this note")
        }

        test("AppKit global to AX global flips Y around the primary height, and back") {
            let appKit = CGPoint(x: 855, y: 1107)   // top-left corner of the main display
            let ax = ScreenshotGeometry.axGlobalPoint(appKitGlobalPoint: appKit,
                                                      primaryScreenHeight: 1107)
            expectEqual(ax.y, 0, "AX hit-tests in top-left space")
            let back = ScreenshotGeometry.axGlobalPoint(appKitGlobalPoint: ax,
                                                        primaryScreenHeight: 1107)
            expectEqual(back, appKit, "the flip is its own inverse")
        }

        // MARK: PolicyGate

        test("an ordinary button in an ordinary app asks once — it is not forbidden") {
            let d = PolicyGate.decide(target: ActionTargetInfo(
                bundleID: "com.codingcat.highlight", appName: "Highlight", role: "AXButton"))
            expectEqual(d, .needsConsent,
                        "over-refusing would make the feature useless; this is the common case")
        }

        test("a secure field is refused even in an app the user always allows") {
            let target = ActionTargetInfo(bundleID: "com.apple.Safari", appName: "Safari",
                                          role: "AXSecureTextField")
            let d = PolicyGate.decide(target: target, alwaysAllowedBundleIDs: ["com.apple.Safari"])
            if case .forbidden(let reason) = d {
                expect(reason.contains("secure"), "the reason should say why: \(reason)")
            } else {
                expect(false, "AXSecureTextField must never be automated, allowance or not")
            }
        }

        test("the Keychain is refused by bundle id") {
            let d = PolicyGate.decide(target: ActionTargetInfo(
                bundleID: "com.apple.keychainaccess", appName: "Keychain Access"))
            if case .forbidden = d { } else {
                expect(false, "a press inside Keychain Access must be refused outright")
            }
        }

        test("a password manager is refused by name when it reports no bundle id") {
            let d = PolicyGate.decide(target: ActionTargetInfo(bundleID: nil, appName: "1Password"))
            if case .forbidden(let reason) = d {
                expect(reason.contains("1Password"), "the reason should name the app: \(reason)")
            } else {
                expect(false, "name-only matching is the fallback for apps without a bundle id")
            }
        }

        test("an app the user chose to always allow skips the question but not the rules") {
            let d = PolicyGate.decide(target: ActionTargetInfo(
                bundleID: "com.apple.mail", appName: "Mail", role: "AXButton"),
                alwaysAllowedBundleIDs: ["com.apple.mail"])
            expectEqual(d, .allowedWithoutAsking)
        }

        test("missing metadata fails toward asking, never toward acting") {
            let d = PolicyGate.decide(target: ActionTargetInfo())
            expectEqual(d, .needsConsent,
                        "an unknown app must not become allowedWithoutAsking by omission")
        }

        test("an unnamed app is still described in the refusal") {
            let name = PolicyGate.displayName(of: ActionTargetInfo(appName: "   "))
            expectEqual(name, "that app", "a blank name would render as 'inside .'")
        }

        // Turning the confirm card off is a standing instruction about *asking*, so it has to
        // reach every ordinary press — and must not be able to reach the forbidden ones. A
        // boolean placed in front of the rule list would make the app a remote control for the
        // machine, which is the opposite of what this gate exists for.
        test("asking off lets an ordinary press through without a card") {
            let d = PolicyGate.decide(target: ActionTargetInfo(
                bundleID: "com.apple.mail", appName: "Mail", role: "AXButton"),
                askBeforePressing: false)
            expectEqual(d, .allowedWithoutAsking,
                        "the user asked Chunks to act on what they name, not to question it")
        }

        test("asking off does not unlock a secure field") {
            let d = PolicyGate.decide(target: ActionTargetInfo(
                bundleID: "com.apple.Safari", appName: "Safari", role: "AXSecureTextField"),
                askBeforePressing: false)
            if case .forbidden = d { } else {
                expect(false, "without the ask, an app-wide 'don't ask' would otherwise press "
                              + "password fields and payment confirmations with nobody watching")
            }
        }

        test("asking off does not unlock the Keychain or a password manager") {
            let keychain = PolicyGate.decide(target: ActionTargetInfo(
                bundleID: "com.apple.keychainaccess", appName: "Keychain Access"),
                askBeforePressing: false)
            if case .forbidden = keychain { } else {
                expect(false, "a press inside Keychain Access is a grant, not a click")
            }

            let manager = PolicyGate.decide(target: ActionTargetInfo(bundleID: nil,
                                                                     appName: "Bitwarden"),
                                            askBeforePressing: false)
            if case .forbidden = manager { } else {
                expect(false, "name-only refusal has to survive the switch too")
            }
        }

        test("asking on keeps the ordinary question") {
            let d = PolicyGate.decide(target: ActionTargetInfo(
                bundleID: "com.apple.mail", appName: "Mail", role: "AXButton"),
                askBeforePressing: true)
            expectEqual(d, .needsConsent,
                        "the new parameter must not quietly invert the consent path")
        }

        // MARK: ConsentGate

        test("allowing once returns the request and closes the question") {
            var gate = ConsentGate()
            gate.stage(.press(ActionTests.request(1, 2, "Send")))
            expect(gate.resolve(.allowedOnce) == PendingAct.press(ActionTests.request(1, 2, "Send")),
                   "an approval has to hand back the exact request the card showed")
            expect(!gate.isPending, "the card must not stay up after an answer")
        }

        test("denying returns nothing to act on") {
            var gate = ConsentGate()
            gate.stage(.press(ActionTests.request(1, 2, "Send")))
            expect(gate.resolve(.denied) == nil, "a denial must never produce a press")
            expectEqual(gate.lastOutcome ?? .allowedOnce, .denied)
        }

        test("answering twice does nothing twice") {
            var gate = ConsentGate()
            gate.stage(.press(ActionTests.request(1, 2, "Send")))
            expect(gate.resolve(.allowedOnce) != nil)
            expect(gate.resolve(.allowedOnce) == nil,
                   "a double tap on Allow must not press the control twice")
        }

        test("answering when nothing is pending is inert") {
            var gate = ConsentGate()
            expect(gate.resolve(.allowedOnce) == nil)
            expect(gate.cancel() == nil)
        }

        test("a new request displaces an unanswered one, and the displaced one is denied") {
            var gate = ConsentGate()
            gate.stage(.press(ActionTests.request(1, 2, "first")))
            let displaced = gate.stage(.press(ActionTests.request(3, 4, "second")))
            expectEqual(displaced, PendingAct.press(ActionTests.request(1, 2, "first")),
                        "the caller must know it was dropped")
            expectEqual(gate.lastOutcome ?? .allowedOnce, .denied)
            expectEqual(gate.pending, PendingAct.press(ActionTests.request(3, 4, "second")))
        }

        test("canceling the card withdraws the act") {
            var gate = ConsentGate()
            gate.stage(.press(ActionTests.request(1, 2, "Send")))
            expectEqual(gate.cancel(), PendingAct.press(ActionTests.request(1, 2, "Send")))
            expect(!gate.isPending, "dismissing the notch must not leave a live press waiting")
        }

        test("always-allow is a distinct answer from allow-once") {
            var gate = ConsentGate()
            gate.stage(.press(ActionTests.request(1, 2, "Send")))
            expectEqual(gate.resolve(.alwaysAllowed), PendingAct.press(ActionTests.request(1, 2, "Send")))
            expectEqual(gate.lastOutcome ?? .denied, .alwaysAllowed,
                        "the caller needs the distinction to record the allowance")
        }

        test("a press and a tool run cannot be pending at the same time") {
            // One card, one question. If the gate could hold both, "Allow" would answer an
            // ambiguous request — the user could not tell whether they approved a click, a
            // volume change, or both.
            var gate = ConsentGate()
            gate.stage(.press(ActionTests.request(1, 2, "Send")))
            let displaced = gate.stage(.tool(DoRequest.openApp(name: "Notes")))
            expectEqual(displaced, PendingAct.press(ActionTests.request(1, 2, "Send")),
                        "a tool request must not silently park the press it replaced")
            expectEqual(gate.pending, PendingAct.tool(DoRequest.openApp(name: "Notes")))
            expectEqual(gate.resolve(.allowedOnce), PendingAct.tool(DoRequest.openApp(name: "Notes")))
        }

        // MARK: AXTDriver — answering to a name

        // A model's label describes what it *saw*; an element's title is what the app *calls* it.
        // These are the pairs that have to line up for "click the Pluralsight icon" to press the
        // icon rather than the pixel the model guessed at.
        test("a name the app publishes is matched exactly, article and verb stripped") {
            expectEqual(AXTDriver.nameScore(label: "Pluralsight", title: "Pluralsight"), 3)
            expectEqual(AXTDriver.nameScore(label: "click the pluralsight app",
                                            title: "Pluralsight"), 3,
                        "the sentence around the name must not cost the match")
        }

        test("a file's kind matches even when its title carries a timestamp") {
            let score = AXTDriver.nameScore(label: "desktop screenshot",
                                            title: "Screenshot 2026-09-13 at 9.09.04 PM")
            expect(score >= 1,
                   "a screenshot on the desktop is exactly the case the aim keeps missing")
        }

        test("an unrelated name scores nothing") {
            expectEqual(AXTDriver.nameScore(label: "Notes", title: "Mail"), 0,
                        "a match on nothing must not become a press on something")
        }

        // The desktop fallback reaches into Finder's icon list from an aim that landed in some
        // other app's window (measured 2026-10-04: "free claude code" aimed at (1287,86), which is
        // Qoder's window; the icon is at (1648,73)). Crossing apps on one shared word would let a
        // vague description press whichever icon the tree walk happened to reach first.
        // The wrong-row press measured 2026-10-05: "click Nitesh GVP 2" in WhatsApp's chat list,
        // the aim landed one row down on "Tech Eximius 2026", and the pixel won because the pixel
        // always used to win. Rows are ~70 pt apart and a model's aim is good to about that.
        test("a pixel that lands on a differently-named control does not keep the press") {
            expect(!AXTDriver.pixelKeepsPress(label: "Nitesh GVP 2", names: ["Tech Eximius 2026"]),
                   "a name that shares nothing with the request is the signal to search first")
            expect(AXTDriver.pixelKeepsPress(label: "Nitesh GVP 2", names: ["Nitesh GVP 2"]),
                   "the aim that found the right row must not be talked out of it")
            expect(AXTDriver.pixelKeepsPress(label: "the send icon", names: []),
                   "an unnamed control cannot contradict anyone, so the pixel stands")
        }

        test("a press onto a control with another name is visible in the log") {
            let wrong = AXElementInfo(pid: 1, appName: "WhatsApp", role: "AXButton",
                                      title: "Tech Eximius 2026")
            expect(AXTDriver.aimNamesSomethingElse(label: "Nitesh GVP 2", element: wrong),
                   "with no card to catch it, the mismatch has to be sayable afterwards")
            let right = AXElementInfo(pid: 1, appName: "WhatsApp", role: "AXButton",
                                      title: "Nitesh GVP 2")
            expect(!AXTDriver.aimNamesSomethingElse(label: "Nitesh GVP 2", element: right),
                   "no noise when the aim and the name agree")
            let unnamed = AXElementInfo(pid: 1, appName: "WhatsApp", role: "AXGroup")
            expect(!AXTDriver.aimNamesSomethingElse(label: "the send icon", element: unnamed),
                   "an element that publishes no name is not evidence of a wrong press")
        }

        test("a description that only shares one word cannot reach across to the desktop") {
            expect(AXTDriver.nameScore(label: "free claude code", title: "Free Claude Code")
                       >= AXTDriver.desktopMinNameScore,
                   "the icon the user pointed at has to be matchable by its real name")
            expect(AXTDriver.nameScore(label: "the claude thing", title: "Free Claude Code")
                       < AXTDriver.desktopMinNameScore,
                   "one shared word is a hint inside a window, not a licence to press in another app")
            expect(AXTDriver.nameScore(label: "pluralsight icon", title: "O'Reilly")
                       < AXTDriver.desktopMinNameScore,
                   "the neighbour an aim lands next to must not become the press")
        }

        // The safety half of the feature: if the label is only filler, there is no name to match,
        // and a press must not be invented out of the words that describe the *action*.
        test("a label of pure filler matches no element at all") {
            expectEqual(AXTDriver.nameScore(label: "click the icon", title: "Pluralsight"), 0,
                        "\"icon\" and \"click\" name the verb, never the target")
            let candidates = [AXTDriver.NamedElementMatch(title: "Pluralsight"),
                              AXTDriver.NamedElementMatch(title: "Notes")]
            expect(AXTDriver.bestMatch(label: "open the app", candidates: candidates,
                                       near: .zero) == nil,
                   "filler would otherwise press the first control the tree walk happened to reach")
        }

        test("the nearer of two same-named controls wins, and a better name beats distance") {
            let far = AXTDriver.NamedElementMatch(
                title: "Screenshot one", frame: CGRect(x: 0, y: 0, width: 64, height: 64))
            let near = AXTDriver.NamedElementMatch(
                title: "Screenshot two", frame: CGRect(x: 900, y: 900, width: 64, height: 64))
            let exact = AXTDriver.NamedElementMatch(
                title: "Pluralsight", frame: CGRect(x: 1000, y: 1000, width: 64, height: 64))

            expectEqual(AXTDriver.bestMatch(label: "screenshot two", candidates: [far, near],
                                            near: CGPoint(x: 930, y: 930)), 1,
                        "two tiles of the same kind are told apart by where the model aimed")
            expectEqual(AXTDriver.bestMatch(label: "pluralsight",
                                            candidates: [near, far, exact],
                                            near: CGPoint(x: 0, y: 0)), 2,
                        "an exact name must outrank a closer partial one")
        }

        // MARK: AXTDriver — which window a press may even target

        test("our own windows are never press candidates") {
            let entries = [ActionTests.entry(pid: 4242, layer: 0, x: 0, y: 0, w: 400, h: 300, owner: "Chunks"),
                           ActionTests.entry(pid: 99, layer: 0, x: 0, y: 0, w: 1000, h: 800)]
            let candidates = AXTDriver.candidateWindows(from: entries, ownPID: 4242)
            expectEqual(candidates.count, 1,
                        "leaving our own card in lets Chunks press the Allow button it is asking about")
            expectEqual(candidates.first?.pid, 99)
        }

        test("only layer 0 counts as a window") {
            let entries = [ActionTests.entry(pid: 1, layer: 0, x: 0, y: 0, w: 500, h: 400),
                           ActionTests.entry(pid: 2, layer: 3, x: 0, y: 0, w: 500, h: 400, owner: "Floating Panel"),
                           ActionTests.entry(pid: 3, layer: 2147483627, x: 0, y: 0, w: 500, h: 24, owner: "Menubar")]
            let candidates = AXTDriver.candidateWindows(from: entries, ownPID: 0)
            expectEqual(candidates.map(\.pid), [1],
                        "menus and the menu bar are not what the user means by 'that window'")
        }

        // "Click the file on my desktop" is an instruction about a thing the user can see. The
        // desktop is a window below layer 0, so the strict rule above answered it with "there is
        // no app window there" — the widening below is what lets the hit test reach it, while
        // surfaces *above* 0 (menus, notifications, panels) stay unreachable.
        test("the desktop is only a target when the caller asks for it") {
            let entries = [ActionTests.entry(pid: 1, layer: 0, x: 0, y: 0, w: 500, h: 400),
                           ActionTests.entry(pid: 4, layer: -2147483623, x: 0, y: 0, w: 1512, h: 900,
                                             owner: "Finder"),
                           ActionTests.entry(pid: 5, layer: 7, x: 0, y: 0, w: 500, h: 400, owner: "Notification")]
            expectEqual(AXTDriver.candidateWindows(from: entries, ownPID: 0).map(\.pid), [1],
                        "the default list must stay exactly as strict as it was")

            let widened = AXTDriver.candidateWindows(from: entries, ownPID: 0, includeDesktop: true)
            expectEqual(widened.map(\.pid), [1, 4],
                        "a point on the wallpaper should resolve to the desktop, never to a "
                            + "notification or a panel floating over it")
        }

        test("a real window still wins over a desktop icon behind it") {
            let desktop = WindowRecord(pid: 4, layer: -2147483623,
                                       bounds: CGRect(x: 0, y: 0, width: 1512, height: 900))
            let window = WindowRecord(pid: 1, layer: 0,
                                      bounds: CGRect(x: 100, y: 100, width: 300, height: 200))
            // `currentWindowCandidatesIncludingDesktop` appends the desktop last, so front-to-back
            // order in the combined list already puts a real window first.
            let got = AXTDriver.topmostWindow([window, desktop], containing: CGPoint(x: 150, y: 150))
            expectEqual(got?.pid, 1,
                        "pressing the icon behind the window the user is looking at is a wrong press")
        }

        test("a malformed or empty entry is skipped, not fatal") {
            let entries: [[String: Any]] = [
                [:],
                [kCGWindowOwnerPID as String: 7],
                ActionTests.entry(pid: 8, layer: 0, x: 0, y: 0, w: 0, h: 0),
                ActionTests.entry(pid: 9, layer: 0, x: 10, y: 20, w: 100, h: 50),
            ]
            let candidates = AXTDriver.candidateWindows(from: entries, ownPID: 0)
            expectEqual(candidates.count, 1, "a zero-size window is a hit target for nothing")
            expect(candidates.first?.bounds == CGRect(x: 10, y: 20, width: 100, height: 50),
                   "window bounds did not parse")
            expectEqual(candidates.first?.ownerName ?? "", "Highlight")
        }

        test("the front window wins when two overlap the point") {
            let front = WindowRecord(pid: 1, layer: 0, bounds: CGRect(x: 100, y: 100, width: 300, height: 200))
            let behind = WindowRecord(pid: 2, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 900))
            let got = AXTDriver.topmostWindow([front, behind], containing: CGPoint(x: 150, y: 150))
            expectEqual(got?.pid, 1, "picking by area would press the window behind the dialog")
        }

        test("a point in the gap between windows resolves to nothing") {
            let a = WindowRecord(pid: 1, layer: 0, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
            let b = WindowRecord(pid: 2, layer: 0, bounds: CGRect(x: 200, y: 0, width: 100, height: 100))
            expect(AXTDriver.topmostWindow([a, b], containing: CGPoint(x: 150, y: 50)) == nil,
                   "off-window points must not press a neighbour")
        }

        test("an empty window list is an honest no-window answer") {
            expect(AXTDriver.topmostWindow([], containing: .zero) == nil)
            expect(!AXTDriver.PressResult.noWindow(containing: .zero).didPress)
        }

        // MARK: AXTDriver — how an element is described to the user

        test("the element's own name is preferred, in order") {
            let named = AXElementInfo(pid: 1, appName: "Mail", role: "AXButton", title: "Send")
            expectEqual(named.elementLabel, "Send", "the card should show the real control name")

            let described = AXElementInfo(pid: 1, role: "AXButton", descriptionText: "Reply")
            expectEqual(described.elementLabel, "Reply")

            let roleOnly = AXElementInfo(pid: 1, role: "AXCheckBox")
            expectEqual(roleOnly.elementLabel, "AXCheckBox")

            let blank = AXElementInfo(pid: 1, role: "AXButton", title: "   ")
            expectEqual(blank.elementLabel, "AXButton", "whitespace is not a name")

            let nothing = AXElementInfo(pid: 1)
            expectEqual(nothing.elementLabel, "that control",
                        "a card reading 'Press  ?' is worse than a generic phrase")
        }

        test("the policy target carries role and app, and the caller supplies the bundle id") {
            let info = AXElementInfo(pid: 1, appName: "Mail", role: "AXButton", title: "Send")
            let target = info.policyTarget(bundleID: "com.apple.mail")
            expectEqual(target.bundleID, "com.apple.mail")
            expectEqual(target.appName, "Mail")
            expectEqual(target.role, "AXButton")
            expectEqual(target.elementLabel, "Send")
        }

        test("an element is not pressable until something answers to an action") {
            let found = AXElementInfo(pid: 1, appName: "Chrome", role: "AXGroup")
            expect(!found.isPressable,
                   "a bare group must not become a yes/no question — found live: a Chromium page "
                     + "resolves to an unnamed group whose only name is the window title")

            let button = AXElementInfo(pid: 1, appName: "Mail", role: "AXButton",
                                       title: "Send", isPressable: true)
            expect(button.isPressable)
        }

        test("a window title used as a control name is cut to one readable line") {
            let long = AXElementInfo(pid: 1, appName: "Chrome", role: "AXGroup",
                                     title: "(494) 🚨BREAKING FLYDUBAI Hijacked Co-Pilot Details "
                                        + "Exposed |Decoding 10-7-3 MYSTERY, 29Sec PLUNGE|VR Raja "
                                        + "- YouTube – Audio playing – Rishideep")
            expect(long.elementLabel.count <= AXElementInfo.labelCharacterBudget + 1,
                   "the question row is measured for one line, got \(long.elementLabel.count) chars")
            expect(long.elementLabel.hasSuffix("…"), "the cut should be visible: \(long.elementLabel)")
        }

        test("every failure outcome reports didPress false and a reason that names the fix") {
            let info = AXElementInfo(pid: 1, appName: "Mail", role: "AXGroup")
            let outcomes: [AXTDriver.PressResult] = [
                .permissionMissing,
                .noWindow(containing: .zero),
                .noElement(containing: .zero),
                .notPressable(element: info),
                .actionFailed(code: -25205, action: "AXOpen",
                              advertised: ["AXOpen", "AXShowMenu"], element: info),
            ]
            for outcome in outcomes {
                expect(!outcome.didPress, "\(outcome) must not read as success")
                expect(!outcome.userFacingReason.isEmpty, "\(outcome) has no reason to show")
            }
            expect(outcomes[0].userFacingReason.contains("Accessibility"),
                   "the permission failure is the one the user can fix themselves")
        }

        test("a failed press says which verb failed and what the control advertised") {
            // Measured on the first live desktop-icon press: the icon advertised AXOpen, Chunks
            // performed AXOpen, and the reply was -25205 with nothing opened — and the line the user
            // heard was "the app refused the press", which told them nothing about whether Chunks
            // asked for the wrong verb or the app lied.
            let info = AXElementInfo(pid: 1, appName: "Finder", role: "AXImage", title: "Pluralsight")
            let line = AXTDriver.PressResult
                .actionFailed(code: -25205, action: "AXOpen",
                              advertised: ["AXOpen", "AXShowMenu"], element: info)
                .userFacingReason
            expect(line.contains("AXOpen"), "the refused verb has to be in the line: \(line)")
            expect(line.contains("-25205"), "the code is the only thing a fixer can grep for: \(line)")
            expect(line.contains("attributeUnsupported"),
                   "the number alone is not something a reader can act on: \(line)")
            expect(line.contains("AXShowMenu"),
                   "without the advertised list this reads as our bug, not the app's: \(line)")
            expect(line.contains("Pluralsight"), "the user should see the thing they named: \(line)")
        }

        test("the codes that mean the app answered badly are the ones worth one look at") {
            // -25205, -25204 and -25200 say the app took the request and reported it badly, so the
            // effect is unknown and worth checking for focus. -25206 is the opposite: it states the
            // verb did not run, so `perform` answers it with the next verb instead of waiting.
            expect(AXTDriver.isAmbiguousFailure(-25205), "what AXOpen on a desktop icon answered")
            expect(AXTDriver.isAmbiguousFailure(-25204), "an unresponsive app answers this")
            expect(AXTDriver.isAmbiguousFailure(-25200), "a bare failure says nothing about the effect")
            expect(!AXTDriver.isAmbiguousFailure(-25206),
                   "actionUnsupported means it did not run — retry the verb, do not wait")
            expect(!AXTDriver.isAmbiguousFailure(-25202),
                   "a torn-down element is not a press that landed")
            expect(!AXTDriver.isAmbiguousFailure(0), "success never reaches this check")
        }

        test("an icon is selected before it is opened, and an ordinary button is not") {
            // Read off the desktop's own action list: every icon is `AXImage` advertising
            // `AXOpen, AXShowMenu` and nothing else, and performing `AXOpen` alone came back
            // refused with nothing opened. A double-click selects first, so Chunks has to as well.
            expect(AXTDriver.shouldSelectFirst(action: "AXOpen"),
                   "the desktop-icon press is the case this exists for")
            expect(!AXTDriver.shouldSelectFirst(action: kAXPressAction),
                   "selecting a button the user never named moves focus out from under them")
            expect(!AXTDriver.shouldSelectFirst(action: kAXPickAction),
                   "a menu item is not a selection holder")
        }

        test("a failure code is spelled as the word a reader can act on") {
            // One digit apart, opposite meanings: this is the distinction that decided whether the
            // Pluralsight press had worked, and a bare number hides it.
            expectEqual(AXTDriver.errorCodeName(-25205), "attributeUnsupported")
            expectEqual(AXTDriver.errorCodeName(-25206), "actionUnsupported")
            expectEqual(AXTDriver.errorCodeName(-25204), "cannotComplete")
            expect(AXTDriver.errorCodeName(-25999).contains("-25999"),
                   "an unmapped code still has to show its number")
        }

        test("the press is believed from its effect, not from the code the target returned") {
            // The O'Reilly turn in one pair of snapshots: the icon belongs to Finder, Finder
            // answered `AXOpen` with -25205, and the app the user named opened anyway. A check that
            // only watched the pressed element's pid (Finder's) kept reporting that as a refusal.
            let before = AXTDriver.PressSnapshot(frontmostPID: 100,
                                                 runningApps: [100: "Safari", 7: "Finder"])
            let launched = AXTDriver.PressSnapshot(frontmostPID: 42,
                                                   runningApps: [100: "Safari", 7: "Finder",
                                                                 42: "O'Reilly"])
            expect(AXTDriver.pressLanded(before: before, after: launched, label: "o'reilly icon"),
                   "the named app started and took the front — that is the press landing")
            expect(!AXTDriver.pressLanded(before: before, after: before, label: "o'reilly icon"),
                   "nothing changed, so the failure stands — an error code alone is not a success")
            let lostFocus = AXTDriver.PressSnapshot(frontmostPID: nil,
                                                    runningApps: [100: "Safari", 7: "Finder"])
            expect(!AXTDriver.pressLanded(before: before, after: lostFocus, label: "send button"),
                   "nothing frontmost cannot confirm a press")
        }

        test("an app that was already running lands the press by taking focus alone") {
            let before = AXTDriver.PressSnapshot(frontmostPID: 100,
                                                 runningApps: [100: "Safari", 7: "Finder",
                                                               42: "Notes"])
            let after = AXTDriver.PressSnapshot(frontmostPID: 42,
                                                runningApps: [100: "Safari", 7: "Finder",
                                                              42: "Notes"])
            expect(AXTDriver.pressLanded(before: before, after: after, label: "notes"),
                   "focus moved to a different app, which a refused action does not do")
        }

        test("an app that starts without taking focus lands the press only if it answers the label") {
            let before = AXTDriver.PressSnapshot(frontmostPID: 100,
                                                 runningApps: [100: "Safari", 7: "Finder"])
            let pluralsight = AXTDriver.PressSnapshot(frontmostPID: 100,
                                                      runningApps: [100: "Safari", 7: "Finder",
                                                                    42: "Pluralsight"])
            expect(AXTDriver.pressLanded(before: before, after: pluralsight,
                                         label: "the pluralsight app"),
                   "a launch behind a dialog still has the right name to be believed by")
            // An unrelated process starting in the same window says nothing about this press, and
            // claiming otherwise would let any background app manufacture a reported success.
            let unrelated = AXTDriver.PressSnapshot(frontmostPID: 100,
                                                    runningApps: [100: "Safari", 7: "Finder",
                                                                  42: "Music"])
            expect(!AXTDriver.pressLanded(before: before, after: unrelated,
                                          label: "the pluralsight app"),
                   "a new app nobody asked for is not evidence")
        }

        test("a press the app reported as failed but which opened the app claims success") {
            let info = AXElementInfo(pid: 1, appName: "Finder", role: "AXImage", title: "Pluralsight")
            let result = AXTDriver.PressResult.landedByEffect(element: info, action: "AXOpen",
                                                              code: -25205)
            expect(result.didPress, "the icon opened, so the act is done")
            expect(result.userFacingReason.contains("Pressed Pluralsight"),
                   "the user is told what happened, not that it was refused: \(result.userFacingReason)")
        }

        test("a successful press is the only outcome that claims success") {
            let info = AXElementInfo(pid: 1, appName: "Mail", role: "AXButton", title: "Send")
            let result = AXTDriver.PressResult.pressed(element: info, action: kAXPressAction)
            expect(result.didPress)
            expect(result.userFacingReason.contains("Send"), "the card should confirm what it did")
        }

        // MARK: Parsing [DO:…] — the tool protocol

        test("a [DO:open_app:Notes] becomes one tool request, not text") {
            let p = ResponseParser()
            let ev = p.feed("[DO:open_app:Notes]") + p.finish()
            expectEqual(tools(ev).count, 1, "tool tag did not become a DoRequest")
            expectEqual(tools(ev).first, DoRequest.openApp(name: "Notes"))
            expectEqual(texts(ev), "", "the tool tag leaked into visible text")
        }

        test("a tool tag split across deltas still becomes exactly one request") {
            let p = ResponseParser()
            var ev: [ReplyEvent] = []
            ev += p.feed("one moment. [DO:open")
            expectEqual(tools(ev).count, 0, "half a tag emitted a tool run")
            expect(!texts(ev).contains("[DO"), "partial tag leaked to the card while streaming")
            ev += p.feed("_app:Notes]") + p.finish()
            expectEqual(tools(ev).count, 1)
            expectEqual(tools(ev).first, DoRequest.openApp(name: "Notes"))
            expectEqual(texts(ev), "one moment. ")
        }

        test("a tool tag fed one character at a time never appears as markup") {
            let p = ResponseParser()
            var ev: [ReplyEvent] = []
            for ch in "<SAY>quieter now</SAY>\n[DO:set_volume:30]" {
                ev += p.feed(String(ch))
            }
            ev += p.finish()
            expectEqual(tools(ev).count, 1, "a tag arriving one character at a time must parse once")
            expect(!texts(ev).contains("DO"), "markup reached the visible transcript")
        }

        test("an unknown tool is shown to the user, never guessed into something close") {
            let p = ResponseParser()
            let ev = p.feed("[DO:delete_all_messages:inbox]") + p.finish()
            expect(tools(ev).isEmpty, "an unrecognised tool must not become a run")
            expectEqual(texts(ev), "[DO:delete_all_messages:inbox]",
                        "fail open: the user sees the thing the model tried to ask for")
        }

        test("an app name that is a path is refused before it can become a question") {
            // `[DO:open_app:X]` names an installed app. A slash or a leading dot means the
            // tag is aiming somewhere else, and that is exactly how a prompt injection inside
            // a screenshot's text would try to reach it.
            for body in ["open_app:/tmp/evil", "open_app:../../bin/sh", "open_app:./Evil"] {
                let p = ResponseParser()
                let ev = p.feed("[DO:\(body)]") + p.finish()
                expect(tools(ev).isEmpty, "\(body) parsed into a run")
                expect(texts(ev).contains("[DO:"), "\(body) was swallowed instead of shown")
            }
        }

        test("the volume forms a model writes all resolve to a percent") {
            let cases: [(String, Int)] = [
                ("set_volume:40", 40),
                ("set_volume:40%", 40),
                ("set_volume:0.4", 40),
                ("set_volume:40 percent", 40),
                ("volume:75", 75),
                ("SET_VOLUME:20", 20),
                ("set_volume: 5 ", 5),
                ("set_volume:0", 0),
                ("set_volume:1", 100),
            ]
            for (body, expected) in cases {
                expectEqual(DoRequest.parse(body), DoRequest.setVolume(percent: expected),
                            "\(body) should mean \(expected)%")
            }
        }

        test("an impossible volume fails open instead of clamping into a different request") {
            // Turning 150 into 100 would run something the card never described, and "loud"
            // into 0 would mute the machine. Both belong on the card as text instead.
            for body in ["set_volume:150", "set_volume:-5", "set_volume:loud", "set_volume:",
                         "open_app:", "open_app:\(String(repeating: "n", count: 80))"] {
                expect(DoRequest.parse(body) == nil, "\(body) must not become a request")
            }
        }

        test("the streamer collects tool requests without polluting the shown detail") {
            let s = AnswerStreamer()
            s.push("<SAY>Quieter now</SAY>\n[DO:set_volume:30]")
            s.finish()
            expectEqual(s.toolRequests.count, 1)
            expectEqual(s.toolRequests.first, DoRequest.setVolume(percent: 30))
            expect(!s.detail.contains("DO"), "the tool tag showed up in the transcript")
        }

        test("a press and a tool in one reply are both kept for the caller to choose between") {
            let s = AnswerStreamer()
            s.push("[ACT:1,2,Send] [DO:open_app:Notes]")
            s.finish()
            expectEqual(s.actionRequests.count, 1)
            expectEqual(s.toolRequests.count, 1,
                        "dropping the second proposal here is what hides it from the log too")
        }

        // MARK: ToolLayer — what the card actually says

        test("the question names the exact effect, on one line") {
            expectEqual(ToolLayer.question(for: .openApp(name: "Notes")), "Open Notes?")
            expectEqual(ToolLayer.question(for: .setVolume(percent: 40)), "Set the volume to 40%?")
            expect(!ToolLayer.question(for: .setVolume(percent: 40)).contains("\n"),
                   "the confirm row is measured for a single line")
        }

        test("a tool that failed never reports success") {
            expectEqual(ToolLayer.outcomeLine(for: .openApp(name: "Notes"), succeeded: false),
                        "Could not open Notes.")
            let volumeFailure = ToolLayer.outcomeLine(for: .setVolume(percent: 40), succeeded: false)
            expect(!volumeFailure.contains("40"),
                   "saying the number on a failure reads as though it was applied: \(volumeFailure)")
        }

        // MARK: ToolRunner — the halves that need no disk and no launch

        test("the app name matches the bundle ignoring case and the .app suffix") {
            let candidates = ["/Applications/Safari.app",
                              "/System/Applications/Utilities/Terminal.app"]
            expectEqual(ToolRunner.resolveApplicationPath(name: "safari", candidates: candidates) ?? "",
                        "/Applications/Safari.app")
            expectEqual(ToolRunner.resolveApplicationPath(name: "Terminal.app", candidates: candidates) ?? "",
                        "/System/Applications/Utilities/Terminal.app")
        }

        test("a unique substring matches, an ambiguous one matches nothing") {
            expectEqual(
                ToolRunner.resolveApplicationPath(name: "chrome",
                                                  candidates: ["/Applications/Google Chrome.app",
                                                               "/Applications/Notes.app"]) ?? "",
                "/Applications/Google Chrome.app",
                "people say the short name and mean the real bundle")
            expect(ToolRunner.resolveApplicationPath(
                name: "store",
                candidates: ["/Applications/App Store.app", "/Applications/Photo Store.app"]) == nil,
                "opening a guess is worse than failing: the card said one thing, another app appeared")
        }

        test("an empty name or an empty app list resolves to nothing") {
            expect(ToolRunner.resolveApplicationPath(name: "   ",
                                                    candidates: ["/Applications/Notes.app"]) == nil,
                   "a blank needle would match every bundle by substring")
            expect(ToolRunner.resolveApplicationPath(name: "Notes", candidates: []) == nil)
        }

        test("the app search is confined to the four known directories") {
            for directory in ToolRunner.applicationDirectories {
                expect(directory.hasPrefix("/Applications")
                        || directory.hasPrefix("/System/Applications")
                        || directory.hasPrefix(NSHomeDirectory()),
                       "an app search outside the known directories lets a name reach any bundle")
            }
        }

        test("a percent becomes the scalar CoreAudio takes, clamped") {
            expectEqual(ToolRunner.scalar(for: 40), 0.4)
            expectEqual(ToolRunner.scalar(for: 100), 1.0)
            expectEqual(ToolRunner.scalar(for: 0), 0.0)
            // Out-of-range values must not reach the API as 150.0: that is an error code, and
            // the card would have read "Volume set to 150%" over a machine that changed nothing.
            expectEqual(ToolRunner.scalar(for: 150), 1.0)
            expectEqual(ToolRunner.scalar(for: -20), 0.0)
        }

        // MARK: Opening a web address

        test("open youtube in chrome is one url request, not three acts") {
            let request = DoRequest.parse("open_url:youtube.com|Chrome")
            expectEqual(request, .openURL(url: "https://youtube.com", browser: "Chrome"),
                        "the address needs the scheme it is opened with and the browser the user named")
            expectEqual(ToolLayer.question(for: request!), "Open youtube.com in Chrome?",
                        "the card names the site and the browser, and nothing else")
            expectEqual(ToolLayer.outcomeLine(for: request!, succeeded: true),
                        "Opened youtube.com in Chrome.")
            let anyBrowser = DoRequest.parse("open_url:https://getpocket.com")
            expectEqual(anyBrowser, .openURL(url: "https://getpocket.com", browser: nil))
            expect(ToolLayer.question(for: anyBrowser!).contains("your browser"),
                   "naming a browser Chunks did not choose would be a promise the card cannot keep")
        }

        test("anything that is not a web address fails open into visible text") {
            for body in ["open_url:file:///etc/passwd",     // reads the disk
                         "open_url:javascript:alert(1)",    // runs in the page the user is looking at
                         "open_url:Notes",                  // a word, not a host
                         "open_url:two words.com",          // a space means it was never one address
                         "open_url:https://no-dot-host"] {
                expect(DoRequest.parse(body) == nil,
                       "\(body) became a request; the user approved a sentence, not this target")
            }
        }

        test("the card says the site and the runner opens the same site") {
            // The question is what the user agreed to, so the string on the card has to be the
            // string that gets opened — minus the scheme nobody reads out loud.
            let stored = DoRequest.normalizedURL("https://youtube.com/watch") ?? ""
            expectEqual(stored, "https://youtube.com/watch")
            expectEqual(DoRequest.displayURL(stored), "youtube.com/watch")
        }

        // MARK: Chromium's actions arrive late

        test("a web element that published no action is read again before it is refused") {
            // Measured 2026-10-05 on the live browser: the first read of a web link answered
            // `AXShowMenu, AXScrollToVisible` and the second answered `AXPress` as well, so the
            // refusal "not a control Chunks can press" was about a tree still being built.
            expect(AXTDriver.isPublishingLazily(actions: ["AXShowMenu", "AXScrollToVisible"]),
                   "a web area mid-publish looks exactly like an unpressable group")
            expect(!AXTDriver.isPublishingLazily(
                actions: ["AXPress", "AXShowMenu", "AXScrollToVisible"]),
                   "an element that can already be pressed must not cost a second round trip")
            expect(!AXTDriver.isPublishingLazily(actions: []),
                   "an element with no actions at all is a dead end, not a slow one")
            expect(AXTDriver.webActionRetryDelay > 0 && AXTDriver.webActionRetryDelay < 0.4,
                   "the retry is a layout pass, not a wait the user notices")
        }

        test("a control outside the window the aim landed in is never pressed") {
            // Measured with `--probe-ax 900,120` over Chrome's address bar: the hit test answered
            // an AXMenuItem at y = −82, a row of an omnibox dropdown that had already closed.
            let window = WindowRecord(pid: 1, layer: 0,
                                      bounds: CGRect(x: 0, y: 34, width: 1710, height: 1073),
                                      ownerName: "Google Chrome")
            expect(!AXTDriver.isOnScreen(CGRect(x: 830, y: -82, width: 200, height: 22), in: window),
                   "an off-screen suggestion row pressed is an act the user never saw happen")
            expect(AXTDriver.isOnScreen(CGRect(x: 900, y: 120, width: 200, height: 22), in: window),
                   "the ordinary case must still press")
            expect(AXTDriver.isOnScreen(nil, in: window),
                   "desktop icons publish no frame; refusing them would break the presses that work")
            expect(AXTDriver.isOnScreen(CGRect(x: 0, y: 33, width: 40, height: 40), in: window),
                   "one point of tolerance, because a window edge is measured not drawn")
        }

        test("a Catalyst field is a field even when its role says otherwise") {
            // Measured 2026-10-08 on WhatsApp with the search box open: the element is
            // `role=AXStaticText subrole=AXSearchField`. A role-only check called it a label for
            // five rounds of fixes while a caret blinked in it.
            expect(AXTDriver.isEditableField(role: "AXStaticText", subrole: "AXSearchField"),
                   "WhatsApp's search box is a field, and Chunks said there was no field there")
            expect(AXTDriver.isEditableField(role: "AXStaticText", subrole: "AXTextField"))
            expect(!AXTDriver.isEditableField(role: "AXStaticText", subrole: nil),
                   "a plain label is not a field; the subrole is the whole evidence")
            expect(!AXTDriver.isEditableField(role: "AXStaticText", subrole: "AXSecureTextField"),
                   "a secure field is refused on the subrole too, not just the role")
            expect(!AXTDriver.isEditableField(role: "AXSecureTextField", subrole: "AXSearchField"),
                   "a secure role cannot be made typeable by any subrole")
            expect(AXTDriver.isEditableField(role: "AXTextArea", subrole: nil),
                   "the ordinary AppKit case must keep working")
        }

        // MARK: Scrolling a list

        test("a [SCROLL:x,y:label|down] becomes one scroll request, not text") {
            var parser = ResponseParser()
            let events = parser.feed("[SCROLL:120,600:chat list|down 3]") + parser.finish()
            expectEqual(acts(events).count, 1,
                        "a scroll tag shown as markup is a list the user asked to move and never did")
            let intent = acts(events)[0].scrollIntent
            expectEqual(intent?.direction.rawValue ?? "-", "down")
            expectEqual(intent?.pages ?? -1, 3)
            expectEqual(acts(events)[0].label, "chat list")
            expect(acts(events)[0].textToType == nil,
                   "a scroll parsed as a type would put words in a field nobody named")
        }

        test("every way the model writes a direction means the same movement") {
            let forms = ["640,500:list|down", "640,500:list|DOWN", "640,500:list|down,2",
                         "640,500:list|2 down", "640,500:list:down", "640,500:list:up"]
            for form in forms {
                expect(ActionRequest.parseScroll(form) != nil,
                       "\"\(form)\" reached the user as text instead of scrolling")
            }
            expectEqual(ActionRequest.parseScroll("640,500:list|up")?.scrollIntent?.pages, 1,
                        "a bare direction is one page, not zero and not a whole view of guesses")
            expectEqual(ActionRequest.parseScroll("640,500:list|left")?.scrollIntent?.direction,
                        .left)
        }

        test("a scroll that is not a scroll fails open into visible text") {
            for form in ["640,500:list|sideways",     // not a direction
                         "640,500:list",              // no direction at all
                         "640,500:|down",             // no label to name on the card
                         "640,500:list|0",            // zero pages is not a movement
                         "640,500:list|down \(ActionRequest.maxScrollPages + 1)",
                         "notapoint|down"] {
                expect(ActionRequest.parseScroll(form) == nil,
                       "\"\(form)\" became a request; the card would have asked about something else")
            }
        }

        test("a page verb is chosen over a stepper on the same element") {
            // `AXDecrement` on a value control changes a setting; on a scroller it moves one line.
            // Only the element's own list can tell the two apart, and a page verb always wins.
            let both = ["AXScrollDownByPage", "AXDecrement", "AXScrollToVisible"]
            let choice = AXTDriver.scrollAction(for: .down, advertisedIn: both)
            expectEqual(choice?.action ?? "-", "AXScrollDownByPage")
            expectEqual(choice?.movesPages, true)

            let stepperOnly = ["AXIncrement", "AXDecrement"]
            expectEqual(AXTDriver.scrollAction(for: .up, advertisedIn: stepperOnly)?.action ?? "-",
                        "AXIncrement")
            expectEqual(AXTDriver.scrollAction(for: .up, advertisedIn: stepperOnly)?.movesPages,
                        false, "a stepper has to be repeated to cover a page")
            expect(AXTDriver.scrollAction(for: .down, advertisedIn: ["AXPress"]) == nil,
                   "a button is not a scroller; pressing it is a different act entirely")
        }

        test("only a scrolled result says anything moved") {
            let list = AXElementInfo(pid: 7, appName: "WhatsApp", role: "AXList",
                                     title: "chat list")
            let moved = AXTDriver.ScrollResult.scrolled(element: list, direction: .down,
                                                        pages: 2, action: "AXScrollDownByPage")
            expect(moved.didScroll)
            expect(moved.userFacingReason.contains("Scrolled chat list down by 2 pages"),
                   "the line the user hears has to name the list that moved: \(moved.userFacingReason)")

            let refusals: [AXTDriver.ScrollResult] = [
                .permissionMissing,
                .noScrollableElement(containing: CGPoint(x: 10, y: 10)),
                .refusedByElement(element: list, action: "AXScrollDownByPage", code: -25200),
            ]
            for refusal in refusals {
                expect(!refusal.didScroll, "\(refusal) would be reported as a list that moved")
                expect(refusal.userFacingReason.lowercased().contains("noth")
                        || refusal.userFacingReason.lowercased().contains("grant"),
                       "\(refusal.userFacingReason) leaves the user guessing whether the list moved")
            }
            expect(refusals[2].userFacingReason.contains("failure"),
                   "a refused scroll names the code as a word, because one digit separates the two readings")
        }

        test("the scroll question names the list, the direction, and how far") {
            expectEqual(ActionRequest.scrollQuestion(elementLabel: "chat list", direction: .down,
                                                     pages: 1), "Scroll chat list down?",
                        "one page needs no number, and a number the user never said is noise")
            expectEqual(ActionRequest.scrollQuestion(elementLabel: "Inbox", direction: .up,
                                                     pages: 3), "Scroll Inbox up 3 pages?")
        }

        // MARK: Typing into a field

        test("a [TYPE:x,y:label|text] becomes one type request, not text") {
            var parser = ResponseParser()
            let events = parser.feed("<SAY>typing that in now.</SAY>\n[TYPE:1180,1002:message box|good night]")
                + parser.finish()
            expectEqual(acts(events).count, 1,
                        "a type tag that reaches the user as markup is a message they read twice and never sent")
            expectEqual(acts(events)[0].verb, .type(text: "good night"),
                        "the words after the bar are the payload, not part of the label")
            expectEqual(acts(events)[0].label, "message box")
            expectEqual(acts(events)[0].target.x, 1180)
            expectEqual(acts(events)[0].target.y, 1002)
            expect(!texts(events).contains("[TYPE:"), "the tag leaked into the shown text")
        }

        test("the colon form of a type tag parses to the same request") {
            // `[ACT:…]` is the shape the model has already been taught, so a `[TYPE:…]` written
            // with a second colon instead of a bar is the common miss, not an exotic one.
            let withBar = ActionRequest.parseType("640,910:send box|hi")
            let withColon = ActionRequest.parseType("640,910:send box:hi")
            expectEqual(withColon, withBar,
                        "the same ask parses one way and silently drops the other")
            expectEqual(withColon?.textToType ?? "", "hi")
        }

        test("a type tag fed one character at a time still becomes exactly one request") {
            var parser = ResponseParser()
            var events: [ReplyEvent] = []
            for character in "[TYPE:640,910:box|good night]".unicodeScalars {
                events += parser.feed(String(Character(character)))
            }
            events += parser.finish()
            expectEqual(acts(events).count, 1)
            expectEqual(acts(events).first?.textToType ?? "", "good night")
            expectEqual(texts(events), "", "fragments of the tag were shown as typed text")
        }

        test("a type tag that is not a complete ask fails open into visible text") {
            for body in ["640,910:send box",       // no text at all
                         "640,910:|good night",     // no label to name on the card
                         "640,910:box|",            // a bar with nothing after it
                         "notapoint|good night"] {  // coordinates that never resolve
                expect(ActionRequest.parseType(body) == nil,
                       "\"\(body)\" became a request; the user approved words they never saw")
            }
            var parser = ResponseParser()
            let events = parser.feed("[TYPE:notapoint|good night]") + parser.finish()
            expect(acts(events).isEmpty,
                   "a malformed type tag swallowed whole is a message the user thinks went out")
            expect(texts(events).contains("[TYPE:notapoint"),
                   "the failure has to be visible: a raw tag reads as a thing Chunks tried to do")
        }

        test("text longer than one act holds is refused before it can become keystrokes") {
            let tooLong = String(repeating: "x", count: ActionRequest.maxTypedCharacters + 1)
            expect(ActionRequest.parseType("640,910:box|\(tooLong)") == nil,
                   "thousands of synthetic keystrokes into a live form cannot be undone by one button")
            let atCap = String(repeating: "x", count: ActionRequest.maxTypedCharacters)
            expectEqual(ActionRequest.parseType("640,910:box|\(atCap)")?.textToType?.count,
                        ActionRequest.maxTypedCharacters)
        }

        test("a screen suffix on a type tag picks the display, not the message") {
            // The prompt says the tag follows [ACT:…]'s rules *including* `:screenN`, and a model
            // writes that suffix at the end of the tag — which is inside the words after a `|`.
            // Sending "good night:screen2" to a friend is the whole bug.
            let afterLabel = ActionRequest.parseType("640,910:box:screen2|good night")
            let afterText = ActionRequest.parseType("640,910:box|good night:screen2")
            expectEqual(afterLabel?.target.display, 2)
            expectEqual(afterLabel?.textToType ?? "", "good night")
            expectEqual(afterText?.target.display, 2,
                        "the second display was typed into instead of the first")
            expectEqual(afterText?.textToType ?? "", "good night",
                        "the screen suffix leaked into the message the user asked to send")
        }

        test("only roles a person can type into are editable") {
            for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXEmailField"] {
                expect(AXTDriver.isEditableRole(role), "\(role) is a field the user types in")
            }
            // A secure field is the one place an automated keystroke can leak a secret, and the
            // list being empty-safe matters more than the list being complete.
            expect(!AXTDriver.isEditableRole("AXSecureTextField"),
                   "a password box is not a chat input, whatever the policy gate also does")
            for role in ["AXButton", "AXStaticText", "AXGroup", "AXImage", nil] {
                expect(!AXTDriver.isEditableRole(role),
                       "\(role ?? "nil") cannot hold typed text; aiming there types nothing")
            }
        }

        test("no typing outcome but a verified one claims success") {
            let field = AXElementInfo(pid: 432, appName: "WhatsApp", role: "AXTextArea",
                                      title: "message box")
            expect(AXTDriver.TypeResult.typed(element: field, characters: 10).didType,
                   "a typed-and-read-back result is the only thing that may say so")
            let refusals: [AXTDriver.TypeResult] = [
                .permissionMissing,
                .noField(containing: CGPoint(x: 10, y: 10)),
                .focusRefused(element: field),
                .rejectedByField(element: field),
            ]
            for outcome in refusals {
                expect(!outcome.didType, "\(outcome) would be reported as a message that was sent")
                let line = outcome.userFacingReason
                expect(!line.isEmpty, "an empty line on the card reads as Chunks ignoring the ask")
                expect(!line.hasPrefix("Typed "),
                       "\(line) claims text landed in a field that refused it")
            }
            expect(AXTDriver.TypeResult.focusRefused(element: field).userFacingReason
                    .contains("nothing was typed"),
                   "the focus refusal has to say out loud that nothing went anywhere")
            expect(AXTDriver.TypeResult.rejectedByField(element: field).userFacingReason
                    .contains("may not be there"),
                   "a field that took the keys then dropped the text is a maybe, not a lie")
            expect(AXTDriver.TypeResult.typed(element: field, characters: 10).userFacingReason
                    .contains("Typed 10 characters into message box"),
                   "the success line has to name the field it actually read back from")
        }

        test("a field with no name is still called something a person would say") {
            // Measured on a live TextEdit window: the text area publishes no title and no
            // description, so the role fallback would have asked "Type … into AXTextArea?" — and
            // with asking off that sentence is the only report of an act that ran.
            let bare = AXElementInfo(pid: 1, appName: "TextEdit", role: "AXTextArea")
            expectEqual(AXTDriver.fieldLabel(for: bare), "the text area")
            for role in AXTDriver.editableRoles {
                let words = AXTDriver.fieldLabel(for: AXElementInfo(pid: 1, role: role))
                expect(!words.contains("AX"), "\(role) reached the user as a role code: \"\(words)\"")
                expect(!words.isEmpty && words != "that field",
                       "\(role) is a field Chunks types into, so it deserves its own words")
            }
            let titled = AXElementInfo(pid: 1, appName: "WhatsApp", role: "AXTextArea",
                                       title: "Message")
            expectEqual(AXTDriver.fieldLabel(for: titled), "Message",
                        "the name the user looked at and approved is the name the card says")
        }

        test("a type request is refused where a press would be, and named honestly on the card") {            let secure = ActionTargetInfo(bundleID: "com.apple.Safari", appName: "Safari",
                                          role: "AXSecureTextField", elementLabel: "password")
            guard case .forbidden = PolicyGate.decide(target: secure, askBeforePressing: false)
            else {
                expect(false, "a secure field with asking off must still be refused, whatever the verb")
                return
            }
            let chat = ActionTargetInfo(bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp",
                                        role: "AXTextArea", elementLabel: "message box")
            expectEqual(PolicyGate.decide(target: chat, askBeforePressing: true), .needsConsent,
                        "typing into a chat is a normal act, and asking about it is the user's switch")
        }

        // MARK: Against the real machine

        test("the installed-app lookup returns bundles from the allowed directories only") {
            let found = ToolRunner.installedApplications()
            expect(!found.isEmpty,
                   "an empty list means the directory list or the enumeration is broken on this Mac")
            for path in found {
                expect(path.hasSuffix(".app"), "\(path) is not a bundle — it would become an 'Open <folder>?' question")
                expect(ToolRunner.applicationDirectories.contains { path.hasPrefix($0 + "/") },
                       "\(path) came from a directory the tool may not search")
            }
            expect(ToolRunner.resolveApplicationPath(name: "safari", candidates: found) != nil,
                   "every Mac has Safari; if this fails the matching is too strict for real names")
        }

        test("writing the volume the device already has is accepted and changes nothing") {
            // A no-op write is the only way to prove the CoreAudio path works without turning
            // the user's speakers up or down from a test run. If *this* is refused, then every
            // `[DO:set_volume:…]` the user approves would report failure.
            guard let current = ToolRunner.currentSystemVolumePercent() else {
                expect(false, "the default output device publishes no readable scalar volume")
                return
            }
            expect(ToolRunner.setSystemVolume(percent: current),
                   "a write of the device's own \(current)% was refused")
            let readBack = ToolRunner.currentSystemVolumePercent() ?? -1
            expect(abs(readBack - current) <= 1,
                   "the no-op write moved the volume from \(current)% to \(readBack)% — "
                     + "the percent/scalar conversion is wrong")
        }
    }
}
