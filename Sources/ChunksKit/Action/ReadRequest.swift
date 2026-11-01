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
        /// A format Chunks has no reader for yet — a spreadsheet or a slide deck.
        ///
        /// Its own case because the generic one lied: "that is not a text file" about an `.xlsx` is
        /// technically true and useless, and it was the sentence a user read on the card for a
        /// document he could see was full of words.
        case unsupportedFormat
        /// Larger than what the model can be given in one turn.
        case tooLarge

        public var description: String {
            switch self {
            case .empty:
                return "Chunks was asked to read a file but no path came through."
            case .outsideAllowedDirectories:
                // Names the folders that *are* open, because a refusal with no escape teaches him
                // that the feature is broken rather than that this file is out of scope. Home
                // itself used to be a root, and its absence has to be explainable in one line.
                return "That file is outside the folders Chunks reads — Documents, Downloads, "
                    + "Desktop, Projects, Code, src and repos. Move it into one, or open it yourself."
            case .secretStore:
                return "That file holds credentials, so Chunks will not read it or send it to a model."
            case .binary:
                return "That is not a text file, so there is nothing for the model to read."
            case .unsupportedFormat:
                return "Chunks can read a Word file, a PDF, a picture or plain text — not a "
                    + "spreadsheet or a slide deck yet."
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
    ///
    /// **`~` itself is not in this list, and neither is `~/.config`.** Home as a root made every
    /// unread-subtree question moot in the wrong direction: `~/Library/Mail`, `~/Library/Safari`
    /// and `~/.config/gh/hosts.yml` — a GitHub token in plain YAML — all resolved inside an
    /// "allowed" root, and the deny-list is a list of *known* secrets, which can never be complete.
    /// The rule is invariant 9's, so the roots have to be places work lives rather than "his
    /// account". The cost is honest and stated: naming `~/.zshrc` out loud is now refused, and the
    /// sentence says which folders are open.
    public static let defaultAllowedRoots: [String] = [
        "~/Documents", "~/Downloads", "~/Desktop", "~/Projects", "~/Developer", "~/Code", "~/src",
        "~/repos",
    ]

    /// Path fragments that end the conversation. Matched against the *resolved* path rather than
    /// the typed one, so a symlink out of an allowed folder into `~/.ssh` is still refused, and
    /// matched as a whole directory because a component check would let `~/.config/gcloud` through
    /// — no single component of that path is on any list.
    ///
    /// This list is **credentials only**, and that is a deliberate limit. `~/Library/Mail` is
    /// private too, but it is unreachable because home is no longer a root, and putting it here
    /// would tell him "that file holds credentials" about something that does not — a wrong reason
    /// is worse than a broad one, because he acts on the words.
    public static let deniedPathFragments: [String] = [
        "/.ssh/", "/.aws/", "/.gnupg/", "/.config/gcloud/", "/.config/gh/", "/.azure/",
        "/.docker/", "/.kube/", "/Keychains/", "/.password-store/",
    ]

    /// File names that are credentials whatever folder they sit in.
    public static let deniedFileNames: Set<String> = [
        "id_rsa", "id_ed25519", "id_ecdsa", "credentials", ".netrc", "passwd", "shadow",
        ".git-credentials", ".npmrc", ".pypirc", ".htpasswd",
    ]

    /// Extensions that are a key, a keystore or a vault, wherever they are.
    ///
    /// A project's `certs/server.key` is inside an allowed root and is a private key. The file's
    /// *purpose* is readable and its content is not, so this is checked before any reader runs.
    public static let secretExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "kdbx", "asc", "jks", "keystore", "mobileprovision",
    ]

    /// Extensions that are never readable, as text or as a picture.
    ///
    /// The images are *not* on this list any more, and neither is the PDF above it. Both used to be
    /// refused with "not a text file", which was true and useless: every model Chunks reaches has
    /// eyes, and the question that motivated the feature — "what does this receipt say" — is about a
    /// picture. They are routed by `kind(of:)` instead.
    public static let deniedExtensions: Set<String> = [
        "zip", "gz", "tar", "dmg", "app", "framework",
        "dylib", "so", "a", "o", "class", "jar", "mp4", "mov", "mp3", "wav", "ttf", "otf", "woff",
        "woff2", "ico", "db", "sqlite", "sqlite3", "pack", "pyc", "beam", "beam.smp",
    ]

    /// Formats whose text has to be extracted page by page rather than read as bytes.
    public static let documentExtensions: Set<String> = ["pdf"]

    /// Formats that are read by *looking* rather than by decoding.
    ///
    /// These used to sit in `deniedExtensions` with the reason "not a text file", which was true and
    /// useless: every model Chunks can reach has eyes, so a screenshot, a scanned receipt or a photo
    /// is the most readable thing on the disk. They are attached to the turn as an image instead of
    /// sent as characters.
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp",
    ]

    /// Ceiling on an image's own bytes before it is resized.
    ///
    /// A phone photo is 4-8 MB and resizes to a few hundred KB; past this the file is a RAW or a
    /// stack of layers and the honest answer is that Chunks will not spend a turn on it.
    public static let maxImageBytes = 25_000_000

    /// Whether this path names a document rather than a text file.
    public static func isDocument(_ path: String) -> Bool {
        documentExtensions.contains(pathExtension(of: path))
    }

    /// Whether this path names something to be looked at rather than read.
    public static func isImage(_ path: String) -> Bool {
        imageExtensions.contains(pathExtension(of: path))
    }

    /// Word, RTF and OpenDocument files — containers whose payload *is* text, so they go through an
    /// importer rather than a file handle.
    public static let officeExtensions: Set<String> = [
        "doc", "docx", "rtf", "odt", "pages",
    ]

    public static func isOfficeDocument(_ path: String) -> Bool {
        officeExtensions.contains(pathExtension(of: path))
    }

    /// Formats with no reader yet. Named apart from `deniedExtensions` because the honest sentence is
    /// different: a spreadsheet is not "not a text file", it is a file Chunks cannot open today.
    public static let unsupportedExtensions: Set<String> = [
        "xls", "xlsx", "ppt", "pptx", "key", "numbers", "epub", "ibooks",
    ]

    public static func isUnsupported(_ path: String) -> Bool {
        unsupportedExtensions.contains(pathExtension(of: path))
    }

    /// The file's format class, which decides the route: characters, pages, or pixels.
    public static func kind(of path: String) -> FileMention.Kind {
        let ext = pathExtension(of: path)
        if imageExtensions.contains(ext) { return .image }
        // A Word file is a document in the way he says the word, even though its route is an
        // importer rather than PDFKit — routing checks the extension itself. Calling it `.text`
        // made "the visual designer resume" fail to match his own `.docx`, because the kind bonus
        // compared a document word against a text class.
        if documentExtensions.contains(ext) || officeExtensions.contains(ext) { return .document }
        if unsupportedExtensions.contains(ext) { return .unknown }
        if deniedExtensions.contains(ext) { return .unknown }
        return .text
    }

    static func pathExtension(of path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    /// The raw text disk-read ceiling, independent of the framed model-input budget.
    ///
    /// A head or tail window reads at most 24 KB; `ReadInputBudget` then selects whole lines within
    /// its conservative token upper bound, charging the path, coverage warning and framing too.
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
        let components = candidate
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let fileName = components.last ?? ""
        let wrapped = "/" + candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"

        // The credential checks run **before** the root check, and the order is not cosmetic: a path
        // under `~/.ssh` is refused either way, but only one of the two reasons tells him what he
        // actually asked about. It also closes the symlink case, where the typed path is inside a
        // work folder and only the resolved target is the key.
        if ReadRequest.deniedPathFragments.contains(where: { wrapped.contains($0) }) {
            return .failure(.secretStore)
        }
        if ReadRequest.deniedFileNames.contains(fileName) { return .failure(.secretStore) }
        if fileName.hasPrefix("id_") && fileName != "id" { return .failure(.secretStore) }
        if ReadRequest.secretExtensions.contains((fileName as NSString).pathExtension.lowercased()) {
            // `certs/server.key` inside an allowed folder is still a private key. The file's purpose
            // is readable and its content is not.
            return .failure(.secretStore)
        }

        // Dropping the `~` and keeping the slash, because `homeDirectory + path.dropFirst(2)` builds
        // `/Users/rishiDocuments` — a root that matches nothing. That bug was invisible for exactly
        // one reason: `~` used to be in the list too, and swallowed everything under the home
        // directory. It is not any more, so the join is the only thing deciding what `~/Documents`
        // means, and it has to mean `~/Documents`.
        let roots = allowedRoots.map { ReadRequest.standardise($0.hasPrefix("~")
            ? homeDirectory + $0.dropFirst(1) : $0) }
        guard roots.contains(where: { candidate == $0 || candidate.hasPrefix($0 + "/") }) else {
            return .failure(.outsideAllowedDirectories)
        }

        if ReadRequest.unsupportedExtensions.contains((fileName as NSString).pathExtension.lowercased()) {
            return .failure(.unsupportedFormat)
        }
        if ReadRequest.deniedExtensions.contains((fileName as NSString).pathExtension.lowercased()) {
            return .failure(.binary)
        }
        return .success(candidate)
    }

    /// `a//b/./c` collapses to `a/b/c`, and a `..` that walks out of every directory stays visible
    /// so the root check below can refuse it.
    public static func standardise(_ path: String) -> String {
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
