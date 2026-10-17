import Foundation

/// A request to put the contents of one file in front of the model.
///
/// This is the only way Chunks can answer the questions the screen does not show: "what failed in
/// the build log", "why does my shell prompt look wrong", "is this migration safe". The scope is
/// reading — the agent never writes a file and never emits an artifact, so the whole surface here
/// is a proposal to *look* at something, and `Policy` is what decides whether it happens.
///
/// The policy is not decoration. Everything a file contains goes to a cloud model in the same
/// request as the screenshot, so a path that resolves into `~/.ssh` would send a private key to
/// Google. The refusal happens here, in pure code with no file system access, because that is the
/// only version of the rule that can be tested against the paths that matter.
public struct ReadRequest: Equatable, Sendable {

    /// What the app will do with a parsed path.
    public enum Refusal: String, Equatable, Sendable, Error {
        /// Nothing recognisable as a path was there.
        case empty
        /// Too many segments, or a `..` that escapes.
        case outsideAllowedDirectories
        /// A private key, a credential store, a token file — whatever the rest says.
        case secretStore
        /// Not a text file the model could read anyway.
        case binary
        /// Larger than what the model can be given in one turn.
        case tooLarge

        public var description: String {
            switch self {
            case .empty:
                return "Chunks was asked to read a file but no path came through."
            case .outsideAllowedDirectories:
                return "That file is outside the folders Chunks is allowed to read."
            case .secretStore:
                return "That file holds credentials, so Chunks will not read it or send it to a model."
            case .binary:
                return "That is not a text file, so there is nothing for the model to read."
            case .tooLarge:
                return "That file is bigger than Chunks can put in one question."
            }
        }
    }

    /// The expanded, absolute path as the user wrote it.
    public var path: String

    /// The question the user asked of it, carried so the reading round can be answered in his own
    /// words rather than a generic "what's in this file".
    public var question: String

    public init(path: String, question: String = "") {
        self.path = path
        self.question = question
    }

    // MARK: - Policy

    /// Directories a read may resolve into. Deliberately the places a developer actually keeps
    /// work, and nothing else: `/etc`, another user's home, and anything under `/Library` stay out.
    public static let defaultAllowedRoots: [String] = [
        "~/Documents", "~/Downloads", "~/Desktop", "~/Projects", "~/Developer", "~/Code", "~/src",
        "~/repos", "~/.config", "~",
    ]

    /// Path fragments that end the conversation. Matched against the *resolved* path rather than
    /// the typed one, so a symlink out of an allowed folder into `~/.ssh` is still refused, and
    /// matched as a whole directory because a component check would let `~/.config/gcloud` through
    /// — no single component of that path is on any list.
    public static let deniedPathFragments: [String] = [
        "/.ssh/", "/.aws/", "/.gnupg/", "/.config/gcloud/", "/.azure/", "/.docker/",
        "/Keychains/", "/.password-store/",
    ]

    /// File names that are credentials whatever folder they sit in.
    public static let deniedFileNames: Set<String> = [
        "id_rsa", "id_ed25519", "id_ecdsa", "credentials", ".netrc", "passwd", "shadow",
    ]

    /// Extensions that are never text.
    public static let deniedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "pdf", "zip", "gz", "tar", "dmg", "app", "framework",
        "dylib", "so", "a", "o", "class", "jar", "mp4", "mov", "mp3", "wav", "ttf", "otf", "woff",
        "woff2", "ico", "db", "sqlite", "sqlite3", "pack", "pyc", "beam", "beam.smp",
    ]

    /// How much text one turn may carry.
    ///
    /// A full-screen screenshot is ~1,066 image tokens, and the free-tier models that answer fast
    /// are the small ones. A 24 KB file is roughly 6,000 tokens — already the bulk of a turn — and
    /// past this the honest answer is "give me a smaller slice", not a slower and dumber reply.
    public static let maxBytes = 24_000

    /// Resolve a user-typed path against the allowed roots.
    ///
    /// `~` is expanded by hand rather than with `expandingTildeInPath` because the caller in tests
    /// must not depend on whose home directory the harness happens to run in.
    public func resolved(homeDirectory: String, allowedRoots: [String] = ReadRequest.defaultAllowedRoots,
                         symlinksResolved: String? = nil) -> Result<String, Refusal> {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        let absolute: String
        if trimmed.hasPrefix("~") {
            let suffix = trimmed.dropFirst(trimmed.hasPrefix("~/") ? 2 : 1)
            absolute = homeDirectory + (suffix.isEmpty ? "" : "/" + suffix)
        } else if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else {
            // A bare name is a guess about where the user meant, and a wrong guess that resolves
            // into some other folder is worse than a refusal. Home is the one root where it is
            // usually right: `~/.zshrc` typed as `.zshrc`.
            absolute = homeDirectory + "/" + trimmed
        }
        let normalised = ReadRequest.standardise(absolute)

        // `..` is allowed to move *within* a root, but a path that climbed above every root is not.
        let candidate = symlinksResolved ?? normalised
        let roots = allowedRoots.map { ReadRequest.standardise($0.hasPrefix("~")
            ? homeDirectory + $0.dropFirst($0.hasPrefix("~/") ? 2 : 1) : $0) }
        guard roots.contains(where: { candidate == $0 || candidate.hasPrefix($0 + "/") }) else {
            return .failure(.outsideAllowedDirectories)
        }

        let components = candidate
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let wrapped = "/" + candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        if ReadRequest.deniedPathFragments.contains(where: { wrapped.contains($0) }) {
            return .failure(.secretStore)
        }
        let fileName = components.last ?? ""
        if ReadRequest.deniedFileNames.contains(fileName) { return .failure(.secretStore) }
        if fileName.hasPrefix("id_") && fileName != "id" { return .failure(.secretStore) }
        if ReadRequest.deniedExtensions.contains((fileName as NSString).pathExtension.lowercased()) {
            return .failure(.binary)
        }
        return .success(candidate)
    }

    /// `a//b/./c` collapses to `a/b/c`, and a `..` that walks out of every directory stays visible
    /// so the root check below can refuse it.
    static func standardise(_ path: String) -> String {
        var stack: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                if stack.isEmpty { stack.append("..") } else { stack.removeLast() }
            default: stack.append(String(component))
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    // MARK: - Parsing

    /// `[READ:~/Downloads/build.log|why did it fail]`
    ///
    /// Fails open: an unrecognisable body returns nil and the tag reaches the user as text, which
    /// is the same rule every other construct follows — a swallowed tag looks like an ignored
    /// question.
    public static func parse(_ raw: String) -> ReadRequest? {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let parts = body.components(separatedBy: "|")
        let path = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let question = parts.dropFirst().joined(separator: "|")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        // A path-shaped string with a newline in it is a model that stopped inside a tag.
        guard !path.contains("\n"), path.count <= 512 else { return nil }
        return ReadRequest(path: path, question: question)
    }
}
