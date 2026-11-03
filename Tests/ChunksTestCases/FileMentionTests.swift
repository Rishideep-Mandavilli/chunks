import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for finding the file a sentence means.
///
/// The failure this guards is worse than a refusal: Chunks reads the *wrong* file, answers from it
/// with full confidence, and the user has no way to know. So the interesting cases are the ambiguous
/// ones — two PDFs and no name must produce a question, not a coin toss — and the ordinary ones,
/// because a finder that never attaches anything is the feature not existing.
public enum FileMentionTests {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func file(_ name: String, _ days: Int = 0, bytes: Int = 4_000) -> FileMention.Candidate {
        FileMention.Candidate(path: "/Users/rishi/Downloads/" + name, name: name,
                              kind: ReadRequest.kind(of: name), bytes: bytes,
                              modified: now.addingTimeInterval(TimeInterval(-days * 86_400)))
    }

    /// `score` is internal, so the assertions go through the same entry point the shell uses.
    private static func attaches(_ question: String, _ names: [String]) -> String? {
        let ranked = FileMention.rank(names.map { file($0) }, question: question)
        guard FileMention.shouldAttach(top: ranked.first, runnerUp: ranked.dropFirst().first,
                                       question: question) else { return nil }
        return ranked.first?.name
    }

    /// The policy's own answer for one path, with a home that is not the machine running the test.
    private static func refusesFormat(_ path: String) -> ReadRequest.Refusal? {
        if case .failure(let why) = ReadRequest(path: path)
            .resolved(homeDirectory: "/Users/rishi") { return why }
        return nil
    }

