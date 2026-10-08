import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// What the memory layer tells the user about a batch of writes, and how much room the card
/// makes for it.
///
/// The wording is the behaviour under test, because of invariant 3: a refused fact must be
/// *reported*. These cases are the guard against a future edit that returns `nil` for a
/// refusal — that would make a silently-dropped credential indistinguishable from a turn
/// where nothing was remembered.
public enum MemoryReportTests {

    public static func register() {
        TestRunner.currentSuite = "MemoryReport"

        // MARK: Remembered

        test("one stored fact is named on the card") {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = MemoryStore(fileURL: url, today: "2026-10-04")
            let line = MemoryReport.line(for: [store.propose(section: .you, text: "uses raycast")], pruned: 0)
            expectEqual(line, "Remembered: uses raycast",
                        "the user has to see which fact landed, not just that something did")
        }

        test("several stored facts collapse to a count") {
            let line = MemoryReport.line(for: [
                .added(MemoryStore.Fact(section: .you, text: "a", date: "2026-10-04")),
                .added(MemoryStore.Fact(section: .notes, text: "b", date: "2026-10-04")),
            ], pruned: 0)
            expectEqual(line, "Remembered 2 things")
        }

        // MARK: Refusals

        test("a refused secret says it was refused") {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = MemoryStore(fileURL: url, today: "2026-10-04")
            let line = MemoryReport.line(for: [
                store.propose(section: .you, text: "my api key is sk-abcdefghijklmnopqrstuvwxyz123456")
            ], pruned: 0)
            expect(line?.contains("Refused 1 secret") == true,
                   "invariant 3: a rejected fact is reported, never dropped quietly — got \(line ?? "nil")")
            expect(line?.contains("sk-abcdefghijklmnopqrstuvwxyz") == false,
                   "the report must not echo back the secret it just refused")
        }

        test("a full store reports the bytes, because the fix is the user's") {
            let line = MemoryReport.line(for: [.refusedFull(remainingBytes: 21)], pruned: 0)
            expect(line?.contains("full") == true, "invariant 4: capacity asks, so the ask has to be visible")
            expect(line?.contains("21") == true, "the remaining budget belongs in the refusal")
        }

        test("an unreadable proposal is admitted rather than swallowed") {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = MemoryStore(fileURL: url, today: "2026-10-04")
            let line = MemoryReport.line(for: [store.propose(section: .you, text: "two\nlines")], pruned: 0)
            expectEqual(line, "Skipped 1 unreadable fact",
                        "a multi-line proposal is the model's failure and the user should see it")
        }

        // MARK: Nothing to say

        test("a fact already known is not reported as a success") {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = MemoryStore(fileURL: url, today: "2026-10-04")
            store.propose(section: .you, text: "uses raycast")
            let line = MemoryReport.line(for: [store.propose(section: .you, text: "Uses Raycast")], pruned: 0)
            expectEqual(line, "Already knew that.",
                        "\"Remembered\" that changed nothing would misreport the store")
        }

        test("a turn with no memory activity gets no footnote") {
            expect(MemoryReport.line(for: [], pruned: 0) == nil,
                   "most turns remember nothing; a footnote on those is noise on the card")
        }

        // MARK: Pruning

        test("forgetting is phrased as forgetting") {
            expectEqual(MemoryReport.line(for: [], pruned: 1), "Forgot that")
        }

        test("remembering and forgetting in one turn report both") {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = MemoryStore(fileURL: url, today: "2026-10-04")
            let outcome = store.propose(section: .preferences, text: "prefers swift")
            let line = MemoryReport.line(for: [outcome], pruned: 2)
            expect(line?.contains("Remembered: prefers swift") == true, "got \(line ?? "nil")")
            expect(line?.contains("Forgot 2 things") == true,
                   "a prune that landed must be visible, or a wrong deletion looks like a no-op")
        }

        // MARK: Room on the card

        test("the footnote costs exactly a gap plus its two lines") {
            let speech = String(repeating: "a spoken sentence that keeps going. ", count: 8)
            let without = AnswerPanelLayout.measure(speech: speech, detail: "",
                                                    pointCount: 0, hasNote: false, width: 360)
            let withNote = AnswerPanelLayout.measure(speech: speech, detail: "",
                                                     pointCount: 0, hasNote: true, width: 360)
            // Both bounds clamp the delta away, so pin the premise first: a card sitting
            // between them is the only case where a difference means what it looks like.
            let allowance = AnswerPanelLayout.sectionGap + AnswerPanelLayout.noteHeight
            expect(without > AnswerPanelLayout.minimumHeight
                    && without + allowance < AnswerPanelLayout.maximumHeight,
                   "premise: the card must be mid-range to measure a footnote, it was \(without)")
            expectEqual(withNote - without, allowance,
                        "the card must grow by exactly what the view draws, or the note clips")
        }

        test("a long footnote is bounded to what two lines can hold") {
            let long = String(repeating: "remembered a very useful fact. ", count: 20)
            let bounded = AnswerPanelLayout.boundedDetail(long,
                                                          budget: AnswerPanelLayout.noteCharacterBudget)
            expect(bounded.count <= AnswerPanelLayout.noteCharacterBudget + 1,
                   "an unbounded footnote pushes the point chips off the bottom of the card")
        }

        // MARK: Proposal to disk and back

        test("a decoded proposal survives into the next turn's prompt") {
            // The Phase 1 milestone as an assertion: "I use Raycast" must still be in the
            // injected block when the *next* prompt is assembled from a fresh store.
            guard let proposal = MemoryProposal.decode(
                "{\"add\":[{\"section\":\"You\",\"fact\":\"uses raycast as a launcher\"}],\"prune\":[]}")
            else {
                expect(false, "the block the prompt asks the model to emit must decode")
                return
            }
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }

            let store = MemoryStore(fileURL: url, today: "2026-10-04")
            let outcomes = proposal.add.map {
                store.propose(section: $0.section, text: $0.fact)
            }
            expectEqual(MemoryReport.line(for: outcomes, pruned: 0), "Remembered: uses raycast as a launcher")

            let reloaded = MemoryStore(fileURL: url, today: "2026-10-05")
            expect(reloaded.injectedBlock().contains("uses raycast as a launcher"),
                   "a fresh store on the same file is what the next turn's prompt is built from")
        }
    }

    /// A path in the system temp directory, so no case writes into the user's real memory file.
    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chunks-memory-report-\(UUID().uuidString).md")
    }
}
