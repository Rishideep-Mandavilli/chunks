import ChunksKit
import Foundation

/// Asks a local model server what it actually has.
///
/// The registry cannot carry this information: what a Mac can do offline depends on which weights
/// the user pulled, and Ollama reports per-model `capabilities` — including `vision` — that no
/// name list could produce. Measured on this machine, `/api/tags` says `vision` for
/// `gemma4:e2b-it-qat` and not for `qwen3:14b`, which is the whole difference between an answer
/// about the screen and a guess about it.
///
/// Cached for a short window because it is called at the start of every turn, and a loopback
/// request that hangs must not hang the turn with it: the timeout is what makes "Ollama is not
/// answering" an answer rather than a stall.
enum LocalBrainDiscovery {
    private static let cacheSeconds: TimeInterval = 60
    private static let requestTimeout: TimeInterval = 2.5

    private struct Cache {
        var at = Date.distantPast
        var byProvider: [String: [ProviderRegistry.LocalModelDescriptor]] = [:]
    }

    /// Only touched from the main actor: a turn reads it once, and a plain dictionary would be
    /// another race on a thread that has no business owning shared state.
    @MainActor private static var cache = Cache()

    @MainActor
    static func descriptors(for provider: BrainProvider) async -> [ProviderRegistry.LocalModelDescriptor] {
        guard provider.isLoopback else { return provider.models.map {
            ProviderRegistry.LocalModelDescriptor(name: $0.id, reportsVision: $0.visionCapable)
        } }
        if Date().timeIntervalSince(cache.at) < cacheSeconds, let cached = cache.byProvider[provider.id] {
            return cached
        }
        let found = await fetch(from: provider)
        cache.at = Date()
        cache.byProvider[provider.id] = found
        return found
    }

    /// Drop the cache so the next turn re-reads the server. Needed after `ollama pull`, when the
    /// model the user just downloaded is invisible until something refreshes.
    @MainActor
    static func invalidate() {
        cache = Cache()
    }

    private static func fetch(from provider: BrainProvider) async -> [ProviderRegistry.LocalModelDescriptor] {
        var url = provider.baseURL
        // Ollama's capabilities live on its own endpoint; the OpenAI-compatible `/models` list is
        // name-only and is what everything else, including LM Studio, answers with.
        if provider.id == "ollama" {
            let root = provider.baseURL.absoluteString.replacingOccurrences(of: "/v1", with: "")
            url = URL(string: root + "/api/tags") ?? provider.baseURL
        } else {
            let trimmed = url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
            url = URL(string: trimmed + "/models") ?? url
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            Log.write("brain: discovery found nothing at \(url.absoluteString)")
            return []
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> [ProviderRegistry.LocalModelDescriptor] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        if let models = object["models"] as? [[String: Any]] {
            return models.compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                let capabilities = (entry["capabilities"] as? [String]) ?? []
                let reportsVision: Bool? = capabilities.isEmpty ? nil
                    : capabilities.contains("vision")
                return ProviderRegistry.LocalModelDescriptor(name: name, reportsVision: reportsVision)
            }
        }

        // OpenAI-compatible shape: {"data":[{"id":"..."}]} — names only, so capability stays
        // unknown and the name heuristic decides, with the warning path covering the rest.
        if let list = object["data"] as? [[String: Any]] {
            return list.compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                return ProviderRegistry.LocalModelDescriptor(name: id, reportsVision: nil)
            }
        }
        return []
    }
}

/// Where the user's choice of brain is stored.
///
/// `UserDefaults`, not the Keychain, exactly like `askBeforeActing`: this is a switch, not a
/// secret. Keeping it out of the Keychain is what lets it be flipped from a terminal while
/// debugging, which is the only way anyone is going to compare two brains.
enum BrainSettings {
    static let providerKey = "app.chunks.brainProvider"
    static let modelKey = "app.chunks.brainModel"

    /// The names the panel and a `defaults write` both accept.
    static let knownIDs = ["gemini", "ollama", "lm-studio"]
}
