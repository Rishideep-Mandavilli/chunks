import Foundation

/// What the user asked for, and what Chunks saw.
public struct TurnRequest: Sendable {
    public enum Scope: Sendable, Equatable {
        /// The whole screen.
        case wholeScreen
        /// A region the user circled or drew on, in display-local logical points.
        case region(LogicalRect)
    }

    public var question: String
    public var scope: Scope
    /// PNG data for the scope. For `.region` this is the padded crop.
    public var imageData: Data?
    /// Pixel dimensions of `imageData`. Stated to the model so its `[POINT]` answers can
    /// be expressed in the image's own pixel space.
    public var imagePixelSize: DeviceSize?
    /// The user's own annotations over the image, if any.
    public var annotationNote: String?
    /// Curated memory block, injected verbatim.
    public var memoryBlock: String

    public init(question: String, scope: Scope, imageData: Data?,
                imagePixelSize: DeviceSize? = nil,
                annotationNote: String? = nil,
                memoryBlock: String = "") {
        self.question = question
        self.scope = scope
        self.imageData = imageData
        self.imagePixelSize = imagePixelSize
        self.annotationNote = annotationNote
        self.memoryBlock = memoryBlock
    }

    public var needsVision: Bool { imageData != nil }
}

// MARK: - Request building (pure, testable)

/// Builds Gemini **Interactions API** request bodies.
///
/// Notes carried over from the Phase 0 probes, because getting these wrong is expensive:
/// - The endpoint is `POST /v1beta/interactions`, not `:generateContent`. The latter
///   returns *"no longer available to new users"* for retired models.
/// - `Api-Revision: 2026-05-20` is required for the multimodal content shape.
/// - `"store": false` means Google does not retain the interaction. This is the default
///   and must never be flipped — Chunks sends screenshots of the user's whole screen.
/// - Streaming appends `?alt=sse` and sets `"stream": true`.
public enum GeminiRequestBuilder {

    public static let apiRevision = "2026-05-20"

    public enum ContentPart {
        case text(String)
        case image(base64: String, mimeType: String)

        public var json: [String: Any] {
            switch self {
            case .text(let t):
                return ["type": "text", "text": t]
            case .image(let b64, let mime):
                return ["type": "image", "data": b64, "mime_type": mime]
            }
        }
    }

    /// The system instruction. Kept short and concrete — this is a screen tutor, not a
    /// general assistant, and long prompts dilute the tagging contract.
    ///
    /// `imageSize` is interpolated because the `[POINT]` contract depends on it. Chunks
    /// asks for coordinates in **the image's own pixel space**, not the display's logical
    /// space, even though the original Clicky used the latter. The reason is arithmetic the
    /// model would otherwise have to do: after a circle-to-explain crop it is looking at a
    /// 400x300 region, and asked for "display coordinates" it has to infer the crop's offset
    /// from the screen. In image-local pixels it can only be right.
    public static func systemInstruction(imageSize: DeviceSize? = nil) -> String {
        let coordinateRule: String
        if let size = imageSize {
            coordinateRule = """
            - To point at a control, emit [POINT:x,y,label] where x and y are PIXELS \
            within the image you were just shown. That image is \(size.width)x\(size.height) \
            pixels, with (0,0) at its top-left corner. Keep the label short and name the \
            control ("Save", "Run button", "Deploy").
            """
        } else {
            coordinateRule = """
            - To point at a control, emit [POINT:x,y,label] where x and y are pixels \
            within the image you were just shown, with (0,0) at its top-left corner.
            """
        }

        return """
        You are Chunks, a Mac companion that explains what is on the user's screen.

        HOW YOU REPLY
        - Put the words you want SPOKEN inside <SAY>...</SAY>. Keep it to one or two
          sentences; it is read aloud.
        - Anything outside <SAY> is shown on screen only. Use it for detail: bullet lists,
          steps, code.
        \(coordinateRule)
        - Be concrete and brief. The user is looking at this screen while you talk.
        - If you cannot see an image, say so plainly. Never guess at screen contents.

        MEMORY
        - You may propose a durable fact about the user with:
          <MEMORY>{"add":[{"section":"You|Corrections|Standing preferences|Notes","fact":"one line"}],"prune":[]}</MEMORY>
        - Only propose what is genuinely durable (their tools, projects, preferences, or a
          correction they made). Never propose anything that looks like a credential.
        - Sections: "You" (facts about them), "Corrections" (things they got you wrong),
          "Standing preferences" (how they like answers), "Notes" (ongoing work).
        - Emit at most one MEMORY block, and only when you actually learned something.

        WHAT YOU DO NOT DO
        - You do not write code, build projects, or create files.
        - You do not click or type anything unless Chunks explicitly asks you to propose an
          action, and Chunks always asks the user first.
        """
    }

