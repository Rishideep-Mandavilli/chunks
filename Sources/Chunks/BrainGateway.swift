//
//  BrainGateway.swift
//  Chunks
//
//  The Gemini client, in the shape farzaa/clicky's ClaudeAPI expects.
//
//  Why a shim rather than a rewrite of CompanionManager: clicky's call site is
//  `analyzeImageStreaming(images:systemPrompt:conversationHistory:userPrompt:onTextChunk:)`
//  and it does not care who answers. Keeping that signature means the streaming, the point
//  parsing, the TTS and the cursor animation all work untouched, and the swap is one file.
//
//  What genuinely had to change, and why:
///
///  * **Endpoint.** Gemini's Interactions API, not Anthropic's Messages API. `generateContent`
///    is retired for new models; the Interactions API also lets us set `store: false`, which
///    is the difference between "Google does not retain your screenshot" and "we think it
///    doesn't".
///  * **Retries.** The free tier returns `503 high demand` on roughly half of requests
///    against the newest flash models and caps at 5 req/min. clicky's Claude path has no
///    equivalent problem, so there is nothing to port — this is new, and a turn that gives
///    up on a 503 is a bug rather than bad luck.
///  * **Fallback.** Five models, walked in order when one is contended.
///

import ChunksKit
import Foundation

/// A labelled screenshot, as clicky's pipeline assembles them.
struct LabelledImage {
    let data: Data
    let label: String
}

/// Whether any attempt of a turn has already put words on the card. Read at each attempt start to
/// decide whether the shell's streamer must be reset before a new model writes (AUDIT.md B-03).
/// Locked: the chunk callback runs on the main actor while the chain loop runs beside it.
private final class EmittedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var any: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
}

enum BrainError: Error, CustomStringConvertible {
    case missingKey
    case noCapableModel(String)
    case http(statusCode: Int, body: String)
    case transport(String)
    /// A model that answered with a well-formed, empty reply. Distinct from a transport failure:
    /// the server is healthy and another model on it may answer fine, which is the difference
    /// between trying the next one and giving up.
    case localModelWasSilent(String)
    case keychain(OSStatus)
    /// The chain spent its whole budget without an answer. Kept separate from a model failure
    /// because the honest statement differs: nothing refused, everything was slow, and Chunks
    /// stopped deliberately rather than making him wait out the rest of the list.
    case turnBudgetExceeded(used: Double, models: Int)

    /// Whether the backup key is worth a second walk of the chain.
    ///
    /// Classified through `RetryPolicy`, the same table the model-switching rules use, so the two
    /// cannot disagree about what a status code means. Anything that is not a budget is not retried:
    /// a second key would answer the same 401, the same 400, the same dead socket, and the turn would
    /// end twice as late with the same words on the card.
    var worthBackupRetry: Bool {
        switch self {
        case .http(let status, let body):
            return RetryPolicy.backupKeyHelps(RetryPolicy.classify(statusCode: status, body: body))
        case .missingKey, .noCapableModel, .transport, .localModelWasSilent, .keychain,
             .turnBudgetExceeded:
            return false
        }
    }

    var description: String {
        switch self {
        case .missingKey:
            return "No Gemini API key set. Add one from the Chunks menu."
        case .noCapableModel(let detail):
            return detail
        case .http(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = RetryPolicy.userFacingMessage(
                for: RetryPolicy.classify(statusCode: code, body: trimmed))
            return trimmed.isEmpty ? summary : "\(summary) — server said: \(trimmed.prefix(300))"
        case .transport(let detail):
            return "Couldn't reach the model: \(detail)"
        case .localModelWasSilent(let model):
            // Wording matters: the server answered perfectly well, so "couldn't reach" would send
            // the user off to check Ollama is running when the real problem is one model's output
            // format.
            return "\(model) answered with nothing to show. Chunks tried the other models on this Mac."
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Could not read the API key from the Keychain: \(detail)."
        case .turnBudgetExceeded(let used, let models):
            return "The model gave nothing in \(Int(used))s across \(models) attempt"
                + "\(models == 1 ? "" : "s"). Ask again in a moment, or switch to a model on this Mac."
        }
    }
}

/// Wraps the Gemini Interactions API behind clicky's expected interface.
final class BrainGateway {

    /// Kept for compatibility with the `selectedModel` preference clicky exposes. Chunks is
    /// free-tier only, so the value is a model in `ProviderRegistry.geminiFreeModels` and an
    /// unrecognised one falls back to the default rather than failing.
    var model: String {
        get { _model }
        set { _model = newValue }
    }
    private var _model = ProviderRegistry.defaultFreeModelID

    /// `workerBaseURL` in clicky pointed at its Cloudflare proxy. Chunks talks to Google
    /// directly, so nothing is proxied and nothing about the request passes through a
    /// server we do not control.
    private let session: URLSession

    /// One bucket per model, because that is how the free tier counts: five requests a minute
    /// *per model*. With a single shared bucket, one contended turn walking three attempts
    /// across three models burned nine tokens out of five — and every turn after it then slept
    /// out the rest of the 60-second window before sending a request that was going to fail
    /// anyway. That wait, not the model, is most of what "takes minutes" meant.
    private var rateLimiters: [String: RateLimiter] = [:]

    /// Models this process has already been told refuse the `thinking_level` field.
    ///
    /// The recognition stays message-driven, never name-driven — a model id is not evidence that a
    /// deployment changed. What is cached is the *fact that it was refused*, which the next request
    /// to the same model cannot unlearn. Measured 2026-10-31 on his Mac: `gemini-3.8-flash` answered
    /// `400 Thinking level THINKING_LEVEL_MINIMAL is not supported` on every turn it was reached, and
    /// because the flag was reset with the turn, each one paid ~1.7s and a wasted request to find
    /// that out again before the retry that works. Forgetting this on relaunch is the safe direction:
    /// a model Google later teaches to accept the field simply keeps answering undieted until the
    /// next launch, rather than a model that never accepts it being asked forever.
    private var thinkingRejected: Set<String> = []

