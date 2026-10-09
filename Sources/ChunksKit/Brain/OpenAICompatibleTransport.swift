import Foundation

/// Request building for any OpenAI-compatible `/chat/completions` server.
///
/// This is the shape that makes offline Chunks possible at all: Ollama, LM Studio, llama.cpp's
/// server and vLLM all answer it, and none of them need a network. It is deliberately separate
/// from `GeminiTransport` rather than a flag inside it — the two APIs disagree about where the
/// system prompt goes, how an image is attached and what a stream event looks like, and folding
/// both into one builder is how a provider switch ends up silently sending Gemini-shaped JSON to
/// a local server that answers with a 400 and no explanation.
///
/// The prompt itself is **not** duplicated: the parts come from `GeminiRequestBuilder.parts(for:)`, so
/// the region-crop warning, the memory block and the `[POINT]` coordinate contract are identical
/// whichever brain answers. Only the envelope differs.
public enum OpenAICompatibleTransport {

    /// `/chat/completions` under the provider's base URL.
    ///
    /// Trailing slashes are stripped first: `http://localhost:11434/v1/` and
    /// `http://localhost:11434/v1` must produce the same request, and a doubled slash is a 404
    /// that looks like the server is down.
    public static func chatCompletionsURL(baseURL: URL) -> URL {
        let trimmed = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        return URL(string: trimmed + "/chat/completions")!
    }

    /// A bearer token only when there is one. Local servers reject an `Authorization` header
    /// carrying an empty key, and sending one would also mean pasting a Gemini key at a loopback
    /// address for no reason.
    public static func headers(apiKey: String?) -> [String: String] {
        var headers = ["Content-Type": "application/json", "Accept": "text/event-stream"]
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        return headers
    }

    /// Map the transport-neutral parts into a chat message's `content`.
    ///
    /// Images ride as data URLs because that is what these servers accept; the base64 payload is
    /// already produced for Gemini, so no re-encoding happens.
    public static func content(_ parts: [GeminiRequestBuilder.ContentPart]) -> [[String: Any]] {
        parts.map { part in
            switch part {
            case .text(let text):
                return ["type": "text", "text": text]
            case .image(let base64, let mimeType):
                return ["type": "image_url",
                        "image_url": ["url": "data:\(mimeType);base64,\(base64)"]]
            }
        }
    }

    public static func body(model: String,
                            request: TurnRequest,
                            stream: Bool,
                            history: [(user: String, assistant: String)] = []) -> [String: Any] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": GeminiRequestBuilder.systemInstruction(imageSize: request.imagePixelSize)]
        ]
        // Vendored conversations put the earlier turns in as real messages; the Gemini path does
        // the same, so both transports must agree or a switch changes what the model sees.
        for turn in history {
            messages.append(["role": "user", "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }
        messages.append(["role": "user", "content": content(GeminiRequestBuilder.parts(for: request))])

        var body: [String: Any] = ["model": model, "messages": messages, "stream": stream]
        // Local servers do not retain anything, and Ollama rejects an unknown top-level key with a
        // 400 that names no field — so this stays Gemini-only.
        return body
    }

    /// A body built from plain strings, for the vendored single-shot path that has no `TurnRequest`.
    public static func body(model: String,
                            systemPrompt: String,
                            userPrompt: String,
                            images: [(data: Data, label: String)],
                            history: [(userPlaceholder: String, assistantResponse: String)],
                            stream: Bool) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        for turn in history {
            messages.append(["role": "user", "content": turn.userPlaceholder])
            messages.append(["role": "assistant", "content": turn.assistantResponse])
        }

        var userContent: [[String: Any]] = []
        for image in images {
            userContent.append([
                "type": "text",
                "text": image.label.isEmpty ? "A screenshot." : "Screenshot of \(image.label):",
            ])
            userContent.append([
                "type": "image_url",
                "image_url": ["url": "data:image/png;base64,\(image.data.base64EncodedString())"],
            ])
        }
        userContent.append(["type": "text", "text": userPrompt])
        messages.append(["role": "user", "content": userContent])

        return ["model": model, "messages": messages, "stream": stream]
    }

    public static func encode(body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body)
    }

    /// True when the request carries an image. Used to force the "this model has not been
    /// verified to see" warning out loud rather than letting a text-only model guess.
    public static func carriesImage(_ body: [String: Any]) -> Bool {
        guard let messages = body["messages"] as? [[String: Any]] else { return false }
        for message in messages {
            if let content = message["content"] as? [[String: Any]],
               content.contains(where: { ($0["type"] as? String) == "image_url" }) {
                return true
            }
        }
        return false
    }
}

/// Reads an OpenAI-compatible SSE stream into the *same* events `GeminiStreamParser` produces.
///
/// Sharing the event type is the point: `AnswerStreamer` and everything downstream of it — the
/// `[POINT]` extraction, the act tags, the spoken summary — must not care which brain answered,
/// and a second event vocabulary is where a provider switch would start dropping tags.
public enum OpenAIStreamParser {

    public static func parse(line: String) -> [GeminiStreamParser.Event] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return [] }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)

        if payload == "[DONE]" { return [.completed] }

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // A server-side failure arrives as a top-level `error` object, not as a status code, when
        // the stream was already open — e.g. Ollama running out of context mid-reply. Ignoring it
        // would present as a reply that simply stopped early.
        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "the model server reported an error"
            return [.error(message)]
        }

        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else { return [] }

        var events: [GeminiStreamParser.Event] = []
        let delta = first["delta"] as? [String: Any]
        // `reasoning_content` is what several local servers use for chain-of-thought. Chunks does
        // not surface model reasoning, and appending it would put private scratch text in the card.
        if let text = delta?["content"] as? String, !text.isEmpty {
            events.append(.textDelta(text))
        }
        if (first["finish_reason"] as? String) != nil {
            events.append(.completed)
        }
        return events
    }

    /// Concatenate everything a non-streaming `messages` response contains.
    public static func text(from object: [String: Any]) -> String? {
        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String else { return nil }
        return text
    }
}
