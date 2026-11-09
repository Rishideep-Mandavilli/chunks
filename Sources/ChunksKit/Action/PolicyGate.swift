import Foundation

/// What is known about the control an `ActionRequest` would land on, once it has been
/// hit-tested. Everything is optional because the hit test can fail, and because a control
/// found through Accessibility often has no title at all.
public struct ActionTargetInfo: Equatable, Sendable {
    public var bundleID: String?
    public var appName: String?
    public var role: String?
    /// The element's own title or description, when it has one — shown to the user so the
    /// card can say what will actually be pressed rather than what the model guessed.
    public var elementLabel: String?
    /// The untruncated name, for the consequence check: a commitment word past the display budget
    /// is still a commitment (AUDIT.md A-08). Nil falls back to the bounded label.
    public var fullLabel: String?

    public init(bundleID: String? = nil, appName: String? = nil,
                role: String? = nil, elementLabel: String? = nil, fullLabel: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.role = role
        self.elementLabel = elementLabel
        self.fullLabel = fullLabel
    }
}

/// Decides whether a press may happen, must be confirmed, or must never happen.
///
/// This is the structural half of the "permissioned act" promise: the model proposes, and a
/// rule it cannot speak its way past decides. Keeping the rules in pure logic means the
/// guarantee is testable rather than a matter of prompt wording.
public enum PolicyGate {

    public enum Decision: Equatable, Sendable {
        /// Ask the user once, this turn.
        case needsConsent
        /// The user has already allowed this app on this machine.
        case allowedWithoutAsking
        /// Refuse, and tell the user why. Never shown as a yes/no question.
        case forbidden(reason: String)
    }

    /// Roles that must never be pressed, whatever the user has allowed.
    ///
    /// A secure text field is the one control where an automated press can leak a password
    /// or complete a payment, and no per-app allowance should be able to reach it.
    public static let neverAutomatedRoles: Set<String> = ["AXSecureTextField"]

    /// Apps whose controls Chunks will not touch at all.
    ///
    /// Keychain, password autofill and Apple-ID surfaces, where "press this button" is
    /// indistinguishable from "grant this access".
    public static let neverAutomatedBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.apple.Safari.passwordmanager",
    ]

    /// Bundle IDs that look sensitive by name alone, for the case where the app is running
    /// without a bundle identifier we can match.
    public static let neverAutomatedAppNameFragments: [String] = [
        "keychain", "passwords", "1password", "bitwarden", "lastpass",
    ]

    /// Words that mean a press cannot be taken back, or that what happens next leaves the machine.
    ///
    /// Measured 2026-10-18: a spoken plan ended in `<CONTINUE>press send in the chat with
    /// Dad</CONTINUE>`, the continuation round ran that step on its own, and the message went out
    /// while he was still reading the answer. `askBeforeActing` off is a standing instruction about
    /// *routine* acts — "don't interrupt me to press a tab" — and was never an instruction to send,
    /// pay or delete on the model's say-so. A rule that only holds until the model forgets it is not
    /// a rule, so this is keyed on the name the **app** publishes for the control, which the model
    /// cannot rewrite: WhatsApp calls it `Send`, and that is enough.
    ///
    /// Deliberately narrow. Every word here is a commitment, an outbound message, a payment, or
    /// permanent data loss; "cancel", "back" and "more" are not, because asking about those is noise
    /// that trains the user to tap Allow without reading.
    public static let alwaysAskControlWords: Set<String> = [
        "send", "submit", "post", "publish", "reply", "forward", "share",
        "pay", "buy", "purchase", "order", "transfer", "withdraw", "tip", "donate",
        "subscribe", "unsubscribe", "delete", "remove", "erase", "uninstall",
        "book", "reserve", "confirm", "approve", "accept", "revoke", "apply",
    ]

    /// Multi-word controls the token test above cannot see.
    public static let alwaysAskControlPhrases: [String] = [
        "check out", "checkout", "empty trash", "place order", "send to",
    ]

    /// Whether this control's own name commits the user to something.
    ///
    /// Matched on whole tokens, not substrings: a field called "Sender" is not a Send button, and a
    /// false positive here would stop working flows that the user asked to run silently.
    public static func isConsequential(label: String?) -> Bool {
        guard let label else { return false }
        let text = label.lowercased()
        if alwaysAskControlPhrases.contains(where: { text.contains($0) }) { return true }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.contains { alwaysAskControlWords.contains($0) }
    }

    /// The order is the whole design: a forbidden role is refused even when the user has turned
    /// asking off *and* even in an app they chose to always allow; missing metadata fails toward
    /// *asking*, never toward acting.
    ///
    /// `askBeforePressing` is the user's standing instruction about the confirm card, not a
    /// policy relaxation. It moves `.needsConsent` to `.allowedWithoutAsking` and nothing else:
    /// the forbidden rules run first and are unaffected, which is why turning the card off does
    /// not put a secure field or a password manager one model hallucination away from a press.
    public static func decide(target: ActionTargetInfo,
                              alwaysAllowedBundleIDs: Set<String> = [],
                              askBeforePressing: Bool = true,
                              inferredAim: Bool = false) -> Decision {
        if let role = target.role, neverAutomatedRoles.contains(role) {
            return .forbidden(reason: "That is a secure field, so Chunks will not touch it.")
        }

        if let bundleID = target.bundleID, neverAutomatedBundleIDs.contains(bundleID) {
            return .forbidden(reason: "Chunks never acts inside \(displayName(of: target)).")
        }

        if let name = target.appName?.lowercased(),
           neverAutomatedAppNameFragments.contains(where: { name.contains($0) }) {
            return .forbidden(reason: "Chunks never acts inside \(displayName(of: target)).")
        }

        // Before the two shortcuts below, on purpose: a permanent act is asked about even in an app
        // the user permanently allowed, and even on a machine where the card is switched off. The
        // allowance was about opening things and moving around, never about sending.
        if isConsequential(label: target.fullLabel ?? target.elementLabel) {
            return .needsConsent
        }

        // An aim resolved by ranking — where the app published no name and the words came from inside
        // the control — is a guess about a picture, and a guess is never routine. This sits above the
        // two shortcuts below on purpose, for the same reason the consequential-act rule does:
        // "don't ask" is a standing instruction about the acts he recognises when he sees one, and a
        // press aimed at something the application never named is not that. Asking off is the default
        // on his machine, so without this rule a card that would have shown him "the area that says
        // Mute (m)" instead presses an unnamed group with no question anywhere.
        if inferredAim { return .needsConsent }

        if let bundleID = target.bundleID, alwaysAllowedBundleIDs.contains(bundleID) {
            return .allowedWithoutAsking
        }

        if !askBeforePressing { return .allowedWithoutAsking }

        return .needsConsent
    }

    public static func displayName(of target: ActionTargetInfo) -> String {
        let name = target.appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "that app" : name
    }
}
