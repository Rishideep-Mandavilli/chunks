import Foundation

/// Finding the file a sentence is pointing at.
///
/// The old flow made the *model* produce the path, which failed twice over: it cannot see a
/// directory, so it invented names, and the turn that read the file then had to wait for a second
/// model call that the plan gate often never started. This inverts it — the shell resolves the
/// reference before the request is built, so the file arrives in the same turn as the question.
///
/// Pure by construction: the disk hands over `[Candidate]` and this decides what they mean, because
/// "which of the 200 files in Downloads is the invoice" is the part that needs tests, not
/// `contentsOfDirectory`.
public enum FileMention {

    /// What a file is, as far as an extension can tell.
    public enum Kind: String, Equatable, Sendable {
        /// Readable as characters: source, logs, config, markdown.
        case text
        /// A container with a text layer — a PDF.
        case document
        /// Readable only by looking: PNG, JPEG, HEIC.
        case image
        /// Neither, including the formats that stay refused (archives, binaries, video).
        case unknown

        /// The word the card and the prompt use for it.
        public var phrase: String {
            switch self {
            case .text: return "file"
            case .document: return "document"
            case .image: return "image"
            case .unknown: return "thing"
            }
        }
    }

    public struct Candidate: Equatable, Sendable {
        public var path: String
        public var name: String
        public var kind: Kind
        public var bytes: Int
        public var modified: Date

        public init(path: String, name: String, kind: Kind, bytes: Int, modified: Date) {
            self.path = path
            self.name = name
            self.kind = kind
            self.bytes = bytes
            self.modified = modified
        }
    }

    /// How many candidates a turn may be offered, and how many words the listing may spend.
    ///
    /// Four is enough to choose from and small enough that the block costs less than one line of the
    /// screenshot's tokens.
    public static let listingLimit = 4

    // MARK: - Words that name a class, not a file

    /// There is deliberately **no trigger-word list here, and no gate on what he may say.**
    ///
    /// There was one — "pdf", "invoice", "downloads", "read", "open" — and a sentence that missed it
    /// simply did not get its file, which puts a ceiling on how he can talk to a voice assistant:
    /// he ends up learning the vocabulary the software needs. The scan is 40 ms and the ranking reads
    /// his own words against his own file names, so the gate was never what protected anything.
    /// What decides is the score, and where the score is not decisive the model is handed the list
    /// and told to choose. Intent is the one thing a word list cannot tell apart — "visual designer
    /// images" is a web search about a person, and "the visual designer resume" is a file — so that
    /// judgement goes to the model, with the file attached as a guess it is allowed to refuse.

    /// Words that name a *class* of file rather than one file, so they must not win a ranking.
    ///
    /// `pdf` says he means a file, and says nothing about *which* — the kind bonus does that. Without
    /// this list, every PDF in Downloads would tie against every other on the word "pdf" and the
    /// newest would win by accident.
    static let genericWords: Set<String> = [
        "file", "files", "pdf", "png", "jpg", "jpeg", "heic", "tiff", "image", "images",
        "picture", "pictures", "photo", "photos", "screenshot", "screenshots", "scan", "scans",
        "log", "logs", "document", "documents", "csv", "json", "markdown", "folder",
        "downloads", "downloaded", "attachment", "text", "doc", "docs", "code", "script",
        "config", "settings", "page", "pages",
    ]

    /// Words that would match half the files on a Mac, or are grammar.
    static let stopWords: Set<String> = [
        "the", "and", "for", "what", "why", "how", "does", "this", "that", "with", "from",
        "tell", "about", "there", "here", "please", "can", "you", "did", "was", "were",
        "get", "put", "sum", "all", "one", "two", "read", "look", "check", "show", "find",
        "open", "mine", "myn", "any", "some", "just", "now", "then", "says", "say", "into",
    ]

    // MARK: - Ranking

