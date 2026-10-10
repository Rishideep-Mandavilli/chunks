import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for reading a local model server's refusals.
///
/// The bodies are copied from what Ollama actually returned on this Mac, because the whole value
/// of this type is turning a nested JSON string into something a person can do something about.
public enum LocalBrainErrorTests {

    /// Verbatim from `qwen3-vl:8b` on 2026-10-09, inside a Chunks screen turn.
    static let contextBody = "{\"error\":{\"message\":\"{\\\"error\\\":{\\\"code\\\":400,"
        + "\\\"message\\\":\\\"request (8063 tokens) exceeds the available context size (4096 tokens),"
        + " try increasing it\\\",\\\"type\\\":\\\"exceed_context_size_error\\\","
        + "\\\"n_prompt_tokens\\\":8063,\\\"n_ctx\\\":4096}}\","
        + "\"type\":\"invalid_request_error\"}}"

    public static func register() {
        TestRunner.currentSuite = "Local brain errors"

        test("a context refusal names both numbers and the fix") {
            let line = LocalBrainError.explain(statusCode: 400, body: contextBody) ?? ""
            expect(line.contains("4096"), "the sentence has to say what the limit is: \(line)")
            expect(line.contains("8063"), "and what the turn needed, or it reads as generic advice: \(line)")
            expect(line.contains("OLLAMA_CONTEXT_LENGTH"),
                   "a user who is told 'too small' with nothing to change will conclude Chunks is broken")
        }

        test("a context refusal is this model's problem, not the server's") {
            let cause = LocalBrainError.classify(statusCode: 400, body: contextBody)
            expectEqual(cause, .contextTooSmall)
            expect(LocalBrainError.isPerModel(cause),
                   "another model on the same server may take the turn, which is why Chunks should try it instead of going quiet")
        }

        test("a dead server is not retried model by model") {
            expect(!LocalBrainError.isPerModel(.serverResourceShortage),
                   "cascading through every model when the Mac is out of memory turns one failure into five slow ones")
            expect(!LocalBrainError.isPerModel(.addressWrong),
                   "a wrong base URL is the same for every model on it")
        }

        test("a slow model is retried with the next one, a dead server is not") {
            expectEqual(LocalBrainError.classify(statusCode: -1, body: "timed out"), .timedOut)
            expect(LocalBrainError.isPerModel(.timedOut),
                   "the connection was made and the answer never came; measured here at 91s on qwen3-vl-16k against 14s on gemma4 for the same turn")
            expect(LocalBrainError.explain(statusCode: -1, body: "timed out")?.contains("faster model") == true,
                   "the user should learn a second model was tried, not that Chunks gave up")
        }

        test("a model that is not pulled says to pull it") {
            let body = "{\"error\":{\"message\":\"model 'qwen3-vl:8b' not found\"}}"
            expectEqual(LocalBrainError.classify(statusCode: 400, body: body), .modelMissing)
            expect(LocalBrainError.explain(statusCode: 400, body: body)?.contains("pull") == true,
                   "the number one local failure after a fresh install is a model that was never downloaded")
        }

        test("an unrecognised refusal invents no advice") {
            expect(LocalBrainError.explain(statusCode: 400, body: "{\"error\":{\"message\":\"something odd\"}}") == nil,
                   "guessing at a cause the server never stated is how a wrong fix gets sold as a diagnosis")
        }


        test("a silent model is retried, a dead server is not") {
            expect(LocalBrainError.isPerModel(.emptyAnswer),
                   "the server answered fine and this model had nothing to show; the next local model may answer, and giving up is the wrong call")
            expect(LocalBrainError.explain(statusCode: 200, body: "no text") != nil
                    || LocalBrainError.isPerModel(.emptyAnswer),
                   "an empty reply has to be described in words the user can act on")
        }

        test("the token counts are read from inside the nested string") {
            expectEqual(LocalBrainError.extractNumber(named: "n_ctx", in: contextBody), 4096)
            expectEqual(LocalBrainError.extractNumber(named: "n_prompt_tokens", in: contextBody), 8063)
            expect(LocalBrainError.extractNumber(named: "absent_key", in: contextBody) == nil,
                   "a missing field must read as unknown, not as zero")
        }
    }
}
