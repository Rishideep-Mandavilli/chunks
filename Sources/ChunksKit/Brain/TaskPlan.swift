import Foundation

/// The model's own step checklist for a multi-part request, kept outside the message history.
///
/// A weak model loses the thread over several dependent steps: each continuation re-reads a fresh
/// screen and a short replay, and the original intent decays. Plan-and-execute keeps an externalized
/// checklist re-injected every round so the model always sees the whole task and what is left, rather
/// than re-deriving it from pixels (StateAct's "externalized plan"; the single-agent plan-and-execute
/// pattern). This is the pure half: parse the `<PLAN>` body into steps and render the checklist back
/// with the shell's record of what already happened. The model stays the author; the shell only keeps
/// it in front of it.
public enum TaskPlan {

    /// Few enough to stay a plan and not a wall; a request that needs more is several tasks.
    public static let maxSteps = 8

    /// Parse a `<PLAN>` body into ordered steps. Lines first, then `;` within a single line; leading
    /// bullets, checkboxes and numbering are stripped so the model's formatting does not become part
    /// of the step. Empty bodies yield nothing.
    public static func parse(_ body: String) -> [String] {
        var raw = body.components(separatedBy: .newlines)
        if raw.count == 1 { raw = body.components(separatedBy: ";") }
        var steps: [String] = []
        for line in raw {
            var clean = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["- ", "* ", "[ ] ", "[x] ", "[X] "] where clean.hasPrefix(prefix) {
                clean = String(clean.dropFirst(prefix.count))
            }
            // A leading "1." / "2)" ordinal is formatting, not the step.
            while let first = clean.first, first.isNumber {
                clean = String(clean.dropFirst())
            }
            clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: ".) "))
            if !clean.isEmpty { steps.append(clean) }
            if steps.count == maxSteps { break }
        }
        return steps
    }

    /// The checklist re-injected on a continuation: the whole plan, then the shell's record of what
    /// already happened, then the instruction to do the next undone step one per reply.
    public static func block(steps: [String], done: [String]) -> String? {
        guard !steps.isEmpty else { return nil }
        var text = "the plan you made for his request (kept here so it survives across looks):\n"
        text += steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if !done.isEmpty {
            text += "\nwhat has already happened this task:\n"
            text += done.map { "- \($0)" }.joined(separator: "\n")
        }
        text += "\ncontinue from the first plan step not yet done. do one step per reply and carry "
            + "the rest in <CONTINUE>; do not re-do a step that already happened."
        return text
    }
}