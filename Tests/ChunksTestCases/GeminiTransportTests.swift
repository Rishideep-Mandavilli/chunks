import Foundation
import ChunksTestHarness
@testable import ChunksKit

public enum GeminiTransportTests {

    static func makeRequest(scope: TurnRequest.Scope = .wholeScreen,
                            question: String = "What am I looking at?",
                            image: Bool = true,
                            memory: String = "") -> TurnRequest {
        TurnRequest(question: question, scope: scope,
                    imageData: image ? Data([0x89, 0x50, 0x4E, 0x47]) : nil,
                    memoryBlock: memory)
    }

    public static func register() {
        TestRunner.currentSuite = "GeminiTransport / Request"

        test("store is always false so screenshots are not retained") {
            let body = GeminiRequestBuilder.body(model: "gemini-3.8-flash",
                                                 request: makeRequest(), stream: false)
            expectEqual(body["store"] as? Bool, false,
                        "store must be false — Chunks sends whole-screen screenshots")
        }

        test("stream flag is only set when streaming") {
            let streamed = GeminiRequestBuilder.body(model: "m", request: makeRequest(), stream: true)
            let plain = GeminiRequestBuilder.body(model: "m", request: makeRequest(), stream: false)
            expectEqual(streamed["stream"] as? Bool, true)
            expect(plain["stream"] == nil, "stream key should be absent, not false")
        }

        test("a whole-screen request labels the image as the whole screen") {
            let parts = GeminiRequestBuilder.parts(for: makeRequest())
            guard case .text(let first) = parts[0] else { return expect(false, "expected a text part") }
            expect(first.contains("whole screen"), "should say it's the whole screen: \(first)")
            expect(first.contains("What am I looking at?"))
        }

        // The failure this prevents is very visible: the model describes the entire screen
        // as if it were the circled region.
        test("a region request states the crop is a crop and gives its size") {
            let rect = LogicalRect(x: 100, y: 200, width: 400, height: 300)
            let req = makeRequest(scope: .region(rect), question: "What is this?")
            let parts = GeminiRequestBuilder.parts(for: req)
            guard case .text(let text) = parts[0] else { return expect(false, "expected a text part") }
            expect(text.contains("crop"), "must say it is a crop: \(text)")
            expect(text.contains("400x300"), "should give the crop size: \(text)")
            expect(text.contains("cut off"), "should warn that the rest is cut off")
            expect(text.contains("What is this?"))
        }

        test("annotation notes are passed through to the model") {
            let req = TurnRequest(question: "Explain", scope: .region(LogicalRect(x: 0, y: 0, width: 10, height: 10)),
                                  imageData: Data([1]), annotationNote: "circled the error message")
            let parts = GeminiRequestBuilder.parts(for: req)
            guard case .text(let text) = parts[0] else { return expect(false, "expected a text part") }
            expect(text.contains("circled the error message"), "annotation note dropped: \(text)")
        }

        test("memory is prepended as its own part, before the question") {
            let req = makeRequest(memory: "  (2026-09-29) Uses Raycast")
            let parts = GeminiRequestBuilder.parts(for: req)
            guard case .text(let first) = parts[0] else { return expect(false, "expected memory part first") }
            expect(first.contains("already know"), "memory should be introduced: \(first)")
            expect(first.contains("Uses Raycast"))
            guard case .text(let second) = parts[1] else { return expect(false, "expected question second") }
            expect(second.contains("whole screen"))
        }

        test("an empty memory block adds no part") {
            let parts = GeminiRequestBuilder.parts(for: makeRequest(memory: ""))
            expectEqual(parts.count, 2, "should be question + image only")
        }

        test("image parts carry base64 and mime type") {
            let parts = GeminiRequestBuilder.parts(for: makeRequest())
            guard case .image(let b64, let mime)? = parts.last else {
                return expect(false, "expected an image part, got \(parts)")
            }
            expectEqual(mime, "image/png")
            expect(!b64.isEmpty, "image data should be base64-encoded")
        }

        test("a text-only request sends no image part") {
            let parts = GeminiRequestBuilder.parts(for: makeRequest(image: false))
            expect(parts.allSatisfy { if case .image = $0 { return false }; return true },
                   "no image should be sent")
        }

        test("needsVision tracks whether an image is present") {
            expect(makeRequest(image: true).needsVision)
            expect(!makeRequest(image: false).needsVision)
        }

        test("the system instruction pins the reply contract") {
            let sys = GeminiRequestBuilder.systemInstruction
            expect(sys.contains("<SAY>"), "must define the speech tag")
            expect(sys.contains("[POINT:"), "must define the point tag")
            expect(sys.contains("<MEMORY>"), "must define the memory tag")
            expect(sys.contains("<NOTE>"), "must define the notebook tag")
            expect(sys.contains("LOGICAL POINTS"), "must warn about pixels vs points")
            expect(sys.lowercased().contains("never guess at screen contents"),
                   "must forbid hallucinating screen contents")
        }

        test("the system instruction forbids the out-of-scope capabilities") {
            let sys = GeminiRequestBuilder.systemInstruction.lowercased()
            expect(sys.contains("do not write code"), "must forbid code generation")
            expect(sys.contains("create files"), "must forbid file artifacts")
            expect(sys.contains("always asks the user first"), "must require consent before acting")
        }

        test("the body encodes to valid JSON") {
            var threw = false
            do {
                let data = try GeminiRequestBuilder.encode(model: "gemini-3.8-flash",
                                                           request: makeRequest(), stream: true)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                expectEqual(object?["model"] as? String, "gemini-3.8-flash")
                expectEqual(object?["store"] as? Bool, false)
            } catch {
                threw = true
            }
            expect(!threw, "a valid request should encode cleanly")
        }

        // MARK: SSE

        test("parses a text delta") {
            let line = #"data: {"index":0,"delta":{"text":"Hello "},"event_type":"step.delta"}"#
            expectEqual(GeminiStreamParser.parse(line: line), [.textDelta("Hello ")])
        }

        test("parses the completion event") {
            let line = #"data: {"interaction":{"status":"completed"},"event_type":"interaction.completed"}"#
            expectEqual(GeminiStreamParser.parse(line: line), [.completed])
        }

        test("parses an error event") {
            let line = #"data: {"error":{"message":"high demand","code":"service_unavailable"},"event_type":"error"}"#
            expectEqual(GeminiStreamParser.parse(line: line), [.error("high demand")])
        }

        test("thought deltas are skipped, not shown as reply text") {
            // Reasoning uses the same event_type with a different delta shape.
            let line = #"data: {"index":0,"delta":{"signature":"abc123","type":"thought_signature"},"event_type":"step.delta"}"#
            expect(GeminiStreamParser.parse(line: line).isEmpty,
                   "model reasoning must not reach the transcript")
        }

        test("ignores event: lines, blank lines and malformed JSON") {
            for line in ["event: step.delta", "", "   ", "data: {not json", "data:"] {
                expect(GeminiStreamParser.parse(line: line).isEmpty, "should ignore: \(line)")
            }
        }

        test("reassembles a full realistic stream") {
            let body = """
            event: interaction.created
            data: {"interaction":{"id":"v1_abc","status":"in_progress"},"event_type":"interaction.created"}

            event: step.start
            data: {"index":0,"step":{"type":"thought"},"event_type":"step.start"}

            event: step.delta
            data: {"index":0,"delta":{"signature":"EvEFCu4F","type":"thought_signature"},"event_type":"step.delta"}

            event: step.start
            data: {"index":1,"step":{"type":"model_output"},"event_type":"step.start"}

            event: step.delta
            data: {"index":1,"delta":{"text":"That is "},"event_type":"step.delta"}

            event: step.delta
            data: {"index":1,"delta":{"text":"the Debug Navigator."},"event_type":"step.delta"}

            event: step.stop
            data: {"index":1,"event_type":"step.stop"}

            event: interaction.completed
            data: {"interaction":{"status":"completed","usage":{"total_input_tokens":1117,"total_output_tokens":101}},"event_type":"interaction.completed"}
            """
            let events = GeminiStreamParser.parse(body: body)
            let text = events.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined()
            expectEqual(text, "That is the Debug Navigator.")
            expect(events.contains(.completed))
        }

        test("extracts usage including image tokens") {
            let object: [String: Any] = [
                "usage": [
                    "total_input_tokens": 1117,
                    "total_output_tokens": 101,
                    "input_tokens_by_modality": [["modality": "image", "tokens": 1089]],
                ]
            ]
            guard let usage = GeminiStreamParser.usage(from: object) else { return expect(false, "no usage parsed") }
            expectEqual(usage.inputTokens, 1117)
            expectEqual(usage.outputTokens, 101)
            expectEqual(usage.imageTokens, 1089)
        }

        test("usage tolerates a missing image modality") {
            let object: [String: Any] = ["usage": ["total_input_tokens": 10, "total_output_tokens": 2]]
            guard let usage = GeminiStreamParser.usage(from: object) else { return expect(false, "no usage parsed") }
            expectEqual(usage.imageTokens, nil)
        }
    }
}