    private func limiter(for modelID: String) -> RateLimiter {
        if let existing = rateLimiters[modelID] { return existing }
        let fresh = RateLimiter()
        rateLimiters[modelID] = fresh
        return fresh
    }

    /// Wall-clock ceiling for walking the whole fallback chain. A healthy free-tier turn on this
    /// account measures 6.6–12.7s, so this only ever fires on the pathological case.
    static let turnBudgetSeconds: Double = 60

    /// How long a turn will stand still for a model's per-minute bucket before walking on.
    ///
    /// Short on purpose: a sub-second refill is free, and a ten-second one is the whole wait the
    /// next model could have spent answering instead.
    static let maximumBucketWait: TimeInterval = 3

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // `timeoutIntervalForRequest` is an *idle* timeout: it resets on every byte, so it
        // bounds the wait for the model's first token and never cuts off a stream that is
        // already talking. At 90s a contended model could hold the user silent for a minute
        // and a half before we were allowed to try another one.
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    /// Same signature and return shape as clicky's `ClaudeAPI.analyzeImageStreaming`.
    ///
    /// The `[0,0,0]` array in the return type is the original, deliberately unused; the
    /// caller binds it to `_`.
    ///
    /// **This is the wrapper that spends the backup key.** Measured 2026-11-03: a free-tier Gemini key
    /// is capped at a few requests a minute *per model per key*, a chain walk burns several of them,
    /// and the user got "Could not answer — Hit the free-tier rate limit… server said: Rate…" on an
    /// ordinary question. That is a budget, not a fault, and a second key carries its own untouched
    /// one — the same reasoning `RetryPolicy` already uses to switch *model* on a 429. Only a quota
    /// refusal qualifies: a 400 or a dead network would be repeated by the second key, and the turn's
    /// own wall-clock budget is never spent twice, because making him wait out the chain a second time
    /// is exactly the minute-long turn these rules exist to end.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void,
        onFreshAttempt: (@MainActor @Sendable () -> Void)? = nil
    ) async throws -> (text: String, duration: TimeInterval) {
        // Stamped per turn, not at gateway init: the gateway lives as long as the app, so an
        // init-time stamp made the backup-key retry unreachable after the first minute of every
        // session (AUDIT.md B-01). The bound is still the turn's own promise, never a fresh minute.
        let turnStarted = Date()
        do {
            return try await turn(images: images, systemPrompt: systemPrompt,
                                  history: conversationHistory, userPrompt: userPrompt,
                                  backupKey: false, onTextChunk: onTextChunk,
                                  onFreshAttempt: onFreshAttempt)
        } catch {
            guard (error as? BrainError)?.worthBackupRetry == true,
                  let backup = KeychainStore.backupGeminiKey(),
                  // The same key twice is the same budget twice, and the second walk would just
                  // spend another thirty seconds proving it.
                  backup != (try? KeychainStore.geminiKey()),
                  // The turn budget is the user's wait, not the chain's; a retry would double it.
                  Date().timeIntervalSince(turnStarted) < Self.turnBudgetSeconds
            else { throw error }
            Log.write("turn: primary key refused for quota — asking the same chain with the backup key")
            // The first walk may already have put half a reply on the card; the second walk must
            // replace it, not append to it (AUDIT.md B-03).
            await onFreshAttempt?()
            return try await turn(images: images, systemPrompt: systemPrompt,
                                  history: conversationHistory, userPrompt: userPrompt,
                                  backupKey: true, onTextChunk: onTextChunk,
                                  onFreshAttempt: onFreshAttempt)
        }
    }

