import Foundation

/// Decides what to do when a brain call fails.
///
/// This exists because the free tier is measurably unreliable: during Phase 0 probing,
/// `503 high demand` came back on roughly half of all requests to the newest flash models,
/// and the free tier caps at **5 requests/minute** per model. Both are normal conditions,
/// not errors — a turn that gives up on a 503 is a bug.
///
/// Retries are **not** performed here. This type only classifies; the caller owns the
/// clock, so it stays testable with no sleeping and no networking.
public enum RetryPolicy: Sendable {

    /// How much of the turn's remaining time one attempt may take.
    ///
    /// A slice, not the whole budget. Handing a model the turn's full deadline means the first one
    /// that refuses slowly keeps it: measured 2026-10-23, `gemini-3.6-flash` held a turn for 64s,
    /// the chain said "switching away from it", and then "budget spent — 4 model(s) left untried".
    /// Dividing what is left by the models still to come gives every one a chance to answer inside
    /// the wait the user agreed to.
    ///
    /// The floor is there because a model needs about six seconds to answer a real screen turn at
    /// all — a 2-second slice is a request that cannot succeed, and asking it wastes the slot.
    ///
    /// A spent budget is **not** a small remaining budget. The floor exists to stop a healthy turn
    /// from handing a model two seconds; it must not hand one eight more seconds after the person has
    /// already been kept too long. Measured 2026-10-31 on his Mac against a 60s budget: three turns
    /// died at 62s, 103s and 120s, because the retry loop ran attempts two and three of one model on
    /// floored slices after the budget was gone. `0` is the caller's signal to stop asking.
    public static func attemptSlice(remaining: TimeInterval, modelsLeft: Int) -> TimeInterval {
        guard remaining > 0 else { return 0 }
        return max(minimumAttemptSeconds, remaining / Double(max(1, modelsLeft)))
    }

    /// The shortest slice worth asking a model for.
    public static let minimumAttemptSeconds: TimeInterval = 8

    /// A 503 that arrives later than this is not "high demand, ask again in a second".
    ///
    /// The retry rule was measured against fast refusals — a contended flash model says so in under
    /// two seconds and clears inside ten. A refusal that took a minute and a half means the request
    /// was never going to be answered, and the next model in the chain is the only thing that can
    /// still save the turn.
    public static let slowContentationSeconds: TimeInterval = 10

    /// Why a call failed.
    public enum Failure: Equatable, Sendable {
        /// Contention at the provider. Retry, then fall back to another model.
        case serviceUnavailable(highDemand: Bool)
        /// Free-tier per-minute cap. Back off and retry the *same* model; falling back
        /// would only hit the same per-model limit.
        case rateLimited(requestsPerMinute: Int)
        /// The API key is missing, wrong, or lacks permission. Retrying cannot help.
        case unauthorised
        /// Malformed request — usually our bug. Retrying cannot help.
        case badRequest(detail: String)
        /// Network dropped. Retry.
        case network(detail: String)
        /// Anything unrecognised. Do not retry blindly.
        case unknown(statusCode: Int?, detail: String)

