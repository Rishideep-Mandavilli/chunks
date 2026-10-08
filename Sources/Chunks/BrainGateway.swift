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

enum BrainError: Error, CustomStringConvertible {
    case missingKey
    case noCapableModel(String)
    case http(statusCode: Int, body: String)
    case transport(String)
    case keychain(OSStatus)

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
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Could not read the API key from the Keychain: \(detail)."
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

    private func limiter(for modelID: String) -> RateLimiter {
        if let existing = rateLimiters[modelID] { return existing }
        let fresh = RateLimiter()
        rateLimiters[modelID] = fresh
        return fresh
    }

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
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {

        let started = Date()
        let key = try KeychainStore.geminiKey()
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
        Log.write("turn: chain \(chain.map(\.id).joined(separator: " > "))"
            + " · \(images.count) image(s), \(images.reduce(0) { $0 + $1.data.count } / 1024) KB"
            + " · text \(userPrompt.count + systemPrompt.count) chars")
        modelLoop: for (index, candidate) in chain.enumerated() {
            attempts = index + 1
            let attemptStarted = Date()
            for attempt in 0..<3 {
                // Stay under the free tier's per-model cap rather than walking into it.
                let limiter = limiter(for: candidate.id)
                let wait = limiter.delayUntilAvailable()
                if wait > 0 {
                    Log.write("turn: \(candidate.id) at its per-minute cap, waiting "
                        + "\(String(format: "%.1f", wait))s")
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                limiter.consume()

                do {
                    let text = try await stream(
                        key: key,
                        model: candidate.id,
                        systemPrompt: systemPrompt,
                        history: conversationHistory,
                        userPrompt: userPrompt,
                        images: images,
                        onTextChunk: onTextChunk)
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
                    let kind = classify(error)
                    let decision = RetryPolicy.decide(for: kind, attempt: attempt)
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
                    Log.write("turn: \(candidate.id) failed after "
                        + "\(String(format: "%.1f", waited))s — \(kind.logName); \(action)")
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

    private func stream(
        key: String,
        model: String,
        systemPrompt: String,
        history: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        images: [(data: Data, label: String)],
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
            history: history)

        var urlRequest = URLRequest(url: Self.interactionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(GeminiRequestBuilder.apiRevision, forHTTPHeaderField: "Api-Revision")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 90

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
        for try await line in bytes.lines {
            for event in GeminiStreamParser.parse(line: String(line)) {
                if case .textDelta(let delta) = event {
                    accumulated += delta
                    await onTextChunk(delta)
                }
            }
        }
        return accumulated
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
        history: [(userPlaceholder: String, assistantResponse: String)]
    ) -> [String: Any] {
        var all = parts.map(\.json)
        if !history.isEmpty {
            let transcript = history
                .map { "User: \($0.userPlaceholder)\nChunks: \($0.assistantResponse)" }
                .joined(separator: "\n\n")
            all.insert(.init(), at: 0)
            all[0] = ["type": "text", "text": "Earlier in this conversation:\n\(transcript)"]
        }

        return [
            "model": model,
            "store": false,
            "stream": true,
            "input": [["type": "user_input", "content": all]],
            // A bare string. `{"text": ...}` is rejected:
            // "The value is invalid for 'system_instruction'. Expected string".
            "system_instruction": systemPrompt,
        ]
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
        case .missingKey, .noCapableModel, .keychain:
            return .unauthorised
        }
    }
}
