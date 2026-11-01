import Foundation

/// Request building and streaming parser for Ollama's native `/api/chat` endpoint.
///
/// While Ollama exposes an OpenAI-compatible `/v1/chat/completions` endpoint, that shim has
/// three critical limitations on multimodal models like `gemma4:e2b-it-qat`:
/// 1. Context length: `/v1` defaults to a 4,096-token runner limit and ignores `options.num_ctx`,
///    causing prompts over 4k tokens to truncate mid-reply with `finish_reason: length`.
/// 2. Thinking control: `/api/chat` natively honors `"think": false`, eliminating 8+ seconds
///    of scratchpad deliberation on Gemma 4, whereas `/v1` leaves reasoning in the stream.
/// 3. Image attachment: `/api/chat` takes `"images": ["<base64>"]` directly on the message,
///    avoiding GGUF template ordering conflicts where leading text obscures the image.
public enum OllamaTransport {

    /// Translate the provider's base URL (often pointing at `/v1`) to the native `/api/chat` endpoint.
    public static func chatURL(baseURL: URL) -> URL {
        let root = baseURL.absoluteString.replacingOccurrences(of: "/v1", with: "")
        let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
        return URL(string: trimmed + "/api/chat") ?? baseURL
    }

    /// Assemble the JSON body for Ollama's native `/api/chat` endpoint.
    public static func body(model: String,
                            systemPrompt: String,
                            userPrompt: String,
                            images: [(data: Data, label: String)],
                            history: [(userPlaceholder: String, assistantResponse: String)],
                            stream: Bool,
                            numCtx: Int = 16384,
                            think: Bool = false) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        for turn in history {
            messages.append(["role": "user", "content": turn.userPlaceholder])
            messages.append(["role": "assistant", "content": turn.assistantResponse])
        }

        var userMessage: [String: Any] = ["role": "user"]
        var textContent = ""
        for image in images where !image.label.isEmpty {
            textContent += image.label + "\n"
        }
        textContent += userPrompt
        userMessage["content"] = textContent

        if !images.isEmpty {
            userMessage["images"] = images.map { $0.data.base64EncodedString() }
        }
        messages.append(userMessage)

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
            "think": think,
            "options": [
                "num_ctx": numCtx
            ]
        ]
        return body
    }

    /// Parses one NDJSON line from Ollama's `/api/chat` stream into shared `GeminiStreamParser.Event`s.
    public static func parse(line: String) -> [GeminiStreamParser.Event] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let error = object["error"] as? String {
            return [.error(error)]
        }

        var events: [GeminiStreamParser.Event] = []
        // Note: `thinking` text in the message is deliberately omitted, matching the policy
        // that model reasoning scratchpads are not surfaced on user-facing cards.
        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            events.append(.textDelta(content))
        }

        if let done = object["done"] as? Bool, done {
            events.append(.completed)
        }

        return events
    }
}
