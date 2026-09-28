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

        test("rate limiting backs off far longer than high demand") {
            let demand = RetryPolicy.decide(for: .serviceUnavailable(highDemand: true), attempt: 0)
            let limited = RetryPolicy.decide(for: .rateLimited(requestsPerMinute: 5), attempt: 0)
            guard case .retrySameModel(let a) = demand, case .retrySameModel(let b) = limited else {
                expect(false, "expected both to retry same model")
                return
            }
            expect(b > a, "rate-limit backoff (\(b)s) should exceed high-demand backoff (\(a)s)")
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
    }
}
