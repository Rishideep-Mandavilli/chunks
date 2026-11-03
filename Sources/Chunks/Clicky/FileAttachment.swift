import AppKit
import ChunksKit
import CoreServices
import Foundation
import ImageIO

/// Finding and attaching the file a sentence points at, before the model is asked.
///
/// The old flow made the model emit `[READ:~/path]`, which failed twice: it cannot see a directory,
/// so it invented names — and the turn that read the file then waited on a second model call that the
/// plan's completion gate usually never started, on a fresh screenshot of a screen that had not
/// changed. This inverts it. The shell searches, ranks against the words he used, and puts the file in
/// the *same* request as his question. One round trip, no invented path, and a name he can hear the
/// card say back.
///
/// The search is shallow and bounded on purpose: one level of the folders a person keeps work in, the
/// newest 60 of each. A recursive walk of `~` would find the file eventually and freeze the notch
/// meanwhile, and "which file did he mean" is answered by names and dates, not by depth.
@MainActor
enum FileAttachment {

    /// Entries per root, newest first.
    static let perRoot = 60

    struct Resolved {
        let candidate: FileMention.Candidate
        /// Characters, when the file is read as text or through a document's text layer.
        var content: FileRead.Content?
        /// JPEG bytes, when the file is read by looking at it — a picture, or a scanned PDF's pages.
        var images: [Data]
        /// Why it was not attached, phrased for the log and the card.
        var failure: String?
    }

    // MARK: - The search

    /// The folders this sentence could mean, narrowed by the container it names.
    static func roots(for question: String, home: String) -> [String] {
        let lower = question.lowercased()
        func named(_ words: [String], _ leaf: String) -> String? {
            words.contains { lower.contains($0) } ? home + "/" + leaf : nil
        }
        var chosen: [String] = []
        if let downloads = named(["download", "downloads", "downloaded"], "Downloads") { chosen.append(downloads) }
        if let desktop = named(["desktop"], "Desktop") { chosen.append(desktop) }
        if let documents = named(["document", "documents"], "Documents") { chosen.append(documents) }
        for leaf in ["Projects", "Developer", "Code", "src", "repos"] {
            if lower.contains(leaf.lowercased()) { chosen.append(home + "/" + leaf) }
        }
        guard chosen.isEmpty else { return chosen }
        // Nothing was named, so every allowed root is searched. Home itself is not one of them:
        // a scan that reached `~` would put `~/Library` one scoring error away from a cloud request.
        return ReadRequest.defaultAllowedRoots.map { root in
            root.hasPrefix("~") ? home + root.dropFirst(1) : root
        }
    }

    /// Files that are never automatic candidates, whatever the sentence says.
    ///
    /// The rule is `FileMention.isAutomaticCandidate` — pure, and tested there, because "which file did
    /// he mean" is the part that needs the negative cases. This layer only walks the disk.
    static func isAutomaticCandidate(_ name: String) -> Bool {
        FileMention.isAutomaticCandidate(name)
    }

