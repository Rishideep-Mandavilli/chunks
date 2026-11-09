import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// The externalized plan: the model's checklist for a multi-part request, kept outside the message
/// history and re-injected each continuation. The cases that matter are that the plan survives parsing
/// in the shapes a weak model writes, that it is never shown to the user as markup, and that the block
/// tells the model to pick up where it left off rather than start over.
public enum TaskPlanTests {

    public static func register() {
        TestRunner.currentSuite = "TaskPlan"

        test("steps parse from lines, semicolons and numbered bullets") {
            expectEqual(TaskPlan.parse("open WhatsApp\nfind Dad\ntype good night"),
                        ["open WhatsApp", "find Dad", "type good night"],
                        "one line per step is the taught shape")
            expectEqual(TaskPlan.parse("open WhatsApp; find Dad; type good night"),
                        ["open WhatsApp", "find Dad", "type good night"],
                        "a single line with semicolons is the same plan")
            expectEqual(TaskPlan.parse("1. open WhatsApp\n2) find Dad\n- [ ] type good night"),
                        ["open WhatsApp", "find Dad", "type good night"],
                        "ordinals and checkboxes are formatting, not the step")
        }

        test("an empty plan yields nothing and the step count is capped") {
            expect(TaskPlan.parse("  \n ").isEmpty, "whitespace is not a plan")
            let many = (0..<20).map { "step \($0)" }.joined(separator: "\n")
            expectEqual(TaskPlan.parse(many).count, TaskPlan.maxSteps,
                        "a plan that never ends is a wall, not a checklist")
        }

        test("the block re-states the whole plan and says to continue, not repeat") {
            let block = TaskPlan.block(steps: ["open WhatsApp", "find Dad"], done: ["Opened WhatsApp."])
            guard let block else {
                expect(false, "a non-empty plan must render a block")
                return
            }
            expect(block.contains("open WhatsApp") && block.contains("find Dad"),
                   "the whole task must stay in view, not just the next step")
            expect(block.contains("Opened WhatsApp."), "what already happened anchors the pickup point")
            expect(block.contains("first plan step not yet done"),
                   "the model must continue, not re-do the task from the top")
            expect(TaskPlan.block(steps: [], done: []) == nil, "no plan means no block")
        }

        test("a PLAN tag is consumed into steps and never reaches the card") {
            let streamer = AnswerStreamer()
            streamer.push("<SAY>on it</SAY><PLAN>open WhatsApp\nfind Dad\ntype good night</PLAN>")
            streamer.finish()
            expectEqual(streamer.planSteps, ["open WhatsApp", "find Dad", "type good night"],
                        "the checklist did not survive the stream")
            expect(!streamer.displayable.speech.contains("<PLAN>")
                   && !streamer.displayable.detail.contains("<PLAN>"),
                   "the plan is the app's instruction, not words for him to read")
        }

        test("a re-emitted plan replaces the old one (replanning)") {
            let streamer = AnswerStreamer()
            streamer.push("<PLAN>open WhatsApp\nfind Dad</PLAN>")
            streamer.push("<PLAN>open WhatsApp\nsearch Dad\nsend hi</PLAN>")
            streamer.finish()
            expectEqual(streamer.planSteps, ["open WhatsApp", "search Dad", "send hi"],
                        "a second plan is a correction, not an append")
        }
    }
}