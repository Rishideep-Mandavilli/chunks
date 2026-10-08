import Foundation

/// Anything the user can be asked to approve: a press on screen, or a tool run outside it.
///
/// One type because one question. Two gates — one for presses, one for tools — would allow the
/// card to ask both at once, and "which button answers which question" is precisely the
/// ambiguity a permission prompt must not have.
public enum PendingAct: Equatable, Sendable {
    case press(ActionRequest)
    case tool(DoRequest)
}

/// One outstanding yes/no about a single act.
///
/// Deliberately dumb and deliberately singular: there is exactly one assistant and one act
/// per turn, so a queue of pending consents would be a bug waiting to be confirmed out of
/// order. The state machine lives in pure logic so "deny clears it", "resolving twice does
/// nothing twice" and "a new request cannot leave the old one live" are guarantees rather
/// than habits.
public struct ConsentGate {

    public enum Outcome: Equatable, Sendable {
        /// Do this one, and ask again next time.
        case allowedOnce
        /// Do this one and stop asking about this app.
        case alwaysAllowed
        case denied
    }

    public private(set) var pending: PendingAct?
    public private(set) var lastOutcome: Outcome?

    public init() {}

    public var isPending: Bool { pending != nil }

    /// Offer a request for confirmation. Returns the request it displaced, which the caller
    /// must treat as denied — silently dropping it would leave the user believing an act
    /// they never approved is still waiting.
    @discardableResult
    public mutating func stage(_ act: PendingAct) -> PendingAct? {
        let displaced = pending
        pending = act
        lastOutcome = displaced == nil ? nil : .denied
        return displaced
    }

    /// Answer the outstanding request. Returns what to run, or `nil` for a denial — and
    /// `nil` for any answer given while nothing is pending, which is what makes a double tap
    /// on "Allow" inert.
    public mutating func resolve(_ outcome: Outcome) -> PendingAct? {
        guard let act = pending else { return nil }
        pending = nil
        lastOutcome = outcome
        return outcome == .denied ? nil : act
    }

    /// Withdraw the outstanding request without deciding it — the card was dismissed, a new
    /// turn started, or the user clicked away.
    public mutating func cancel() -> PendingAct? {
        guard let act = pending else { return nil }
        pending = nil
        lastOutcome = .denied
        return act
    }
}
