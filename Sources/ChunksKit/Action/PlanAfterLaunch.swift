import Foundation

/// What a reply does when it asks for a window *and* aims at pixels.
///
/// `ActionRequest.leadingTool` lets a launch lead a plan only when every step is named, because a
/// pixel describes the screenshot the launch is about to invalidate. The rule is right about the
/// evidence and was wrong about the consequence: at the call site a `nil` there does not stop the
/// plan, it stops the *launch* — the acts are still non-empty, so the branch that would have offered
/// the tool is never reached and the pixel steps run against a capture taken before anything opened.
/// Measured 2026-11-01 with a local model's reply (`open chrome, type 'how to use sql' in the search
/// box`): Chrome never launched and the type act resolved whatever field owned those pixels on the
/// *old* screen.
///
/// This type is the other answer, and it is the one the shell now takes: run the launch through the
/// same policy and consent door it would run through alone, hold every step behind it, and hand the
/// held steps to a fresh look at the screen rather than to the stale one. The bound
/// (`CompanionManager.maxPlanRounds`) and the "only when it actually happened" rule live in the
/// shell, because both need the machine's answer; what is decided here is only *which* tool leads,
/// *which* steps wait, and *what the next look is asked to do*.
public struct PlanAfterLaunch: Equatable, Sendable {

    /// The tool to run now.
    public let tool: DoRequest

    /// The steps this turn must not execute, in the order the model wrote them.
    public let heldSteps: [ActionRequest]

    /// What still has to happen, phrased in the model's own words, for the next round to be aimed at
    /// a screen it can see.
    ///
    /// This is the same channel a `<CONTINUE>` uses — `Continue: <instruction>` — which is why it is
    /// prose rather than a tag: it goes back to the model, not to the resolver.
    public let instruction: String

    /// The longest instruction that may be sent as the next round's question.
    ///
    /// A plan is capped at `ActionRequest.maxProgramSteps` and each payload quote at
    /// `maxQuotedCharacters`, so this is headroom rather than a cliff; the cliff it prevents is a
    /// continuation that has to be truncated mid-sentence, because half a step's description tells
    /// the model to do something the user never asked for.
    public static let maxInstructionCharacters = 200

    /// How much of a type payload is quoted back.
    ///
    /// The payload can be 6,000 characters of C. The next round does not need the code — it needs to
    /// know a field is being filled and roughly with what — and a whole file in a continuation line is
    /// a prompt budget spent on a copy of text the model is going to be shown again anyway.
    public static let maxQuotedCharacters = 40

    /// The launch, the held steps, and the sentence that resumes them — or nil when this reply is
    /// already handled by `leadingTool` (every step named) or has nothing to hold.
    ///
    /// One tool only, for the same reason `leadingTool` gives one: a card holds one question and
    /// nothing honest can be said about which of two the user allowed.
    public static func decide(steps: [ActionRequest],
                              tools: [DoRequest]) -> PlanAfterLaunch? {
        guard tools.count == 1, let tool = tools.first, tool.invalidatesTheScreen else { return nil }
        guard !steps.isEmpty else { return nil }
        // Only when a step carries a pixel. A plan whose every step is named already travels
        // `leadingTool`, resolves against the tree as it is *after* the launch, and needs no new look.
        guard steps.contains(where: { $0.pointTarget != nil }) else { return nil }
        let instruction = describe(steps)
        guard !instruction.isEmpty else { return nil }
        return PlanAfterLaunch(tool: tool, heldSteps: steps, instruction: instruction)
    }

    /// The next round's question, built from whole steps only.
    static func describe(_ steps: [ActionRequest]) -> String {
        var kept: [String] = []
        var used = 0
        for step in steps {
            let phrase = phrase(for: step)
            // A step whose own sentence is over the cap cannot be salvaged by clipping it — the clip
            // would name a thing the user did not ask for — so it is left out and counted.
            guard !phrase.isEmpty else { continue }
            let cost = phrase.count + (kept.isEmpty ? 0 : 6)  // ", then "
            guard used + cost <= maxInstructionCharacters else {
                kept.append("+\(steps.count - kept.count) more")
                break
            }
            used += cost
            kept.append(phrase)
        }
        guard !kept.isEmpty else { return "" }
        var tail = ""
        if let last = kept.last, last.hasPrefix("+") {
            kept.removeLast()
            tail = ", \(last)"
        }
        guard !kept.isEmpty else { return "" }
        return kept.joined(separator: ", then ") + tail
    }

    /// One step in the words the model would use to ask for it again.
    ///
    /// Single quotes throughout: this sentence goes inside the round's own double-quoted line, and
    /// `type "how to use sql" into "search box"` inside outer quotes is unreadable in a log.
    static func phrase(for step: ActionRequest) -> String {
        let subject: String
        if let semantic = step.semanticTarget {
            subject = "'\(semantic.name)' in \(semantic.app)"
        } else if let point = step.pointTarget {
            subject = point.appName.map { "'\(point.label)' in \($0)" } ?? "'\(point.label)'"
        } else {
            return ""
        }
        switch step.verb {
        case .press:
            return "press \(subject)"
        case .type(let text):
            return "type \(quote(text)) into \(subject)"
        case .scroll(let direction, let pages):
            return "scroll \(subject) \(direction.phrase)"
                + (pages == 1 ? "" : " \(pages) pages")
        }
    }

    /// The payload as it may appear inside a continuation line: its opening and its size.
    static func quote(_ text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flattened.count > maxQuotedCharacters else { return "'\(flattened)'" }
        let head = String(flattened.prefix(maxQuotedCharacters))
        return "'\(head)…' (\(flattened.count) characters)"
    }
}