    private func turn(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        history: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        backupKey: Bool,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void,
        onFreshAttempt: (@MainActor @Sendable () -> Void)? = nil
    ) async throws -> (text: String, duration: TimeInterval) {

        let started = Date()

        // Offline goes first, and goes before the Keychain read: a Mac with no Gemini key stored
        // at all must still be able to answer from a model on this machine. Returns nil when the
        // cloud is chosen, which keeps the Gemini path below exactly as it was — the surest way
        // to break a working provider while adding a second one is to refactor the first.
        if let local = try await localTurnIfNeeded(images: images,
                                                   systemPrompt: systemPrompt,
                                                   history: history,
                                                   userPrompt: userPrompt,
                                                   started: started,
                                                   onTextChunk: onTextChunk) {
            return local
        }

        let key: String
        if backupKey, let backup = KeychainStore.backupGeminiKey() {
            key = backup
        } else {
            key = try KeychainStore.geminiKey()
        }
        let registry = ProviderRegistry()

        // Multi-image turns (clicky sends one labelled capture per display) are always
        // vision turns, so the chain is restricted to models verified to read images.
        let (chain, warning) = registry.resolve(
            provider: ProviderRegistry.gemini,
            preferred: model,
            needsVision: !images.isEmpty)
        if let warning {
            NSLog("[Chunks] %@", warning)
        }
        guard !chain.isEmpty else { throw BrainError.noCapableModel(warning ?? "No model available.") }

        var lastError: Error?
        var attempts = 0
        let chainStarted = Date()
        // The turn's own expiry, carried *into* the stream rather than checked only between models.
        // `timeoutInterval = 20` is an idle bound and a server that trickles bytes resets it forever,
        // which is how one contended model ran three ~90s tries inside a single 202s turn on
        // 2026-10-23 while four healthy models went untried.
        //
        // Measured from the moment the user asked, not the moment the chain starts. Measured
        // 2026-10-31 in `--probe-protocol`: two turns reported 126.3s and 44.0s while the log shows
        // the chain itself took 28s and 16s of that — the rest went before the first request, on a
        // Keychain read and provider resolve made slow by the screen going locked. A budget that
        // starts after the wait it is meant to bound is not a bound, and the promise in the docs is
        // "the whole chain carries turnBudgetSeconds", which is the user's wait, not a slice of it.
        let chainDeadline = started.addingTimeInterval(Self.turnBudgetSeconds)
        let preChain = chainStarted.timeIntervalSince(started)
        if preChain > 1 {
            // Said out loud because it is invisible otherwise: the chain's log lines would read as a
            // slow model while the minute had already gone before any request was built.
            Log.write("turn: \(String(format: "%.1f", preChain))s spent before the chain "
                + "(offline check, key read, provider resolve) — \(Int(Self.turnBudgetSeconds - preChain))s "
                + "left of the turn's budget")
        }
        /// Every model this turn has already been answered by, or refused by.
        var asked = Set<String>()
        // Whether any attempt has put words on the card. A failover after a mid-stream drop must
        // reset the shell's streamer before the next model writes, or two models share one card and
        // one plan (AUDIT.md B-03). Locked because the chunk callback runs on the main actor while
        // this loop runs beside it.
        let emitted = EmittedFlag()
        let chunk: @MainActor @Sendable (String) -> Void = { delta in
            emitted.set()
            onTextChunk(delta)
        }
        Log.write("turn: chain \(chain.map(\.id).joined(separator: " > "))"
            + " · \(images.count) image(s), \(images.reduce(0) { $0 + $1.data.count } / 1024) KB"
            + " · text \(userPrompt.count + systemPrompt.count) chars")
        modelLoop: for (index, candidate) in chain.enumerated() {
            if asked.contains(candidate.id) {
                // The hedge asked this model alongside the first one, and its failure is already
                // known. Asking it a second time costs a full timeout — measured 15.5s on
                // 2026-10-23, on a turn that then took 51s to answer a question worth 9.
                Log.write("turn: skipping \(candidate.id) — the hedge already asked it")
                continue
            }
            attempts = asked.count + 1
            // Some models reject the thinking field outright. Measured 2026-10-29 on his own screen:
            // `gemini-3.1-flash-lite-preview` answered every request with 400 `Thinking level
            // THINKING_LEVEL_MINIMAL is not supported for this model`, and a 400 is fatal to a turn —
            // so the field this app added to halve latency killed the reply instead. The retry that
            // can clear is the one that changes the request, not the one that changes the model: the
            // first rejection drops the field for this model and asks the same model again.
            var thinkingLevelAccepted = !thinkingRejected.contains(candidate.id)
            // Stop before the wait outruns the person waiting. Measured 2026-10-15: a turn spent
            // 281s because one model was allowed to run its full timeout three times, and answered
            // in the last 6 of them. Anything still untried at the budget is a model that was not
            // going to reply in time either, and an honest failure at 60s beats an answer he has
            // walked away from.
            let spentSoFar = Date().timeIntervalSince(started)
            if spentSoFar > Self.turnBudgetSeconds {
                Log.write("turn: budget spent after \(String(format: "%.0f", spentSoFar))s — "
                    + "\(chain.count - index) model(s) left untried")
                throw BrainError.turnBudgetExceeded(used: spentSoFar, models: index)
            }
            let attemptStarted = Date()
            for attempt in 0..<3 {
                // Stay under the free tier's per-model cap rather than walking into it.
                let limiter = limiter(for: candidate.id)
                let wait = limiter.delayUntilAvailable()
                if wait > Self.maximumBucketWait {
                    // The free tier's window is a minute wide and a turn is not. Waiting 19s for a
                    // bucket to refill — which the log shows this line did five times — is exactly
                    // the dead time the 429 rule already refuses to pay for, and every other model
                    // on the key has its own untouched budget.
                    Log.write("turn: \(candidate.id) at its per-minute cap for "
                        + "\(String(format: "%.1f", wait))s — skipping it, not waiting")
                    lastError = BrainError.transport("\(candidate.id) is at its requests-per-minute cap")
                    continue modelLoop
                }
                if wait > 0 {
                    Log.write("turn: \(candidate.id) at its per-minute cap, waiting "
                        + "\(String(format: "%.1f", wait))s")
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                limiter.consume()

                let tryStarted = Date()
                // This attempt's own expiry — a slice of what is left, not the whole budget, so a
                // model that refuses slowly cannot keep the turn from the rest of the chain.
                let slice = RetryPolicy.attemptSlice(
                    remaining: chainDeadline.timeIntervalSince(tryStarted),
                    modelsLeft: chain.count - index)
                // The budget check above sits at the *model* boundary, and a model gets three
                // attempts inside its own turn through the loop. Without this, a slow refusal spent
                // the 60s promise twice over: measured 2026-10-31, one model failed at 34.6s, was
                // retried without the thinking field on a fresh floored slice, and held the turn
                // another 66.3s — 120s for a turn that had already run out of budget.
                guard slice > 0 else {
                    let spent = Date().timeIntervalSince(started)
                    Log.write("turn: budget spent after \(String(format: "%.0f", spent))s mid-model "
                        + "— \(candidate.id) not asked again, \(chain.count - index) model(s) left untried")
                    throw BrainError.turnBudgetExceeded(used: spent, models: index)
                }
                let attemptDeadline = tryStarted.addingTimeInterval(slice)
                if emitted.any {
                    Log.write("turn: a previous attempt wrote part of this reply — resetting the card "
                        + "before \(candidate.id) writes")
                    await onFreshAttempt?()
                    emitted.reset()
                }
                do {
                    // The first model is asked alongside its successor if it goes quiet, because
                    // the wait to *discover* a contended model is serial today. Later hops keep
                    // the plain path: hedging every model would spend the free tier's per-minute
                    // budget on three copies of one question.
                    let text: String
                    if index == 0, let partner = chain.dropFirst().first {
                        asked.insert(candidate.id)
                        // The partner is marked only when it is actually asked. It stands down if
                        // the lead has already streamed, or if its own per-minute bucket is full —
                        // and marking it in advance skipped the healthy fallback for the whole
                        // turn, which after the reorder is `gemini-3.1-flash-lite`.
                        text = try await hedged(key: key, lead: candidate, partner: partner,
                                                systemPrompt: systemPrompt,
                                                history: history,
                                                userPrompt: userPrompt, images: images,
                                                deadline: attemptDeadline,
                                                asksForThinking: thinkingLevelAccepted,
                                                markAsked: { asked.insert($0) },
                        isAsked: { asked.contains($0) },
                                                onTextChunk: chunk)
                    } else {
                        asked.insert(candidate.id)
                        text = try await stream(
                            key: key,
                            model: candidate.id,
                            systemPrompt: systemPrompt,
                            history: history,
                            userPrompt: userPrompt,
                            images: images,
                            deadline: attemptDeadline,
                            asksForThinking: thinkingLevelAccepted,
                            onTextChunk: chunk)
                    }
                    let total = Date().timeIntervalSince(started)
                    Log.write("turn: served by \(candidate.id) in \(String(format: "%.1f", total))s"
                        + " (\(attempts) model(s) tried)")
                    // The tail of the reply, always. Every act tag the protocol has is required to
                    // come *last*, so "it said it would do it and did nothing" is a question about
                    // the end of the text — and until now the log recorded the size of the request
                    // and the time, never what came back. A reply ending mid-tag reads here as
                    // `<DONE_TITLE>Ready` with no closer, which is a different bug from a reply
                    // that chose not to emit a tag at all.
                    let tail = text.count > 160 ? "…" + String(text.suffix(160)) : text
                    Log.write("turn: reply ends \u{2023} " + tail.replacingOccurrences(
                        of: "\n", with: " ⏎ "))
                    return (text, total)
                } catch {
                    // Not a model failure. `NSURLErrorCancelled` arrives whenever the caller
                    // stops a turn, and classifying it as an unknown error retried a stream the
                    // user had just asked to end.
                    if RetryPolicy.isCancellation(error) || Task.isCancelled {
                        Log.write("turn: cancelled after "
                            + "\(String(format: "%.1f", Date().timeIntervalSince(started)))s on \(candidate.id)"
                            + " — not retried")
                        throw error
                    }
                    lastError = error
                    let waited = Date().timeIntervalSince(attemptStarted)
                    // The hedge asks two models at once, so the error arriving here may belong to
                    // neither of the ones this loop is nominally standing on. Unwrap it once: the
                    // decision is taken on the underlying failure, and every line that names a model
                    // names the one that actually refused — measured 2026-11-05, where a partner's
                    // 429 produced a line saying the lead had been rate limited, and the two lines in
                    // the same turn contradicted each other.
                    let refused: (model: String, error: Error)
                    if let hedged = error as? HedgedFailure {
                        refused = (hedged.model, hedged.underlying)
                    } else {
                        refused = (candidate.id, error)
                    }
                    let kind = classify(refused.error)
                    if case .badRequest(let detail) = kind,
                       RetryPolicy.rejectsThinkingLevel(detail), thinkingLevelAccepted {
                        thinkingLevelAccepted = false
                        // Remembered on a hop with one request behind its errors. The first hop is
                        // hedged — two models asked at once — and each refusal is now attributed to
                        // its own model inside `hedged`, which caches the diet for the one that
                        // actually rejected it. What is left here is the lead's own retry, where the
                        // field is dropped and the same model is asked again within the turn.
                        if index != 0 { thinkingRejected.insert(refused.model) }
                        // Said out loud, because a turn that succeeds on the second attempt looks like
                        // a slow turn in the log and a model that cannot be told to think less looks
                        // like a contended one.
                        Log.write("turn: \(refused.model) rejects thinking_level (\(detail.prefix(90))) "
                            + "— asking it again without the field")
                    }
                    let decision = RetryPolicy.decide(for: kind, attempt: attempt,
                                                      secondsToFail: Date().timeIntervalSince(tryStarted))
                    // The decision is logged, not guessed at: "failed, retrying" beside a line
                    // that then switched models is how a log stops being worth reading.
                    let action: String
                    switch decision {
                    case .retrySameModel(let after):
                        action = "retrying it in \(String(format: "%.1f", after))s"
                    case .fallBackToNextModel:
                        action = "switching model"
                    case .fail:
                        action = "failing the turn"
                    }
                    Log.write("turn: \(refused.model) failed after "
                        + "\(String(format: "%.1f", waited))s — \(kind.logName); \(action)"
                        + (refused.model == candidate.id ? ""
                           : " (the hedge\'s partner refused; this decision is being applied to "
                             + "\(candidate.id)\'s hop)"))
                    switch decision {
                    case .retrySameModel(let after):
                        try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                    case .fallBackToNextModel:
                        // Labelled, because a bare `break` here exits the switch and
                        // retries the model we just gave up on.
                        let next = index + 1 < chain.count ? chain[index + 1].id : "nothing"
                        Log.write("turn: switching away from \(candidate.id) to \(next)")
                        continue modelLoop
                    case .fail:
                        throw error
                    }
                }
            }
        }
        throw lastError ?? BrainError.noCapableModel("All models failed.")
    }

    // MARK: - Wire

    // MARK: - A brain on this Mac

    /// Run the turn against a local server, or return nil when the user has not chosen one.
    ///
    /// `nil` rather than a shared code path: the Gemini branch below has a measured fallback chain,
    /// per-model rate limits and retries tuned against a free tier that throttles half the time.
    /// None of that applies to a server on loopback, and pretending it does would either rate-limit
    /// a turn that cannot be rate-limited or fall back to the cloud behind the user's back.
    private func localTurnIfNeeded(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        history: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        started: Date,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)? {
        let storedID = BrainSettings.storedProviderID()
        guard let storedID, !storedID.isEmpty, storedID != ProviderRegistry.gemini.id else { return nil }

        guard let provider = ProviderRegistry.all.first(where: { $0.id == storedID }) else {
            Log.write("brain: \"\(storedID)\" is not a brain Chunks knows — asking Google Gemini instead.")
            return nil
        }
        guard provider.isLoopback else { return nil }

        let discovered = await LocalBrainDiscovery.descriptors(for: provider)
        let resolution = BrainSelection.resolve(
            storedProviderID: storedID,
            storedModelID: BrainSettings.storedModelID(),
            discoveredModels: [provider.id: discovered],
            needsVision: !images.isEmpty)
        if let notice = resolution.notice {
            Log.write("brain: \(notice)")
        }
        guard !resolution.isBlocked, let chosen = resolution.model else {
            throw BrainError.noCapableModel(
                resolution.notice ?? "\(provider.displayName) has no model that can answer this.")
        }

        var candidates: [BrainModel] = [chosen]
        candidates += resolution.provider.models.filter { model in model.id != chosen.id }
        var lastFailure: Error?
        for candidate in candidates {
            do {
                return try await runLocalTurn(provider: resolution.provider, model: candidate,
                                              systemPrompt: systemPrompt, history: history,
                                              userPrompt: userPrompt, images: images,
                                              silenceIsRetryable: true,
                                              started: started, onTextChunk: onTextChunk)
            } catch {
                lastFailure = error
                // One model refusing is not the server failing: `qwen3-vl:8b` here has a
                // 4,096-token context and rejects a screen turn that `gemma4:e2b-it-qat` answers.
                // Try the other local models, but stay on this Mac either way — a turn the user
                // asked to run offline never leaves the machine because one model declined it.
                let cause = Self.localCause(of: error)
                if LocalBrainError.isPerModel(cause) {
                    if let explained = Self.localExplanation(of: error) {
                        Log.write("brain: \(candidate.id) — \(explained)")
                    }
                    if candidates.count > 1 { Log.write("brain: trying the next model on this Mac") }
                    continue
                }
                throw error
            }
        }
        throw lastFailure ?? BrainError.noCapableModel(
            "\(resolution.provider.displayName) could not answer this turn.")
    }

    /// The request itself, against one named local model.
    private func runLocalTurn(
        provider: BrainProvider,
        model: BrainModel,
        systemPrompt: String,
        history: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        images: [(data: Data, label: String)],
        silenceIsRetryable: Bool,
        started: Date,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let isOllama = provider.id == "ollama"
        let requestURL: URL
        let body: [String: Any]

        if isOllama {
            requestURL = OllamaTransport.chatURL(baseURL: provider.baseURL)
            body = OllamaTransport.body(model: model.id,
                                        systemPrompt: systemPrompt,
                                        userPrompt: userPrompt,
                                        images: images,
                                               history: history,
                                               stream: true,
                                               numCtx: 16384,
                                               think: false)
        } else {
            requestURL = OpenAICompatibleTransport.chatCompletionsURL(baseURL: provider.baseURL)
            body = OpenAICompatibleTransport.body(model: model.id, systemPrompt: systemPrompt,
                                                  userPrompt: userPrompt, images: images,
                                                  history: history, stream: true,
                                                  thinking: nil)
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        for (field, value) in OpenAICompatibleTransport.headers(apiKey: nil) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Generous, because a local model evicted from RAM spends the first minute loading
        // weights — but bounded, because a model slower than this is not the answer the user is
        // waiting for and the next local model gets its turn instead.
        request.timeoutInterval = 75

        Log.write("brain: local turn → \(provider.displayName)/\(model.id)"
            + " · \(images.count) image(s), \(images.reduce(0) { $0 + $1.data.count } / 1024) KB")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw BrainError.transport("cannot reach \(provider.baseURL.host ?? "the local server")"
                + " — is it running? (\(error.localizedDescription))")
        }
        guard let http = response as? HTTPURLResponse else {
            throw BrainError.transport("no HTTP response from \(provider.displayName)")
        }
        guard (200..<300).contains(http.statusCode) else {
            var detail = ""
            for try await line in bytes.lines {
                detail += line + "\n"
                if detail.count > 4_000 { break }
            }
            // Logged, not just thrown: `--self-test` started a local turn, never finished it, and
            // the reason was only ever printed to stdout — which is unreadable for a process
            // started with `open`. A failure nobody can see is a failure nobody can fix.
            Log.write("brain: \(provider.displayName) answered \(http.statusCode) — "
                + detail.prefix(300).replacingOccurrences(of: "\n", with: " "))
            throw BrainError.http(statusCode: http.statusCode, body: detail)
        }

        var accumulated = ""
        var streamFailure: String?
        for try await line in bytes.lines {
            let events = isOllama
                ? OllamaTransport.parse(line: String(line))
                : OpenAIStreamParser.parse(line: String(line))
            for event in events {
                switch event {
                case .textDelta(let delta):
                    accumulated += delta
                    await onTextChunk(delta)
                case .error(let message):
                    streamFailure = message
                case .completed:
                    break
                }
            }
        }
        // An error with no text is a failure; an error after some text is a reply that stopped
        // early, and the user gets what arrived with the reason in the log.
        if accumulated.isEmpty {
            let reason = streamFailure ?? "\(model.id) answered with no text"
            Log.write("brain: local turn produced no text — \(reason)")
            throw BrainError.localModelWasSilent(model.id)
        }
        if let streamFailure {
            Log.write("brain: local stream ended early — \(streamFailure)")
        }
        // A reply with no `<SAY>` is all detail: the card fills and nothing is spoken. Several
        // small local models do this even when asked properly — measured with the production
        // prompt, not the terse diagnostic one that forbids tags — and the silence has to be
        // attributed to the model rather than left to look like a broken voice.
        if !accumulated.contains("<SAY>") {
            Log.write("brain: \(model.id) returned no spoken line for this reply, "
                + "so nothing will be said out loud.")
        }

        let total = Date().timeIntervalSince(started)
        Log.write("turn: served locally by \(model.id) in \(String(format: "%.1f", total))s")
        let tail = accumulated.count > 160 ? "…" + String(accumulated.suffix(160)) : accumulated
        Log.write("turn: reply ends ‣ " + tail.replacingOccurrences(of: "\n", with: " ⏎ "))
        return (accumulated, total)
    }

    /// The human sentence for a thrown error, when one is known.
    private static func localExplanation(of error: Error) -> String? {
        guard case BrainError.http(let status, let body) = error else { return nil }
        return LocalBrainError.explain(statusCode: status, body: body)
    }

    /// Map a thrown error onto the local-server failure it represents.
    private static func localCause(of error: Error) -> LocalBrainError.Cause {
        if case BrainError.http(let status, let body) = error {
            return LocalBrainError.classify(statusCode: status, body: body)
        }
        if case BrainError.localModelWasSilent = error { return .emptyAnswer }
        // A timeout is this model's slowness, not the server's death: the connection was made and
        // the answer never came. `qwen3-vl-16k` measured 91s for one screen turn on a 16 GB Mac
        // while `gemma4` answers the same turn in 14s, so the useful move is the next model.
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .timedOut
        }
        return .other
    }

