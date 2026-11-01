import ChunksKit
import Foundation

/// `--probe-thinking` — find the thinking-budget field the Interactions API accepts, and measure
/// what it costs to ask for a small answer with and without it.
///
/// Tonight's log says every served turn pays 7–19s discovering the leader is contended and then
/// 8–16s answering, and the dead ones went silent for 20s before any token — the signature of a
/// Gemini 3.x model thinking before it speaks. The request body today carries no control for it.
/// Guessing a field name is not an option: a wrong one 400s every turn, so this probe asks the
/// live API which shapes it accepts, and times the winner against the baseline, alternating runs
/// so a contention spike cannot masquerade as a win.
///
/// It sends a two-word text prompt and no screenshot, and it never prints the key.
@MainActor
enum ThinkingProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-thinking") }

    private static func out(_ line: String) {
        print(line)
        Log.write(line)
    }

    /// Candidate placements for "think less", in the order the two API generations suggest them.
    /// A 400 that names the field means the shape is wrong; 2xx means it is accepted; 429/503
    /// means the shape was not rejected — the model was merely busy.
    private static let candidates: [(name: String, inject: (inout [String: Any]) -> Void)] = [
        ("baseline (no thinking field)", { _ in }),
        ("generation_config.thinking.thinking_budget = 0", { body in
            body["generation_config"] = ["thinking": ["thinking_budget": 0]]
        }),
        ("generation_config.thinking_budget = 0", { body in
            body["generation_config"] = ["thinking_budget": 0]
        }),
        ("generation_config.thinking_level = low", { body in
            body["generation_config"] = ["thinking_level": "low"]
        }),
        ("generation_config.thinking.level = low", { body in
            body["generation_config"] = ["thinking": ["level": "low"]]
        }),
        ("top-level thinking_level = low", { body in
            body["thinking_level"] = "low"
        }),
    ]

    private static let model = "gemini-3.6-flash"

    private static func requestBody(_ inject: (inout [String: Any]) -> Void) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "store": false,
            "input": [[
                "type": "user_input",
                "content": [[
                    "type": "text",
                    "text": "Reply with exactly: ok",
                ]],
            ]],
            "system_instruction": "Answer with only the word the user asked for.",
        ]
        inject(&body)
        return body
    }

    private static func ask(_ key: String,
                            _ inject: (inout [String: Any]) -> Void) async
    throws -> (status: Int, seconds: Double, excerpt: String) {
        var request = URLRequest(url: URL(
            string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(GeminiRequestBuilder.apiRevision, forHTTPHeaderField: "Api-Revision")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(inject), options: [])
        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let seconds = Date().timeIntervalSince(started)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let excerpt = String(decoding: data.prefix(220), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
        return (status, seconds, excerpt)
    }

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        Task { @MainActor in
            let key: String
            do {
                key = try KeychainStore.geminiKey()
            } catch {
                out("SKIP: probe-thinking — no Gemini key stored, nothing to ask: \(error)")
                Log.flush()
                exit(3)
            }

            out("probe-thinking: shape test — \(model), two-word prompt, no screenshot")
            var accepted: [(name: String, inject: (inout [String: Any]) -> Void)] = []
            for candidate in candidates {
                do {
                    let (status, seconds, excerpt) = try await ask(key, candidate.inject)
                    let verdict: String
                    switch status {
                    case 200 ... 299: verdict = "ACCEPTED"
                    case 400: verdict = "REJECTED"
                    case 429, 503: verdict = "PLAUSIBLE (rate-limited, field not rejected)"
                    default: verdict = "status \(status)"
                    }
                    out("probe-thinking: \(candidate.name) — \(verdict) in \(String(format: "%.1f", seconds))s")
                    if status == 400 {
                        out("    server said: \(excerpt.prefix(180))")
                    }
                    if status != 400, !candidate.name.hasPrefix("baseline") {
                        accepted.append((candidate.name, candidate.inject))
                    }
                } catch {
                    out("probe-thinking: \(candidate.name) — transport error: \(error)")
                }
            }

            guard let winner = accepted.first else {
                out("probe-thinking: no candidate shape was accepted — the baseline stays, "
                    + "and the answer lives in the tier, not the body")
                Log.flush()
                exit(1)
            }
            // Which words the accepted field takes: only 400s are evidence here — a 429 means
            // the value parsed and the model was simply busy.
            out("probe-thinking: value sweep on \(winner.name)")
            var goodValues: [String] = []
            for value in ["none", "minimal", "low", "medium", "high"] {
                let inject: (inout [String: Any]) -> Void = { body in
                    body["generation_config"] = ["thinking_level": value]
                }
                if let (status, _, excerpt) = try? await ask(key, inject) {
                    let verdict = status == 400 ? "REJECTED" : "accepted(\(status))"
                    out("    thinking_level=\"\(value)\" — \(verdict)"
                        + (status == 400 ? " \(excerpt.prefix(120))" : ""))
                    if status != 400 { goodValues.append(value) }
                }
            }
            guard !goodValues.isEmpty else {
                out("probe-thinking: the field exists but took none of the tested values")
                Log.flush()
                exit(1)
            }
            let chosen = goodValues.first(where: { $0 == "minimal" }) ?? goodValues.first!
            let chosenInject: (inout [String: Any]) -> Void = { body in
                body["generation_config"] = ["thinking_level": chosen]
            }
            out("probe-thinking: timing thinking_level=\"\(chosen)\" against the baseline, "
                + "alternating, counting only real answers")
            var baselineSeconds: [Double] = []
            var winnerSeconds: [Double] = []
            for round in 1...5 {
                if let (status, seconds, _) = try? await ask(key, { _ in }), status == 200 {
                    baselineSeconds.append(seconds)
                }
                if let (status, seconds, _) = try? await ask(key, chosenInject), status == 200 {
                    winnerSeconds.append(seconds)
                }
                out("    round \(round): baseline \(baselineSeconds.count) answered"
                    + " · thinking_level \(winnerSeconds.count) answered")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            func median(_ xs: [Double]) -> Double {
                let sorted = xs.sorted()
                guard !sorted.isEmpty else { return -1 }
                return sorted[sorted.count / 2]
            }
            out("probe-thinking: median baseline \(String(format: "%.1f", median(baselineSeconds)))s"
                + " vs thinking_level=\"\(chosen)\" "
                + "\(String(format: "%.1f", median(winnerSeconds)))s"
                + " over \(baselineSeconds.count)/\(winnerSeconds.count) real answers")
            Log.flush()
            exit(baselineSeconds.isEmpty || winnerSeconds.isEmpty ? 3 : 0)
        }
        RunLoop.main.run()
    }
}