    /// The candidates that could be the one he meant, best first.
    ///
    /// A name shared with the sentence wins outright — `invoice-oct.pdf` for "read the invoice".
    /// Failing that, the *kind* he named wins, because "the pdf in my downloads" has no name to
    /// match and means the newest PDF, not the newest file. Only when neither applies does the
    /// newest anything win, and the card then says which file it read.
    public static func rank(_ candidates: [Candidate], question: String) -> [Candidate] {
        let asked = kindNamed(in: question)
        let words = nameWords(in: question)
        return candidates
            .map { ($0, score(of: $0, words: words, askedKind: asked)) }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                return left.0.modified > right.0.modified
            }
            .map(\.0)
    }

    /// Score of one candidate. Exposed because a tie that looks wrong is the thing to debug.
    static func score(of candidate: Candidate, words: Set<String>, askedKind: Kind?) -> Int {
        var score = 0
        // Shared words in the name: six each, so one real match outranks any kind or date bonus.
        let name = nameWords(in: candidate.name)
        score += words.filter { shared($0, with: name) }.count * 6
        if let askedKind, candidate.kind == askedKind { score += 4 }
        // A file whose own name says "log" when he asked about a failure — cheap, and it is the
        // match a person would make.
        if candidate.kind == .text, candidate.name.lowercased().contains("log") { score += 1 }
        return score
    }

    /// Whole-word equality, or a stem at least five characters long.
    ///
    /// A stem matters because a person says the verb and the file is named the noun — "summarise"
    /// and `summary.md`, "invoice" and `invoices-q3.pdf`. An unbounded substring match would let
    /// "id" reach "guide", and a strict prefix test would miss both of those, hence the floor.
    static func shared(_ question: String, with name: Set<String>) -> Bool {
        if name.contains(question) { return true }
        guard question.count >= 5 else { return false }
        return name.contains { candidate in
            candidate.count >= 5 && commonPrefix(question, candidate).count >= 5
        }
    }

    static func commonPrefix(_ left: String, _ right: String) -> String {
        var shared = ""
        for (a, b) in zip(left, right) where a == b { shared.append(a) }
        return shared
    }

    /// The kind his words name, if any. `nil` means he did not say, and recency decides.
    ///
    /// Two tiers, because "receipt" and "png" are not the same kind of evidence. A format word is
    /// what he typed while looking at the file, so it wins outright; a category word is a guess about
    /// what a receipt usually is, and is only consulted when no format was named. Without the tiers,
    /// "read the receipt png" matched `receipt` against three PDF receipts in Downloads and ranked a
    /// photograph of his below them — measured on his machine, 2026-10-23.
    public static func kindNamed(in question: String) -> Kind? {
        let words = question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        func says(_ set: Set<String>) -> Bool { words.contains { set.contains($0) } }
        if says(formats[.image] ?? []) { return .image }
        if says(formats[.document] ?? []) { return .document }
        if says(formats[.text] ?? []) { return .text }
        if says(categories[.document] ?? []) { return .document }
        if says(categories[.image] ?? []) { return .image }
        if says(categories[.text] ?? []) { return .text }
        return nil
    }

    /// Words that name a file format, per kind.
    static let formats: [Kind: Set<String>] = [
        .image: ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp", "bmp"],
        .document: ["pdf"],
        .text: ["log", "csv", "json", "md", "markdown", "txt", "yaml", "yml", "env", "sh", "sql"],
    ]

    /// Words that name a kind of *thing* a file might be, which is a weaker hint than a format.
    static let categories: [Kind: Set<String>] = [
        .image: ["photo", "photos", "picture", "pictures", "image", "images", "screenshot",
                 "screenshots", "scan", "scans"],
        .document: ["document", "documents", "contract", "agreement", "statement", "invoice",
                    "receipt", "form", "resume", "cv", "manual"],
        .text: ["code", "script", "config", "settings", "source"],
    ]

    /// The words in a sentence, lowercased and stripped of the ones that match every file.
    static func nameWords(in text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) && !genericWords.contains($0) })
    }

    // MARK: - Confidence

    /// How many of his words have to appear in a file's name for Chunks to read it unasked.
    ///
    /// Two. One shared word is not enough once the word list is gone: "why is the certificate warning
    /// showing" is about a browser dialog, and it name-matched `Certificate of Participation - Temple
    /// Services.pdf` on one word. Two words is a reference; one is a coincidence waiting to be
    /// attached to the wrong question.
    public static let attachSharedWords = 2

    /// The score at which a file is worth *mentioning* to the model, even if it is not attached.
    ///
    /// This is where the one-word case goes: not attached, not ignored — handed to the model by
    /// name, with the door open to ask for it. Intent is the one thing a score cannot judge.
    ///
    /// Six, not four, because the kind bonus alone scores four — and at four every ordinary
    /// question that happened to use the word "code", "settings" or "document" got a list of his
    /// files pasted into the prompt with an instruction to go and read one. A listing now needs a
    /// real overlap with a file's name.
    public static let listingThreshold = 6

    /// The score of one candidate against one sentence. Public because the shell reports it, and a
    /// number nobody can print is a number nobody can debug.
    public static func score(of candidate: Candidate, question: String) -> Int {
        score(of: candidate, words: nameWords(in: question), askedKind: kindNamed(in: question))
    }

    /// How many of his words are in the file's name.
    public static func sharedWords(of candidate: Candidate, question: String) -> Int {
        let name = nameWords(in: candidate.name)
        return nameWords(in: question).filter { shared($0, with: name) }.count
    }

    /// Whether the best candidate should go into the turn without asking the model to choose.
    ///
    /// Three ways in: two of his words are in its name, which is a reference; or one is, and he named
    /// the kind as well — "the invoice pdf"; or he named a kind and exactly one file is of it.
    /// Anything weaker goes to the model as a list instead. A wrong attachment is survivable because
    /// it is labelled a guess the model may ignore; a wrong *answer* is not.
    public static func shouldAttach(top: Candidate?, runnerUp: Candidate?, question: String) -> Bool {
        guard let top else { return false }
        let asked = kindNamed(in: question)
        let shared = sharedWords(of: top, question: question)
        if shared >= attachSharedWords { return true }
        if shared == 1, let asked, top.kind == asked { return true }
        guard shared == 0, let asked, top.kind == asked else { return false }
        // Named a kind, matched no name: only safe when no other file is of that kind.
        if let runnerUp, runnerUp.kind == asked { return false }
        return true
    }

    /// Whether the candidates are worth naming to the model at all.
    public static func shouldOffer(_ candidates: [Candidate], question: String) -> Bool {
        guard let best = candidates.max(by: {
            score(of: $0, question: question) < score(of: $1, question: question)
        }) else { return false }
        return score(of: best, question: question) >= listingThreshold
    }

    // MARK: - Folders

    /// Whether a resolved path names a folder rather than a file.
    ///
    /// A folder is not a refusal: "read my downloads" means the newest thing in it that answers the
    /// question, so the caller expands it into candidates and ranks those.
    public static func expandFolder(_ candidates: [Candidate], question: String) -> [Candidate] {
        rank(candidates, question: question)
    }

    // MARK: - What the model is told

    /// A short block naming the files he might have meant, for the case where none matched well
    /// enough to attach.
    ///
    /// The paths are printed as `~/…` because the model has to be able to *quote* one back in a
    /// `[READ:]` tag, and an absolute path it invents from `/Users/rishideep` is a path it will get
    /// wrong.
    public static func listing(_ candidates: [Candidate], home: String) -> String {
        guard !candidates.isEmpty else {
            return "no file in his folders matches what he said. ask him for the name instead of guessing one."
        }
        let formatter = Self.listingDate
        let lines = candidates.prefix(listingLimit).map { candidate in
            let shown = candidate.path.hasPrefix(home)
                ? "~" + candidate.path.dropFirst(home.count) : candidate.path
            return "- \(shown) (\(candidate.kind.phrase), \(candidate.bytes / 1024) KB, "
                + formatter.string(from: candidate.modified) + ")"
        }
        return "the files in his folders that could be what he means, newest first — "
            + "none matched well enough to read on its own:\n" + lines.joined(separator: "\n")
            + "\nif one of these is it, emit [READ:<that exact path>|what you need from it] and "
            + "Chunks reads it next. never invent a path that is not in this list."
    }

    private static let listingDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
        return formatter
    }()
}
