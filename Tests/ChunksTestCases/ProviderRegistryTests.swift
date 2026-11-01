import Foundation
import ChunksTestHarness
@testable import ChunksKit

public enum ProviderRegistryTests {
    public static func register() {
        TestRunner.currentSuite = "ProviderRegistry"

        test("gemini is free and every listed model is vision-capable") {
            let g = ProviderRegistry.gemini
            expect(g.isFree)
            expect(!g.models.isEmpty, "gemini has no models")
            for m in g.models {
                expect(m.visionCapable == true, "\(m.id) should be marked vision-capable")
                expect(m.isFree, "\(m.id) should be free")
            }
        }

        test("a preferred model is moved to the front of the chain") {
            let chain = ProviderRegistry().visionFallbackChain(
                provider: ProviderRegistry.gemini, preferred: "gemini-3.1-flash-lite")
            expectEqual(chain.first?.id, "gemini-3.1-flash-lite")
            expectEqual(chain.count, ProviderRegistry.gemini.models.count, "no model should be dropped")
        }

        test("an unknown preferred model leaves the declared order intact") {
            let chain = ProviderRegistry().visionFallbackChain(
                provider: ProviderRegistry.gemini, preferred: "does-not-exist")
            expectEqual(chain.map { $0.id }, ProviderRegistry.gemini.models.map { $0.id })
        }

        // Regression: the ordering used a `sorted(by:)` comparator that returned false for
        // everything except the preferred element. That is not a strict weak ordering, so
        // the sort could reorder the rest of the chain unpredictably.
        test("ordering is stable and deterministic, not dependent on sort internals") {
            let r = ProviderRegistry()
            var results: [[String]] = []
            for preferred in ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-flash-lite-latest"] {
                results.append(r.visionFallbackChain(provider: ProviderRegistry.gemini,
                                                     preferred: preferred).map { $0.id })
            }
            expectEqual(results[0].first, "gemini-3.8-flash")
            expectEqual(results[1].first, "gemini-3.6-flash")
            expectEqual(results[2].first, "gemini-flash-lite-latest")

            // The real invariant: hoisting one model must not perturb the relative order of
            // the others. (Comparing whole `dropFirst()` tails would be wrong — the tail
            // legitimately loses whichever element was hoisted out of the middle.)
            let declared = ProviderRegistry.gemini.models.map { $0.id }
            for (index, preferred) in ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-flash-lite-latest"].enumerated() {
                expectEqual(results[index].filter { $0 != preferred },
                            declared.filter { $0 != preferred },
                            "relative order drifted when preferring \(preferred)")
            }
        }

        // The chain is a latency decision, not a capability list. Measured on the same
        // screenshot, `gemini-3.1-pro-preview` took 55 seconds and still came back contended —
        // so with Pro in the second slot, every 503 on Flash cost the user a minute of a card
        // that said nothing. Pro belongs at the end, as the accuracy escape hatch.
        test("a contended Flash escalates through fast models before reaching Pro") {
            let ids = ProviderRegistry.geminiFreeModels.map { $0.id }
            guard let pro = ids.firstIndex(of: "gemini-3.1-pro-preview") else {
                expect(false, "Pro is gone from the chain; a fallback that answers in a minute "
                            + "is not the point of this test, but this case needs updating")
                return
            }
            expect(pro == ids.count - 1,
                  "Pro is at index \(pro) of \(ids.count - 1): a 503 on Flash would route "
                    + "through a slow model before trying the cheap fast ones")
            expectEqual(ids.first, "gemini-3.6-flash",
                        "the first model tried is what the user waits on every single turn")
            // Measured over 161 turns: `3.8-flash` has a 24.2s median and 116 failures, while
            // `3.1-flash-lite` has a 14.5s median and **9** failures. Slot two is where the chain
            // lands after the first refusal *and* the model the hedge asks alongside the leader, so
            // it belongs to the reliable one — the highest number in the name is not a ranking.
            expectEqual(ids.dropFirst().first, "gemini-3.1-flash-lite",
                        "the second slot went back to the slow-and-contended model: \(ids)")
            expect(ids.firstIndex(of: "gemini-3.8-flash") ?? 0 > 1,
                  "3.8-flash is ahead of the model that answers it — its median is slower than "
                    + "the per-attempt slice, so it can only ever lose the slot")
            expectEqual(ProviderRegistry.defaultFreeModelID, ids.first,
                        "the default model and the head of the chain disagree, so a fresh "
                            + "install starts on the tier that has never served a turn here")
        }

        test("models with unknown vision capability are excluded from the vision chain") {
            let p = BrainProvider(
                id: "test", displayName: "Test", transport: .geminiInteractions,
                baseURL: URL(string: "https://example.com")!,
                models: [
                    BrainModel(id: "verified", displayName: "V", visionCapable: true),
                    BrainModel(id: "unknown", displayName: "U", visionCapable: nil),
                    BrainModel(id: "textonly", displayName: "T", visionCapable: false),
                ], isFree: true)
            let chain = ProviderRegistry().visionFallbackChain(provider: p, preferred: nil)
            expectEqual(chain.map { $0.id }, ["verified"], "unverified models must not receive screenshots")
        }

        test("resolve warns loudly when the preferred model cannot see images") {
            let p = BrainProvider(
                id: "test", displayName: "Test", transport: .geminiInteractions,
                baseURL: URL(string: "https://example.com")!,
                models: [
                    BrainModel(id: "verified", displayName: "Verified Vision", visionCapable: true),
                    BrainModel(id: "textonly", displayName: "Text Only", visionCapable: false),
                ], isFree: true)
            let (chain, warning) = ProviderRegistry().resolve(provider: p, preferred: "textonly",
                                                              needsVision: true)
            expectEqual(chain.map { $0.id }, ["verified"])
            expect(warning != nil, "swapping away from a text-only model must be surfaced, not silent")
            if let w = warning { expect(w.contains("Text Only"), "warning should name the model: \(w)") }
        }

        test("resolve returns no warning when the preferred model is usable") {
            let (_, warning) = ProviderRegistry().resolve(provider: ProviderRegistry.gemini,
                                                           preferred: "gemini-3.8-flash",
                                                           needsVision: true)
            expect(warning == nil, "unexpected warning: \(warning ?? "")")
        }

        test("resolve fails loudly when nothing can see images") {
            let p = BrainProvider(id: "t", displayName: "Text Co", transport: .openAICompatible,
                                 baseURL: URL(string: "https://example.com")!,
                                 models: [BrainModel(id: "textonly", displayName: "T", visionCapable: false)],
                                 isFree: true)
            let (chain, warning) = ProviderRegistry().resolve(provider: p, preferred: "textonly", needsVision: true)
            expect(chain.isEmpty, "should offer no models for a vision turn")
            expect(warning != nil, "must explain why nothing is available")
        }

        test("a text-only turn can use models that cannot see images") {
            let p = BrainProvider(id: "t", displayName: "Text Co", transport: .openAICompatible,
                                 baseURL: URL(string: "https://example.com")!,
                                 models: [BrainModel(id: "textonly", displayName: "T", visionCapable: false)],
                                 isFree: true)
            let (chain, warning) = ProviderRegistry().resolve(provider: p, preferred: "textonly", needsVision: false)
            expectEqual(chain.map { $0.id }, ["textonly"])
            expect(warning == nil, "no warning needed: \(warning ?? "")")
        }

        test("measured per-turn cost is reported for paid models") {
            let cheap = BrainModel(id: "c", displayName: "C", visionCapable: true,
                                   costPerMTokIn: 0.10, costPerMTokOut: 0.50)
            let cost = cheap.costPerTurn ?? 0
            expect(cost > 0 && cost < 0.001, "expected a sub-cent estimate, got \(cost)")
            for free in ProviderRegistry.geminiFreeModels {
                expect(free.costPerTurn == 0, "\(free.id) should cost nothing")
            }
        }

        test("Zen is listed but its client-locked free models are not offered") {
            let zen = ProviderRegistry.openCodeZen
            expect(!zen.isFree)
            expect(zen.models.allSatisfy { $0.id.hasPrefix("deepseek") || $0.id.hasPrefix("gpt-") },
                   "no client-locked free models should be offered")
            expect(zen.notes.lowercased().contains("client-locked"),
                   "the client-lock caveat should travel with the provider")
        }
    }
}
