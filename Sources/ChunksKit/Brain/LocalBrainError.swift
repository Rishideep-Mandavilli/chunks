import Foundation

/// Turning a local model server's error into a sentence a person can act on.
///
/// A screen turn is not small: system prompt, memory block and screenshot together measured
/// 8,063 tokens on this Mac. Ollama gives several models a 4,096-token context, so the server
/// refuses before answering — and the body is JSON nested inside a JSON string, which tells the
/// user nothing about why the companion went quiet. Each case names the thing to change, because
/// "400 Bad Request" is not a fix.
public enum LocalBrainError {

    /// Whether the failure belongs to *this model* or to the server as a whole. Decides whether
    /// Chunks should try another local model or stop: a model whose context is too small is a
    /// different problem from a server that is not running, and retrying the second one is noise.
    public enum Cause: Equatable {
        case contextTooSmall
        case emptyAnswer
        /// The server is alive and the model is thinking too slowly to be the answer the user is
        /// waiting for. Another model on the same machine may answer in seconds.
        case modelMissing
        case imageUnreadable
        /// A well-formed reply with no text in it. The server is fine; this model said nothing
        /// that Chunks is willing to show, so the next local model gets a turn.
        case serverResourceShortage
        case timedOut
        case addressWrong
        case other
    }

    public static func classify(statusCode: Int, body: String) -> Cause {
        let text = body.lowercased()
        if text.contains("exceed_context_size") || text.contains("context size") { return .contextTooSmall }
        if text.contains("not found") || text.contains("does not exist") || text.contains("no such model") {
            return .modelMissing
        }
        if text.contains("failed to load image") || text.contains("invalid image") { return .imageUnreadable }
        if text.contains("out of memory") || text.contains("no space left") || statusCode == 503 {
            return .serverResourceShortage
        }
        if statusCode == -1 { return .timedOut }
        if statusCode == 404 { return .addressWrong }
        return .other
    }

    /// True when a *different* model on the same server could succeed.
    public static func isPerModel(_ cause: Cause) -> Bool {
        cause == .contextTooSmall || cause == .modelMissing || cause == .imageUnreadable
            || cause == .emptyAnswer || cause == .timedOut
    }

    public static func explain(statusCode: Int, body: String) -> String? {
        switch classify(statusCode: statusCode, body: body) {
        case .timedOut:
            return "took too long to answer a screen turn. Trying a faster model on this Mac."
        case .emptyAnswer:
            return "answered with no text at all — its output went to a channel Chunks does not show. Trying another model on this Mac."
        case .contextTooSmall:
            var line = "That model's context is too small for a screen turn"
            if let limit = extractNumber(named: "n_ctx", in: body) { line += ": it allows \(limit) tokens" }
            if let needed = extractNumber(named: "n_prompt_tokens", in: body) {
                line += (line.hasSuffix("tokens") ? ", and this turn needed \(needed)" : " and this turn needed \(needed)")
            }
            line += ". Start Ollama with OLLAMA_CONTEXT_LENGTH=16384, or let Chunks use a model with more context."
            return line
        case .modelMissing:
            return "That model is not pulled on this machine. Run `ollama pull <name>`, or pick a different model."
        case .imageUnreadable:
            return "The model server could not read the screenshot. If it keeps failing, this model has no image support enabled."
        case .serverResourceShortage:
            return "This Mac does not have the memory or disk free for that model right now. Close a few apps, or pick a smaller model."
        case .addressWrong:
            return "The server answered, but not at that address — check the base URL and that its API server is switched on."
        case .other:
            return nil
        }
    }

    /// Reads a number out of the body. The key is searched **bare**, without its quotes: these
    /// servers wrap their real error in a JSON string inside another JSON string, so the digits
    /// arrive as `\"n_ctx\":4096` and a quoted search never matches — which is exactly what the
    /// first version of this did, and the user would have got the advice without the numbers.
    static func extractNumber(named key: String, in body: String) -> Int? {
        guard let range = body.range(of: key) else { return nil }
        var digits = ""
        for character in body[range.upperBound...] {
            if character.isNumber {
                digits.append(character)
            } else if digits.isEmpty {
                continue          // the `:` and any space between the key and its value
            } else {
                break             // the first non-digit ends the number
            }
        }
        return Int(digits)
    }
}
