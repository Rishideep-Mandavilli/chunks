import Foundation

/// What `[DO:reveal:…]` may point at.
///
/// A Finder window shows what is in a folder without sending anything to a model, which is why this
/// is its own policy rather than a case of `ReadRequest`: the format rules there (no `.zip`, no
/// `.app`) exist because those bytes cannot be read as text, and they would wrongly refuse the one
/// thing a reveal is for — *looking at where something lives*.
///
/// What is shared with a read is the part that matters: the allowed roots and the credential
/// deny-list, matched against the **standardised** path. Putting `~/.ssh` on a screen for whoever is
/// standing behind him is a leak even when nothing is read.
public enum RevealPolicy {

    public enum Verdict: Equatable, Sendable {
        /// A normalised absolute path Chunks may open, if it exists — existence is the disk's
        /// answer, not this one, because nothing here touches the file system.
        case allowed(String)
        /// A bare name with no directory in it: look it up in his folders.
        case lookup(String)
        /// Above every allowed root, or under none of them.
        case outside
        /// A private key, a keychain, a credential store.
        case secret
        /// Nothing there at all — empty, or a nested scheme.
        case unreadable
    }

    public static let pathLimit = 200

    public static func verdict(for written: String, homeDirectory home: String) -> Verdict {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= pathLimit else { return .unreadable }
        if trimmed.contains(where: { $0.isNewline || $0 == "\t" }) { return .unreadable }
        // `file:///…` is a URL handed to whatever owns URLs, not a path handed to Finder.
        if trimmed.contains("://") || trimmed.hasPrefix("-") { return .unreadable }

        guard trimmed.contains("/") || trimmed.hasPrefix("~") else {
            guard !trimmed.isEmpty else { return .unreadable }
            return .lookup(trimmed)
        }

        let suffix = trimmed.hasPrefix("~/") ? String(trimmed.dropFirst(2))
            : trimmed.hasPrefix("~") ? String(trimmed.dropFirst(1)) : trimmed
        let joined = trimmed.hasPrefix("/") ? trimmed : home + "/" + suffix
        let absolute = ReadRequest.standardise(joined)

        let wrapped = "/" + absolute.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        let fileName = absolute.split(separator: "/").last.map(String.init) ?? ""
        // Credentials are named before roots, exactly as in `ReadRequest`: `~/.ssh` is refused as a
        // credential store, not as "somewhere else", and the home exception below must not swallow it.
        if ReadRequest.deniedPathFragments.contains(where: { wrapped.contains($0) })
            || ReadRequest.deniedFileNames.contains(fileName)
            || (fileName.hasPrefix("id_") && fileName != "id") {
            return .secret
        }

        let roots = ReadRequest.defaultAllowedRoots.map {
            ReadRequest.standardise($0.hasPrefix("~") ? home + $0.dropFirst(1) : $0)
        }
        // Home itself is revealable and not readable, and that asymmetry is the point: opening
        // `~` in Finder shows him his own folder on his own screen, where a read of a file under it
        // sends its contents to a model.
        guard absolute == ReadRequest.standardise(home)
            || roots.contains(where: { absolute == $0 || absolute.hasPrefix($0 + "/") })
        else { return .outside }

        return .allowed(absolute)
    }

    /// The folder a card should name when it says where something lives.
    ///
    /// "Show Memora in Finder?" is not enough to approve — two folders can share a name, and the one
    /// that opens is the one Chunks chose. The parent is the cheapest fact that makes the question
    /// answerable, and it costs one path component.
    public static func label(for absolutePath: String) -> String {
        let url = URL(fileURLWithPath: absolutePath)
        let last = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty, parent != "/", parent != last else { return last }
        return "\(last) (in \(parent))"
    }
}