        /// One word for the log, so a slow turn reads as "flash failed after 20.0s — network"
        /// rather than a dumped associated value that may carry the user's screen text.
        public var logName: String {
            switch self {
            case .serviceUnavailable: return "contended"
            case .rateLimited:        return "rate limited"
            case .unauthorised:       return "unauthorised"
            case .badRequest:         return "bad request"
            case .network:            return "network"
            case .unknown:            return "unknown"
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Wait `seconds`, then try the same model again.
        case retrySameModel(afterSeconds: Double)
        /// Give up on this model, try the next one in the chain immediately.
        case fallBackToNextModel
        /// Surface the failure. Do not retry.
        case fail
    }

    /// Attempt is 0-based.
    ///
    /// `secondsToFail` is how long the model took to produce this error. It decides whether a 503 is
    /// still the failure the retry rule was written for.
    /// Whether a **second API key** could plausibly clear this failure.
    ///
    /// The free tier is capped a few requests a minute *per model per key*, which is why the chain
    /// already switches model on a 429 — every other model has its own untouched budget. A second key
    /// is the same fact one level up: its own budget, untouched. Measured 2026-11-03, the user got
    /// "Hit the free-tier rate limit" on an ordinary question after one chain walk.
    ///
    /// Only a budget answers true. A wrong key (`.unauthorised`) is wrong on both keys; a malformed
    /// request (`.badRequest`) is our bug and repeating it costs another thirty seconds; a dead
    /// network (`.network`) has no key to blame. Trying a backup for those would turn one honest
    /// failure into two.
    public static func backupKeyHelps(_ failure: Failure) -> Bool {
        switch failure {
        case .serviceUnavailable, .rateLimited:
            return true
        case .unauthorised, .badRequest, .network, .unknown:
            return false
        }
    }

    public static func decide(for failure: Failure,
                              attempt: Int,
                              maxAttemptsPerModel: Int = 3,
                              secondsToFail: TimeInterval = 0) -> Decision {

        switch failure {

        case .serviceUnavailable:
            // Contention is per-model, so a *fast* 503 is worth asking again: it clears in seconds
            // and every model has its own budget. A 503 that took a minute and a half to arrive is
            // not that failure wearing a hat — it is a model that spent the whole window and then
            // said no, and asking it again spends the turn. Measured 2026-10-23: one contended
            // `gemini-3.6-flash` ran three ~90s tries inside a single turn and the turn died at 202s
            // with four healthy models untried.
            if secondsToFail > slowContentationSeconds { return .fallBackToNextModel }
            if attempt >= maxAttemptsPerModel - 1 { return .fallBackToNextModel }
            return .retrySameModel(afterSeconds: backoff(attempt: attempt, base: 0.6, cap: 4.0))

        case .rateLimited:
            // The cap is per model per minute, so this model is still full after an eight-second
            // wait — but every other model in the chain has its own untouched window. Switching
            // is free; waiting here is the one thing that provably cannot help. Measured: a turn
            // that retried the 429'd model twice spent 12.6s asleep before moving on.
            return .fallBackToNextModel

        case .network:
            // Switch, do not retry. A network failure here is the idle timeout firing — the
            // connection was made and no byte arrived — and a model that has already spent 20
            // seconds saying nothing will not find its voice on a second attempt. Retrying it is
            // what cost a real turn 271 of its 281 seconds on 2026-10-15: three attempts on
            // `gemini-3.8-flash`, each allowed to run its full timeout, while the model that
            // eventually answered needed 6 seconds.
            return .fallBackToNextModel

        case .badRequest(let detail) where rejectsThinkingLevel(detail):
            // One retry, and the caller drops the field between the two attempts. Deciding this here
            // rather than letting a 400 be fatal is the difference between "Could not answer" and an
            // answer: the request is wrong in exactly one key, and that key is one this app added for
            // speed on the models that think. A second rejection is a real bad request, and fails.
            return attempt >= 1 ? .fail : .retrySameModel(afterSeconds: 0)

        case .unauthorised, .badRequest:
            return .fail

        case .unknown:
            // One retry on an unrecognised status catches transient gateway noise without
            // looping on something deterministic.
            if attempt >= 1 { return .fail }
            return .retrySameModel(afterSeconds: backoff(attempt: attempt, base: 1.0, cap: 2.0))
        }
    }

    /// Exponential backoff with full jitter.
    ///
    /// Jitter matters more than usual here: when a whole fleet of users hits the same
    /// contended model at once, undithered backoff keeps them colliding.
    public static func backoff(attempt: Int, base: Double, cap: Double) -> Double {
        let exponential = base * pow(2.0, Double(max(0, attempt)))
        let capped = min(exponential, cap)
        return Double.random(in: capped / 2.0...capped)
    }

    /// Classify an HTTP status from a provider.
    public static func classify(statusCode: Int, body: String = "") -> Failure {
        let detail = body.prefix(300).description
        switch statusCode {
        case 401, 403:
            return .unauthorised
        case 400, 422:
            return .badRequest(detail: detail)
        case 429:
            // Gemini reports the free-tier cap as RESOURCE_EXHAUSTED; the message names it.
            let isFreeTierCap = detail.lowercased().contains("rate limit")
            return .rateLimited(requestsPerMinute: isFreeTierCap ? 5 : 60)
        case 500...599:
            let highDemand = detail.lowercased().contains("high demand")
            return .serviceUnavailable(highDemand: highDemand)
        default:
            return .unknown(statusCode: statusCode, detail: detail)
        }
    }

    /// Classify a thrown URLSession error.
    public static func classify(error: Error) -> Failure {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .unknown(statusCode: nil, detail: nsError.localizedDescription) }
        switch nsError.code {
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            return .network(detail: nsError.localizedDescription)
        default:
            return .unknown(statusCode: nil, detail: nsError.localizedDescription)
        }
    }

