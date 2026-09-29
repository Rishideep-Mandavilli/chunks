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
    private var _model = "gemini-3.8-flash"

    /// `workerBaseURL` in clicky pointed at its Cloudflare proxy. Chunks talks to Google
    /// directly, so nothing is proxied and nothing about the request passes through a
    /// server we do not control.
    private let session: URLSession
    private let rateLimiter = RateLimiter()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
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
        modelLoop: for candidate in chain {
            for attempt in 0..<3 {
                // Stay under the free tier's per-model cap rather than walking into it.
                let wait = rateLimiter.delayUntilAvailable()
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                rateLimiter.consume()

                do {
                    let text = try await stream(
                        key: key,
                        model: candidate.id,
                        systemPrompt: systemPrompt,
                        history: conversationHistory,
                        userPrompt: userPrompt,
                        images: images,
                        onTextChunk: onTextChunk)
                    return (text, Date().timeIntervalSince(started))
                } catch {
                    lastError = error
                    switch RetryPolicy.decide(for: classify(error), attempt: attempt) {
                    case .retrySameModel(let after):
                        try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                    case .fallBackToNextModel:
                        // Labelled, because a bare `break` here exits the switch and
                        // retries the model we just gave up on.
                        NSLog("[Chunks] %@ contended, trying %@", candidate.id,
                              chain.first { $0.id != candidate.id }?.id ?? "nothing")
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
            parts.append(.image(base64: image.data.base64EncodedString(), mimeType: "image/png"))
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
