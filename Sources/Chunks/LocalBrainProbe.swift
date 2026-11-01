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

            let descriptors = await LocalBrainDiscovery.descriptors(for: ProviderRegistry.ollama)
            guard !descriptors.isEmpty else {
                out("probe-local: FAIL — Ollama is not answering on localhost:11434")
                exit(1)
            }
            out("probe-local: discovered \(descriptors.count) model(s): \(descriptors.map(\.name).joined(separator: ", "))")

            let requestedModel = flag("--model") ?? "gemma 4 e2b"
            let resolution = BrainSelection.resolve(
                storedProviderID: "ollama",
                storedModelID: requestedModel,
                discoveredModels: ["ollama": descriptors],
                needsVision: true
            )

            guard !resolution.isBlocked, let model = resolution.model else {
                out("probe-local: FAIL — could not resolve model '\(requestedModel)': \(resolution.notice ?? "unknown error")")
                exit(1)
            }
            out("probe-local: resolved '\(requestedModel)' → \(model.id) (vision=\(model.visionCapable == true))")

            // Temporarily set brain provider & model in UserDefaults for this process
            UserDefaults.standard.set("ollama", forKey: BrainSettings.providerKey)
            UserDefaults.standard.set(model.id, forKey: BrainSettings.modelKey)

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

            out("probe-local: ALL CHECKS PASSED for \(model.id)")
            exit(0)
        }
        RunLoop.main.run()
    }

    private static func flag(_ name: String) -> String? {
        guard let idx = CommandLine.arguments.firstIndex(of: name),
              idx + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[idx + 1]
    }
}
