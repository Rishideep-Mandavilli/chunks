import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for the window verbs: which window a sentence names, what the card says, and what may never
/// be chosen for him.
///
/// The failure these guard against is the expensive one. A press aimed at the wrong row selects
/// something he can undo; "close that window" aimed at the wrong one loses a document, and the only
/// trace is a card he already answered. So the negative cases carry more weight here than in any other
/// suite: two windows that answer the same words must be refused *with both names listed*, a title
/// that matches another app's window must not cross apps, and nothing may be chosen by where it sits.
public enum WindowActTests {

    private static func candidate(_ app: String, _ title: String,
                                  x: CGFloat = 0, y: CGFloat = 0,
                                  focused: Bool = false) -> WindowAct.Candidate {
        WindowAct.Candidate(pid: 1, appName: app, title: title,
                            frame: CGRect(x: x, y: y, width: 800, height: 600),
                            isFocused: focused)
    }

    public static func register() {
        TestRunner.currentSuite = "Window verbs"

        test("the four verbs parse, with and without a window title") {
            for body in ["focus_window:Safari|Inbox", "focus:Safari|Inbox",
                         "raise:Safari|Inbox", "front:Safari|Inbox"] {
                expectEqual(DoRequest.parse(body), .focusWindow(app: "Safari", title: "Inbox"),
                            "\(body) is one verb with four spellings")
            }
            expectEqual(DoRequest.parse("minimize_window:Code|config.yml"),
                        .minimizeWindow(app: "Code", title: "config.yml"))
            expectEqual(DoRequest.parse("minimise:Code|config.yml"),
                        .minimizeWindow(app: "Code", title: "config.yml"),
                        "both spellings of minimise, because he says either")
            expectEqual(DoRequest.parse("close_window:Code|config.yml"),
                        .closeWindow(app: "Code", title: "config.yml"))
            expectEqual(DoRequest.parse("quit_app:Safari"), .quitApp(name: "Safari"))
            expectEqual(DoRequest.parse("quit:Safari"), .quitApp(name: "Safari"))
            expectEqual(DoRequest.parse("focus_window:Safari"), .focusWindow(app: "Safari", title: nil),
                        "an app with one window needs no title, and demanding one would refuse a "
                        + "sentence he can see the answer to")
        }

        test("a window verb that is not one is text, not an act") {
            // Fail open like every other tag: a path-shaped name is how an injection reaches something
            // that is not an application, and a 200-character title is a card nobody can read.
            expect(DoRequest.parse("close_window:/Applications/Safari.app|Inbox") == nil,
                   "a path is not an app name")
            expect(DoRequest.parse("close_window:.hidden|Inbox") == nil,
                   "nor is a dotfile")
            expect(DoRequest.parse("close_window:|Inbox") == nil, "an empty app names no window")
            expect(DoRequest.parse("close_window:Safari|") == .closeWindow(app: "Safari", title: nil),
                   "an empty title is the no-title case, not a broken tag")
            // The cap moved from 120 to 240 on 2026-11-03 because the gate failed on his real browser:
            // a Chrome tab is legitimately ~190 characters, and at 120 the answer to "close that tab"
            // was *no such window* about a window in front of him. A title's length is the app's choice;
            // what the card does with it is a separate question, and refusing the act was never the
            // answer to a readability problem.
            let atCap = String(repeating: "x", count: DoRequest.maxWindowTitleCharacters)
            expect(DoRequest.parse("close_window:Safari|\(atCap)") != nil,
                   "a title exactly at the cap parses")
            expect(DoRequest.parse("close_window:Safari|\(atCap)x") == nil,
                   "and past it the tag is text, not an act — an unbounded argument is how a model "
                        + "parks a paragraph where a window name belongs")
            expect(DoRequest.parse("kill_app:Safari") == nil,
                   "there is no force-quit in this app, so there is no tag that promises one")
        }

        test("a title may contain the separator, because document titles do") {
            expectEqual(DoRequest.parse("close_window:Code|config.yml | local"),
                        .closeWindow(app: "Code", title: "config.yml | local"),
                        "only the first | separates the app from the window")
        }

        test("the two verbs that lose work are always asked about, and the other two are not") {
            // The same rule a Send button follows: "don't ask" is about routine navigation, never about
            // throwing away an unsaved document on a model's say-so.
            expect(ToolLayer.alwaysAsks(.closeWindow(app: "Code", title: "config.yml")),
                   "closing a window is permanent even with asking switched off")
            expect(ToolLayer.alwaysAsks(.quitApp(name: "Safari")),
                   "and so is quitting the app that owns it")
            expect(!ToolLayer.alwaysAsks(.focusWindow(app: "Safari", title: "Inbox")),
                   "bringing a window forward is undone by one click, so it must not nag")
            expect(!ToolLayer.alwaysAsks(.minimizeWindow(app: "Safari", title: "Inbox")),
                   "and neither must minimising one")
            for verb in WindowAct.Verb.allCases {
                expect(verb.isPermanent == (verb == .close || verb == .quit),
                       "\(verb.rawValue)'s permanence is the reason it is asked about")
            }
        }

        test("all four verbs change which windows are on screen, so a plan behind one is held") {
            // `PlanAfterLaunch` uses this to decide whether the rest of a plan is still aimed at the
            // picture it was written for. Closing the window the picture *was* invalidates it just as
            // surely as opening one does.
            for request in [DoRequest.focusWindow(app: "Safari", title: nil),
                            .minimizeWindow(app: "Safari", title: nil),
                            .closeWindow(app: "Safari", title: nil),
                            .quitApp(name: "Safari")] {
                expect(request.invalidatesTheScreen, "\(request) changes the screen a pixel was aimed at")
            }
            expect(!DoRequest.setVolume(percent: 40).invalidatesTheScreen,
                   "and a volume change still does not")
        }

        test("the card names the window, the app, and what a permanent verb costs") {
            let window = candidate("Code", "config.yml")
            expectEqual(WindowAct.question(verb: .close, candidate: window),
                        "Close \"config.yml\" in Code? Anything unsaved in it is gone.")
            expectEqual(WindowAct.question(verb: .focus, candidate: window),
                        "Bring \"config.yml\" in Code to the front?")
            expectEqual(WindowAct.question(verb: .quit, candidate: candidate("Safari", "Inbox")),
                        "Quit Safari? Anything unsaved in it is gone.",
                        "quitting is about the app, so it does not quote one of its windows")
        }

        test("a window titled after its own app is named once, not twice") {
            // Photographed on the first live run of `--probe-windows`: Qoder's window answered
            // `"Qoder" in Qoder`, which is unreadable at the exact moment the card is asking about
            // closing something.
            let same = candidate("Qoder", "Qoder")
            expectEqual(WindowAct.question(verb: .focus, candidate: same),
                        "Bring Qoder to the front?")
            expectEqual(WindowAct.question(verb: .close, candidate: candidate("Safari", "")),
                        "Close Safari? Anything unsaved in it is gone.",
                        "and a window with no title at all is named by its app, never by an empty quote")
        }

        test("one window answers a title; two equal ones are refused with both names") {
            let inbox = candidate("Mail", "Inbox — 3 unread")
            let draft = candidate("Mail", "New Message")
            if case .one(let found) = WindowAct.resolve(verb: .focus, app: "Mail",
                                                        title: "Inbox", in: [inbox, draft]) {
                expectEqual(found.title, inbox.title, "the words picked the window he meant")
            } else {
                expect(false, "a unique title match must resolve, not refuse")
            }

            let twoInboxes = [candidate("Mail", "Inbox", x: 0), candidate("Mail", "Inbox", x: 400)]
            let ambiguous = WindowAct.resolve(verb: .close, app: "Mail", title: "Inbox",
                                              in: twoInboxes)
            guard case .ambiguous(let many) = ambiguous else {
                expect(false, "two windows called Inbox must be a refusal, got \(ambiguous)")
                return
            }
            expectEqual(many.count, 2, "and both are carried, because the refusal has to list them")
            let refusal = WindowAct.refusal(verb: .close, app: "Mail", title: "Inbox",
                                            resolution: ambiguous)
            expect(refusal.contains("Say which one"),
                   "the refusal asks him to choose rather than choosing: \(refusal)")
            expect(refusal.contains("2 windows"), "and says how many: \(refusal)")
        }

        test("two candidates at the same frame are one window published twice") {
            // Chromium does this for controls, and a window server that lists a window and its shadow
            // would otherwise refuse every close in the app.
            let doubled = [candidate("Code", "config.yml"), candidate("Code", "config.yml")]
            if case .one = WindowAct.resolve(verb: .close, app: "Code", title: "config.yml",
                                             in: doubled) {
                // resolved
            } else {
                expect(false, "the same rectangle twice is one window, not an ambiguity")
            }
        }

        test("no title is answerable only when the app has one window to mean") {
            let only = [candidate("Safari", "Apple")]
            if case .one = WindowAct.resolve(verb: .focus, app: "Safari", title: nil, in: only) {
                // resolved
            } else {
                expect(false, "\"focus Safari\" with one window open is answerable")
            }
            let three = [candidate("Safari", "Apple"), candidate("Safari", "Google"),
                         candidate("Safari", "News")]
            guard case .ambiguous(let many) = WindowAct.resolve(verb: .close, app: "Safari",
                                                                title: nil, in: three) else {
                expect(false, "three windows and no title must not pick one")
                return
            }
            expectEqual(many.count, 3, "all three are listed, because \"close Safari\" could mean any")
        }

        test("a title never reaches into another app's windows") {
            // The app filter comes first, and that ordering is the whole safety argument: a title is a
            // guess, and a guess that searched every app on the screen would close whatever matched.
            let mails = [candidate("Mail", "Inbox")]
            expectEqual(WindowAct.resolve(verb: .close, app: "Notes", title: "Inbox", in: mails),
                        WindowAct.Resolution.appNotRunning("Notes"),
                        "Notes is not running, so nothing of Mail's is even considered")
        }

        test("an app answers to the half of its name a person says") {
            let chrome = [candidate("Google Chrome", "Chunks — TASKS.md")]
            if case .one(let found) = WindowAct.resolve(verb: .focus, app: "Chrome",
                                                        title: "TASKS.md", in: chrome) {
                expectEqual(found.appName, "Google Chrome", "\"Chrome\" is how he says it")
            } else {
                expect(false, "a half-name must reach the app, the same rule the press path uses")
            }
            // …and one shared token is still not enough to close something.
            let weak = [candidate("Google Chrome", "Chunks — TASKS.md")]
            expectEqual(WindowAct.resolve(verb: .close, app: "Chrome", title: "the document",
                                          in: weak), .none,
                        "a single filler word is not a window name")
        }

        test("an app that is not running says so, rather than reporting no window") {
            expectEqual(WindowAct.resolve(verb: .quit, app: "Safari", title: nil, in: []),
                        WindowAct.Resolution.appNotRunning("Safari"),
                        "\"Safari is not running\" and \"Safari has no such window\" are different "
                        + "sentences and only one of them is true here")
        }

        test("between two titles that both answer, the more specific one wins") {
            // He says "Inbox" and Mail has both a window called exactly that and a longer one
            // containing the word. Choosing the longer one is choosing the window he did not name, and
            // refusing both would be a card about nothing — so specificity decides, and it is the only
            // thing allowed to.
            let exact = candidate("Mail", "Inbox")
            let longer = candidate("Mail", "Inbox — 3 unread messages")
            guard case .one(let found) = WindowAct.resolve(verb: .focus, app: "Mail", title: "Inbox",
                                                           in: [longer, exact]) else {
                expect(false, "one of the two is exactly what he said, so this is answerable")
                return
            }
            expectEqual(found.title, "Inbox", "the exact title wins regardless of the order they came in")
            expectEqual(WindowAct.specificity(of: "Inbox", asked: "Inbox"),
                        1_000 - 1, "an exact match scores above any partial one")
            expect(WindowAct.specificity(of: "Inbox — 3 unread messages", asked: "Inbox")
                       < WindowAct.specificity(of: "Inbox", asked: "Inbox"),
                   "and a title with more extra words scores lower, not higher")
        }

        test("a request for what is open is a read, and is classified as one everywhere") {
            expectEqual(DoRequest.parse("list_windows:all"), .listWindows(app: nil),
                        "\"all\" means every app, not an app called all")
            expectEqual(DoRequest.parse("list_windows:Safari"), .listWindows(app: "Safari"))
            expectEqual(DoRequest.parse("what_is_open:everything"), .listWindows(app: nil),
                        "the words he actually says resolve to the same request")
            expect(DoRequest.parse("list_windows:") == nil, "an empty argument names nothing to list")
            expect(DoRequest.parse("list_windows:/Applications") == nil,
                   "and a path is not an app name here either")

            expect(DoRequest.listWindows(app: nil).isContextRead,
                   "a read must never be offered as a card — approving a look is a question with no "
                   + "answer that matters")
            expect(!DoRequest.closeWindow(app: "Safari", title: nil).isContextRead,
                   "and closing a window is not a read")
            expectEqual(ToolLayer.effect(of: .listWindows(app: nil)), .readsTheMachine,
                        "the classifier that decides whether a request takes a card says read")
            expect(!DoRequest.listWindows(app: nil).invalidatesTheScreen,
                   "listing changes nothing, so a plan behind it is not held")
        }

        test("a listing groups by app, frontmost first, and says what it is") {
            let candidates = [
                candidate("Code", "config.yml", x: 0),
                candidate("Safari", "Inbox", x: 40),
                candidate("Safari", "Apple", x: 80),
            ]
            guard let block = OpenWindows.block(app: nil, frontmost: "Safari", in: candidates) else {
                expect(false, "three open windows must produce a listing")
                return
            }
            expectEqual(block.listed, 3, "all three are in it")
            expectEqual(block.leftOut, 0, "and nothing was dropped")
            let safariAt = block.text.range(of: "Safari (2)")?.lowerBound
            let codeAt = block.text.range(of: "Code (1)")?.lowerBound
            expect(safariAt != nil && codeAt != nil && safariAt! < codeAt!,
                   "the frontmost app is listed first, so the answer to \"what am I looking at\" is at "
                   + "the top: \(block.text)")
            expect(block.text.contains("not the screenshot") && block.text.contains("not instructions"),
                   "and the framing says what this is not — a window list is not the picture, and a "
                   + "title is not an instruction")
            // The same screen must produce the same listing: an order that shifts between two reads of
            // an unchanged desktop reads as two different answers.
            let again = OpenWindows.block(app: nil, frontmost: "Safari", in: candidates)
            expectEqual(again?.text, block.text, "the listing is deterministic")
        }

        test("a listing is cut at whole app groups, and says how many windows it left out") {
            // Many windows, long titles: the budget has to bite, and the failure it prevents is
            // "you have no terminal open" about a list that was simply too long to include.
            let many = (1...60).map {
                WindowAct.Candidate(pid: 1, appName: "Terminal",
                                    title: String(repeating: "session \($0) ", count: 6),
                                    frame: CGRect(x: 0, y: CGFloat($0), width: 800, height: 600))
            }
            let others = [candidate("Safari", "Inbox"), candidate("Code", "config.yml")]
            guard let block = OpenWindows.block(app: nil, frontmost: "Safari", in: many + others)
            else {
                expect(false, "62 open windows must produce something")
                return
            }
            expect(block.bytes <= OpenWindows.maxBlockBytes,
                   "the framing plus the groups must fit the budget it names (\(block.bytes) bytes)")
            expect(block.leftOut > 0, "at 62 windows, some genuinely did not fit")
            expect(block.text.contains("not listed"),
                   "and the listing says so rather than looking complete")
            expect(!block.text.contains("Code (0)"),
                   "an app is either listed with its windows or not listed at all")
            for app in ["Safari", "Code", "Terminal"] where block.text.contains("\(app) (") {
                let count = block.text.split(separator: "\n").filter {
                    $0.hasPrefix("  ") && $0.contains("\"")
                }.count
                expect(count > 0, "every app heading in the block has windows under it (\(app))")
            }
        }

        test("nothing open is no listing at all, and one app can be asked for alone") {
            expect(OpenWindows.block(app: nil, frontmost: nil, in: []) == nil,
                   "an empty screen produces no block, so no tokens are spent on nothing")
            let mixed = [candidate("Safari", "Inbox"), candidate("Code", "config.yml")]
            let onlySafari = OpenWindows.block(app: "Safari", frontmost: "Code", in: mixed)
            expectEqual(onlySafari?.listed, 1, "the filter is by app, and it is the same half-name "
                + "match the window verbs use")
            expect(onlySafari?.text.contains("Code") == false,
                   "and another app's windows are not leaked into a listing he asked for one app: "
                   + (onlySafari?.text ?? ""))
        }

        test("opening a file in an app names the file, the folder and the app") {
            expectEqual(DoRequest.parse("open_file_with:Code|~/notes.md"),
                        .openFileWith(app: "Code", path: "~/notes.md"),
                        "the file route is `App|path`")
            expectEqual(DoRequest.parse("open_with:Code|~/notes.md"),
                        .openFileWith(app: "Code", path: "~/notes.md"), "two spellings, one verb")
            expect(DoRequest.parse("open_file_with:Code") == nil,
                   "a file with no app is a launch, and an app with no file is a reveal — both exist, "
                   + "so neither is smuggled in here")
            expect(DoRequest.parse("open_file_with:|~/notes.md") == nil,
                   "an empty app names nothing to open with")
            let question = ToolLayer.question(for: .openFileWith(app: "Code", path: "~/notes.md"))
            expect(question.contains("Code") && question.contains("notes.md"),
                   "the card has to name what will be opened and in what — got: " + question)
            expect(DoRequest.openFileWith(app: "Code", path: "~/notes.md").invalidatesTheScreen,
                   "opening a file puts a window where a plan's pixels were measured, so a plan "
                   + "behind it is held like any launch")
            expect(!DoRequest.openFileWith(app: "Code", path: "~/notes.md").isContextRead,
                   "it is an act, not a read: a window appears, so it takes a card")
        }

        test("where a window sits never decides which one is chosen") {
            // `CandidateRanker`'s rule, restated for windows: geometry separates candidates the words
            // left level, it does not qualify one. A resolve that peeked at frames would answer
            // "the one nearest the cursor", which is a guess dressed as a measurement.
            let left = [candidate("Mail", "Inbox", x: 0), candidate("Mail", "Inbox", x: 900)]
            let right = [candidate("Mail", "Inbox", x: 900), candidate("Mail", "Inbox", x: 0)]
            // Summarised rather than compared by `String(describing:)`: the decision and the names are
            // the property, and a mirror of a struct is not.
            func summary(_ resolution: WindowAct.Resolution) -> String {
                switch resolution {
                case .one(let found): return "one \(found.appName)/\(found.title)"
                case .ambiguous(let many):
                    return "ambiguous " + many.map { "\($0.appName)/\($0.title)" }.sorted()
                        .joined(separator: ",")
                case .none: return "none"
                case .appNotRunning(let name): return "not running \(name)"
                case .unreachable(let found): return "unreachable \(found.appName)/\(found.title)"
                case .notAWindow(let found): return "not a window \(found.appName)/\(found.title)"
                }
            }
            let firstAnswer = WindowAct.resolve(verb: .close, app: "Mail", title: "Inbox", in: left)
            let secondAnswer = WindowAct.resolve(verb: .close, app: "Mail", title: "Inbox", in: right)
            expectEqual(summary(firstAnswer), summary(secondAnswer),
                        "the same two windows in the other order answer the same way")
            if case .ambiguous(let many) = firstAnswer {
                expectEqual(many.count, 2, "and the answer is a refusal either way")
            } else {
                expect(false, "two equal words at two places must not resolve to one")
            }
        }

        test("a window only the window server knows about is named, never offered a card") {
            // Measured on his Mac 2026-11-03: Chrome was running with the tab "GVPCE" published by the
            // window server and by *nothing* in Accessibility, and the old read answered "two windows
            // open" about eight apps. The new one lists it — and a card whose Allow resolves to no
            // element is a question that cannot be honoured, so the verb refuses instead.
            let off = WindowAct.Candidate(pid: 30147, appName: "Google Chrome", title: "GVPCE",
                                          frame: CGRect(x: 0, y: 122, width: 1710, height: 985),
                                          isReachable: false)
            let resolution = WindowAct.resolve(verb: .close, app: "Chrome", title: "GVPCE",
                                               in: [off])
            expectEqual(resolution, .unreachable(off),
                        "the words matched, so the answer is that it is out of reach, not that it is "
                            + "missing")
            let sentence = WindowAct.refusal(verb: .close, app: "Chrome", title: "GVPCE",
                                             resolution: resolution)
            expect(sentence.contains("GVPCE"), "it names the window he asked for: \(sentence)")
            expect(sentence.contains("reach"),
                   "and says Chunks cannot act on it, rather than claiming to know where it is: "
                        + sentence)
            expect(!sentence.lowercased().contains("close"),
                   "a refusal must not read as a question he could answer yes to: \(sentence)")
        }

        test("when both sources list the same window, the one Chunks can act on wins") {
            let frame = CGRect(x: 0, y: 122, width: 1710, height: 985)
            let off = WindowAct.Candidate(pid: 30147, appName: "Google Chrome", title: "GVPCE",
                                          frame: frame, isReachable: false)
            let on = WindowAct.Candidate(pid: 30147, appName: "Google Chrome", title: "GVPCE",
                                         frame: frame, isReachable: true)
            let resolution = WindowAct.resolve(verb: .close, app: "Chrome", title: "GVPCE",
                                               in: [off, on])
            expectEqual(resolution, .one(on),
                        "the same window twice is not an ambiguity, and the reachable copy is the act")
        }

        test("an app with only out-of-reach windows still quits, because quitting needs no window") {
            let off = WindowAct.Candidate(pid: 30147, appName: "Google Chrome", title: "GVPCE",
                                          frame: CGRect(x: 0, y: 122, width: 1710, height: 985),
                                          isReachable: false)
            let resolution = WindowAct.resolve(verb: .quit, app: "Chrome", title: nil, in: [off])
            expectEqual(resolution, .one(off),
                        "terminate() talks to the process, so a window Chunks cannot reach is no "
                            + "obstacle to quitting its app")
            expectEqual(WindowAct.question(verb: .quit, candidate: off),
                        "Quit Google Chrome? Anything unsaved in it is gone.",
                        "and the card is the same always-asked question it has always been")
        }

        test("a listing says which windows are open but out of reach") {
            let off = WindowAct.Candidate(pid: 30147, appName: "Google Chrome", title: "GVPCE",
                                          frame: CGRect(x: 0, y: 122, width: 1710, height: 985),
                                          isReachable: false)
            let lines = OpenWindows.lines(for: "Google Chrome", windows: [off])
            expect(lines.contains("out of Chunks' reach"),
                   "the model has to know promising to close it would be a lie: \(lines)")
            expect(!lines.contains("another Space"),
                   "and the listing must not claim a position it cannot verify: \(lines)")
        }

        test("the desktop is listed as a window and refused as an act") {
            // Found by the geometry probe on its first run, which volunteered to place Finder's desktop
            // in the left half. `--probe-windows Finder` had already been printing *Minimise "desktop"
            // in Finder?* for a day. Writing a frame to the desktop disturbs his icon layout and tidies
            // nothing, so it is refused with the reason rather than filtered into silence.
            let desk = WindowAct.Candidate(pid: 678, appName: "Finder", title: "desktop",
                                          frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
                                          isDesktop: true)
            for verb in [WindowAct.Verb.focus, .minimize, .close] {
                let resolution = WindowAct.resolve(verb: verb, app: "Finder", title: nil,
                                                   in: [desk])
                expectEqual(resolution, .notAWindow(desk),
                            "\(verb.rawValue) on the desktop must be refused, not offered")
                expect(WindowAct.refusal(verb: verb, app: "Finder", title: nil,
                                         resolution: resolution).contains("desktop"),
                       "and the sentence has to say what it actually found")
            }
            // Quitting Finder is a different question — the act is on the process, and the desktop was
            // never the thing being named.
            expectEqual(WindowAct.resolve(verb: .quit, app: "Finder", title: nil, in: [desk]),
                        .one(desk),
                        "quit names an app, not a window, so a desktop candidate does not block it")
        }

        test("a real window beside the desktop is chosen, not refused") {
            let desk = WindowAct.Candidate(pid: 678, appName: "Finder", title: "desktop",
                                          frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
                                          isDesktop: true)
            let window = WindowAct.Candidate(pid: 678, appName: "Finder", title: "Downloads",
                                             frame: CGRect(x: 42, y: 79, width: 913, height: 522))
            let resolution = WindowAct.resolve(verb: .close, app: "Finder", title: nil,
                                               in: [desk, window])
            expectEqual(resolution, .one(window),
                        "the desktop is not a second window to be ambiguous about — it is not a window")
        }

        test("a real browser tab's title is addressable, not refused at parse") {
            // Measured on his Mac 2026-11-03. The first title cap was 120 characters and a Chrome tab
            // arrived at 190, so "close that tab" answered *no such window* about a window in front of
            // him. A title's length is the app's choice, not the model's invention — the gate check
            // caught this by failing on his real browser, not by a fixture I would have written.
            let chromeTitle = "Project configuration – Google Auth Platform – Docu-Engine "
                + "– Google Cloud console – you're sharing this tab with Gemini for the duration of "
                + "this conversation - High memory usage - 1.0 GB - Google Chrome"
            expect(chromeTitle.count > 120,
                   "the fixture has to be past the old cap or this case proves nothing: "
                        + "\(chromeTitle.count) chars")
            expect(chromeTitle.count <= DoRequest.maxWindowTitleCharacters,
                   "and it has to be inside the new one")
            expectEqual(DoRequest.parse("close_window:Google Chrome|\(chromeTitle)"),
                        .closeWindow(app: "Google Chrome", title: chromeTitle),
                        "a tab he can see must be a tab he can close")
            expect(DoRequest.windowPlacement(in: "Google Chrome|\(chromeTitle)|left") != nil,
                   "and the same window must be movable — the two verbs share the cap for a reason")
            // The cap is still a cap: an unbounded argument is how a model parks a paragraph in a tag.
            expect(DoRequest.windowTarget(in: "Safari|\(String(repeating: "x", count: 300))") == nil,
                   "a 300-character blob is not a title either")
        }
    }
}
