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
            expectEqual(acts(ev).first?.pointTarget?.x ?? -1, 820)
            expectEqual(acts(ev).first?.pointTarget?.y ?? -1, 540)
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
            expectEqual(acts(ev).first?.pointTarget?.x ?? -1, 1234, "split delta truncated x")
            expectEqual(acts(ev).first?.pointTarget?.y ?? -1, 50)
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

        test("an aim qualified with an app is a pixel aim, with the app kept") {
            // Measured 2026-10-25 on a live turn: the reply said "clicking the title now to show
            // that file in finder" and wrote `[ACT:app=Qoder x=400,50:file title]`. Neither grammar
            // accepted it — the semantic one because `x` is not a field it knows, the point one
            // because the body does not start with a number — so the tag sat on the card as markup
            // while the summary promised the click. A model that has learned to name the app writes
            // this form, and accepting it is *stricter*: the named app becomes a second thing the
            // hit test has to answer.
            let p = ResponseParser()
            let ev = p.feed("[ACT:app=Qoder x=400,50:file title]") + p.finish()
            guard let request = acts(ev).first else {
                expect(false, "the qualified aim was refused by both grammars again"); return
            }
            expectEqual(request.pointTarget?.x ?? -1, 400)
            expectEqual(request.pointTarget?.y ?? -1, 50)
            expectEqual(request.pointTarget?.label, "file title",
                        "the words after the coordinates are the label, not part of the aim")
            expectEqual(request.pointTarget?.appName, "Qoder",
                        "the app is the corroboration, so dropping it would weaken the press")
            expectEqual(request.semanticTarget, nil,
                        "this is a pixel aim with an app attached, not a named-control aim")
        }

        test("every way the model spells a qualified aim means the same press") {
            let bodies = ["app=Qoder x=400,50:file title",
                          "app=Qoder x=400 y=50:file title",
                          "app=Google Chrome x=900,y=120:address bar"]
            for body in bodies {
                let parsed = ActionRequest.parseAct(body)
                guard let aim = parsed?.pointTarget else {
                    expect(false, "\"\(body)\" produced no pixel aim"); continue
                }
                expect(aim.x > 0 && aim.y > 0, "\"\(body)\" lost its coordinates")
                expect(aim.appName == "Qoder" || aim.appName == "Google Chrome",
                       "\"\(body)\" lost the app the model named")
                expect(!aim.label.isEmpty && !aim.label.contains("="),
                       "\"\(body)\" left the grammar in the label: \"\(aim.label)\"")
            }
        }

        test("a named control still wins over the pixel grammar, and a bare aim still works") {
            // The order is the whole point: `app=… name=…` is a statement about the accessibility
            // tree and must never be re-read as a picture proportion.
            let named = ActionRequest.parseAct("app=WhatsApp name=Send")
            expect(named?.semanticTarget != nil, "a named aim fell through to the pixel grammar")
            expect(named?.pointTarget == nil)
            let bare = ActionRequest.parseAct("420,500:Understand personal build")
            expectEqual(bare?.pointTarget?.label, "Understand personal build",
                        "the form the crop turn actually used regressed")
            expectEqual(bare?.pointTarget?.appName, nil,
                        "no app was named, so nothing may be refused for naming the wrong one")
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
            expectEqual(acts(ev).first?.pointTarget?.display ?? 0, 2)
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

        test("a reply that stops inside a <SAY> is still spoken, and says so") {
            // Measured on his machine 2026-11-04 at 15:00: the stream ended at
            // `<SAY>you're looking at qoder, where` with no closing tag. The parser released the
            // unterminated construct as text — fail-open, which is right for a malformed `[ACT:]` —
            // and the result was raw markup on the card and **no speech at all**, because the caller
            // only speaks a non-empty sentence. Silence with nothing recorded is the failure this
            // project already refuses for an act.
            let s = AnswerStreamer()
            s.push("<SAY>you're looking at qoder, where")
            s.finish()
            expect(s.speech.contains("you're looking at qoder"),
                   "the words he was promised are the sentence, not the tag: \(s.speech)")
            expect(s.endedMidConstruct,
                   "and the turn records that the reply was cut, so the log can say why it stops")
            expect(!s.detail.contains("<SAY>"),
                   "the markup itself must not reach the card: \(s.detail)")
        }

        test("a complete <SAY> does not report a truncation") {
            // The flag is only worth having if it means one thing. A normal answer must not light it.
            let s = AnswerStreamer()
            s.push("<SAY>you're looking at Qoder.</SAY>")
            s.finish()
            expect(!s.endedMidConstruct, "a closed construct is not a truncation")
            expectEqual(s.speech.trimmingCharacters(in: .whitespacesAndNewlines),
                        "you're looking at Qoder.")
        }

        // MARK: ScreenshotGeometry: the aim -> display mapping

        test("the middle of the grid is the middle of the display") {
            let got = ScreenshotGeometry.appKitGlobalPoint(x: 500, y: 500,
                                                           imageWidth: 1280, imageHeight: 829,
                                                           imageFrame: primary)
            expectEqual(got?.x ?? -1, 855)
            expectEqual(got?.y ?? -1, 553.5, "image Y runs from the top; AppKit Y from the bottom")
        }

        test("the top of the grid is the top of the display, not the bottom") {
            let top = ScreenshotGeometry.appKitGlobalPoint(x: 0, y: 0,
                                                           imageWidth: 1280, imageHeight: 829,
                                                           imageFrame: primary)
            let bottom = ScreenshotGeometry.appKitGlobalPoint(x: 0, y: 1000,
                                                              imageWidth: 1280, imageHeight: 829,
                                                              imageFrame: primary)
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
                                                           imageFrame: primary)
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
                                                              imageFrame: primary)
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
                                                              imageFrame: primary)
            expectEqual(anchor?.x ?? -1, 427.5)
            expectEqual(anchor?.y ?? -1, 276.75)

            for scale in [2.0, 3.0] {
                let w = primary.width * scale
                let h = primary.height * scale
                let pixels = ScreenshotGeometry.appKitGlobalPoint(x: w * 0.25, y: h * 0.75,
                                                                  imageWidth: w, imageHeight: h,
                                                                  imageFrame: primary)
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
                                                            imageFrame: primary)
            let right = ScreenshotGeometry.appKitGlobalPoint(x: 1500, y: 4000,
                                                             imageWidth: 1280, imageHeight: 829,
                                                             imageFrame: primary)
            expectEqual(left?.x ?? -1, 0.5, "a negative aim must not press off-screen")
            expectEqual(left?.y ?? -1, 1106.5)
            expectEqual(right?.x ?? -1, 1709.5)
            expectEqual(right?.y ?? -1, 0.5)
            expect(primary.contains(right!), "the mapped aim has to be inside the display it maps to")
        }

        test("a zero-size image returns nil rather than NaN") {
            expect(ScreenshotGeometry.appKitGlobalPoint(x: 10, y: 10,
                                                        imageWidth: 0, imageHeight: 0,
                                                        imageFrame: primary) == nil,
                   "dividing by a zero-width screenshot gives NaN, which lands nowhere")
        }

        test("a secondary display's origin is added, not assumed to be zero") {
            let second = CGRect(x: 1710, y: 0, width: 1600, height: 1000)
            let got = ScreenshotGeometry.appKitGlobalPoint(x: 500, y: 500,
                                                           imageWidth: 1280, imageHeight: 829,
                                                           imageFrame: second)
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

        // MARK: The aim inside a crop

        /// The rectangle the user circled, in the space `CaptureEngine` reports it: global
        /// top-left points on his 1710x1107 display.
        let cropTopLeft = LogicalRect(x: 100, y: 80, width: 400, height: 300)

        test("a crop's rectangle is turned over once, the same way a point is") {
            let crop = ScreenshotGeometry.appKitRect(fromTopLeftGlobal: cropTopLeft,
                                                     primaryScreenHeight: 1107)
            expectEqual(crop.minX, 100, "X does not flip")
            expectEqual(crop.minY, 727, "the crop's top edge in top-left space is 380 from the top")
            expectEqual(crop.height, 300, "a rect flips its origin, not its size")
            // The whole display flips to itself, which is what makes the full-screen path unchanged.
            let whole = ScreenshotGeometry.appKitRect(
                fromTopLeftGlobal: LogicalRect(x: 0, y: 0, width: 1710, height: 1107),
                primaryScreenHeight: 1107)
            expectEqual(whole, CGRect(x: 0, y: 0, width: 1710, height: 1107),
                        "a display-sized picture must map exactly as it did before crops existed")
        }

        test("an aim inside a circled region lands inside that region") {
            // The bug this prevents: a crop covers a fraction of the display, and treating the aim
            // as a fraction of the *whole* display puts the press at the middle of the screen for a
            // control the user circled in its top-left. Measured with his numbers — a 1710x1107
            // display, a 400x300 pt crop at (100, 80), sent to the model as an 800x600 px image.
            let crop = ScreenshotGeometry.appKitRect(fromTopLeftGlobal: cropTopLeft,
                                                     primaryScreenHeight: 1107)
            let aimed = ScreenshotGeometry.appKitGlobalPoint(x: 500, y: 500,
                                                            imageWidth: 800, imageHeight: 600,
                                                            imageFrame: crop)
            let ax = aimed.map { ScreenshotGeometry.axGlobalPoint(appKitGlobalPoint: $0,
                                                                  primaryScreenHeight: 1107) }
            guard let point = ax else { expect(false, "the crop aim did not map at all"); return }
            expectEqual(point.x, 300, "the centre of a crop at 100…500 is 300")
            expectEqual(point.y, 230, "the centre of a crop at 80…380 is 230")

            let asWholeScreen = ScreenshotGeometry.appKitGlobalPoint(
                x: 500, y: 500, imageWidth: 800, imageHeight: 600,
                imageFrame: CGRect(x: 0, y: 0, width: 1710, height: 1107))
            expect(asWholeScreen != aimed,
                   "a crop aimed as if it were the display is the failure, and it passed silently")
        }

        test("a pixel answer inside a crop is read against the crop too") {
            // The same rectangle, the exception path: the model used the image's own dimensions.
            // A 900x700 pt crop at 2x is an 1800x1400 px image, and only a value over 1000 can
            // prove that — a 450 in an 800-wide picture is genuinely ambiguous, and stays the grid.
            let big = LogicalRect(x: 100, y: 80, width: 900, height: 700)
            let crop = ScreenshotGeometry.appKitRect(fromTopLeftGlobal: big,
                                                     primaryScreenHeight: 1107)
            let grid = ScreenshotGeometry.appKitGlobalPoint(x: 250, y: 750,
                                                            imageWidth: 1800, imageHeight: 1400,
                                                            imageFrame: crop)
            let pixels = ScreenshotGeometry.appKitGlobalPoint(x: 450, y: 1050,
                                                              imageWidth: 1800, imageHeight: 1400,
                                                              imageFrame: crop)
            expectEqual(ScreenshotGeometry.aimSpace(x: 450, y: 1050), .imagePixels)
            expectEqual(pixels?.x ?? -1, grid?.x ?? -2,
                        "the quarter-across aim came back in pixels and was scaled by the display")
            expectEqual(pixels?.y ?? -1, grid?.y ?? -2)
        }

        test("a crop that touches the bottom of the display still aims at a hit-testable point") {
            let dock = LogicalRect(x: 0, y: 1007, width: 1710, height: 100)   // to the last row
            let crop = ScreenshotGeometry.appKitRect(fromTopLeftGlobal: dock,
                                                     primaryScreenHeight: 1107)
            let aim = ScreenshotGeometry.appKitGlobalPoint(x: 500, y: 1000,
                                                           imageWidth: 1710, imageHeight: 100,
                                                           imageFrame: crop)
            let ax = aim.map { ScreenshotGeometry.axGlobalPoint(appKitGlobalPoint: $0,
                                                                primaryScreenHeight: 1107) }
            guard let point = ax else { expect(false, "the dock crop did not map"); return }
            expect(point.y < 1107, "an aim on the last row of a crop at the screen's foot must "
                                   + "stay inside the display, or the hit test finds nothing")
            expect(point.y >= 1007, "and it must stay inside the crop the user actually drew")
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
                bundleID: "com.apple.mail", appName: "Mail", role: "AXButton",
                elementLabel: "Get Mail"),
                askBeforePressing: false)
            expectEqual(d, .allowedWithoutAsking,
                        "the user asked Chunks to act on what they name, not to question it")
        }

        // The hole this closes is measured, not hypothetical: 2026-10-18, a plan whose last step came
        // from `<CONTINUE>press send in the chat with Dad</CONTINUE>` ran that step on the
        // auto-continuation round and the message went out with nobody watching. "Don't ask" is an
        // instruction about routine acts; it was never an instruction to send, pay or delete.
        test("a send is asked about even with asking off") {
            for label in ["Send", "‎Send", "Submit", "Pay now", "Delete", "Confirm"] {
                let d = PolicyGate.decide(target: ActionTargetInfo(
                    bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp",
                    role: "AXButton", elementLabel: label),
                    askBeforePressing: false)
                expectEqual(d, .needsConsent,
                            "\"\(label)\" is a commitment, so the standing instruction cannot skip it")
            }
        }

        test("a commitment word past the card's 42-character label is still a commitment") {
            // AUDIT.md A-08: the consequence check read the truncated display label, so a control
            // whose title puts "Delete" past character 42 escaped the even-with-asking-off card.
            let long = "Remove every message in this conversation and delete them permanently"
            let info = AXElementInfo(pid: 1, appName: "WhatsApp", role: "AXButton", title: long)
            expect(info.elementLabel.count <= 43, "the display label is bounded, as the card needs")
            let d = PolicyGate.decide(target: info.policyTarget(bundleID: nil),
                                      askBeforePressing: false)
            expectEqual(d, .needsConsent,
                        "the policy reads the full name, not the truncated one")
        }

        test("an app the user always allows is still asked before it sends") {
            let d = PolicyGate.decide(target: ActionTargetInfo(
                bundleID: "com.apple.mail", appName: "Mail", role: "AXButton",
                elementLabel: "Send"),
                alwaysAllowedBundleIDs: ["com.apple.mail"], askBeforePressing: false)
            expectEqual(d, .needsConsent,
                        "the allowance was about opening things, not about sending what the model wrote")
        }

        test("a press aimed at words the app never named is asked about with asking off") {
            // The web case this route exists for: an `AXGroup` whose only words are its child's, which
            // is why the card has to say "the area that says …" rather than a name. Asking off is the
            // standing instruction on his machine, and it is an instruction about routine acts — a
            // press built from an inference about a picture is not one.
            let web = ActionTargetInfo(bundleID: "com.google.Chrome", appName: "Google Chrome",
                                       role: "AXGroup", elementLabel: "AXGroup")
            expectEqual(PolicyGate.decide(target: web, askBeforePressing: false, inferredAim: true),
                        .needsConsent,
                        "the card is the only place he learns Chunks guessed at the control")
            expectEqual(PolicyGate.decide(target: web, askBeforePressing: false),
                        .allowedWithoutAsking,
                        "and it is the inference that asks, not the unknown role — a nameless control "
                        + "resolved from its own published name still runs as it does today")
        }

        test("an inferred aim is asked about even inside an app he always allows") {
            let d = PolicyGate.decide(target: ActionTargetInfo(
                bundleID: "com.google.Chrome", appName: "Google Chrome",
                role: "AXGroup", elementLabel: "AXGroup"),
                alwaysAllowedBundleIDs: ["com.google.Chrome"],
                askBeforePressing: false, inferredAim: true)
            expectEqual(d, .needsConsent,
                        "the allowance was for the controls he recognises in that app, and a card "
                        + "describing a region by its child's words is not one of them")
        }

        test("an inferred aim never outranks a refusal") {
            let d = PolicyGate.decide(target: ActionTargetInfo(
                bundleID: "com.apple.Safari", appName: "Safari", role: "AXSecureTextField"),
                askBeforePressing: false, inferredAim: true)
            if case .forbidden = d { } else {
                expect(false, "asking is not the safety net for a secure field; a resolution that "
                    + "guesses must not turn a refusal into a question")
            }
        }

        test("no tag can ask to be resolved by ranking") {
            for body in ["app=Chrome name=Send", "app=Chrome role=button name=Send",
                         "640,910:Send", "app=Chrome x=640,910:Send"] {
                guard let act = ActionRequest.parseAct(body) else {
                    expect(false, "\(body) no longer parses, so this check stopped testing anything")
                    continue
                }
                expect(act.rankedAim == nil,
                       "the ranking is what the app falls back to after a refusal, never something a "
                       + "reply can request: \(body)")
                expect(act.pointerClickPoint == nil,
                       "and neither can a real click that moves his pointer: \(body)")
            }
        }

        test("a control that merely contains the word is not a commitment") {
            // A substring rule would catch "Sender" and stop ordinary flows, which trains the user to
            // tap Allow without reading — the failure mode the card exists to avoid.
            expect(!PolicyGate.isConsequential(label: "Sender"))
            expect(!PolicyGate.isConsequential(label: "Sensitivity"))
            expect(!PolicyGate.isConsequential(label: "Removed items"))
            expect(!PolicyGate.isConsequential(label: "Browse"))
            expect(PolicyGate.isConsequential(label: "‎Send"),
                   "WhatsApp prefixes its labels with a directional mark; the token test must see through it")
            expect(PolicyGate.isConsequential(label: "Check out"),
                   "a two-word commitment is still one")
            expect(!PolicyGate.isConsequential(label: nil),
                   "a control with no published name is not refused for it — that is most of the screen")
        }

        test("an ordinary named field still runs silently when asking is off") {
            let d = PolicyGate.decide(target: ActionTargetInfo(
                bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp",
                role: "AXTextArea", elementLabel: "Compose message"),
                askBeforePressing: false)
            expectEqual(d, .allowedWithoutAsking,
                        "typing into a field submits nothing, so the standing instruction still applies")
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

        test("the keyboard tag reads, and refuses to read what is not a key") {
            let interrupt = DoRequest.parse("key:Terminal|ctrl+c")
            expectEqual(interrupt, .key(app: "Terminal", body: "ctrl+c"),
                        "the app and the expression are both load-bearing: keys go to the focused "
                        + "element of the focused application")
            let palette = DoRequest.parse("key:Qoder|command+shift+p")
            expect(palette != nil, "an editor with no published controls is exactly what this is for")
            // A body that is not a key must fail at the parse, so the raw tag reaches the card as
            // text he can read instead of Chunks pressing the nearest thing it could recognise.
            expect(DoRequest.parse("key:Terminal|") == nil, "an empty expression is not a keystroke")
            expect(DoRequest.parse("key:Terminal|hypnotic") == nil,
                   "an unknown key must not become a keystroke by approximation")
            expect(DoRequest.parse("key:Terminal") == nil, "no expression, no act")
            expect(DoRequest.parse("key:/Applications/Notes.app|cmd+n") == nil,
                   "a path is not an application name — the same rule open_app holds")
        }

        test("a key act is worded as the key, the app, and the count") {
            let request = DoRequest.parse("key:Code|shift+down x5")!
            let question = ToolLayer.question(for: request)
            expect(question.contains("⇧down ×5"),
                   "the selection he approved has to be the selection on the card: \(question)")
            expect(question.contains("Code"),
                   "which application receives it is the thing being agreed to: \(question)")
            expectEqual(ToolLayer.outcomeLine(for: request, succeeded: true),
                        "Pressed ⇧down ×5 in Code.",
                        "the count belongs in the report; five keys silently is a different act")
            expect(ToolLayer.outcomeLine(for: request, succeeded: false).contains("Nothing pressed"),
                   "a refused keystroke must not read as a done one")
            expect(ToolLayer.effect(of: request) == .changesSystemState,
                   "a key changes the machine — it is not a read, and reads never take cards")
            expect(!request.invalidatesTheScreen,
                   "a key is not a launch: the plan hold is about a screenshot no longer existing")
        }

        test("only the keyboard verb is gated by the asking switch") {
            expect(DoRequest.parse("key:Terminal|ctrl+c")?.requiresAskingEnabled == true,
                   "the key act must be refused outright when asking is off")
            // The others must NOT be, or the switch stops meaning what it says: with asking off,
            // routine acts run. This is the assertion that keeps the new rule from spreading.
            expect(DoRequest.parse("open_app:Notes")?.requiresAskingEnabled == false,
                   "open_app is not gated by the switch — it has its own rules")
            expect(DoRequest.parse("run_command:caffeinate -di -t 60")?.requiresAskingEnabled == false,
                   "run_command is always asked, which is a different property from switch-linked")
            expect(DoRequest.parse("list_windows:all")?.requiresAskingEnabled == false,
                   "a read must never become a gated act by association")
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

        // MARK: Whether a reveal actually showed him something

        test("a reveal is believed from the window on screen, not from the request it made") {
            // Measured 2026-11-03: `activateFileViewerSelecting` returns `Void`, so every file reveal
            // ever attempted answered `true` and the card said "Showed Ritesh.docx (in Downloads) in
            // Finder." while no window appeared — he had to ask again to get one. These cases are the
            // difference between asking Finder and seeing Finder.
            let file = "/Users/him/Downloads/Ritesh.docx"
            expect(ToolRunner.revealLanded(path: file, isDirectory: false,
                                           now: ["desktop", "Downloads"]),
                   "a window naming the parent folder is the effect he was promised")
            expect(!ToolRunner.revealLanded(path: file, isDirectory: false, now: ["desktop"]),
                   "no window on that folder is NOT a success — this is the exact state the old code "
                        + "reported as \"Showed\"")
            expect(!ToolRunner.revealLanded(path: file, isDirectory: false,
                                            now: ["desktop", "Documents"]),
                   "a window that opened somewhere else is not the reveal he approved, even though "
                        + "Finder definitely put up a window")
            expect(ToolRunner.revealLanded(path: file, isDirectory: false, now: ["downloads"]),
                   "Finder's title casing is not the path's, and a working reveal is not a failure")
        }

        test("a reveal that raises the window already on that folder still counts") {
            // Finder does not open a second window for a folder it is already showing, so a rule built
            // on "something new appeared" would call a working reveal a failure — the opposite bug, and
            // just as loud on the card.
            expect(ToolRunner.revealLanded(path: "/Users/him/Downloads/Ritesh.docx",
                                           isDirectory: false, now: ["Downloads"]),
                   "one window, right folder: Chunks is allowed to say it showed it")
        }

        test("a folder reveal is matched against the folder itself, not its parent") {
            let folder = "/Users/him/Documents/Memora"
            expect(ToolRunner.revealLanded(path: folder, isDirectory: true,
                                           now: ["desktop", "Memora"]),
                   "a directory opens its own window, titled with its own name")
            expect(!ToolRunner.revealLanded(path: folder, isDirectory: true,
                                            now: ["desktop", "Documents"]),
                   "and its parent's window is not the answer")
        }

        test("an empty path is never believed, because there is no name to look for") {
            expect(ToolRunner.revealWindowNames("").isEmpty,
                   "no names means no evidence can ever match, which is the honest answer")
            expect(!ToolRunner.revealLanded(path: "", isDirectory: true, now: ["Macintosh HD"]),
                   "and a window of any kind must not make an empty reveal look like a success")
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

        // MARK: The URL-scheme primitive

        test("running one of the user's shortcuts is one sentence, not a walkthrough of the app") {
            let request = DoRequest.parse("run_shortcut:Focus")
            expectEqual(request, .runShortcut(name: "Focus"))
            expectEqual(ToolLayer.question(for: request!), "Run the shortcut \"Focus\"?",
                        "the shortcut is the user's own, so the card has to say which one by name")
            expectEqual(ToolLayer.outcomeLine(for: request!, succeeded: false),
                        "Shortcuts did not take the run request for \"Focus\".",
                        "an automation that did not run must not be reported as one that might have")
            expectEqual(DoRequest.parse("shortcut:Evening wind-down"), .runShortcut(name: "Evening wind-down"),
                        "a shortcut name with spaces is the normal case")
        }

        test("a name no person gave a shortcut is refused") {
            // Chunks cannot check a shortcut against a list it owns, so the promise the card makes
            // is only that the words on it are the words sent. These are the bodies where that is
            // already false before the encoding starts.
            for body in ["run_shortcut:",
                         "run_shortcut:a/b",
                         "run_shortcut:multi\nline"] {
                expect(DoRequest.parse(body) == nil,
                       "\(body) became a request; the user approved a name, not this")
            }
            let long = String(repeating: "x", count: 61)
            expect(DoRequest.parse("run_shortcut:\(long)") == nil,
                   "a 61-character name is not a shortcut, it is a payload")
        }

        test("showing one thing in Finder is one sentence about where") {
            // The gap this fills: "open the memora workspace in finder" had no tool. `open_app`
            // launches Finder without saying *where*, and an `[ACT]` cannot aim at a window that is
            // not on screen yet.
            expectEqual(DoRequest.parse("reveal:Memora"), .reveal(path: "Memora"))
            expectEqual(DoRequest.parse("open_in_finder:~/Documents/Memora"),
                        .reveal(path: "~/Documents/Memora"),
                        "\"open that folder in finder\" is the same request in other words")
            let request = DoRequest.parse("reveal:/Users/rishi/Documents/Rishi_Projects/Memora")
            expectEqual(ToolLayer.question(for: request!),
                        "Show Memora (in Rishi_Projects) in Finder?",
                        "two folders can share a name; the card has to say which one opens")
            expectEqual(ToolLayer.outcomeLine(for: request!, succeeded: true),
                        "Showed Memora (in Rishi_Projects) in Finder.",
                        "with asking off this runs unannounced, so the spoken line is the only report")
            expect(ToolLayer.outcomeLine(for: request!, succeeded: false)
                    .contains("did not open"),
                   "a Finder window that did not appear must not be reported as one that did")
        }

        test("a reveal argument that is not one thing is refused") {
            for body in ["reveal:",
                         "reveal:file:///etc/passwd",
                         "reveal:\(String(repeating: "x", count: 201))",
                         "reveal:two\nlines"] {
                expect(DoRequest.parse(body) == nil,
                       "\(body) became a request; a nested scheme or a payload is not a folder")
            }
        }

        test("a reveal may name a folder in his work, and never a credential store") {
            let home = "/Users/rishi"
            // The roots and the deny-list a read answers to, applied to a window that only *shows*
            // a folder — because putting `~/.ssh` on screen is a leak even when nothing is read.
            expectEqual(RevealPolicy.verdict(for: "~/Documents/Rishi_Projects/Memora",
                                             homeDirectory: home),
                        .allowed("/Users/rishi/Documents/Rishi_Projects/Memora"))
            expectEqual(RevealPolicy.verdict(for: "/etc/hosts", homeDirectory: home), .outside,
                        "another user's files are not a click away")
            expectEqual(RevealPolicy.verdict(for: "~/.ssh", homeDirectory: home), .secret)
            expectEqual(RevealPolicy.verdict(for: "~/Documents/keys/id_ed25519",
                                             homeDirectory: home), .secret,
                        "the file name is a credential whatever folder it sits in")
            expectEqual(RevealPolicy.verdict(for: "~/Documents/vault/../../.ssh",
                                             homeDirectory: home), .secret,
                        "a `..` that climbs into a denied folder is still that folder")
            expectEqual(RevealPolicy.verdict(for: "Memora", homeDirectory: home), .lookup("Memora"),
                        "a bare name is a thing to find, not a path to guess under home")
            expectEqual(RevealPolicy.verdict(for: "file:///tmp/x", homeDirectory: home), .unreadable,
                        "a URL handed to Finder would be handed to whatever owns URLs")
            // A disk image or an app bundle is revealable even though it is unreadable — the format
            // rules belong to a read, and this is not one.
            expectEqual(RevealPolicy.verdict(for: "~/Downloads/build.zip", homeDirectory: home),
                        .allowed("/Users/rishi/Downloads/build.zip"))
        }

        test("one command, fixed arguments, and no way to write a second one") {
            expectEqual(DoRequest.parse("run_command:caffeinate -u -t 3600"),
                        .runCommand(argv: ["caffeinate", "-u", "-t", "3600"]))
            expectEqual(DoRequest.parse("command:pmset -g batt"),
                        .runCommand(argv: ["pmset", "-g", "batt"]),
                        "\"the terminal command that shows the battery\" is the request he means")
            // Quoting is for an argument with a space in it, which `osascript` needs constantly.
            expectEqual(DoRequest.parse("run_command:defaults read \"My App\""), nil,
                        "defaults is privileged and stays refused whatever follows it")
            expectEqual(DoRequest.parse("run_command:say \"hello there\""),
                        .runCommand(argv: ["say", "hello there"]))
            // AUDIT.md A-02: interpreters and launchers re-open everything the deny list closes —
            // System Events keystrokes past the key refusals, `do shell script` past the network
            // ban, `open` past the credential refusals.
            expectEqual(DoRequest.parse("run_command:osascript -e hello"), nil,
                        "osascript buys keystrokes and shell scripts the rest of the policy refuses")
            expectEqual(DoRequest.parse("run_command:open notes.txt"), nil,
                        "open bypasses the read policy's credential and root rules")
            expectEqual(DoRequest.parse("run_command:python3 -c hello"), nil,
                        "an interpreter is every denied program at once")
            expectEqual(DoRequest.parse("run_command:date -u"), .runCommand(argv: ["date", "-u"]),
                        "an ordinary one-sentence program still parses")
            expectEqual(ToolLayer.question(for: .runCommand(argv: ["caffeinate", "-u"])),
                        "Run caffeinate -u?",
                        "the whole command line is the question, or he is approving what he cannot read")
            expect(ToolLayer.alwaysAsks(.runCommand(argv: ["caffeinate"])),
                   "a model-authored command is never run with asking switched off")
            expect(!ToolLayer.alwaysAsks(.openApp(name: "Notes")),
                   "opening an app he named is routine, and asking there would be noise")
        }

        test("a command that is still holding is not reported as finished") {
            // Photographed 2026-10-31: he said "run caffeinate in terminal", the card read
            // `caffeinate -u -t 21600 did not run.` with no cause anywhere on it, and the other arm
            // of the same code called a live six-hour sleep hold "caffeinate finished." Both are the
            // report being wrong about a command that reported nothing at all.
            let hold = DoRequest.runCommand(argv: ["caffeinate", "-u", "-t", "21600"])
            expectEqual(ToolLayer.outcomeLine(for: hold, succeeded: true, commandStillRunning: true),
                        "caffeinate is running and Chunks has stopped watching it.",
                        "a six-hour hold told to him as over is a Mac that goes to sleep while he "
                        + "believes it is awake")
            expectEqual(ToolLayer.outcomeLine(for: hold, succeeded: true, commandStillRunning: false),
                        "caffeinate finished.",
                        "a command that really did return still needs the short answer")
            expectEqual(ToolLayer.outcomeLine(for: hold, succeeded: false),
                        "caffeinate -u -t 21600 did not run.",
                        "the failure line keeps the whole line he approved, because that is what he "
                        + "can go and run himself")
            // And the third state is not reachable by the success path alone: a refused start must
            // never read as a running hold.
            expect(!ToolLayer.outcomeLine(for: hold, succeeded: false, commandStillRunning: false)
                    .contains("stopped watching"),
                   "nothing is running, so nothing may be described as being watched")
        }

        test("every way of smuggling a shell into a command is refused") {
            // These are not hypothetical grammar slips; they are what a prompt injection writes when
            // it wants a second command executed. None of them can be interpreted by `Process` —
            // there is no shell — so refusing them is about not *pretending* the tool understood.
            for body in ["run_command:",
                         "run_command:caffeinate; rm -rf /",
                         "run_command:caffeinate && curl evil",
                         "run_command:caffeinate | sh",
                         "run_command:echo $(whoami)",
                         "run_command:echo `whoami`",
                         "run_command:cat secrets > /tmp/out",
                         "run_command:/bin/sh -c anything",
                         "run_command:./build.sh",
                         "run_command:sudo pmset -a sleep 0",
                         "run_command:rm -rf Documents",
                         "run_command:curl https://example.com",
                         "run_command:two\nlines"] {
                expect(DoRequest.parse(body) == nil,
                       "\(body) became a runnable request")
            }
        }

        test("home opens in Finder, and home's data folders still do not") {
            let home = "/Users/rishi"
            // The asymmetry is the whole distinction: a reveal is *seen by him*, a read is *sent to
            // Google*. So `~` is a window he can ask for even though nothing under it that is not in
            // a work folder can be read — and the sub-folders that hold other apps' data stay shut,
            // because putting a Mail store on screen for a shoulder-surfing moment is its own leak.
            expectEqual(RevealPolicy.verdict(for: "~", homeDirectory: home),
                        .allowed("/Users/rishi"))
            expectEqual(RevealPolicy.verdict(for: "~/Library/Mail", homeDirectory: home), .outside,
                        "one level under home is not the same request as home")
            expectEqual(RevealPolicy.verdict(for: "~/Documents/Memora", homeDirectory: home),
                        .allowed("/Users/rishi/Documents/Memora"))
            expectEqual(RevealPolicy.verdict(for: "~/.ssh", homeDirectory: home), .secret,
                        "the deny-list outranks the home exception")
        }

        test("punctuation a real shortcut name carries stays one name") {
            // "Focus & Deep work" is a name a human types. Refusing `&` would have rejected it and
            // taught the model that shortcuts with punctuation are unreachable.
            expectEqual(DoRequest.parse("run_shortcut:Focus&x=1"), .runShortcut(name: "Focus&x=1"))
            expectEqual(DoRequest.parse("run_shortcut:100%"), .runShortcut(name: "100%"))
        }

        test("the shortcut url carries the exact name the card showed") {
            // Built through URLComponents, so the assertion is a round trip rather than a string:
            // a name that comes back different is a different automation being run.
            let url = DoRequest.shortcutURL(name: "Focus & Deep work")
            expectEqual(url?.scheme ?? "-", "shortcuts")
            expectEqual(url?.host ?? "-", "run-shortcut")
            let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            expectEqual(items?.first?.value ?? "-", "Focus & Deep work",
                         "the name has to survive encoding, not be truncated at the ampersand")
        }

        test("an email request fills a message and stops at the address") {
            let request = DoRequest.parse("email:rick@studio.com")
            expectEqual(request, .email(to: "rick@studio.com"))
            expectEqual(ToolLayer.question(for: request!), "Start an email to rick@studio.com?")
            expectEqual(DoRequest.mailtoURL(address: "rick@studio.com")?.absoluteString,
                        "mailto:rick@studio.com")
        }

        test("a string that is not an address does not open a compose window") {
            for body in ["email:hey", "email:two@words@studio.com", "email:@studio.com",
                         "email:rick@studio", "email:rick@.com", "email:mailto:x@y.com"] {
                expect(DoRequest.parse(body) == nil,
                       "\(body) became a request; an address the user did not say is not a recipient")
            }
        }

        // MARK: The schedule, from a spoken sentence

        test("a routine is added from three named parts") {
            let body = "routine_add:Morning glance|daily at 08:00|brief me on what is open"
            let request = DoRequest.parse(body)
            expectEqual(request, .addRoutine(title: "Morning glance",
                                             cadence: .daily(at: "08:00"),
                                             prompt: "brief me on what is open"))
            // The card has to carry the question, not just the time: approving a schedule without
            // reading what it asks is approving something unread.
            expectEqual(ToolLayer.question(for: request!),
                        "Add \"Morning glance\" — every day at 08:00 — asking "
                        + "\"brief me on what is open\"?")
            expectEqual(ToolLayer.outcomeLine(for: request!, succeeded: true),
                        "Added \"Morning glance\", every day at 08:00.")
        }

        test("the four cadences a person actually says") {
            expectEqual(DoRequest.routineCadence(from: "daily at 08:00"), .daily(at: "08:00"))
            expectEqual(DoRequest.routineCadence(from: "every day at 8:00"), .daily(at: "08:00"),
                        "a model writes \"8:00\"; the store keeps one shape so the panel can read "
                        + "back the time the scheduler will use")
            expectEqual(DoRequest.routineCadence(from: "weekdays at 09:30"),
                        .weekdays(at: "09:30"))
            expectEqual(DoRequest.routineCadence(from: "every 30 minutes"), .every(minutes: 30))
            expectEqual(DoRequest.routineCadence(from: "every 2 hours"), .every(minutes: 120))
        }

        test("a cadence Chunks cannot honour is refused at parse, not guessed") {
            // A routine that fires at a time the model invented is a notification at the wrong hour,
            // and the schedule outlives the conversation that made it.
            for words in ["daily at 25:00", "daily at morning", "someday at 08:00",
                          "every 40 seconds", "weekly at 08:00", "at 08:00", ""] {
                expect(DoRequest.routineCadence(from: words) == nil,
                       "\"\(words)\" became a schedule; it should have stayed a sentence")
            }
        }

        test("a malformed routine body shows the user the tag rather than doing nothing") {
            for body in ["routine_add:daily at 08:00|brief me",
                         "routine_add:Morning glance|whenever|brief me",
                         "routine_add:|daily at 08:00|brief me",
                         "routine_add:Morning glance|daily at 08:00|"] {
                expect(DoRequest.parse(body) == nil,
                       "\(body) parsed into a routine the panel could not show")
            }
        }

        test("a routine question longer than the card can show is not added") {
            let long = String(repeating: "word ", count: 40)
            expect(!DoRequest.routinePromptIsValid(long),
                   "the store allows 400 characters; the card shows two lines, so the tool is the "
                   + "stricter door")
            expect(DoRequest.routinePromptIsValid("brief me on what is open"))
            expect(DoRequest.parse("routine_add:T|daily at 08:00|\(long)") == nil)
        }

        test("a routine whose card sentence runs past two lines is refused") {
            // Each part is legal on its own; the pair is not readable in the space the card has.
            let longTitle = Array(repeating: "morning", count: 7).joined(separator: " ")   // 55 chars
            let body = "routine_add:\(longTitle)|daily at 08:00|brief me on what is open"
            expect(DoRequest.routineTitleIsValid(longTitle),
                   "the title alone is inside the store's own limit")
            expect(DoRequest.parse(body) == nil,
                   "a clipped question is an approval given for words nobody read")
        }

        test("removing a routine names the effect and the failure") {
            let request = DoRequest.parse("routine_remove:Morning glance")
            expectEqual(request, .removeRoutine(title: "Morning glance"))
            expectEqual(ToolLayer.question(for: request!), "Remove the routine \"Morning glance\"?")
            expectEqual(ToolLayer.outcomeLine(for: request!, succeeded: false),
                        "There is no routine called \"Morning glance\".")
        }

        test("every tool is asked about, because every tool changes something") {
            for request in [DoRequest.parse("open_app:Notes"), DoRequest.parse("set_volume:40"),
                            DoRequest.parse("open_url:youtube.com"),
                            DoRequest.parse("run_shortcut:Focus"),
                            DoRequest.parse("email:rick@studio.com"),
                            DoRequest.parse("routine_add:T|daily at 08:00|p"),
                            DoRequest.parse("routine_remove:T")] {
                expect(request != nil, "a tool stopped parsing")
                expectEqual(ToolLayer.effect(of: request!), .changesSystemState,
                            "a new tool must be asked about by default, not allowed silently")
            }
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

        test("a name never reaches inside a menu, and still reaches the button that opens it") {
            // Measured 2026-10-24 on a spoken plan: asked to "click the Memora workspace" — a tile in
            // the Qoder window — the named route answered `AXMenuItem/Memora verb=AXPress at
            // (0.0, 1107.0)`, said "Pressed Memora." and opened a Finder window for a folder of that
            // name. `isOnScreen` passed it because a menu bar's rows sit on the edge of the display.
            expect(AXTDriver.isMenuRole("AXMenuItem"),
                   "a closed menu keeps its rows addressable; a name finding one is pressing blind")
            expect(AXTDriver.isMenuRole("AXMenu"))
            expect(!AXTDriver.isMenuRole("AXMenuButton"),
                   "the button the user can see and that opens the menu is a real control — "
                     + "refusing it would be a false negative, not a safety win")
            expect(!AXTDriver.isMenuRole("AXButton"),
                   "a workspace row, a tile and a toolbar item all answer as AXButton")
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
            expectEqual(acts(events)[0].pointTarget?.x ?? -1, 1180)
            expectEqual(acts(events)[0].pointTarget?.y ?? -1, 1002)
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

        // A line break is a newline in an editor and a Send in a one-line box. His own proven typer
        // presses Enter between lines on purpose, in an editor; in a chat composer the same key
        // submits half the code to half the wrong people, so the whole act refuses instead.
        test("a line break is a newline in an editor and a send in a one-line box") {
            expectEqual(AXTDriver.newlinePolicy(text: "line one\nline two", role: "AXTextArea"), .ok,
                        "a multiline editor must take the code with its line breaks")
            expectEqual(AXTDriver.newlinePolicy(text: "line one\nline two", role: "AXTextField"),
                        .refused(lineBreaks: 1),
                        "a one-line box would send the first line and swallow the rest")
            expectEqual(AXTDriver.newlinePolicy(text: "one line only", role: "AXTextField"), .ok,
                        "ordinary messages must not pay for a rule about line breaks")
            expect(AXTDriver.TypeResult.postedUnverified(appName: "Google Chrome", characters: 1489)
                     .userFacingReason.contains("would not confirm"),
                   "an unconfirmed post must say to look at the field, not claim it typed")
            expect(AXTDriver.TypeResult.multilineWithoutWitness(appName: "Google Chrome",
                                                                lineBreaks: 3)
                     .userFacingReason.contains("nothing was typed"),
                   "line breaks with no witness must refuse, not send")
            expect(AXTDriver.TypeResult.postedUnverified(appName: "Google Chrome", characters: 1)
                     .didType,
                   "posted keystrokes are a completed step, or a plan stops over work that landed")
        }

        // The focus click into web content is the shell's decision, made while resolving a question
        // he already answered — never something a tag can ask for.
        test("the focus click is the shell's decision, never the model's") {
            expect(ActionRequest.parseType("640,910:editor|code")?.webFocusClick == false,
                   "a tag must not be able to request a click")
            let question = ActionRequest.webTypeQuestion(label: "editor", appName: "Google Chrome",
                                                         characters: 1489,
                                                         point: CGPoint(x: 640, y: 910))
            expect(question.contains("Click the editor at (640,910) in Google Chrome")
                   && question.contains("1489 characters"),
                   "the question must name the click and the size he is approving: \(question)")
        }

        // CodeMirror indents on Return, so the value of a successfully typed file carries more
        // leading whitespace than the payload did. A strict equality on the read-back would
        // report that act as refused — the lie the line-wise witness exists to prevent.
        test("the read-back witness tolerates the editor re-indenting each line") {
            let payload = "#include <a.h>\nint main(void) {\nreturn 0;\n}"
            let value = "#include <a.h>\n    int main(void) {\n        return 0;\n    }"
            expect(AXTDriver.allLinesPresent(value: value, payload: payload),
                   "an editor that indented the code he typed must still be reported as typed")
            expect(!AXTDriver.allLinesPresent(value: "#include <a.h>", payload: payload),
                   "half a file arriving must not be reported as the whole of it")
            // The 22:00 Programiz case: the value holds the visible viewport of a 31-line file.
            let viewport = "int main(void) {\n    return 0;\n}\n\nstruct node_state {"
            expect(AXTDriver.mostPayloadLinesPresent(value: viewport, payload: payload),
                   "a field showing most of the on-screen code must not report itself refused")
            expect(!AXTDriver.mostPayloadLinesPresent(value: "hello world", payload: payload),
                   "an editor must not be called successful when it shows unrelated words")
        }

        // The 2026-10-30 Examlly failure, photographed in the log: focus verified, 200 characters
        // posted, and the card answering "the text area took the keystrokes and then refused the
        // text" fourteen times in a row. A Chromium `AXTextArea` answers `kAXValueAttribute` with an
        // empty string even when it took everything, so an empty read-back is *no witness* — and a
        // refusal is a claim this app cannot support. The three-way split is asserted here because
        // it cannot be tested while it is welded to a live AXUIElement.
        test("an empty read-back is no witness, not a refusal") {
            let payload = "SELECT *\nFROM adopters;"
            expectEqual(AXTDriver.witness(value: nil, payload: payload), .silent,
                        "an absent attribute has always meant 'cannot check', not 'refused'")
            expectEqual(AXTDriver.witness(value: "", payload: payload), .silent,
                        "a Chromium editor that answers the empty string must not be reported as "
                        + "having refused text it may well have taken")
            expectEqual(AXTDriver.witness(value: "   \n ", payload: payload), .silent,
                        "whitespace is the same silence with newlines in it")
        }

        test("a field that shows other words is still a real refusal") {
            // The half that must NOT loosen: a value that came back with content and does not hold
            // the payload is evidence, and the act has to be reported as it reads.
            let payload = "SELECT *\nFROM adopters;"
            expectEqual(AXTDriver.witness(value: "the old answer is here", payload: payload),
                        .contradicts,
                        "a field that answers with different words did refuse the text — that is "
                        + "the one case allowed to say so")
            expectEqual(AXTDriver.witness(value: payload, payload: payload), .confirmed,
                        "an exact match is still the ordinary success")
            expectEqual(AXTDriver.witness(value: "prefix " + payload + " suffix", payload: payload),
                        .confirmed,
                        "an editor that added its own surrounding text still took his code")
            expectEqual(AXTDriver.witness(value: "    SELECT *\n        FROM adopters;",
                                          payload: payload), .confirmed,
                        "a re-indented multi-line payload is a success, not a contradiction")
        }

        // The qualified-coordinate form ACT learned in October, photographed written into a
        // `[TYPE:]` on 2026-10-28 — where it failed open as raw text over an empty editor.
        test("a TYPE aimed at app plus coordinates is the same qualified aim ACT accepts") {
            let request = ActionRequest.parseType("app=Google Chrome x=200,y=400|hello there")
            expectEqual(request?.textToType, "hello there",
                        "the model named the app and the point; the words must ride with them")
            expectEqual(request?.pointTarget?.appName, "Google Chrome",
                        "the named app is the corroboration the press path checks against")
            expectEqual(request?.pointTarget?.x ?? -1, 200, "the aim must keep its x")
            expectEqual(request?.pointTarget?.y ?? -1, 400, "the aim must keep its y")
        }

        // He named typing the whole code into an editor as the capability the product is for, the
        // day he watched a buffer struct get offered for copy instead. This is the case that stops
        // the cap quietly shrinking back under a snippet.
        test("a whole code snippet fits in one type act, newlines included") {
            expect(ActionRequest.maxTypedCharacters >= 6_000,
                   "a 1,200-character cap turns the headline capability into a copy button")
            let code = "typedef struct Node { void *data; } Node;\n"
                + "void enqueue(void *q, void *data) { Node *n = malloc(sizeof(Node)); n->data = data; }"
            expectEqual(ActionRequest.parseType("640,910:editor|\(code)")?.textToType, code,
                        "the tag must carry every character it promises")
        }

        test("a screen suffix on a type tag picks the display, not the message") {
            // The prompt says the tag follows [ACT:…]'s rules *including* `:screenN`, and a model
            // writes that suffix at the end of the tag — which is inside the words after a `|`.
            // Sending "good night:screen2" to a friend is the whole bug.
            let afterLabel = ActionRequest.parseType("640,910:box:screen2|good night")
            let afterText = ActionRequest.parseType("640,910:box|good night:screen2")
            expectEqual(afterLabel?.pointTarget?.display ?? 0, 2)
            expectEqual(afterLabel?.textToType ?? "", "good night")
            expectEqual(afterText?.pointTarget?.display ?? 0, 2,
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
