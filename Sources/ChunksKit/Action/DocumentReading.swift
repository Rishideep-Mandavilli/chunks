import Foundation

/// The page half of reading a document.
///
/// A PDF is not a text file. `FileHandle` hands back compressed streams, so the bytes on disk mean
/// nothing and the only route is an extractor that yields the *pages* as strings. This type decides
/// which of those pages go into one turn, and it is pure precisely because extraction is the part
/// that needs PDFKit and a real file: the cases that matter — a scanned contract with no text at
/// all, a 61-page manual, a question that names one page — are arithmetic, and arithmetic is
/// testable without a fixture on disk.
public enum DocumentReading {

    /// A file this big is not opened.
    ///
    /// A 400 MB PDF is a folder of photographs wearing a document's name, and PDFKit would spend a
    /// minute and a large part of the app's memory discovering that. Said as a size rather than a
    /// page count because the page count is only knowable *after* the open.
    public static let maxFileBytes = 80_000_000

    /// What went into the turn.
    public struct Selection: Equatable, Sendable {
        /// One-based page numbers, ascending — the order the document is read in.
        public var pages: [Int]
        /// The text, one header per page, so a quoted line can be traced back to a page.
        public var text: String
        /// How much of the document this is, phrased for the model. `nil` means all of it.
        public var slice: String?
    }

    public enum Failure: Equatable, Sendable, Error {
        /// No page yielded a character. Almost always a scan: a picture of paper wearing a PDF.
        case noTextLayer(pages: Int)
        /// Bigger than `maxFileBytes`.
        case tooLarge(bytes: Int)
        /// The best relevant page (or first text page without a match) cannot be sent whole.
        case pageExceedsBudget(page: Int, budget: Int)

        public var description: String {
            switch self {
            case .noTextLayer(let pages):
                return "That PDF has no text in it — it is a scan of \(pages == 1 ? "a page" : "\(pages) pages"), "
                    + "so Chunks can look at it on screen but cannot read it as words."
            case .tooLarge(let bytes):
                return "That PDF is \(bytes / 1_000_000) MB, which is more than Chunks opens in one turn."
            case .pageExceedsBudget(let page, let budget):
                return "Page \(page) cannot fit whole within the read-input budget (\(budget) "
                    + "UTF-8-byte token upper-bound units, including labels and coverage warning). "
                    + "Chunks did not clip a clause or substitute a less relevant page; "
                    + "choose a smaller excerpt."
            }
        }
    }

    /// Whether a file is worth opening at all.
    ///
    /// A function rather than a call site because the number without the rule attached is the kind
    /// of constant that gets quietly re-typed on the other side of the split.
    public static func isTooLarge(bytes: Int) -> Bool { bytes > maxFileBytes }

    // MARK: - Selection

    /// Choose whole pages by relevance, but present them in document order. The resolved path is
    /// required because it is part of the exact frame charged by the shared token upper bound.
    /// Never replace an oversized best page with a smaller, less relevant one: that would turn a
    /// budget limitation into a confident answer about the wrong part of the document.
    public static func select(pages: [String], question: String, path: String,
                              budget: Int = ReadInputBudget.maximumUnits) -> Result<Selection, Failure> {
        let held = pages
        // Whitespace-only pages have no text, but a selected page keeps its exact extracted text,
        // including boundary whitespace. Even those bytes belong in the framed upper bound.
        let nonEmpty = held.indices.filter { !held[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return .failure(.noTextLayer(pages: held.count)) }

        func selection(_ chosen: [Int], matched: Bool) -> Selection {
            let ordered = chosen.sorted()
            let numbers = ordered.map { $0 + 1 }
            return Selection(pages: numbers, text: join(held, ordered),
                             slice: ordered.count == nonEmpty.count ? nil
                                : sliceLine(pages: numbers, total: held.count, matched: matched))
        }
        func fits(_ selection: Selection) -> Bool {
            ReadInputBudget.fits(path: path, text: selection.text, slice: selection.slice, budget: budget)
        }
        let whole = selection(nonEmpty, matched: false)
        if fits(whole) { return .success(whole) }

        let words = ConversationStore.contentWords(in: question)
        let scores = held.map { score(of: $0, words) }
        let ranked = nonEmpty.sorted { left, right in
            scores[left] == scores[right] ? left < right : scores[left] > scores[right]
        }
        let best = ranked[0]
        let matched = scores[best] > 0
        var chosen = [best]
        var result = selection(chosen, matched: matched)
        guard fits(result) else {
            return .failure(.pageExceedsBudget(page: best + 1, budget: budget))
        }
        for page in ranked.dropFirst() {
            // Every candidate pays for its actual labels, separators, changing page list and frame.
            let candidate = selection(chosen + [page], matched: matched)
            if fits(candidate) {
                chosen.append(page)
                result = candidate
            } else if !matched {
                // Without a relevance signal, "opening pages" must mean a prefix, not scattered
                // small pages chosen by how conveniently they fit.
                break
            }
        }
        return .success(result)
    }

    /// Names the selected pages and explicitly disclaims the remainder: a partial read must not
    /// become "the contract has no indemnity clause" about pages the model never received.
    static func sliceLine(pages: [Int], total: Int, matched: Bool) -> String {
        let listed = pages.map(String.init).joined(separator: ", ")
        let why = matched ? "pages ranked by the words he asked about" : "the opening pages"
        return "only pages \(listed) of \(total) — \(why); the rest of the document was not read, "
            + "so say which page an answer came from and do not claim the rest is absent"
    }

    static func header(_ page: Int) -> String { "--- page \(page + 1) ---\n" }

    /// Hits on the question's content words.
    ///
    /// Substring rather than word-boundary matching: this only *orders* pages, it never decides
    /// whether text is sent, and a per-page regex per word costs more than the guessing is worth.
    static func score(of page: String, _ words: Set<String>) -> Int {
        guard !words.isEmpty else { return 0 }
        let lower = page.lowercased()
        return words.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
    }

    private static func join(_ pages: [String], _ chosen: [Int]) -> String {
        chosen.map { header($0) + pages[$0] }.joined(separator: "\n")
    }
}