    public static func register() {
        TestRunner.currentSuite = "File mention"

        // There is no word list any more, and this test is the reason: a gate is a ceiling on how he
        // can talk. The sentence is always scored against his own file names, and what decides is the
        // score — not whether he happened to say a word the software knows.
        test("any wording is scored, so no phrasing is forbidden") {
            let files = ["invoice-october.pdf", "zumba-timetable.pdf"]
            expectEqual(attaches("read the invoice pdf", files), "invoice-october.pdf")
            expectEqual(attaches("invoice october — what is the total", files), "invoice-october.pdf",
                        "a sentence with no verb and no format word is still his invoice")
            expectEqual(attaches("the visual designer resume please",
                                 ["MRD resume - 2026.docx", "zumba-timetable.pdf"]),
                        "MRD resume - 2026.docx")
        }

        test("a sentence with nothing in it to match attaches nothing and offers nothing") {
            let files = ["invoice-october.pdf", "zumba-timetable.pdf", "build.log"]
            for phrase in ["why is the certificate warning showing", "click the send button",
                           "what does this button do", "open the bookmarks menu"] {
                expect(attaches(phrase, files) == nil, "\"\(phrase)\" attached a file")
                expect(!FileMention.shouldOffer(files.map { file($0) }, question: phrase),
                       "\"\(phrase)\" put a file listing in the prompt for no reason")
            }
        }

        // The case that a word list could never solve and a single-word score gets wrong: his
        // sentence is about a browser dialog, and one of its words happens to open a PDF's name.
        // One shared word is now too weak to attach — it goes to the model as a name instead.
        test("one shared word is a coincidence, two is a reference") {
            let certificate = "Certificate of Participation - Temple Services.pdf"
            expectEqual(FileMention.sharedWords(of: file(certificate),
                                                question: "why is the certificate warning showing"),
                        1, "the fixture stopped matching on one word, so it proves nothing")
            expect(attaches("why is the certificate warning showing", [certificate]) == nil,
                   "a browser question attached a PDF because they share the word 'certificate'")
            expect(FileMention.shouldOffer([file(certificate)],
                                           question: "why is the certificate warning showing"),
                   "and the model was never told it exists, so it cannot ask for it")
            expectEqual(attaches("what does the certificate of participation say",
                                 [certificate, "zumba-timetable.pdf"]), certificate,
                        "two of his words are in its name — that is a reference, read it")
        }

        test("a document noun keeps its weight in the ranking") {
            expectEqual(attaches("read the invoice pdf",
                                 ["invoice-october.pdf", "zumba-timetable.pdf"]),
                        "invoice-october.pdf",
                        "a word that names his file was excluded from matching it")
        }

        test("class words match nothing on their own") {
            // Without this, "read the pdf" would tie every PDF in Downloads on the word `pdf` and the
            // newest would win by accident rather than by reference.
            expect(FileMention.nameWords(in: "read the pdf invoice").isDisjoint(with:
                    ["read", "the", "pdf"]),
                   "a format word is not a name: \(FileMention.nameWords(in: "read the pdf invoice"))")
            expectEqual(FileMention.nameWords(in: "read the pdf invoice"), ["invoice"],
                        "and the one real name in the sentence survives")
        }

        test("a spreadsheet is refused as a spreadsheet, not as a non-text file") {
            expectEqual(ReadRequest.kind(of: "~/Downloads/budget.xlsx"), .unknown,
                        "an xlsx must never be offered as a candidate — it is a zip of XML")
            expect(refusesFormat("~/Downloads/budget.xlsx") == .unsupportedFormat,
                   "the card said \"not a text file\" about a document full of words")
            let why = ReadRequest.Refusal.unsupportedFormat.description
            expect(why.contains("spreadsheet") && why.contains("Word"),
                   "the sentence has to name what he can do instead: \(why)")
            expectEqual(ReadRequest.kind(of: "~/Downloads/resume.docx"), .document,
                        "a Word file is a document in the way he says the word")
        }

        test("a file named in the middle of a sentence is still found") {
            // With no gate, the name is all there is to go on — so "what does build.log say" has to
            // reach `build.log` through the words themselves, not through a trigger word.
            expectEqual(attaches("what does build.log say", ["build.log", "invoice-october.pdf"]),
                        "build.log")
            expectEqual(attaches("is totals.csv correct", ["totals.csv", "notes.md"]), "totals.csv")
            expect(attaches("version 2.4 of the app", ["build.log", "notes.md"]) == nil,
                   "a version number is not a file reference")
        }

        test("a name in the sentence wins over a newer unrelated file") {
            let chosen = attaches("read the invoice pdf",
                                  ["invoice-october.pdf", "zumba-timetable.pdf", "notes.md"])
            expectEqual(chosen, "invoice-october.pdf",
                        "the word he used is in one file name and nowhere else")
        }

        test("the kind he named wins when he named no file") {
            let chosen = attaches("what does the pdf say", ["build.log", "statement.pdf"])
            expectEqual(chosen, "statement.pdf", "one PDF in the folder is a reference, not a guess")
        }

        // The gate. Two files of the kind and no name is the case where attaching the newest is a
        // coin toss, and a confident answer from the wrong man's statement is the harm.
        test("two candidates of the named kind and no name is a question, not a choice") {
            expect(attaches("read the pdf", ["invoice-2024.pdf", "invoice-2025.pdf"]) == nil,
                   "Chunks picked one at random and would have answered from it as though sure")
        }

        // Measured on his machine, 2026-10-23: "read the receipt png" ranked three PDF receipts above
        // the photograph he meant, because `receipt` is a *thing* and `png` is a *format*, and the
        // first list checked won. A word he typed while looking at the file outranks a word about
        // what such files usually are.
        test("a format word outranks a category word of the other kind") {
            let chosen = attaches("read the receipt png",
                                  ["Receipt (2).pdf", "receipt-2026.png"])
            expectEqual(chosen, "receipt-2026.png",
                   "the format he named lost to a noun in the file's title")
            expectEqual(attaches("read the receipt", ["Receipt (2).pdf", "receipt-2026.png"]),
                        "Receipt (2).pdf",
                        "with no format named, a receipt is more often a PDF than a photo")
        }

        test("nothing readable is offered as nothing, not as the newest file") {
            expect(attaches("read the file", []) == nil)
            expect(FileMention.listing([], home: "/Users/rishi").contains("no file"),
                   "the model has to be told there is nothing, or it will invent a path")
        }

        test("recency breaks a tie between files that match equally well") {
            let older = FileMention.Candidate(path: "/x/report.pdf", name: "report.pdf",
                                              kind: .document, bytes: 100,
                                              modified: now.addingTimeInterval(-86_400 * 30))
            let newer = FileMention.Candidate(path: "/x/report.pdf", name: "report.pdf",
                                              kind: .document, bytes: 100, modified: now)
            let ranked = FileMention.rank([older, newer], question: "the report pdf")
            expectEqual(ranked.first?.modified, newer.modified,
                        "two identical matches, and the one he touched yesterday is the one he means")
        }

        test("a word stem is enough, and a two-letter word is not") {
            expect(FileMention.shared("summarise", with: ["summary"]),
                   "he says the verb, the file is named the noun")
            expect(!FileMention.shared("id", with: ["guide"]),
                   "a substring match would let a two-letter word reach an unrelated file")
        }

        test("the listing shows tilde paths the model can quote back") {
            let text = FileMention.listing([file("statement.pdf", 1)], home: "/Users/rishi")
            expect(text.contains("~/Downloads/statement.pdf"),
                   "an absolute path it has never seen is a path it will get wrong: \(text)")
            expect(text.contains("[READ:"), "and it is told what to do with the name")
        }

        test("stop words and format words do not match every file in the folder") {
            // "the", "read" and "pdf" appear in half the names on a Mac. If they scored, every
            // ranking would be a tie broken by date and the wrong file would win constantly — so
            // the words a sentence shares with *everything* must contribute nothing.
            expect(FileMention.nameWords(in: "read the pdf invoice").isDisjoint(with:
                    ["read", "the", "pdf"]),
                   "a format word is not a name: \(FileMention.nameWords(in: "read the pdf invoice"))")
            expectEqual(FileMention.nameWords(in: "read the pdf invoice"), ["invoice"],
                        "and the one real name in the sentence survives")
        }

        test("a Word owner file is never the file he meant") {
            // Word writes `~$<document>.docx` beside a document while it is open: 165 bytes of author
            // metadata, no document, and — the trap — *newest by modification time*, which is how a
            // ranking breaks a tie. Measured 2026-11-04 when the gate's own fixture discovery chose
            // `~$5103310103-K.s.satwik-.docx` as "a Word file" to read.
            expect(!FileMention.isAutomaticCandidate("~$resume.docx"),
                   "an owner file is not a candidate for a ranking")
            expect(!FileMention.isAutomaticCandidate("/Users/rishi/Downloads/~$resume.docx"),
                   "and the rule holds when it arrives as a full path, not only as a name")
            expect(FileMention.isAutomaticCandidate("resume.docx"),
                   "the document it belongs to still is — the exclusion is the lock file, not .docx")
        }

        test("the files that are never automatic stay named-readable") {
            // The refusal is about *choosing for him*. Naming one of these out loud is a different
            // door — `ReadRequest`, with the credential list — and this asserts the set that stays
            // out of the ranking, so a future candidate list cannot quietly widen it.
            for name in [".DS_Store", ".localized", ".zsh_history", "~$Q3 plan.docx"] {
                expect(!FileMention.isAutomaticCandidate(name),
                       "\(name) must never be picked up by a score")
            }
            for name in ["Q3 plan.docx", "invoice.pdf", "notes.md", "IMG_2044.jpeg"] {
                expect(FileMention.isAutomaticCandidate(name),
                       "an ordinary work file is still a candidate — \(name)")
            }
        }
    }
}
