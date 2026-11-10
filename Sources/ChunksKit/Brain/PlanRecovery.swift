import Foundation

/// The two bounded recoveries that let a weak model finish a multi-step task instead of stopping at
/// the first surprise: replan a failed step, and verify the end-state before claiming done.
///
/// Both are *instructions to the one assistant*, not new identities — the scope rule forbids
/// sub-agents, so recovery is a further look at the screen through the same policy gate, never a
/// worker. Both are bounded by the plan's round budget so a task that cannot be done fails honestly
/// instead of looping.
public enum PlanRecovery {

    /// A step failed or was refused by the app: hand the model the failure and the whole plan so it
    /// can choose a different approach from the screen as it is now. Returns nil when there is no
    /// plan to recover or the round budget is spent — a hard stop then is the honest answer.
    ///
    /// Only call this for an app refusal/failure, never for a user's "not now": a denial is a decision
    /// and must not be replanned around. Every act the replan proposes still meets `PolicyGate` and the
    /// re-read-before-pressing rule, so a recovery cannot bypass a safety refusal.
    public static func replanInstruction(failure: String, steps: [String],
                                         round: Int, maxRounds: Int) -> String? {
        guard !steps.isEmpty, round < maxRounds else { return nil }
        let plan = steps.joined(separator: "; ")
        return "a step of the plan failed: \(failure). the whole plan was: \(plan). look at the screen "
            + "as it is now and carry on from the first step not yet done, choosing a different "
            + "approach for the one that failed; do not repeat the failed step unchanged."
    }

    /// The finish gate: before a plan is allowed to end, one narration-blind look that checks the
    /// request against the current state instead of trusting the agent's own account of its work.
    /// Returns nil when there is no plan to verify.
    public static func verifyInstruction(steps: [String]) -> String? {
        guard !steps.isEmpty else { return nil }
        let plan = steps.joined(separator: "; ")
        return "verify against the screen as it is now, not against what you said earlier: was this "
            + "request actually completed? the plan was: \(plan). if every step's effect is really on "
            + "screen, answer with a short confirmation and no further acts. if anything is missing or "
            + "wrong, do that one thing now and carry the rest in <CONTINUE>."
    }
}