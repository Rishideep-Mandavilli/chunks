import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Whole pages, honest coverage and the exact frame that the live prompt injects.
public enum DocumentReadingTests {
    private static let path = "/Users/rishi/Downloads/contract.pdf"

    private static func pages(_ count: Int, _ each: (Int) -> String) -> [String] {
        (0..<count).map { each($0) }
    }

    private static func filler(_ page: Int) -> String {
        "page \(page + 1) of the schedule of works. "
            + String(repeating: "lorem ipsum dolor sit amet. ", count: 12)
    }

    private static func framedCost(_ selection: DocumentReading.Selection,
                                   path: String = path) -> Int {
        ReadInputBudget.tokenUpperBound(of: ReadInputBudget.frame(
            path: path, text: selection.text, slice: selection.slice))
    }

    public static func register() {
        TestRunner.currentSuite = "Document reading"

        test("a document that fits goes in whole, with no caveat attached") {
            let result = DocumentReading.select(pages: ["First page words.", "Second page words."],
                                                question: "what is the total", path: path)
            guard case .success(let selection) = result else {
                expect(false, "a two-line document must not be refused: \(result)")
                return
            }
            expectEqual(selection.pages, [1, 2], "whole pages are numbered from one, in document order")
            expect(selection.slice == nil, "a full read must not be labelled partial")
            expectEqual(selection.text, "--- page 1 ---\nFirst page words.\n--- page 2 ---\nSecond page words.")
            expect(framedCost(selection) <= ReadInputBudget.maximumUnits, "the live frame must fit too")
        }

        test("a blank page costs nothing and is not sent") {
            let result = DocumentReading.select(pages: ["Real words here.", "", "   "],
                                                question: "words", path: path)
            guard case .success(let selection) = result else {
                expect(false, "one page of text is readable")
                return
            }
            expectEqual(selection.pages, [1], "a blank page must not consume the text budget")
        }

        test("a scan with no text layer is said to be a scan") {
            let result = DocumentReading.select(pages: ["", "", ""], question: "amount due", path: path)
            guard case .failure(let why) = result else {
                expect(false, "an empty document cannot produce an answer")
                return
            }
            expectEqual(why, .noTextLayer(pages: 3))
            expect(why.description.contains("scan"), "the refusal explains the missing text layer")
            expect(why.description.contains("3 pages"), "it names how many pages were examined")
        }

        test("an empty page list is refused rather than answering nothing") {
            expectEqual(DocumentReading.select(pages: [], question: "anything", path: path),
                        .failure(.noTextLayer(pages: 0)))
        }

        test("the pages that answer the question are the pages that go in") {
            let sixty = pages(60) { page in
                page == 40 ? "Clause 9.2 — indemnity. The contractor indemnifies the client for all "
                    + "losses arising from the works described in schedule three." : filler(page)
            }
            let result = DocumentReading.select(pages: sixty, question: "what does the indemnity say", path: path)
            guard case .success(let selection) = result else {
                expect(false, "one relevant whole clause must still be readable")
                return
            }
            expect(selection.pages.contains(41), "the only indemnity page was left out: \(selection.pages)")
            expect(selection.text.contains(sixty[40]), "the clause must survive in its entirety")
            expect(framedCost(selection) <= ReadInputBudget.maximumUnits, "labels and slice also cost units")
            expect(selection.slice?.contains("of 60") == true, "the model must know the document was sliced")
            expect(selection.slice?.contains("do not claim the rest is absent") == true,
                   "an unread clause cannot be reported absent")
        }

        test("the budget bounds the framed input, not the page count") {
            let large = pages(200) { _ in String(repeating: "a", count: 4_000) }
            let result = DocumentReading.select(pages: large, question: "what page is it on", path: path)
            guard case .success(let selection) = result else {
                expect(false, "a 4000-byte whole page fits the default frame")
                return
            }
            expectEqual(selection.pages, [1], "two whole pages cannot fit")
            expect(framedCost(selection) <= ReadInputBudget.maximumUnits, "the complete attachment is bounded")
        }

        test("a question that matches nothing gets a contiguous opening, not later small pages") {
            let book = [String(repeating: "lorem ", count: 50), String(repeating: "ipsum ", count: 1_000), "dolor"]
            let result = DocumentReading.select(pages: book, question: "tell me about it", path: path, budget: 1_200)
            guard case .success(let selection) = result else {
                expect(false, "the opening whole page fits")
                return
            }
            expectEqual(selection.pages, [1], "do not skip page two and call pages one and three the opening")
            expect(selection.slice?.contains("opening pages") == true, "the fallback must be labelled honestly")
            expect(framedCost(selection) <= 1_200, "the opening's coverage warning is charged")
        }

        test("an oversized relevant page refuses rather than clipping a clause or substituting filler") {
            let clause = "indemnity liability " + String(repeating: "obligation ", count: 1_000)
                + "except where the client caused the loss."
            let result = DocumentReading.select(pages: ["An unrelated short page.", clause],
                                                question: "indemnity liability", path: path)
            guard case .failure(let why) = result else {
                expect(false, "sending a clipped clause or the unrelated page would misrepresent the contract")
                return
            }
            expectEqual(why, .pageExceedsBudget(page: 2, budget: ReadInputBudget.maximumUnits))
            expect(why.description.contains("budget"), "the user must learn this is a budget failure")
            expect(why.description.contains("Page 2"), "name the page that needs a smaller excerpt")
            expect(why.description.contains("upper-bound"), "do not call a byte bound measured tokens")
        }

        test("an oversized opening page without matches is refused too") {
            let result = DocumentReading.select(pages: [String(repeating: "lorem ", count: 2_000), "tiny"],
                                                question: "explain", path: path)
            expectEqual(result, .failure(.pageExceedsBudget(page: 1, budget: ReadInputBudget.maximumUnits)),
                        "a later short page cannot stand in for an unread opening")
        }

        test("a full document fits at the exact frame boundary and refuses one unit below") {
            let body = "  A complete clause.\n"
            let frame = ReadInputBudget.frame(path: path, text: "--- page 1 ---\n" + body, slice: nil)
            let budget = frame.utf8.count
            let result = DocumentReading.select(pages: [body], question: "clause", path: path, budget: budget)
            guard case .success(let selection) = result else {
                expect(false, "equality with the complete frame is allowed")
                return
            }
            expectEqual(selection.text, "--- page 1 ---\n" + body, "a whole page keeps its boundary whitespace too")
            expectEqual(framedCost(selection), budget, "charge every frame byte, not just page text")
            expectEqual(DocumentReading.select(pages: [body], question: "clause", path: path, budget: budget - 1),
                        .failure(.pageExceedsBudget(page: 1, budget: budget - 1)),
                        "one missing unit cannot be borrowed by clipping the clause")
        }

        test("a partial boundary charges page labels, separators and the changing slice list") {
            let book = ["indemnity liability", "indemnity", String(repeating: "lorem ", count: 2_000)]
            let text = "--- page 1 ---\nindemnity liability\n--- page 2 ---\nindemnity"
            let slice = DocumentReading.sliceLine(pages: [1, 2], total: 3, matched: true)
            let budget = ReadInputBudget.frame(path: path, text: text, slice: slice).utf8.count
            let result = DocumentReading.select(pages: book, question: "indemnity liability", path: path, budget: budget)
            guard case .success(let selection) = result else {
                expect(false, "two whole pages fit the exact partial frame")
                return
            }
            expectEqual(selection.pages, [1, 2])
            expectEqual(selection.text, text, "separators must match the charged frame exactly")
            expectEqual(framedCost(selection), budget)
            let smaller = DocumentReading.select(pages: book, question: "indemnity liability", path: path, budget: budget - 1)
            guard case .success(let reduced) = smaller else {
                expect(false, "the best page alone still fits")
                return
            }
            expectEqual(reduced.pages, [1], "one unit below the boundary must drop a whole page")
            expect(framedCost(reduced) <= budget - 1, "recompute the selected page list's own cost")
        }

        test("the best later page wins among sixty matches in four hundred pages") {
            let book = pages(400) { page in
                let subject = page == 399 ? "indemnity liability damages " : (page < 59 ? "indemnity " : "lorem ")
                return subject + String(repeating: "ipsum ", count: 140)
            }
            let result = DocumentReading.select(pages: book, question: "indemnity liability damages", path: path)
            guard case .success(let selection) = result else {
                expect(false, "the best page fits despite being the last of many matches")
                return
            }
            expect(selection.pages.contains(400), "ranking must happen before the budget is spent on early matches")
            expect(selection.pages.count < 60, "this fixture must force a real choice among matching pages")
            expectEqual(selection.pages, selection.pages.sorted(), "selected pages return to document order")
            let expected = selection.pages.map { "--- page \($0) ---\n" + book[$0 - 1] }.joined(separator: "\n")
            expectEqual(selection.text, expected, "every selected page must be whole, including its last clause")
            expect(framedCost(selection) <= ReadInputBudget.maximumUnits, "the final frame stays within 6000 units")
        }

        test("multilingual pages pay UTF-8 bytes rather than character estimates") {
            let body = String(repeating: "界éह🙂", count: 600)
            expect(body.count < ReadInputBudget.maximumUnits, "the old character-only check would accept this page")
            expect(body.utf8.count > ReadInputBudget.maximumUnits, "the upper bound must reject this page")
            expectEqual(DocumentReading.select(pages: [body], question: "explain", path: path),
                        .failure(.pageExceedsBudget(page: 1, budget: ReadInputBudget.maximumUnits)))
        }

        test("a multilingual filename is charged exactly and never shortened to make a page fit") {
            let unicodePath = "/Users/rishi/Downloads/契約-é-🙂.pdf"
            let text = "--- page 1 ---\nclause"
            let budget = ReadInputBudget.frame(path: unicodePath, text: text, slice: nil).utf8.count
            guard case .success(let selection) = DocumentReading.select(pages: ["clause"], question: "clause",
                                                                         path: unicodePath, budget: budget) else {
                expect(false, "a path is allowed when its exact byte cost fits")
                return
            }
            expectEqual(framedCost(selection, path: unicodePath), budget)
            let longer = unicodePath + "界"
            expectEqual(DocumentReading.select(pages: ["clause"], question: "clause", path: longer, budget: budget),
                        .failure(.pageExceedsBudget(page: 1, budget: budget)), "the path cannot be free overhead")
        }

        test("tiny or negative budgets refuse without returning an empty or clipped page") {
            let emptyFrameCost = ReadInputBudget.frame(path: path, text: "", slice: nil).utf8.count
            for budget in [-1, 0, 1, emptyFrameCost] {
                expectEqual(DocumentReading.select(pages: ["complete clause"], question: "clause", path: path, budget: budget),
                            .failure(.pageExceedsBudget(page: 1, budget: budget)))
            }
        }

        test("a file too big to open is refused before PDFKit is asked") {
            expect(DocumentReading.isTooLarge(bytes: DocumentReading.maxFileBytes + 1), "do not open enormous scans")
            expect(!DocumentReading.isTooLarge(bytes: DocumentReading.maxFileBytes - 1), "ordinary contracts still open")
            expect(DocumentReading.Failure.tooLarge(bytes: 400_000_000).description.contains("400 MB"),
                   "the line names the size, not just the rule")
        }
    }
}
