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

    public init(bundleID: String? = nil, appName: String? = nil,
                role: String? = nil, elementLabel: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.role = role
        self.elementLabel = elementLabel
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
                              askBeforePressing: Bool = true) -> Decision {
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