    /// How long the first model gets to say *anything* before the second is asked alongside it.
    ///
    /// Measured 2026-10-18: a turn spent 8.3s waiting to learn that `gemini-3.6-flash` was
    /// contended, retried it as the policy says, and answered in 17.2s — for a reply that took six
    /// seconds to generate. The retry rule is right (a 503 clears in seconds on the same model, and
    /// every model has its own per-minute budget) and is untouched. What is wrong is that the
    /// *discovery* is serial: the user pays for a model's silence before anyone knows it is silent.
    static let hedgeAfterSeconds: Double = 3.5

    /// Who is allowed to put text in front of the user.
    ///
    /// Two models can be in flight during a hedge and exactly one may speak: a card that receives
    /// chunks from both interleaves two answers into one unreadable sentence, and a text-to-speech
    /// queue that hears both says both out loud. The first to produce a chunk owns the reply, and
    /// the other is cancelled mid-stream.
    final class StreamClaim: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: String?

        var isClaimed: Bool {
            lock.lock(); defer { lock.unlock() }
            return owner != nil
        }

        /// Whether `model` may emit this chunk. Once one model owns the reply, no other does.
        func claim(_ model: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if owner == nil { owner = model; return true }
            return owner == model
        }
    }

    /// A hedge failure with the model that produced it attached, so the retry decision and the log
    /// line that reports it can agree about who refused.
    struct HedgedFailure: Error, Sendable {
        let underlying: Error
        let model: String
    }

    private enum RaceResult: Sendable {
        case served(String, model: String)
        /// The model is named because the turn's next decision depends on which one refused: the
        /// hedge asks two at once, and a failure with no name on it cannot be cached, logged or
        /// skipped honestly.
        case failed(Error, model: String)
        /// The hedge stood down because the lead model started talking first.
        case abstained
    }

    /// Ask the lead model, and the partner as well if the lead has not streamed anything within
    /// `hedgeAfterSeconds`.
    ///
    /// Only the first hop of the chain uses this. Beyond that a turn would spend the free tier's
    /// per-minute budget on three copies of one question, and a model that arrives second in the
    /// chain has already been chosen as the fallback.
    private func hedged(key: String, lead: BrainModel, partner: BrainModel,
                        systemPrompt: String,
                        history: [(userPlaceholder: String, assistantResponse: String)],
                        userPrompt: String, images: [(data: Data, label: String)],
                        deadline: Date,
                        asksForThinking: Bool,
                        markAsked: @escaping (String) -> Void,
                        /// Whether this turn has already put a request to a model. The attempt loop
                        /// re-enters the hedge on a fast-503 retry, and re-dispatching the partner
                        /// each time spends that model's per-minute budget on copies of one question
                        /// — measured 2026-11-05 as three requests against one bucket in a turn.
                        isAsked: @escaping (String) -> Bool,
                        onTextChunk: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        let claim = StreamClaim()
        let started = Date()

        func gated(model id: String) -> @MainActor @Sendable (String) -> Void {
            { chunk in
                if claim.claim(id) { onTextChunk(chunk) }
            }
        }

        func ask(_ model: BrainModel) async -> RaceResult {
            do {
                let text = try await stream(key: key, model: model.id, systemPrompt: systemPrompt,
                                            history: history, userPrompt: userPrompt,
                                            images: images, deadline: deadline,
                                            asksForThinking: asksForThinking,
                                            onTextChunk: gated(model: model.id))
                return .served(text, model: model.id)
            } catch {
                return .failed(error, model: model.id)
            }
        }

        return try await withThrowingTaskGroup(of: RaceResult.self) { group in
            group.addTask { await ask(lead) }
            group.addTask {
                // The partner sleeps rather than being scheduled later, because a task group cannot
                // be added to from inside itself. If the lead has streamed by the time it wakes,
                // it stands down and costs nothing.
                try? await Task.sleep(nanoseconds: UInt64(Self.hedgeAfterSeconds * 1_000_000_000))
                if Task.isCancelled || claim.isClaimed { return .abstained }
                if isAsked(partner.id) {
                    Log.write("turn: \(partner.id) was already asked this turn — not hedged again")
                    return .abstained
                }
                // The partner has its own per-minute budget, and a hedge that walks into its cap
                // is worse than waiting: it spends the request and returns a 429. Standing down
                // keeps the lead's retry path exactly as the policy describes it.
                let partnerWait = self.limiter(for: partner.id).delayUntilAvailable()
                guard partnerWait <= 0 else {
                    Log.write("turn: \(partner.id) is at its per-minute cap — not hedged")
                    return .abstained
                }
                self.limiter(for: partner.id).consume()
                Log.write("turn: nothing from \(lead.id) after "
                    + "\(String(format: "%.1f", Self.hedgeAfterSeconds))s — asking \(partner.id) "
                    + "alongside it")
                return await ask(partner)
            }

            var failure: Error?
            var firstFailure: (model: String, error: Error)?
            while !group.isEmpty {
                let result = try await group.next()
                switch result {
                case .served(let text, let model):
                    group.cancelAll()
                    if claim.isClaimed {
                        Log.write("turn: served first by \(model) after "
                            + "\(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                    }
                    return text
                case .failed(let error, let model):
                    // Held, not thrown: the other request may still be about to answer, and the
                    // loser's error is not the user's problem if the winner arrives.
                    if failure == nil { failure = error }
                    if firstFailure == nil { firstFailure = (model, error) }
                    // Named, in the log and in the turn's memory. Measured 2026-11-05: twelve lines
                    // said `skipping gemini-3.1-flash-lite — the hedge already asked it` while the
                    // log held zero refusals for that model, because this branch knew the error and
                    // not its author. A skip nobody can trace reads as a dropped healthy fallback,
                    // and a thinking-level 400 that is never attributed is paid again next turn.
                    markAsked(model)
                    let kind = classify(error)
                    Log.write("turn: \(model) refused in the hedge after "
                        + "\(String(format: "%.1f", Date().timeIntervalSince(started)))s — "
                        + kind.logName)
                    if case .badRequest(let detail) = kind, RetryPolicy.rejectsThinkingLevel(detail) {
                        thinkingRejected.insert(model)
                    }
                case .abstained, .none:
                    break
                }
            }
            group.cancelAll()
            // Wrapped with its author. The caller classifies and decides on the underlying error,
            // but its log line has to name the model that actually refused — measured 2026-11-05,
            // where a partner's 429 produced a line saying the *lead* had been rate limited, and the
            // two lines in the same turn contradicted each other.
            if let first = firstFailure {
                throw HedgedFailure(underlying: first.error, model: first.model)
            }
            throw BrainError.transport("hedged stream ended without a reply")
        }
    }

    private func stream(
        key: String,
        model: String,
        systemPrompt: String,
        history: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        images: [(data: Data, label: String)],
        /// The turn's expiry. Checked on every line, because an idle timeout cannot see a stream
        /// that trickles.
        deadline: Date,
        /// Whether to ask this model to think less. False after it has said it cannot — the field is
        /// an optimisation, and a model that rejects it outright is not a model that must be argued
        /// with twice per turn.
        asksForThinking: Bool = true,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {

        // Label each capture with its pixel size. That is what lets the model answer with
        // [POINT:x,y] in the image's own coordinates, which is the only coordinate space it
        // can get right after a crop.
        var parts: [GeminiRequestBuilder.ContentPart] = []
        for image in images {
            parts.append(.text(image.label))
            parts.append(.image(base64: image.data.base64EncodedString(),
                                mimeType: Self.mimeType(for: image.data)))
        }
        parts.append(.text(userPrompt))

        // Conversation history is replayed as plain text turns. The Interactions API takes a
        // single `user_input`, so the exchange is flattened rather than reconstructed as
        // separate messages.
        var request = TurnRequest(
            question: userPrompt,
            scope: .wholeScreen,
            imageData: nil)
        request.imagePixelSize = nil

        let body = Self.body(
            model: model,
            parts: parts,
            systemPrompt: systemPrompt,
            history: history,
            asksForThinking: asksForThinking)

        var urlRequest = URLRequest(url: Self.interactionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(GeminiRequestBuilder.apiRevision, forHTTPHeaderField: "Api-Revision")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        // 20, not the 90 this line used to carry. `URLRequest.timeoutInterval` *overrides* the
        // session's `timeoutIntervalForRequest`, so the idle bound reasoned out in `init()` — "at
        // 90s a contended model could hold the user silent for a minute and a half" — was silently
        // replaced by exactly that 90s on every Gemini request. It is why one model was able to
        // stall three times for 90s inside a single turn.
        urlRequest.timeoutInterval = 20

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw BrainError.transport("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Read the body even on failure. A bare status code on a 400 is useless; Gemini
            // names the offending field and that is the only way to find the fault.
            var text = ""
            do {
                for try await line in bytes.lines { text += line + "\n" }
            } catch {
                text = "<unreadable>"
            }
            throw BrainError.http(statusCode: http.statusCode, body: text)
        }

        var accumulated = ""
        // An SSE `.error` inside a 200 used to be dropped here, so a quota or safety refusal read as
        // a served turn: empty card, no failover, no backup key (AUDIT.md B-02). The local loop has
        // always kept this; the cloud loop now keeps it too.
        var streamFailure: String?
        for try await line in bytes.lines {
            // A hedged turn cancels the loser, and `AsyncBytes` does not notice on its own: without
            // this the model that lost the race keeps streaming a whole reply into a callback that
            // ignores it, holding the connection and its rate-limit token.
            if Task.isCancelled { throw URLError(.cancelled) }
            // Past the turn's budget this stream is no longer worth finishing, and `.network` is
            // the classification that moves to the next model instead of asking this one again.
            // Only a *silent* stream is cut here. A model that has already begun answering is
            // worth letting finish: aborting mid-sentence and switching made the next model append
            // to the same `AnswerStreamer`, so one card and one spoken sentence came from two
            // models — and both models' act tags ran as one plan.
            if accumulated.isEmpty, Date() >= deadline { throw URLError(.timedOut) }
            for event in GeminiStreamParser.parse(line: String(line)) {
                switch event {
                case .textDelta(let delta):
                    accumulated += delta
                    await onTextChunk(delta)
                case .error(let message):
                    streamFailure = message
                case .completed:
                    break
                }
            }
        }
        if let streamFailure {
            Log.write("brain: cloud stream ended early — \(streamFailure)")
            if accumulated.isEmpty {
                throw BrainError.http(statusCode: Self.statusInStreamMessage(streamFailure) ?? 500,
                                      body: streamFailure)
            }
        }
        return accumulated
    }

    /// An in-stream error carries the server's own words. When they name a quota refusal, classify
    /// it as the 429 it is, so the chain walks to the next model and the backup key earns its retry
    /// exactly as an HTTP 429 would.
    private static func statusInStreamMessage(_ message: String) -> Int? {
        let lowered = message.lowercased()
        if lowered.contains("resource_exhausted") || lowered.contains("quota") || message.contains("429") {
            return 429
        }
        if lowered.contains("unavailable") || lowered.contains("high demand") || message.contains("503") {
            return 503
        }
        return nil
    }

    /// The live capture path encodes JPEG and `--self-test` encodes PNG, and the tuple carrying
    /// them has no field for the difference — so the type is read off the magic bytes. Claiming
    /// `image/png` for JPEG bytes is the kind of bug that appears to work, because Gemini sniffs;
    /// the day it stops sniffing, the model is asked to explain a screen it was never shown.
    static func mimeType(for data: Data) -> String {
        guard data.count > 1, data[0] == 0xFF, data[1] == 0xD8 else { return "image/png" }
        return "image/jpeg"
    }

    /// `store: false` is not negotiable. Chunks sends screenshots of the user's whole screen
    /// and Google must not retain them.
    private static func body(
        model: String,
        parts: [GeminiRequestBuilder.ContentPart],
        systemPrompt: String,
        history: [(userPlaceholder: String, assistantResponse: String)],
        asksForThinking: Bool = true
    ) -> [String: Any] {
        var all = parts.map(\.json)
        if !history.isEmpty {
            let transcript = history
                .map { "User: \($0.userPlaceholder)\nChunks: \($0.assistantResponse)" }
                .joined(separator: "\n\n")
            all.insert(.init(), at: 0)
            all[0] = ["type": "text", "text": "Earlier in this conversation:\n\(transcript)"]
        }

        var request: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "input": [["type": "user_input", "content": all]],
            // A bare string. `{"text": ...}` is rejected:
            // "The value is invalid for 'system_instruction'. Expected string".
            "system_instruction": systemPrompt,
        ]
        // Not every model takes it, and one that does not ends the turn: measured 2026-10-29 on his
        // own screen, `gemini-3.1-flash-lite-preview` answered every request with 400 `Thinking level
        // THINKING_LEVEL_MINIMAL is not supported for this model`, and a 400 was fatal — so the field
        // added to halve latency was the reason "Could not answer" appeared over a question the model
        // could answer in seconds. The key now goes only when this model has not already refused it.
        // Gemini 3.x thinks before it speaks, and the dead 20-second silences in the log — a model
        // streaming nothing while the idle bound counts down — are that thinking, unbudgeted.
        // `--probe-thinking` measured the shape on 2026-10-28: this field and only this one is
        // accepted (`none` is not a value; `minimal`, `low`, `medium` and `high` are), and on the
        // five-turn protocol probe `minimal` halved served-turn seconds (21–24s against 42–49s on the
        // same prompts). The one tag family it appeared to lose — a "scrolling down to find the
        // invoice" with no `[SCROLL:]` behind it — went missing at `low` too, on a screen with nothing
        // scrollable: a promise with no request, not a thinking budget, and `AnswerStreamer
        // .retractUnbackedPromises` replaces it with an honest line whatever the model thought.
        //
        // Not every model takes it, and one that does not ends the turn. Measured 2026-10-29 on his own
        // screen: `gemini-3.1-flash-lite-preview` answered every request with 400 `Thinking level
        // THINKING_LEVEL_MINIMAL is not supported for this model`, and a 400 was fatal — so the field
        // added to halve latency was why "Could not answer" appeared over a question that model could
        // answer in seconds. The key now goes only when this model has not already refused it.
        if asksForThinking {
            request["generation_config"] = ["thinking_level": "minimal"]
        }
        return request
    }

    private static var interactionsURL: URL {
        // `?alt=sse` is what turns the response into a server-sent event stream.
        URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions?alt=sse")!
    }

    private func classify(_ error: Error) -> RetryPolicy.Failure {
        guard let brainError = error as? BrainError else {
            return RetryPolicy.classify(error: error)
        }
        switch brainError {
        case .http(let code, let body):
            return RetryPolicy.classify(statusCode: code, body: body)
        case .transport:
            return .network(detail: brainError.description)
        case .localModelWasSilent:
            return .unknown(statusCode: nil, detail: brainError.description)
        case .missingKey, .noCapableModel, .keychain, .turnBudgetExceeded:
            // Everything here is terminal: `.unauthorised` is the failure the policy answers with
            // `.fail`, and a spent budget must not start walking the chain again.
            return .unauthorised
        }
    }
}