    /// Assemble the parts for a turn, in order.
    public static func parts(for request: TurnRequest) -> [ContentPart] {
        var parts: [ContentPart] = []

        if !request.memoryBlock.isEmpty {
            parts.append(.text("What you already know about this user:\n\(request.memoryBlock)"))
        }

        var question = request.question

        switch request.scope {
        case .wholeScreen:
            question = "Here is the user's whole screen.\n\n\(question)"
        case .region(let rect):
            // Tell the model the crop is a crop, so it does not describe the whole screen
            // as if it were the region — a common and very visible failure. Stating the
            // pixel size also anchors the `[POINT]` contract.
            let sizeNote = request.imagePixelSize.map { " (\($0.width)x\($0.height) pixels)" } ?? ""
            question = """
            This is a crop of the user's screen — the region they selected \
            (\(Int(rect.width))x\(Int(rect.height)) points)\(sizeNote). \
            Only what is inside this crop is visible. Everything outside it is cut off.
            \(question)
            """
            if let note = request.annotationNote, !note.isEmpty {
                question += "\n\nThey marked it up: \(note)"
            }
        }

        parts.append(.text(question))

        if let data = request.imageData {
            parts.append(.image(base64: data.base64EncodedString(), mimeType: "image/png"))
        }
        return parts
    }

    public static func body(model: String, request: TurnRequest, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            // Screenshots are the whole point of Chunks; do not let them be retained.
            "store": false,
            "input": [[
                "type": "user_input",
                "content": parts(for: request).map { $0.json },
            ]],
            // A plain string. The Interactions API takes `{"text": ...}` for some fields and
            // a bare string for this one, and the mismatch is visible only in the server's
            // reply: "The value is invalid for 'system_instruction'. Expected string,
            // unexpected character: '{'". The unit tests could not catch this because the
            // body was valid JSON either way — `--self-test` caught it against the real API.
            "system_instruction": systemInstruction(imageSize: request.imagePixelSize),
        ]
        if stream { body["stream"] = true }
        return body
    }

    public static func encode(model: String, request: TurnRequest, stream: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: body(model: model, request: request, stream: stream))
    }
}

// MARK: - SSE parsing (pure, testable)

/// Extracts text deltas from an Interactions API SSE stream.
///
/// Observed event sequence during Phase 0:
/// `interaction.created` → `interaction.status_update` → `step.start` → `step.delta` ×N
/// → `step.stop` → `interaction.completed`
///
/// Only `step.delta` entries carrying `delta.text` contribute to the reply. `thought`
/// steps use the same event type with a different payload shape and are skipped — Chunks
/// does not surface model reasoning.
public enum GeminiStreamParser {

    public enum Event: Equatable {
        case textDelta(String)
        case completed
        case error(String)
    }

    /// Feed one raw SSE line. Returns events, possibly empty.
    public static func parse(line: String) -> [Event] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return [] }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // Errors arrive as a top-level `error` object.
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return [.error(message)]
        }

        switch object["event_type"] as? String {
        case "step.delta":
            guard let delta = object["delta"] as? [String: Any],
                  let text = delta["text"] as? String, !text.isEmpty else { return [] }
            return [.textDelta(text)]
        case "interaction.completed":
            return [.completed]
        default:
            return []
        }
    }

    /// Split a whole SSE body into events.
    public static func parse(body: String) -> [Event] {
        body.components(separatedBy: .newlines).flatMap { parse(line: $0) }
    }

    /// Usage numbers from the terminal event, if present.
    public struct Usage: Equatable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var imageTokens: Int?
    }

    public static func usage(from object: [String: Any]) -> Usage? {
        guard let usage = object["usage"] as? [String: Any] else { return nil }
        var imageTokens: Int?
        if let byModality = usage["input_tokens_by_modality"] as? [[String: Any]] {
            imageTokens = byModality.first { $0["modality"] as? String == "image" }?["tokens"] as? Int
        }
        return Usage(inputTokens: usage["total_input_tokens"] as? Int ?? 0,
                     outputTokens: usage["total_output_tokens"] as? Int ?? 0,
                     imageTokens: imageTokens)
    }
}
