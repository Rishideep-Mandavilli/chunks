import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Tests for running Chunks against a local model server.
///
/// Two things are load-bearing here and both fail quietly: the request envelope (a local server
/// answers a Gemini-shaped body with a 400 that names no field, which reads as "the model is
/// broken") and the *refusal to substitute* (a user who chose offline must not have their screen
/// uploaded because a loopback port was closed).
public enum LocalBrainTests {

    public static func register() {
        TestRunner.currentSuite = "Local brains"

        let request = TurnRequest(
            question: "what is this?",
            scope: .wholeScreen,
            imageData: Data([0x89, 0x50, 0x4E, 0x47]),
            memoryBlock: "")

        // MARK: Envelope

        test("a local request puts the system prompt in a system message") {
            let body = OpenAICompatibleTransport.body(model: "llava:13b", request: request, stream: true)
            let messages = body["messages"] as? [[String: Any]] ?? []
            expect(!messages.isEmpty, "an empty messages array is a 400 from every local server")
            expectEqual(messages.first?["role"] as? String, "system",
                        "these APIs ignore a system instruction placed anywhere else, so the [POINT] contract and the 'never guess at screen contents' rule would silently vanish")
        }

        test("the screenshot rides as a data URL in the user message") {
            let body = OpenAICompatibleTransport.body(model: "llava:13b", request: request, stream: true)
            let messages = body["messages"] as? [[String: Any]] ?? []
            let content = messages.last?["content"] as? [[String: Any]] ?? []
            let imageURL = content.compactMap { $0["image_url"] as? [String: Any] }.first?["url"] as? String ?? ""
            expect(imageURL.hasPrefix("data:image/png;base64,"),
                   "a local server that cannot find the image answers about a screen it was never given, and the user sees a confident invention")
        }

        test("the same prompt text is used whichever brain answers") {
            let gemini = GeminiRequestBuilder.parts(for: request)
            let local = OpenAICompatibleTransport.content(gemini)
            expectEqual(local.count, gemini.count,
                        "two builders that drift apart mean the model sees a different question depending on a settings switch nobody was consulting")
        }

        test("a base URL with a trailing slash does not produce a double slash") {
            let url = OpenAICompatibleTransport.chatCompletionsURL(
                baseURL: URL(string: "http://localhost:11434/v1/")!)
            expectEqual(url.absoluteString, "http://localhost:11434/v1/chat/completions",
                        "a doubled slash is a 404, and a 404 looks exactly like a server that is not running")
        }

        test("an Ollama request asks the model not to think") {
            let body = OpenAICompatibleTransport.body(model: "qwen3-vl:8b", systemPrompt: "s",
                                                      userPrompt: "u", images: [], history: [],
                                                      stream: true, thinking: false)
            expectEqual(body["think"] as? Bool, false,
                        "measured on this Mac: qwen3-vl put 176 characters in delta.reasoning and 0 in content, so a thinking model leaves Chunks with an empty card")
        }

        test("a server that is not Ollama is not sent Ollama's private key") {
            let body = OpenAICompatibleTransport.body(model: "gpt-4o", systemPrompt: "s",
                                                      userPrompt: "u", images: [], history: [],
                                                      stream: true)
            expect(body["think"] == nil,
                   "\"think\" is an Ollama extension; a strict OpenAI parser rejects unknown top-level keys with a 400 that names nothing")
        }

        test("no key means no Authorization header at all") {
            let headers = OpenAICompatibleTransport.headers(apiKey: nil)
            expect(headers["Authorization"] == nil,
                   "sending an empty bearer token to a loopback server both fails auth and pastes a cloud key at a local port")
            let withKey = OpenAICompatibleTransport.headers(apiKey: "sk-test")
            expectEqual(withKey["Authorization"], "Bearer sk-test")
        }

        // MARK: Stream parsing

        test("a delta becomes a textDelta and [DONE] becomes completed") {
            let delta = OpenAIStreamParser.parse(
                line: #"data: {"choices":[{"delta":{"content":"hello"}}]}"#)
            expectEqual(delta, [.textDelta("hello")])
            let done = OpenAIStreamParser.parse(line: "data: [DONE]")
            expectEqual(done, [.completed],
                        "the shared event vocabulary is what lets AnswerStreamer, the [POINT] tags and the spoken summary stay provider-blind")
        }

        test("a mid-stream server error is reported, not swallowed") {
            let events = OpenAIStreamParser.parse(
                line: #"data: {"error":{"message":"model requires more system memory"}}"#)
            expectEqual(events, [.error("model requires more system memory")],
                        "an open stream that fails inside the body otherwise reads as a reply that simply stopped early")
        }

        test("chain-of-thought text never reaches the reply") {
            let events = OpenAIStreamParser.parse(
                line: #"data: {"choices":[{"delta":{"reasoning_content":"thinking hard"}}]}"#)
            expect(events.isEmpty,
                   "local servers put private scratch text in reasoning_content; surfacing it would overwrite the answer the user is reading")
        }

        // MARK: Selection

        test("nothing stored means Gemini and the measured chain") {
            let resolution = BrainSelection.resolve(storedProviderID: nil, storedModelID: nil,
                                                    needsVision: true)
            expectEqual(resolution.provider.id, "gemini")
            expect(resolution.model == nil,
                   "pinning one model here would bypass the retry chain that was tuned against the free tier's caps")
        }

        test("a closed local server blocks the turn instead of falling back to the cloud") {
            let resolution = BrainSelection.resolve(storedProviderID: "ollama", storedModelID: nil,
                                                    needsVision: true)
            expect(resolution.isBlocked,
                   "the user chose offline deliberately; uploading the screen because a port was closed is the worst possible way to honour that choice")
            expect(resolution.notice?.contains("not answering") == true,
                   "the failure has to name what to do about it, not just say it failed")
        }

        test("a discovered vision model is chosen first and trusted") {
            let resolution = BrainSelection.resolve(
                storedProviderID: "ollama", storedModelID: nil,
                discoveredModels: ["ollama": [ProviderRegistry.LocalModelDescriptor(name: "llama3:8b", reportsVision: nil),
                                                  ProviderRegistry.LocalModelDescriptor(name: "llava:13b", reportsVision: nil)]],
                needsVision: true)
            expect(!resolution.isBlocked, "Ollama answered, so the turn should run")
            expect(resolution.model?.id.contains("llava") == true,
                   "a vision turn must not start on the text-only model that happens to be listed first")
        }

        test("an unlisted local model still answers, but says it is unverified") {
            let resolution = BrainSelection.resolve(
                storedProviderID: "ollama", storedModelID: "myhomebrew",
                discoveredModels: ["ollama": [ProviderRegistry.LocalModelDescriptor(name: "myhomebrew", reportsVision: nil)]],
                needsVision: true)
            expect(!resolution.isBlocked, "an unknown capability is not a reason to refuse work the user asked for")
            expect(resolution.notice?.contains("not been verified to read images") == true,
                   "invariant 5: degrading is allowed, degrading quietly is not")
        }


        test("the server's own capability list beats any name guess") {
            // Measured on this Mac: Ollama reports `vision` for gemma4:e2b-it-qat and not for
            // qwen3:14b. A name heuristic could never have known the first, and would have been
            // wrong about models whose names say nothing.
            let resolution = BrainSelection.resolve(
                storedProviderID: "ollama", storedModelID: nil,
                discoveredModels: ["ollama": [
                    ProviderRegistry.LocalModelDescriptor(name: "qwen3:14b", reportsVision: false),
                    ProviderRegistry.LocalModelDescriptor(name: "gemma4:e2b-it-qat", reportsVision: true),
                ]],
                needsVision: true)
            expect(resolution.model?.id.contains("gemma4") == true,
                   "the model that reported vision must be the one a vision turn lands on")
            expect(resolution.notice == nil,
                   "a server that says it can see needs no warning")
        }

        test("a vision-sounding name the server refuses to vouch for is not trusted") {
            let resolution = BrainSelection.resolve(
                storedProviderID: "ollama", storedModelID: "llava-text-only",
                discoveredModels: ["ollama": [
                    ProviderRegistry.LocalModelDescriptor(name: "llava-text-only", reportsVision: false),
                ]],
                needsVision: true)
            expect(resolution.notice?.contains("not been verified to read images") == true,
                   "the name said vision and the server said no; the user hears about the disagreement instead of a confident guess")
        }

        test("an unknown provider name says so and uses Gemini") {
            let resolution = BrainSelection.resolve(storedProviderID: "gemni", storedModelID: nil,
                                                    needsVision: false)
            expectEqual(resolution.provider.id, "gemini")
            expect(resolution.notice?.contains("don't know the brain") == true,
                   "a typo in a settings surface must still produce an answer, and must also tell the user it was not the answer they configured")
        }

        test("a named local model that is not loaded is reported") {
            let resolution = BrainSelection.resolve(
                storedProviderID: "ollama", storedModelID: "gemma2:2b",
                discoveredModels: ["ollama": [ProviderRegistry.LocalModelDescriptor(name: "llava:13b", reportsVision: nil)]],
                needsVision: true)
            expect(resolution.notice?.contains("has no model called") == true,
                   "silently switching the model the user picked is how 'it stopped following my instructions' bugs start")
        }

        test("the vision markers ignore case and suffixes") {
            expectEqual(ProviderRegistry.localVisionGuess(modelID: "Qwen2.5-VL-7B-Instruct"), true,
                        "server names are written every way imaginable")
            expectEqual(ProviderRegistry.localVisionGuess(modelID: "mistral:7b"), nil,
                        "nil means unknown, never false — the difference is whether the user is warned or blocked")
        }

        // MARK: - Ollama Native Transport & Gemma 4 Support

        test("OllamaTransport converts base URL to native /api/chat endpoint") {
            let url = OllamaTransport.chatURL(baseURL: URL(string: "http://localhost:11434/v1")!)
            expectEqual(url.absoluteString, "http://localhost:11434/api/chat",
                        "Ollama's /api/chat is required to bypass the 4k context truncation and enable native think control")
            let trailing = OllamaTransport.chatURL(baseURL: URL(string: "http://localhost:11434/v1/")!)
            expectEqual(trailing.absoluteString, "http://localhost:11434/api/chat")
        }

        test("OllamaTransport body configures num_ctx, think: false, and images array") {
            let testImgData = Data([0x89, 0x50, 0x4E, 0x47])
            let body = OllamaTransport.body(
                model: "gemma4:e2b-it-qat",
                systemPrompt: "You are Chunks.",
                userPrompt: "What am I looking at?",
                images: [(data: testImgData, label: "The user's whole screen.")],
                history: [],
                stream: true,
                numCtx: 16384,
                think: false
            )
            expectEqual(body["model"] as? String, "gemma4:e2b-it-qat")
            expectEqual(body["think"] as? Bool, false)
            let options = body["options"] as? [String: Any]
            expectEqual(options?["num_ctx"] as? Int, 16384, "must provide expanded context so Gemma 4 does not truncate on large system prompts")
            let messages = body["messages"] as? [[String: Any]] ?? []
            expectEqual(messages.count, 2)
            let userMsg = messages.last ?? [:]
            let images = userMsg["images"] as? [String] ?? []
            expectEqual(images.count, 1)
            expectEqual(images.first, testImgData.base64EncodedString())
        }

        test("OllamaTransport stream parser handles NDJSON and ignores thinking scratchpads") {
            let chunkWithThought = #"{"message":{"role":"assistant","content":"","thinking":"User wants help"},"done":false}"#
            let thoughtEvents = OllamaTransport.parse(line: chunkWithThought)
            expect(thoughtEvents.isEmpty, "thinking content should not be surfaced to the user")

            let chunkWithContent = #"{"message":{"role":"assistant","content":"I see your desktop."},"done":false}"#
            let contentEvents = OllamaTransport.parse(line: chunkWithContent)
            expectEqual(contentEvents, [.textDelta("I see your desktop.")])

            let doneChunk = #"{"message":{"role":"assistant","content":""},"done":true}"#
            let doneEvents = OllamaTransport.parse(line: doneChunk)
            expectEqual(doneEvents, [.completed])
        }

        test("model(named:) resolves normalized names like 'gemma 4 e2b' to 'gemma4:e2b-it-qat'") {
            let provider = BrainProvider(
                id: "ollama",
                displayName: "Ollama",
                transport: .openAICompatible,
                baseURL: URL(string: "http://localhost:11434/v1")!,
                models: [
                    BrainModel(id: "qwen3:14b", displayName: "qwen3:14b", visionCapable: false),
                    BrainModel(id: "gemma4:e2b-it-qat", displayName: "gemma4:e2b-it-qat", visionCapable: true),
                    BrainModel(id: "gemma3n:e2b", displayName: "gemma3n:e2b", visionCapable: false)
                ],
                isFree: true
            )
            expectEqual(provider.model(named: "gemma4:e2b-it-qat")?.id, "gemma4:e2b-it-qat")
            expectEqual(provider.model(named: "gemma4:e2b")?.id, "gemma4:e2b-it-qat")
            expectEqual(provider.model(named: "gemma 4 e2b")?.id, "gemma4:e2b-it-qat")
            expectEqual(provider.model(named: "gemma 4")?.id, "gemma4:e2b-it-qat")
        }

        test("OpenAICompatibleTransport content places image_url before text for GGUF template safety") {
            let requestWithImg = TurnRequest(
                question: "what is this?",
                scope: .wholeScreen,
                imageData: Data([0x89, 0x50, 0x4E, 0x47]),
                memoryBlock: "")
            let parts = GeminiRequestBuilder.parts(for: requestWithImg)
            let content = OpenAICompatibleTransport.content(parts)
            expect(!content.isEmpty)
            expectEqual(content.first?["type"] as? String, "image_url",
                        "GGUF multimodal templates require image tokens before text to prevent mistaking images for OCR text")
        }
    }
}