    /// Every readable file in those roots, as candidates.
    static func candidates(for question: String, home: String = NSHomeDirectory())
        -> [FileMention.Candidate] {
        let finder = FileManager.default
        var out: [FileMention.Candidate] = []
        for root in roots(for: question, home: home) {
            let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            guard let entries = try? finder.contentsOfDirectory(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]) else { continue }
            var held: [FileMention.Candidate] = []
            for url in entries {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true { continue }
                let name = url.lastPathComponent
                guard isAutomaticCandidate(name) else { continue }
                let path = url.path
                guard !ReadRequest.deniedPathFragments.contains(where: { path.contains($0) }) else { continue }
                let kind = ReadRequest.kind(of: name)
                guard kind != .unknown else { continue }
                let bytes = values?.fileSize ?? 0
                if kind == .image, bytes > ReadRequest.maxImageBytes { continue }
                held.append(FileMention.Candidate(
                    path: path, name: name, kind: kind, bytes: bytes,
                    modified: values?.contentModificationDate ?? .distantPast))
            }
            out += held.sorted { $0.modified > $1.modified }.prefix(perRoot)
        }
        return out
    }

    // MARK: - The attachment

    /// Resolve a question into a file, or into nothing when the choice is genuinely ambiguous.
    ///
    /// No word list gates this — the sentence is always ranked against the disk, because a gate is
    /// only ever a limit on how he can talk. What decides is the score.
    static func resolve(question: String, home: String = NSHomeDirectory()) -> Resolved? {
        let ranked = FileMention.rank(candidates(for: question, home: home), question: question)
        guard FileMention.shouldAttach(top: ranked.first, runnerUp: ranked.dropFirst().first,
                                       question: question),
              let top = ranked.first else { return nil }
        return load(top, question: question, home: home)
    }

    /// Read one candidate, by whichever route its format needs — and by the picture route when the
    /// text route comes back empty.
    static func load(_ candidate: FileMention.Candidate, question: String,
                     home: String = NSHomeDirectory()) -> Resolved {
        guard candidate.kind != .image else {
            guard let data = Self.jpeg(fromFileAt: candidate.path) else {
                return Resolved(candidate: candidate, content: nil, images: [],
                                failure: "Chunks could not open that picture")
            }
            return Resolved(candidate: candidate, content: nil, images: [data], failure: nil)
        }
        let request = ReadRequest(path: candidate.path, question: question)
        switch FileRead.perform(request, home: home) {
        case .success(let content):
            return Resolved(candidate: candidate, content: content, images: [], failure: nil)
        case .failure(.document(.noTextLayer)):
            // A scan is not a dead end. The pages have no words to extract, so they go as pixels and
            // the model reads them the way he would — which is the difference between "I cannot read
            // that" and an answer.
            let pages = DocumentRead.renderedJPEG(at: candidate.path)
            guard !pages.isEmpty else {
                return Resolved(candidate: candidate, content: nil, images: [],
                                failure: "that PDF has no text and no pages Chunks could draw")
            }
            return Resolved(candidate: candidate, content: nil, images: pages, failure: nil)
        case .failure(let why):
            return Resolved(candidate: candidate, content: nil, images: [], failure: why.description)
        }
    }

    // MARK: - Images

    /// A file's picture, at the ceiling the screen capture already uses.
    ///
    /// ImageIO's thumbnail path rather than `NSImage`: it downscales during decode, so a 12 MB HEIC
    /// becomes a few hundred kilobytes without ever becoming a full-size bitmap in memory — and the
    /// same 1280 pt / 0.8 quality as every screenshot means one image costs one image, whichever way
    /// it arrived.
    static func jpeg(fromFileAt path: String, maxDimension: Int = 1280) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            ] as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

/// `--probe-find "<question>"` — search, rank and load exactly as a spoken turn would, and say which
/// file won.
///
/// Exists because "read the invoice in my downloads" is a sentence about a disk, and until this ran
/// against real folders there was no way to tell a bad ranking from a missing file.
@MainActor
enum FileFindProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-find") }

    private static func out(_ line: String) {
        print(line)
        Log.write(line)
    }

    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let question = CommandLine.arguments.drop(while: { $0 != "--probe-find" }).dropFirst()
            .joined(separator: " ")
        guard !question.isEmpty else {
            out("probe-find: give it the sentence, in quotes")
            Log.flush()
            exit(2)
        }
        let candidates = FileAttachment.candidates(for: question)
        let ranked = FileMention.rank(candidates, question: question)
        out("probe-find: \"\(question)\" — \(candidates.count) readable files searched")
        for candidate in ranked.prefix(6) {
            out("probe-find:   score \(FileMention.score(of: candidate, question: question)) "
                + "\(candidate.kind.rawValue) \(candidate.name) "
                + "(\(candidate.bytes / 1024) KB, \(candidate.modified.description.prefix(16)))")
        }
        let attach = FileMention.shouldAttach(top: ranked.first,
                                              runnerUp: ranked.dropFirst().first,
                                              question: question)
        out("probe-find: attach=\(attach ? "yes" : "no — the model gets the list instead")")
        guard attach, let top = ranked.first else {
            out(FileMention.listing(ranked, home: NSHomeDirectory()))
            Log.flush()
            exit(0)
        }
        let loaded = FileAttachment.load(top, question: question)
        if let failure = loaded.failure {
            out("probe-find: LOAD FAILED — \(failure)")
            Log.flush()
            exit(1)
        }
        if !loaded.images.isEmpty {
            out("probe-find: ATTACHED as \(loaded.images.count == 1 ? "an image" : "images"), "
                + "\(loaded.images.reduce(0) { $0 + $1.count } / 1024) KB of JPEG at \(top.path)")
        } else if let content = loaded.content {
            out("probe-find: ATTACHED as text, \(content.text.count) characters at \(content.path)")
            if let slice = content.slice { out("probe-find:   slice — \(slice)") }
        }
        Log.flush()
        exit(0)
    }
}
