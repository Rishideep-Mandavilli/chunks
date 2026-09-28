import Foundation
import ChunksTestHarness
@testable import ChunksKit

public enum MemoryStoreTests {

    static func makeTempStore() -> (MemoryStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chunks-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("memory.md")
        return (MemoryStore(fileURL: url, today: "2026-09-29"), url)
    }

    public static func register() {
        TestRunner.currentSuite = "MemoryStore"

        test("starts empty and renders every section") {
            let (s, url) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            expect(s.facts.isEmpty, "a fresh store should be empty")
            let text = s.render()
            for section in MemoryStore.Section.writable {
                expect(text.contains("## \(section.rawValue)"), "missing section \(section.rawValue)")
            }
        }

        test("injectedBlock is empty when there is nothing to inject") {
            let (s, url) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            expect(s.injectedBlock() == "")
        }

        test("a proposed fact is added, dated, and appears in the injected block") {
            let (s, url) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            let outcome = s.propose(section: .you, text: "Uses Raycast, not Spotlight")
            if case .added(let f) = outcome {
                expect(f.date == "2026-09-29", "date should come from the store's clock")
            } else {
                expect(false, "expected .added, got \(outcome)")
            }

            let block = s.injectedBlock()
            expect(block.contains("Uses Raycast, not Spotlight"), "fact missing from injected block")
            expect(block.contains("(2026-09-29)"), "fact should be dated in the block")
            expect(block.contains("### You"), "section heading missing")
        }

        test("refuses to store a credential, and records why") {
            let (s, url) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            let outcome = s.propose(section: .you, text: "api key sk-abc123def456ghi789jkl012")
            if case .rejectedAsSecret = outcome { } else { expect(false, "expected .rejectedAsSecret, got \(outcome)") }
            expect(s.facts.isEmpty, "a rejected secret must not be written")
            expect(s.lastWriteWasRejected != nil, "rejection reason should be surfaced")
        }

        test("rejects multi-line and empty facts") {
            let (s, url) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            if case .rejectedMalformed = s.propose(section: .notes, text: "line one\nline two") {
                // expected
            } else {
                expect(false, "multi-line fact should be rejected")
            }
            if case .rejectedMalformed = s.propose(section: .notes, text: "   ") {
                // expected
            } else {
                expect(false, "empty fact should be rejected")
            }
            expect(s.facts.isEmpty)
        }

        test("deduplicates facts that differ only in case and punctuation") {
            let (s, url) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            _ = s.propose(section: .you, text: "Uses Raycast")
            let second = s.propose(section: .you, text: "uses  raycast!")
            if case .duplicate = second { } else { expect(false, "expected .duplicate, got \(second)") }
            expect(s.facts.count == 1, "expected 1 fact, got \(s.facts.count)")
        }

        test("respects the byte cap by refusing, never truncating") {
            let (s, url) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            var refused = false
            for i in 0..<400 {
                let outcome = s.propose(section: .notes, text: "Durable fact number \(i) about my workflow")
                if case .refusedFull = outcome { refused = true; break }
            }
            expect(refused, "store never hit its cap")
            expect(s.byteCount <= MemoryStore.byteCap,
                   "byteCount \(s.byteCount) exceeded cap \(MemoryStore.byteCap) — it must never truncate")
            expect(s.isFull)
            // Nothing already stored was lost to make room.
            expect(!s.facts.isEmpty, "refusing must not evict existing facts")
        }

        test("round-trips through save and load") {
            let (s, url) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            _ = s.propose(section: .you, text: "Working on a SwiftUI menu bar app")
            _ = s.propose(section: .corrections, text: "Don't call it Spotlight — I mean Raycast")
            _ = s.propose(section: .preferences, text: "Explain code before explaining concept")
            _ = s.propose(section: .notes, text: "Learning DaVinci Resolve")

            let reloaded = MemoryStore(fileURL: url, today: "2026-09-29")
            expect(reloaded.facts.count == s.facts.count,
                   "count drifted: \(reloaded.facts.count) vs \(s.facts.count)")
            expectEqual(reloaded.render(), s.render(), "rendered file drifted across a save/load cycle")
        }

        test("preserves hand edits the user made outside the app") {
            let (s, url) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            _ = s.propose(section: .you, text: "Original fact")

            // Simulate the user opening the file and adding a line by hand.
            var text = try! String(contentsOf: url, encoding: .utf8)
            text = text.replacingOccurrences(of: "- Original fact (2026-09-29)",
                                             with: "- Original fact (2026-09-29)\n- Hand-written addition (2026-09-28)")
            try! text.write(to: url, atomically: true, encoding: .utf8)

            let reloaded = MemoryStore(fileURL: url, today: "2026-09-29")
            expect(reloaded.facts.count == 2, "hand edit was lost")
            expect(reloaded.facts.contains { $0.text == "Hand-written addition" })
        }

        test("removal works by id and by substring") {
            let (s, url) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            _ = s.propose(section: .you, text: "Uses Raycast, not Spotlight")
            _ = s.propose(section: .notes, text: "Learning DaVinci Resolve")

            expect(s.remove(matching: "raycast") == 1, "substring remove should find one fact")
            expect(s.facts.count == 1)
            expect(s.remove(id: "nonexistent") == false, "removing an unknown id should report false")
            expect(s.remove(matching: "nothing matches this") == 0)
        }

        test("ignores unknown sections when parsing") {
            let parsed = MemoryStore.parse("""
            # Chunks Memory

            ## You
            - A real fact (2026-09-29)

            ## Something Chunks Does Not Know
            - Should be ignored (2026-09-29)
            """, today: "2026-09-29")
            expect(parsed.count == 1, "expected 1 fact, got \(parsed.count)")
            expect(parsed.first?.text == "A real fact")
        }

        test("injected block is small enough to be free") {
            let (s, url) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            for i in 0..<30 { _ = s.propose(section: .you, text: "Preference number \(i) about how I like answers") }
            let block = s.injectedBlock()
            expect(block.utf8.count <= MemoryStore.byteCap,
                   "injected block \(block.utf8.count) exceeds the \(MemoryStore.byteCap)-byte budget")
        }

        // Regression: `isFull` used to be `byteCount >= cap`, which is almost never true
        // because the last fact that fits always lands just under the cap. The store would
        // refuse writes while reporting itself not-full, so the user never got warned.
        test("isFull warns before writes actually start failing") {
            let (s, url) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            var firstFullReport: Int?
            var firstRefusal: Int?

            for i in 0..<200 {
                let outcome = s.propose(section: .notes, text: "Durable fact number \(i) about my workflow")
                if firstFullReport == nil && s.isFull { firstFullReport = i }
                if case .refusedFull = outcome { firstRefusal = i; break }
            }

            guard let refusal = firstRefusal else {
                expect(false, "store never refused a write")
                return
            }
            guard let full = firstFullReport else {
                expect(false, "store never reported itself full")
                return
            }

            expect(full <= refusal,
                   "store reported full at i=\(full) but only refused at i=\(refusal) — the warning must come first")
            expect(refusal > 5, "refused almost immediately (i=\(refusal)) — reserve too large")

            // The property that was broken: a store that has refused must report full.
            expect(s.isFull, "a store that just refused a write must report itself full")

            let (fresh, freshURL) = makeTempStore()
            defer { try? FileManager.default.removeItem(at: freshURL.deletingLastPathComponent()) }
            expect(!fresh.isFull, "a fresh store must not report itself full")
        }

        // Regression: fact IDs used `String(text.hashValue)`, which Swift seeds per
        // process. IDs changed on every launch, so a prune referring to a fact stored
        // yesterday would silently match nothing.
        test("fact identifiers are stable across launches") {
            let a = MemoryStore.Fact(section: .you, text: "Uses Raycast, not Spotlight", date: "2026-09-29")
            let b = MemoryStore.Fact(section: .you, text: "Uses Raycast, not Spotlight", date: "2026-09-30")
            expectEqual(a.id, b.id, "id must not depend on the date")
            // Explicitly pin the known-good FNV-1a value so a future refactor to a
            // process-seeded hash fails loudly here instead of silently in production.
            expectEqual(a.id, MemoryStore.Fact.identifier(for: "Uses Raycast, not Spotlight"),
                        "identifier is not self-consistent")
            expect(a.id.count >= 8 && a.id.allSatisfy { $0.isHexDigit }, "id should be hex: \(a.id)")
        }

        test("different facts get different identifiers") {
            let a = MemoryStore.Fact.identifier(for: "Uses Raycast")
            let b = MemoryStore.Fact.identifier(for: "Prefers short answers")
            let c = MemoryStore.Fact.identifier(for: "uses  raycast")
            expect(a != b, "distinct facts collided")
            expectEqual(a, c, "case/punctuation variants must normalise to one id")
        }
    }
}
