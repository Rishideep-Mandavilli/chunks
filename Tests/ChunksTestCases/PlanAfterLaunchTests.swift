import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for what happens to a plan when the reply also asks for a window.
///
/// The bug this suite pins is the one that produced the wrong keystrokes rather than an error: a
/// launch in front of a pixel aim used to have its *launch* dropped while the pixel step still ran
/// against the screenshot taken before anything opened. Both halves are asserted here — that
/// `leadingTool` still refuses the combination (the refusal is correct evidence), and that the
/// refusal now leads to a hold rather than to a blind act.
public enum PlanAfterLaunchTests {

    public static func register() {
        TestRunner.currentSuite = "Plan after a launch"

        test("a pixel step behind a launch is held for a fresh capture, not run against the old one") {
            // Measured 2026-11-01 with a local model asked to `open chrome and type 'how to use sql'
            // in the search box`: the app never opened and the type act resolved whatever field
            // owned those pixels on the screen that was already there.
            let reply = [ActionRequest.parseType("368,497:search box|how to use sql")!]
            let tools = [DoRequest.openApp(name: "Chrome")]

            expect(ActionRequest.leadingTool(for: reply, tools: tools) == nil,
                   "the evidence rule still holds: a pixel cannot describe a screen the launch replaces")

            let plan = PlanAfterLaunch.decide(steps: reply, tools: tools)
            expect(plan != nil,
                   "and the refusal now produces a hold instead of running the step blind")
            expectEqual(plan?.tool, DoRequest.openApp(name: "Chrome"),
                        "the launch is the thing that runs now")
            expectEqual(plan?.heldSteps.count, 1, "the type step waits for the next look")
            expect(plan?.instruction.contains("how to use sql") ?? false,
                   "the next round has to be told what was waiting: \(plan?.instruction ?? "")")
            expect(plan?.instruction.contains("search box") ?? false,
                   "and where it was meant to go")
        }

        test("a named plan behind a launch is still led, not held") {
            // The other route must stay the fast one: names are re-resolved against the tree as it is
            // *after* the window opens, so no extra look at the screen is needed and no round is spent.
            let named = [ActionRequest.parseAct("app=Chrome name=Search")!,
                         ActionRequest.parseType("app=Chrome name=\"address bar\"|how to use sql")!]
            let tools = [DoRequest.openApp(name: "Chrome")]
            expectEqual(ActionRequest.leadingTool(for: named, tools: tools), tools.first,
                        "a launch in front of names leads the plan as it always did")
            expect(PlanAfterLaunch.decide(steps: named, tools: tools) == nil,
                   "and nothing is held, so the reply costs one turn instead of two")
        }

        test("a mixed plan holds every step, because the launch invalidates the whole picture") {
            // The reply is a *set* of acts and a set of tools — the grammar cannot say "this press
            // happens before the open" — so the whole plan waits and the next look re-aims it in order.
            let mixed = [ActionRequest.parseAct("app=Chrome name=Search")!,
                         ActionRequest(target: PointTarget(x: 100, y: 200, label: "first result"))]
            let plan = PlanAfterLaunch.decide(steps: mixed, tools: [DoRequest.openApp(name: "Chrome")])
            expectEqual(plan?.heldSteps.count, 2, "the named step waits with the pixel one")
            expect(plan?.instruction.hasPrefix("press 'Search' in Chrome") ?? false,
                   "in the order the model wrote them: \(plan?.instruction ?? "")")
            expect(plan?.instruction.contains("then press 'first result'") ?? false,
                   "both halves of the plan are in the sentence: \(plan?.instruction ?? "")")
        }

        test("a tool that changes no window does not hold the plan") {
            // `set_volume` was the negative case that mattered: making every tool a launch would
            // double the latency of `turn the volume down and type this in`, for no safety at all.
            let steps = [ActionRequest.parseType("368,497:box|hi")!]
            expect(PlanAfterLaunch.decide(steps: steps, tools: [DoRequest.setVolume(percent: 40)]) == nil,
                   "a volume change covers nothing, so the pixels are still valid")
            expect(PlanAfterLaunch.decide(steps: steps, tools: [DoRequest.runCommand(argv: ["caffeinate", "-di"])]) == nil,
                   "a command's effect cannot be read off argv, and it already carries its own card")
            expect(DoRequest.reveal(path: "/Users/x/Rishi_Projects/Memora").invalidatesTheScreen,
                   "a reveal does put a folder on the screen, so it is a launch for this purpose")
        }

        test("two tools and one card is still a refusal, not two holds") {
            let steps = [ActionRequest(target: PointTarget(x: 10, y: 10, label: "box"))]
            expect(PlanAfterLaunch.decide(steps: steps,
                                          tools: [.openApp(name: "Chrome"), .openApp(name: "Notes")]) == nil,
                   "nothing honest can be said about which of two the user allowed")
            expect(PlanAfterLaunch.decide(steps: [], tools: [.openApp(name: "Chrome")]) == nil,
                   "no steps means the ordinary single-tool path")
        }

        test("a long payload is named by its opening and its count, never clipped mid-word") {
            let code = String(repeating: "int main(void) { return 0; }\n", count: 40)
            let step = ActionRequest.parseType("100,200:editor|\(code)")
            let plan = PlanAfterLaunch.decide(steps: [step!], tools: [.openApp(name: "Xcode")])
            let instruction = plan?.instruction ?? ""
            expect(instruction.contains("characters)"),
                   "the next round needs the size of the payload, not all of it: \(instruction)")
            expect(instruction.count <= PlanAfterLaunch.maxInstructionCharacters,
                   "a continuation over the cap is a sentence the model reads as the whole ask "
                   + "(\(instruction.count) characters)")
            expect(!instruction.contains("int main(void) { return 0; }\nint main"),
                   "and it must not be the code pasted twice")
        }

        test("a held plan too long for one sentence counts what it left out") {
            // The rule is whole steps only: an instruction that ran past the cap would be a
            // continuation the model reads as the entire ask, and half a step's description tells it
            // to do something the user never asked for. So the overflow is named, never clipped.
            let wide = String(repeating: "column", count: 8)
            let steps = (1...7).map {
                ActionRequest(target: PointTarget(x: Double($0) * 10, y: 10, label: "\(wide) \($0)"))
            }
            let plan = PlanAfterLaunch.decide(steps: steps, tools: [.openApp(name: "Finder")])
            let instruction = plan?.instruction ?? ""
            expect(instruction.count <= PlanAfterLaunch.maxInstructionCharacters,
                   "the cap is a promise, not an aim: \(instruction.count) characters")
            expect(instruction.contains("more"),
                   "and what fell out of the sentence is counted in it rather than silently gone: "
                   + instruction)
            expect(instruction.hasSuffix("more"),
                   "the count is the last thing in the line: \(instruction)")
            expect(!instruction.contains(", then \""),
                   "no step may be cut mid-phrase: \(instruction)")
        }

        test("a plan that does fit is spelled out in full, with no count of leftovers") {
            let steps = (1...7).map {
                ActionRequest(target: PointTarget(x: Double($0) * 10, y: 10, label: "row \($0)"))
            }
            let plan = PlanAfterLaunch.decide(steps: steps, tools: [.openApp(name: "Finder")])
            let instruction = plan?.instruction ?? ""
            expect(instruction.contains("row 7"),
                   "seven short aims fit in one sentence, and a '+N more' that is not true is its own "
                   + "kind of truncation: \(instruction)")
            expect(!instruction.contains("more"),
                   "nothing was left out here: \(instruction)")
        }
    }
}
