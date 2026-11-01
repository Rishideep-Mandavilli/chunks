import ChunksKit
import Foundation

/// The `Sources/Chunks` half of `[DO:reveal:…]` — turn what the model named into **one real path**
/// before anything is asked about it.
///
/// The split is the one this codebase already uses for files: the policy is pure (`RevealPolicy`,
/// tested against the paths that matter), the disk is not. What is decided here is only *which thing
/// on his machine* the card should name, because a card that asks "Show Memora in Finder?" and then
/// reports "no such folder" made the question a lie — the same rule the routine tools follow.
///
/// A name is looked for, not guessed: matched exactly (case-insensitively) against what sits in his
/// work roots two levels deep, and two matches is a question rather than a coin toss.
enum FinderReveal {

    enum Outcome: Equatable {
        /// One thing, at this absolute path — the card can be built.
        case found(String)
        /// Two or more things share the name. The paths are for the sentence that asks.
        case ambiguous([String])
        /// Nothing on this disk answers to it.
        case nothing
        /// The thing exists but Chunks will not open it: outside the allowed roots, or a folder
        /// that holds credentials.
        case refused(String)
    }

    /// How many directories the name search reads before it stops.
    ///
    /// A wrong name on a deep tree must not freeze the notch mid-turn — the same budget the
    /// accessibility walks carry. At this many it covers a normal `~/Documents` in well under a
    /// second, and a monorepo that takes longer reports `nothing` rather than hanging.
    static let maxDirectoriesRead = 1200

    /// How deep below each root the search goes.
    static let depth = 2

    static func resolve(_ target: String, home: String = NSHomeDirectory()) -> Outcome {
        switch RevealPolicy.verdict(for: target, homeDirectory: home) {
        case .allowed(let absolute):
            return fileExists(absolute) ? .found(absolute) : .nothing
        case .lookup(let name):
            return named(name, home: home)
        case .outside:
            return .refused("outside")
        case .secret:
            return .refused("secret")
        case .unreadable:
            return .nothing
        }
    }

    // MARK: - A name to look for

    static func named(_ name: String, home: String) -> Outcome {
        let finder = FileManager.default
        let wanted = name.lowercased()
        var matches: [String] = []
        var directoriesRead = 0

        for root in searchRoots(home: home) {
            guard directoriesRead < maxDirectoriesRead else { break }
            var queue: [(path: String, level: Int)] = [(root, 0)]
            while let (directory, level) = queue.popLast(), directoriesRead < maxDirectoriesRead {
                directoriesRead += 1
                guard let entries = try? finder.contentsOfDirectory(
                    at: URL(fileURLWithPath: directory),
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]) else { continue }
                for entry in entries {
                    let full = entry.path
                    if entry.lastPathComponent.lowercased() == wanted {
                        matches.append(full)
                    }
                    if level + 1 < depth, isDirectory(full) {
                        queue.append((full, level + 1))
                    }
                }
            }
        }

        let found = unique(matches).sorted()
        switch found.count {
        case 0: return .nothing
        case 1: return .found(found[0])
        default: return .ambiguous(found)
        }
    }

    /// The folders a person's work actually lives in.
    ///
    /// `~` itself is left out on purpose: a two-level walk of a home directory reads thousands of
    /// unrelated folders for one name, and `~/Library/Caches/…` is not where a workspace is.
    static func searchRoots(home: String) -> [String] {
        ["Documents", "Downloads", "Desktop", "Projects", "Developer", "Code", "src", "repos"]
            .map { home + "/" + $0 }
            .filter { isDirectory($0) }
    }

    private static func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}
