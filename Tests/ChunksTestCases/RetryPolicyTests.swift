import Foundation
import ChunksTestHarness
@testable import ChunksKit

public enum RetryPolicyTests {
    public static func register() {
        TestRunner.currentSuite = "RetryPolicy"

        // MARK: Classification

        test("503 maps to serviceUnavailable and is recognised as high demand") {
            let f = RetryPolicy.classify(statusCode: 503,
                                         body: "This model is currently experiencing high demand.")
            expectEqual(f, .serviceUnavailable(highDemand: true))
        }

        test("500 without a demand hint is still serviceUnavailable") {
            expectEqual(RetryPolicy.classify(statusCode: 500), .serviceUnavailable(highDemand: false))
        }

        test("429 with a rate-limit message maps to the free-tier cap") {
            let f = RetryPolicy.classify(statusCode: 429,
                                         body: "Rate limit exceeded for model gemini-3.5-flash (limit: 5 req/min)")
            expectEqual(f, .rateLimited(requestsPerMinute: 5))
        }

        test("401 and 403 mean unauthorised and must not retry") {
            for code in [401, 403] {
                expectEqual(RetryPolicy.decide(for: RetryPolicy.classify(statusCode: code), attempt: 0), .fail,
                             "status \(code) must not retry")
            }
        }

        test("400 is a bad request and must not retry") {
            expectEqual(RetryPolicy.decide(for: .badRequest(detail: "bad field"), attempt: 0), .fail)
        }

        test("an unknown status gets exactly one retry, then fails") {
            let f = RetryPolicy.classify(statusCode: 418, body: "teapot")
            expectEqual(f, .unknown(statusCode: 418, detail: "teapot"))
            if case .retrySameModel = RetryPolicy.decide(for: f, attempt: 0) {} else {
                expect(false, "expected a single retry for an unknown status")
            }
            expectEqual(RetryPolicy.decide(for: f, attempt: 1), .fail)
        }

        // MARK: Decisions

        test("503 retries a couple of times, then moves to the next model") {
            let f = RetryPolicy.Failure.serviceUnavailable(highDemand: true)
            if case .retrySameModel = RetryPolicy.decide(for: f, attempt: 0) {} else {
                expect(false, "first attempt should retry")
            }
            expectEqual(RetryPolicy.decide(for: f, attempt: 2), .fallBackToNextModel)
        }

        // A network failure here is the idle timeout firing: the connection was made and no byte
        // arrived. Asking the same model again is what spent 271 of a real turn's 281 seconds on
        // 2026-10-15 — three full timeouts on one model, while the next one in the chain answered
        // the same request in six seconds.
        test("a model that said nothing is switched away from, not waited on") {
            for attempt in 0...2 {
                expectEqual(RetryPolicy.decide(for: .network(detail: "no bytes"),
                                               attempt: attempt),
                            .fallBackToNextModel,
                            "attempt \(attempt) re-waited on a model that had already gone quiet")
            }
        }

        // The free tier counts five requests a minute *per model*. Backing off on the model
        // that just 429'd means sleeping for eight seconds against a sixty-second window, then
        // hitting the same wall — while the next model in the chain sat there unused.
        test("a rate limit switches model immediately instead of sleeping on the same one") {
            for attempt in 0...2 {
                expectEqual(RetryPolicy.decide(for: .rateLimited(requestsPerMinute: 5),
                                               attempt: attempt),
                            .fallBackToNextModel,
                            "attempt \(attempt) slept on a model whose minute had not expired")
            }
            // Contention is different: it clears in seconds, so waiting on the same model is
            // the cheap answer there and the fallback stays a last resort.
            guard case .retrySameModel = RetryPolicy.decide(for: .serviceUnavailable(highDemand: true),
                                                             attempt: 0) else {
                expect(false, "high demand should retry the same model before switching")
                return
            }
        }

        test("backoff grows with attempt and stays under the cap") {
            let first = RetryPolicy.backoff(attempt: 0, base: 1, cap: 8)
            let third = RetryPolicy.backoff(attempt: 3, base: 1, cap: 8)
            let huge = RetryPolicy.backoff(attempt: 12, base: 1, cap: 8)
            expect(third > first, "backoff should grow: \(first) vs \(third)")
            expect(huge <= 8, "backoff exceeded the cap: \(huge)")
            expect(first > 0)
        }

        test("backoff includes jitter so colliding clients spread out") {
            let samples = (0..<40).map { _ in RetryPolicy.backoff(attempt: 2, base: 1, cap: 8) }
            expect(Set(samples.map { String(format: "%.4f", $0) }).count > 1,
                   "no jitter observed across 40 samples")
        }

        // MARK: Messages

        test("failures never claim to have produced an answer") {
            let messages: [RetryPolicy.Failure] = [
                .serviceUnavailable(highDemand: true),
                .rateLimited(requestsPerMinute: 5),
                .unauthorised,
                .badRequest(detail: "x"),
                .network(detail: "timed out"),
                .unknown(statusCode: 500, detail: "y"),
            ]
            for f in messages {
                let m = RetryPolicy.userFacingMessage(for: f).lowercased()
                expect(!m.contains("here's") && !m.contains("here is"),
                       "message should not imply success: \(m)")
                expect(!m.isEmpty)
            }
        }

        // MARK: Rate limiter

        test("rate limiter blocks after the free-tier cap and recovers after the window") {
            var clock = Date(timeIntervalSince1970: 1_700_000_000)
            let limiter = RateLimiter(limit: 5, window: 60, now: { clock })

            for _ in 0..<5 { limiter.consume() }
            expect(limiter.delayUntilAvailable() > 0, "6th request should be blocked")

            // Nothing ages out yet.
            clock = clock.addingTimeInterval(30)
            expect(limiter.delayUntilAvailable() > 0, "still inside the window")

            // All five age out.
            clock = clock.addingTimeInterval(31)
            expectEqual(limiter.delayUntilAvailable(), 0, "should be free again after the window")
        }

        test("rate limiter unblocks progressively as the window slides") {
            var clock = Date(timeIntervalSince1970: 1_700_000_000)
            let limiter = RateLimiter(limit: 5, window: 60, now: { clock })
            for _ in 0..<5 { limiter.consume() }

            expect(limiter.delayUntilAvailable() > 55, "should wait for the oldest entry")
            clock = clock.addingTimeInterval(10)
            let after10 = limiter.delayUntilAvailable()
            expect(after10 < 55 && after10 > 40, "10s later should wait ~50s, got \(after10)")
        }

        test("a fresh rate limiter never blocks") {
            let limiter = RateLimiter(limit: 5, window: 60)
            expectEqual(limiter.delayUntilAvailable(), 0)
        }

        // The turn log is the only place a slow answer can be diagnosed after the fact, and it
        // must not have to print an associated value that could carry the user's screen text.
        test("each failure kind has a one-word log name") {
            expectEqual(RetryPolicy.Failure.serviceUnavailable(highDemand: true).logName, "contended")
            expectEqual(RetryPolicy.Failure.rateLimited(requestsPerMinute: 5).logName, "rate limited")
            expectEqual(RetryPolicy.Failure.network(detail: "boom").logName, "network")
            expectEqual(RetryPolicy.Failure.badRequest(detail: "boom").logName, "bad request")
            expect(RetryPolicy.Failure.unknown(statusCode: nil, detail: "x").logName == "unknown")
        }

        // `classify` has no word for "the user stopped the turn", so a cancellation lands as
        // `.unknown` — and `.unknown` is retried. That is the bug this predicate exists to catch
        // before the classifier runs: pressing stop used to make Chunks answer a request for
        // silence by opening a second stream and logging it as a model failure.
        test("a cancellation is recognised as the end of a turn, not a model failure") {
            let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            expect(RetryPolicy.isCancellation(cancelled),
                   "URLSession reports a task it killed as NSURLErrorCancelled; the gateway's "
                        + "stream path is exactly where that arrives")
            expect(RetryPolicy.isCancellation(CancellationError()),
                   "a Swift-level cancel must end the turn too")

            expect(!RetryPolicy.isCancellation(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
                "a timeout is the model being slow, and the user did not ask for silence")
            expect(!RetryPolicy.isCancellation(
                NSError(domain: "com.example.other", code: 1)),
                  "an unrelated error must not be swallowed as a cancellation")
        }
    }
}
