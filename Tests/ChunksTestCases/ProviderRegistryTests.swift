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
