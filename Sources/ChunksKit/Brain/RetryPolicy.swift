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
    public static func decide(for failure: Failure,
                              attempt: Int,
                              maxAttemptsPerModel: Int = 3) -> Decision {

        switch failure {

        case .serviceUnavailable:
            // Contention is per-model, so moving on is usually faster than waiting.
            if attempt >= maxAttemptsPerModel - 1 { return .fallBackToNextModel }
            return .retrySameModel(afterSeconds: backoff(attempt: attempt, base: 0.6, cap: 4.0))

        case .rateLimited:
            // The cap is per model per minute, so this model is still full after an eight-second
            // wait — but every other model in the chain has its own untouched window. Switching
            // is free; waiting here is the one thing that provably cannot help. Measured: a turn
            // that retried the 429'd model twice spent 12.6s asleep before moving on.
            return .fallBackToNextModel

        case .network:
            if attempt >= maxAttemptsPerModel - 1 { return .fallBackToNextModel }
            return .retrySameModel(afterSeconds: backoff(attempt: attempt, base: 1.0, cap: 8.0))

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
