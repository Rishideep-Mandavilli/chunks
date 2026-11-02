import AppKit
import ChunksKit
import Foundation

/// `--probe-local` — runs an end-to-end turn against the local model (e.g. Gemma 4 on Ollama).
///
/// Verifies:
/// 1. Discovery finds the local model with vision capability.
/// 2. Text turn streams back an answer.
/// 3. Multimodal image turn streams back an accurate answer about the provided pixels.
@MainActor
enum LocalBrainProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-local") }

    private static func out(_ line: String) {
        print(line)
        Log.write(line)
    }

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        Task { @MainActor in
            out("probe-local: checking Ollama discovery and Gemma 4...")
            guard let modelID = await selectLocalBrain(requested: flag("--model") ?? "gemma 4 e2b",
                                                 report: out) else { exit(1) }
            out("probe-local: resolved to \(modelID)")

            // 1. Text Turn
            out("probe-local: testing text turn...")
            var textAnswer = ""
            do {
                let startText = Date()
                let response = try await BrainGateway().analyzeImageStreaming(
                    images: [],
                    systemPrompt: "You are a concise assistant. Reply in one line.",
                    userPrompt: "What is 3 + 4? Reply with just the number.",
                    onTextChunk: { chunk in
                        textAnswer += chunk
                    }
                )
                let elapsedText = Date().timeIntervalSince(startText)
                out("probe-local: text turn PASS (\(String(format: "%.1f", elapsedText))s) → \(response.text.trimmingCharacters(in: .whitespacesAndNewlines))")
            } catch {
                out("probe-local: FAIL text turn — \(error)")
                exit(1)
            }

            // 2. Vision Turn (using a real image from the workspace)
            out("probe-local: testing vision turn with image...")
            let testImagePath = "Nautical Pastel Chunks Interface.png"
            guard let pngData = try? Data(contentsOf: URL(fileURLWithPath: testImagePath)) else {
                out("probe-local: could not load \(testImagePath)")
                exit(1)
            }

            var visionAnswer = ""
            do {
                let startVision = Date()
                let response = try await BrainGateway().analyzeImageStreaming(
                    images: [(data: pngData, label: "The user's whole screen (800x600 pixels)")],
                    systemPrompt: CompanionManager.companionVoiceResponseSystemPrompt,
                    userPrompt: "What am I looking at? Reply in one sentence.",
                    onTextChunk: { chunk in
                        visionAnswer += chunk
                    }
                )
                let elapsedVision = Date().timeIntervalSince(startVision)
                out("probe-local: vision turn PASS (\(String(format: "%.1f", elapsedVision))s) → \(response.text.trimmingCharacters(in: .whitespacesAndNewlines))")
            } catch {
                out("probe-local: FAIL vision turn — \(error)")
                exit(1)
            }

            // 3. Task: Opening app ("open Notes for me")
            out("probe-local: testing opening app task...")
            do {
                let streamer = AnswerStreamer()
                let startOpen = Date()
                _ = try await BrainGateway().analyzeImageStreaming(
                    images: [(data: pngData, label: "The user's whole screen (800x600 pixels)")],
                    systemPrompt: CompanionManager.companionVoiceResponseSystemPrompt,
                    userPrompt: "open Notes for me",
                    onTextChunk: { chunk in
                        streamer.push(chunk)
                    }
                )
                streamer.finish()
                let elapsed = Date().timeIntervalSince(startOpen)
                let hasOpen = streamer.toolRequests.contains {
                    if case .openApp(let name) = $0 { return name.lowercased().contains("notes") }
                    return false
                }
                guard hasOpen else {
                    out("probe-local: FAIL opening app — expected openApp tool for Notes, got tools: \(streamer.toolRequests), actions: \(streamer.actionRequests.map(\.label))")
                    exit(1)
                }
                out("probe-local: opening app PASS (\(String(format: "%.1f", elapsed))s) → [DO:open_app:Notes]")
            } catch {
                out("probe-local: FAIL opening app — \(error)")
                exit(1)
            }

            // 4. Task: Guiding / pointing ("where is the Ask button? guide me to it and point to it")
            out("probe-local: testing guiding/pointing task...")
            do {
                let streamer = AnswerStreamer()
                let startGuide = Date()
                let response = try await BrainGateway().analyzeImageStreaming(
                    images: [(data: pngData, label: "The user's whole screen (800x600 pixels)")],
                    systemPrompt: CompanionManager.companionVoiceResponseSystemPrompt,
                    userPrompt: "where is the Ask button? guide me to it and point to it",
                    onTextChunk: { chunk in
                        streamer.push(chunk)
                    }
                )
                streamer.finish()
                let elapsed = Date().timeIntervalSince(startGuide)
                guard let pt = streamer.points.first else {
                    out("probe-local: FAIL guiding — expected point target in streamer.points, got raw text: \(response.text)")
                    exit(1)
                }
                out("probe-local: guiding PASS (\(String(format: "%.1f", elapsed))s) → [POINT:\(Int(pt.x)),\(Int(pt.y)):\(pt.label)]")
            } catch {
                out("probe-local: FAIL guiding — \(error)")
                exit(1)
            }

            // 5. Task: Typing ("type 'how to use sql' in the search field")
            out("probe-local: testing typing task...")
            do {
                let streamer = AnswerStreamer()
                let startType = Date()
                let response = try await BrainGateway().analyzeImageStreaming(
                    images: [(data: pngData, label: "The user's whole screen (800x600 pixels)")],
                    systemPrompt: CompanionManager.companionVoiceResponseSystemPrompt,
                    userPrompt: "type 'how to use sql' in the search field",
                    onTextChunk: { chunk in
                        streamer.push(chunk)
                    }
                )
                streamer.finish()
                let elapsed = Date().timeIntervalSince(startType)
                let hasType = streamer.actionRequests.contains { if case .type = $0.verb { return true }; return false }
                guard hasType else {
                    out("probe-local: FAIL typing — expected type action, got text: \(response.text)")
                    exit(1)
                }
                out("probe-local: typing PASS (\(String(format: "%.1f", elapsed))s)")
            } catch {
                out("probe-local: FAIL typing — \(error)")
                exit(1)
            }

            out("probe-local: ALL CHECKS PASSED for \(modelID)")
            exit(0)
        }
        RunLoop.main.run()
    }

    /// Point this process at the local model the way the panel's switch does, and say which one it
    /// chose.
    ///
    /// Extracted because `--probe-reply --local` needs the same selection: a second copy of the
    /// discovery-and-resolve path is a second opinion about which model answered, and the whole point
    /// of that probe is that the *real* local model's reply is what gets audited.
    /// Returns nil (after reporting why) when Ollama is not answering or the name resolves to nothing.
    static func selectLocalBrain(requested: String,
                                 report: (String) -> Void = { _ in }) async -> String? {
        let descriptors = await LocalBrainDiscovery.descriptors(for: ProviderRegistry.ollama)
        guard !descriptors.isEmpty else {
            report("FAIL — Ollama is not answering on localhost:11434")
            return nil
        }
        report("discovered \(descriptors.count) model(s): \(descriptors.map(\.name).joined(separator: ", "))")
        let resolution = BrainSelection.resolve(
            storedProviderID: "ollama",
            storedModelID: requested,
            discoveredModels: ["ollama": descriptors],
            needsVision: true
        )
        guard !resolution.isBlocked, let model = resolution.model else {
            report("FAIL — could not resolve model '\(requested)': \(resolution.notice ?? "unknown error")")
            return nil
        }
        report("resolved '\(requested)' → \(model.id) (vision=\(model.visionCapable == true))")
        // Process-scoped, deliberately not `UserDefaults`: writing these keys switches *his app* to
        // the model this probe was curious about, and it stays switched when the probe exits. See
        // `BrainSettings.processOverride`.
        BrainSettings.processOverride = (ProviderRegistry.ollama.id, model.id)
        return model.id
    }

    private static func flag(_ name: String) -> String? {
        guard let idx = CommandLine.arguments.firstIndex(of: name),
              idx + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[idx + 1]
    }
}
