import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for the semantic primitive.
///
/// The rule under test is "name a control, not a pixel", and the failure mode it guards against is
/// the one that hurts: a loosely-parsed target that matches the wrong element and presses something
/// the user never pointed at. So every case that should *not* parse has to fail closed — a tag that
/// half-parsed is more dangerous than one that visibly did nothing.
public enum SemanticTargetTests {

    public static func register() {
        TestRunner.currentSuite = "Semantic targets"

        test("app, role and name come through in any order") {
            let plain = SemanticTarget.parse("app=WhatsApp role=button name=Send")
            expectEqual(plain?.app, "WhatsApp")
            expectEqual(plain?.role, "button")
            expectEqual(plain?.name, "Send")

            let reordered = SemanticTarget.parse("name=Send app=WhatsApp")
            expectEqual(reordered?.name, "Send", "the model does not write fields in a fixed order")
            expect(reordered?.role == nil, "an absent role must stay absent, not become an empty string")
        }

        test("the app is the value after the prefix, not a key in the list") {
            // Parsing `app=` as one field among many reads the app as "WhatsApp name" and then
            // finds nothing, or worse, finds something in the wrong application.
            let parsed = SemanticTarget.parse("app=WhatsApp name=Send")
            expectEqual(parsed?.app, "WhatsApp", "the app swallowed the next key")
            expectEqual(parsed?.name, "Send")
        }

        test("a field Chunks does not know is refused, not guessed") {
            expect(SemanticTarget.parse("app=WhatsApp name=Send x=5") == nil,
                   "an unrecognised field means the model invented a grammar; that is a visible tag, not a press")
        }

        test("a quoted name keeps its spaces") {
            let parsed = SemanticTarget.parse("app=WhatsApp name=\"Dad chat\"")
            expectEqual(parsed?.name, "Dad chat",
                        "a contact name with a space is the common case, not an edge case")
        }

        test("a name without quotes keeps its words too") {
            // The prompt tells the model to write the application's own name, and two of the apps on
            // this machine are called "Google Chrome" and "Visual Studio Code". Cutting a bare value
            // at the first space turned those into an unknown field and closed the whole tag — found
            // with `--probe-semantic app=Google Chrome name="All Bookmarks"` on 2026-10-18, which is
            // exactly the request the user would say out loud.
            let browser = SemanticTarget.parse("app=Google Chrome name=Send")
            expectEqual(browser?.app, "Google Chrome", "the app is two words, not a broken tag")
            expectEqual(browser?.name, "Send")

            let editor = SemanticTarget.parse("app=Visual Studio Code role=textfield name=Search")
            expectEqual(editor?.app, "Visual Studio Code")
            expectEqual(editor?.role, "textfield")
            expectEqual(editor?.name, "Search")

            // Bare values run to the next `key=`, in either direction.
            let person = SemanticTarget.parse("role=button app=WhatsApp name=Dad chat")
            expectEqual(person?.name, "Dad chat", "a two-word name at the end of the tag")
            expectEqual(person?.app, "WhatsApp")

            expect(SemanticTarget.looksLikeField("name=x"), "a field opens here")
            expect(!SemanticTarget.looksLikeField("50%=off"),
                   "a control whose name contains = is a value, not a key")
            expect(!SemanticTarget.looksLikeField("Chat"), "a plain word is a value")
        }

        test("anything that is not a named control does not parse") {
            // Each of these would otherwise become a search over a whole app with a partial
            // description, which is how a press lands somewhere unexpected.
            expect(SemanticTarget.parse("app=WhatsApp") == nil, "no name is not a target")
            expect(SemanticTarget.parse("name=Send") == nil, "no app is not a target")
            expect(SemanticTarget.parse("app=WhatsApp name=\"unterminated") == nil,
                   "a tag the model stopped writing inside must not resolve to a control")
            expect(SemanticTarget.parse("app= name=Send") == nil)
            expect(SemanticTarget.parse("820,145:send button") == nil,
                   "the pixel grammar is a different request and must not be read as this one")
        }

        test("the card's sentence names the app, the role and the control") {
            let target = SemanticTarget(app: "WhatsApp", role: "button", name: "Send")
            let phrase = target.questionPhrase
            expect(phrase.contains("WhatsApp") && phrase.contains("button") && phrase.contains("Send"),
                   "what the user approves has to be what is searched for: \(phrase)")
        }

        test("a name needs real agreement to count, because there is no pixel to corroborate it") {
            // `nameScore` 1 is one shared token — enough inside a window the aim already landed on,
            // nowhere near enough to press in an app chosen by name alone.
            expect(SemanticTarget.minNameScore >= 2,
                   "a single-token match must not be pressable when nothing else confirms it")
        }

        test("a role matches its family and not its neighbours") {
            let field = SemanticTarget(app: "WhatsApp", role: "textfield", name: "message")
            expect(field.roleMatches("AXTextArea"), "Chromium and WhatsApp publish text fields as AXTextArea")
            expect(field.roleMatches("AXSearchField"),
                   "Catalyst puts the field-ness in the subrole, so a role-only check would miss its own search box")
            expect(field.roleMatches("button") == false,
                   "a field request must not be satisfied by a button")
            expect(SemanticTarget(app: "X", name: "y").roleMatches("anything"),
                   "no role named means no role constraint")
            expect(field.roleMatches("mystery-role") == false,
                   "an unknown published role must not be assumed to satisfy the request")
            expect(SemanticTarget(app: "Chrome", role: "button", name: "x")
                        .roleMatches("AXPopUpButton"),
                   "a bookmark menu really is a button, and refusing it over vocabulary loses a press the user can see")
            expect(SemanticTarget(app: "Chrome", role: "link", name: "x").roleMatches("AXHyperlink"),
                   "Chromium's own name for a link")
            expect(SemanticTarget(app: "Chrome", role: "submit", name: "x")
                        .roleMatches("AXPopUpButton") == false,
                   "a role that is not in the vocabulary the prompt teaches must not stretch to anything")
        }

        // MARK: - The tag the model actually writes

        test("a named [ACT:] carries no coordinates at all") {
            // The whole point of the semantic path is that nothing is mapped through a screenshot.
            // A request that kept a fake point in it would press whatever those pixels land on.
            let request = ActionRequest.parseAct("app=WhatsApp role=button name=Send")
            expectEqual(request?.label, "Send", "the card and the log speak the control's name")
            expect(request?.semanticTarget != nil, "the body named a control and was read as a guess")
            expect(request?.pointTarget == nil,
                   "a named request that also carried a point would take the pixel route and skip the name")
        }

        test("a coordinate body is still a point aim") {
            // The two grammars share one tag, and the regression this guards is the interesting one:
            // a label containing an `=` must not turn a working pixel press into a name search.
            let request = ActionRequest.parseAct("820,540:send=run")
            expectEqual(request?.pointTarget?.x ?? -1, 820,
                        "the pixel grammar is the fallback for unnamed content and must keep working")
            expect(request?.semanticTarget == nil)
        }

        test("a body that is neither grammar reaches the user as text") {
            // Fail-open in the only safe direction: a swallowed `[ACT:…]` is a spoken instruction
            // the user thinks Chunks heard.
            expect(ActionRequest.parseAct("app=WhatsApp") == nil, "a name is required")
            expect(ActionRequest.parseAct("role=button name=Send") == nil, "an app is required")
            expect(ActionRequest.parseAct("app=WhatsApp name=Send window=3") == nil,
                   "an invented field must not be quietly dropped and the rest pressed")
        }

        test("a named [TYPE:] puts the words after the bar and nowhere else") {
            let request = ActionRequest.parseType("app=WhatsApp name=\"Message box\"|good night")
            expectEqual(request?.textToType ?? "", "good night")
            expectEqual(request?.semanticTarget?.name, "Message box",
                        "the field the plan opened one step ago is named, not aimed")
            expect(request?.pointTarget == nil)

            // Without the bar there is no way to tell where a quoted name ends and the message
            // begins, and guessing wrong types into the wrong place.
            expect(ActionRequest.parseType("app=WhatsApp name=box") == nil,
                   "a type act with no words is a request that cannot be shown on a card")
        }

        test("a named [SCROLL:] carries direction and distance") {
            let one = ActionRequest.parseScroll("app=WhatsApp name=\"Chat list\"|down")
            expectEqual(one?.scrollIntent?.direction, .down)
            expectEqual(one?.scrollIntent?.pages ?? 0, 1)
            expectEqual(one?.label, "Chat list",
                        "the card names the list the user spoke about, not the scroller above it")

            let many = ActionRequest.parseScroll("app=Chrome name=\"History list\"|3 down")
            expectEqual(many?.scrollIntent?.direction, .down, "the number and the word swap freely")
            expectEqual(many?.scrollIntent?.pages ?? 0, 3)

            // A scroll with no direction is not a scroll, and the bar is what separates a name from
            // a direction — without it, `down` could be the list called "down".
            expect(ActionRequest.parseScroll("app=WhatsApp name=\"Chat list\"") == nil)
            expect(ActionRequest.parseScroll("app=WhatsApp name=\"Chat list\"|sideways") == nil,
                   "an invented direction must not default to down and move the screen")
            expect(ActionRequest.parseScroll("app=WhatsApp name=\"Chat list\"|down 99") == nil,
                   "99 pages is past the cap, and the cap is what keeps a scroll inside the list")
        }

        test("a launch leads a plan only when every step is named") {
            // The launch is what makes the next screen, so a step aimed at pixels from the *old*
            // screen would press whatever the new window put there. Names are re-resolved against
            // the tree as it is then; coordinates are not, and that difference is the whole rule.
            let launch = [DoRequest.openApp(name: "WhatsApp")]
            let named = [ActionRequest.parseAct("app=WhatsApp name=Search")!,
                         ActionRequest.parseType("app=WhatsApp name=\"Message box\"|HI")!]
            expectEqual(ActionRequest.leadingTool(for: named, tools: launch), launch.first,
                        "a named plan cannot be run without the app it is about being open")

            let onePixelStep = named + [ActionRequest(target: PointTarget(x: 500, y: 500,
                                                                         label: "send"))]
            expect(ActionRequest.leadingTool(for: onePixelStep, tools: launch) == nil,
                   "one coordinate step after a launch is a press aimed at a screen that no longer exists")
            expect(ActionRequest.leadingTool(for: named, tools: launch + launch) == nil,
                   "two tools and one card is the question nobody can answer")
            expect(ActionRequest.leadingTool(for: [], tools: launch) == nil,
                   "no plan means the ordinary single-tool path, not this rule")
        }

        test("a better name beats a better role guess") {
            // Measured 2026-10-18 in WhatsApp: `name=Search` found the search box, and the same ask
            // with `role=button` was refused outright — Catalyst publishes that box as an
            // `AXStaticText` answering `AXPress`. So a role the app does not use must not veto a
            // control the name has already identified; it only decides between equals.
            expect(AXTDriver.displaces(score: 3, roleMatched: false, best: (2, true)),
                   "an exact name must not lose to a weaker name that happens to fit the model's role")
            expect(AXTDriver.displaces(score: 2, roleMatched: true, best: (2, false)),
                   "at an equal name, the element that answers the role is the one meant")
            expect(!AXTDriver.displaces(score: 2, roleMatched: false, best: (2, true)),
                   "the incumbent that matched both keeps the tie")
            expect(AXTDriver.displaces(score: 2, roleMatched: false, best: nil),
                   "the first candidate is held until something beats it")
        }
        test("a two-word app answers to the half of its name a person says") {
            // `nameScore` gives one shared token a 1 and the named route needs a 2, so before this
            // rule `app=Chrome` could not find "Google Chrome" and `app=VS Code` could not find
            // "Code" — the two most likely things to come out of a mouth.
            expect(AXTDriver.matchesAppName(label: "Chrome", owner: "Google Chrome"))
            expect(AXTDriver.matchesAppName(label: "VS Code", owner: "Code"))
            expect(AXTDriver.matchesAppName(label: "WhatsApp", owner: "WhatsApp"))
            expect(AXTDriver.matchesAppName(label: "Google Chrome", owner: "Chrome"),
                   "containment works in either direction")

            // Whole tokens only. A substring rule would let "Mail" reach "MailMate", and the wrong
            // app is the one failure a named request must never be able to reach.
            expect(!AXTDriver.matchesAppName(label: "Mail", owner: "MailMate"))
            expect(!AXTDriver.matchesAppName(label: "Notes", owner: "Notion"))
            expect(!AXTDriver.matchesAppName(label: "", owner: "Finder"))
            expect(!AXTDriver.matchesAppName(label: "Safari", owner: "Finder"))
        }

        test("a field accepts the words on it as well as the words in it") {
            // WhatsApp's composer says "Type a message" on screen and publishes `Compose message`.
            // A model that reads the screen is right, so the lookup tries the group's other names —
            // but only for fields, and only after the exact name found nothing.
            let variants = SemanticTarget.fieldAliasVariants(of: "message box")
            expect(variants.contains("Compose message".lowercased()),
                   "the measured WhatsApp name has to be reachable from the placeholder's words")
            expect(SemanticTarget.fieldAliasVariants(of: "Playlist list").isEmpty,
                   "an ordinary name is not run through a thesaurus")

            let field = SemanticTarget(app: "WhatsApp", role: "textfield", name: "message box")
            expect(AXTDriver.nameCandidates(for: field, kind: .field).count > 1,
                   "a field lookup carries its aliases")
            expect(AXTDriver.nameCandidates(for: field, kind: .control) == ["message box"],
                   "a press carries only what was asked for — an alias there is a guess at an action")
        }
    }
}
