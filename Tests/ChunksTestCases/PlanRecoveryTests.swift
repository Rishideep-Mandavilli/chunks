import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// The two bounded recoveries that let a weak model finish a multi-step task: replan a failed step
/// and verify the end-state before claiming done. The cases that matter are the bounds — a recovery
/// with no plan or no round budget left must be nothing, so a task that cannot be done ends honestly
/// instead of looping — and that the verify look distrusts the agent's own narration.
public enum PlanRecoveryTests {

    public static func register() {
        TestRunner.currentSuite = "PlanRecovery"

        test("a failed step with a plan and budget left gets a replan") {
            let instruction = PlanRecovery.replanInstruction(
                failure: "WhatsApp has no Send control while the box is empty",
                steps: ["open WhatsApp", "type good night", "press Send"],
                round: 1, maxRounds: 4)
            guard let instruction else {
                expect(false, "a failed step inside the budget must be recoverable")
                return
            }
            expect(instruction.contains("no Send control"),
                   "the replan must carry the actual failure, not a generic retry")
            expect(instruction.contains("different approach"),
                   "repeating the failed step unchanged is how a plan burns its rounds")
            expect(instruction.contains("open WhatsApp; type good night; press Send"),
                   "the whole plan must stay in view so the model picks up, not restarts")
        }

        test("no plan or no budget left means no replan — a hard stop is the honest answer") {
            expect(PlanRecovery.replanInstruction(failure: "x", steps: [], round: 0, maxRounds: 4) == nil,
                   "nothing to recover means nothing to say")
            expect(PlanRecovery.replanInstruction(failure: "x", steps: ["a"], round: 4, maxRounds: 4) == nil,
                   "a spent round budget must not start another round")
        }

        test("the finish gate checks the screen, not the agent's own account") {
            let instruction = PlanRecovery.verifyInstruction(steps: ["open Notes", "type hi"])
            guard let instruction else {
                expect(false, "a plan about to end gets one verification look")
                return
            }
            expect(instruction.contains("not against what you said earlier"),
                   "a narration-conditioned judge agrees with itself; the gate must not")
            expect(instruction.contains("open Notes; type hi"),
                   "the gate names the request it is checking")
            expect(PlanRecovery.verifyInstruction(steps: []) == nil,
                   "no plan means nothing to verify")
        }
    }
}