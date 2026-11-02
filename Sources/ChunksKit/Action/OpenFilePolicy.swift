import Foundation

/// The decision behind `[DO:open_file_with:Code|notes.md]`, owned where it can be tested.
///
/// This used to live inside `CompanionManager`, which is the one place a unit test cannot reach and a
/// probe cannot quote without performing the act. That matters more here than it looks: the answer this
/// gives is "no, that file holds credentials" and "no, that is outside the folders I may open", and a
/// refusal nobody can read at a terminal is a refusal that will silently rot the first time someone
/// edits the wording. So the shell supplies two facts — what the disk says about the path, and whether
/// the app is installed — and the decision and its sentences live here.
public enum OpenFilePolicy {

    /// What the disk said about the path the model wrote, before any decision was made.
    public enum Resolved: Equatable, Sendable {
        case path(String)          // one absolute path, exists, already inside an allowed root
        case ambiguous([String])   // two or more things share that name
        case nothing               // no such file, or no name matched
        case secret                // a credential store, a key, a keychain
        case outside               // above every allowed root, or under none of them
        case notAPath              // empty, a nested scheme, or something with a tab in it
    }

    public enum Outcome: Equatable, Sendable {
        /// Open this file, with that app. The card is built from this.
        case opens(app: String, path: String)
        /// Two things share the name, so he has to choose. Never a coin toss.
        case ambiguous(name: String, paths: [String])
        /// Nothing there. Distinct from a refusal: one is his mistake, the other is a boundary.
        case notFound(String)
        case refused(Resolved)
        /// The app is not installed. Said plainly, because "Code did not open notes.md" about an app
        /// that is not on the machine sends him to check the file.
        case appNotInstalled(String)

        public var canProceed: Bool {
            if case .opens = self { return true }
            return false
        }
    }

    /// Decide. `resolved` is the disk's answer and `appExists` is the application folder's, both
    /// injected so the whole rule set — including the ordering — is unit-testable.
    public static func decide(app: String, written: String,
                              resolved: Resolved, appExists: Bool) -> Outcome {
        guard appExists else { return .appNotInstalled(app) }
        switch resolved {
        case .path(let absolute):
            return .opens(app: app, path: absolute)
        case .ambiguous(let paths):
            return .ambiguous(name: lastComponent(written), paths: paths)
        case .nothing:
            return .notFound(lastComponent(written))
        case .secret, .outside, .notAPath:
            return .refused(resolved)
        }
    }

    /// Why the app was refused, in his words.
    ///
    /// The order of the checks above is part of the contract: a boundary (secret, outside) is reported
    /// as a boundary, and a missing file is reported as missing, because the first is something he can
    /// overrule by naming a different file and the second is something he can fix by naming the right
    /// one. Collapsing them into "could not open" would make a security rule look like a bug.
    public static func refusal(for outcome: Outcome) -> String {
        switch outcome {
        case .opens:
            return ""
        case .ambiguous(let name, let paths):
            let placeNames = paths.prefix(3).map { path in
                "\(lastComponent(path)) in \((path as NSString).deletingLastPathComponent)"
            }
            return "More than one thing is called \(name): "
                + placeNames.joined(separator: "; ") + ". Say which one."
        case .notFound(let name):
            return "There is no file called \(name) in the folders Chunks is allowed to open."
        case .appNotInstalled(let app):
            return "\(app) is not installed, so there is nothing to open the file in."
        case .refused(let reason):
            switch reason {
            case .secret:
                return "That file holds credentials, so Chunks will not put it on screen."
            case .outside:
                return "That path is outside the folders Chunks is allowed to open."
            case .notAPath:
                return "That is not a path Chunks can open."
            case .path, .ambiguous, .nothing:
                // Unreachable: `decide` turns those three into their own cases, never into `.refused`.
                // A sentence here would be a second answer to a question the cases above already own,
                // so an empty string is the honest value — and the caller only reads this when the
                // outcome cannot proceed.
                return ""
            }
        }
    }

    static func lastComponent(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? trimmed : name
    }
}