    /// Whether an error means "someone stopped this turn" rather than "the model answered badly".
    ///
    /// A URL task cancelled by a Swift task cancellation surfaces as `NSURLErrorCancelled`, which
    /// `classify` can only call `.unknown` — and `.unknown` retries. So the user pressing stop was
    /// being logged as a model failure, and Chunks responded to a request for silence by starting
    /// a second stream. Nothing here is a policy decision: a cancelled turn is over.
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Whether a rejected request is rejecting the *thinking field* rather than the request itself.
    ///
    /// Measured 2026-10-29 on the user's own screen: every live request now carries
    /// `generation_config.thinking_level = "minimal"` — added because it halves served-turn seconds on
    /// the models that deliberate — and `gemini-3.1-flash-lite-preview` answered all of them with
    /// `400 Thinking level THINKING_LEVEL_MINIMAL is not supported for this model`. A 400 was fatal, so
    /// the card said "Could not answer" about a question the model could have answered in seconds.
    /// Three spellings because the API names the field, the enum value and the concept in different
    /// places in one message; nothing about *which* model, so the next one that draws the line is
    /// handled by the same rule.
    public static func rejectsThinkingLevel(_ detail: String) -> Bool {
        let text = detail.lowercased()
        return text.contains("thinking_level") || text.contains("thinking level")
            || text.contains("thinkinglevel")
    }

    /// A message worth showing the user. Deliberately honest about *what* went wrong —
    /// Chunks never pretends a failed turn produced an answer.
    public static func userFacingMessage(for failure: Failure) -> String {
        switch failure {
        case .serviceUnavailable:
            return "The model is busy right now. Chunks tried the other available models and they were busy too."
        case .rateLimited:
            return "Hit the free-tier rate limit (a few requests a minute). Try again in a moment."
        case .unauthorised:
            return "The Gemini API key was rejected. Check it in Settings."
        case .badRequest(let detail):
            return "The request was rejected: \(detail)"
        case .network(let detail):
            return "Couldn't reach the model — check your connection. (\(detail))"
        case .unknown(_, let detail):
            return "Something went wrong talking to the model: \(detail)"
        }
    }
}

// MARK: - Rate limiting

/// Client-side token bucket for the free tier's per-model request cap.
///
/// The provider enforces 5 requests/minute per model; this keeps Chunks from walking into
/// that wall in the first place. Shared by interactive turns and background automations, so
/// a scheduled job can't starve the person using the app.
public final class RateLimiter: @unchecked Sendable {
    private let limit: Int
    private let window: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var timestamps: [Date] = []

    public init(limit: Int = ProviderRegistry.freeTierRequestsPerMinute,
                window: TimeInterval = 60,
                now: @escaping () -> Date = Date.init) {
        self.limit = limit
        self.window = window
        self.now = now
    }

    /// Seconds until another request is allowed; `0` if one is allowed now.
    public func delayUntilAvailable() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        trimLocked()
        guard timestamps.count >= limit, let oldest = timestamps.first else { return 0 }
        let elapsed = now().timeIntervalSince(oldest)
        return max(0, window - elapsed)
    }

    /// Record that a request is being made right now.
    public func consume() {
        lock.lock()
        defer { lock.unlock() }
        trimLocked()
        timestamps.append(now())
    }

    private func trimLocked() {
        let cutoff = now().addingTimeInterval(-window)
        timestamps.removeAll { $0 <= cutoff }
    }
}
