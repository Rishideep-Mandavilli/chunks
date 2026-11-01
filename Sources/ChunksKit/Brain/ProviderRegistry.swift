import Foundation

/// A brain Chunks can talk to.
///
/// Every provider carries a **capability profile**. This is the whole point of the type:
/// "explain my screen" needs a model that can see, and switching brains must never silently
/// hand a screenshot to something that can't read it.
public struct BrainProvider: Identifiable, Equatable, Sendable {
    public enum Transport: String, Sendable {
        /// Google Gemini Interactions API. The current surface — `generateContent` returns
        /// *"no longer available to new users"* for retired models.
        case geminiInteractions
        /// OpenAI-compatible `/chat/completions`, e.g. OpenCode Zen, Ollama, Groq.
        case openAICompatible
        /// Anthropic Messages API.
        case anthropicMessages
    }

    public let id: String
    public let displayName: String
    public let transport: Transport
    public let baseURL: URL
    public let models: [BrainModel]
    public let isFree: Bool
    public let notes: String

    public init(id: String, displayName: String, transport: Transport, baseURL: URL,
                models: [BrainModel], isFree: Bool, notes: String = "") {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.baseURL = baseURL
        self.models = models
        self.isFree = isFree
        self.notes = notes
    }

    public func model(named name: String) -> BrainModel? {
        if let exact = models.first(where: { $0.id == name }) {
            return exact
        }
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let caseMatch = models.first(where: { $0.id.lowercased() == lower }) {
            return caseMatch
        }
        // Normalized matching: ignore spaces, hyphens, and colons to match user queries
        // like "gemma 4", "gemma 4 e2b", "gemma4:e2b" against "gemma4:e2b-it-qat".
        let cleanName = lower.replacingOccurrences(of: " ", with: "")
                             .replacingOccurrences(of: "-", with: "")
                             .replacingOccurrences(of: ":", with: "")
        guard !cleanName.isEmpty else { return nil }
        return models.first(where: {
            let cleanID = $0.id.lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
            if cleanID == cleanName || cleanID.hasPrefix(cleanName) || cleanName.hasPrefix(cleanID) {
                return true
            }
            if cleanName.contains("4b") && (cleanID.contains("e4b") || cleanID.contains("4b")) {
                return true
            }
            if cleanName.contains("2b") && (cleanID.contains("e2b") || cleanID.contains("2b")) {
                return true
            }
            return false
        })
    }
}

/// One model within a provider.
public struct BrainModel: Equatable, Sendable {
    public let id: String
    public let displayName: String

    /// `nil` means **unknown**, not `false`. Chunks resolves this by probing with a tiny
    /// test image rather than trusting a list. Assuming "no" would silently disable the
    /// core feature; assuming "yes" would send images into a text-only model.
    public let visionCapable: Bool?

    public let contextTokens: Int?
    public let costPerMTokIn: Double?
    public let costPerMTokOut: Double?

    public init(id: String, displayName: String, visionCapable: Bool?,
                contextTokens: Int? = nil,
                costPerMTokIn: Double? = nil, costPerMTokOut: Double? = nil) {
        self.id = id
        self.displayName = displayName
        self.visionCapable = visionCapable
        self.contextTokens = contextTokens
        self.costPerMTokIn = costPerMTokIn
        self.costPerMTokOut = costPerMTokOut
    }

    public var costPerTurn: Double? {
        guard let i = costPerMTokIn, let o = costPerMTokOut else { return nil }
        // Measured on this machine: a full-screen screenshot is ~1,066 image tokens and a
        // typical turn is ~1,200 tokens total. See CHUNKS-BUILD-PLAN.md.
        let tokens = 1_200.0
        return (i * tokens + o * 150) / 1_000_000
    }

    public var isFree: Bool { (costPerMTokIn ?? 0) == 0 && (costPerMTokOut ?? 0) == 0 }
}

// MARK: - Registry

/// The catalogue of brains Chunks knows about.
public struct ProviderRegistry: Sendable {

    public static let geminiBase = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    /// Free-tier Gemini models, measured rather than assumed.
    ///
    /// Rate limit observed on the free tier: 5 requests/minute per model.
    public static let freeTierRequestsPerMinute = 5

    /// Order matters — `fallbackChain` walks it, and a turn is only as fast as the model it lands
    /// on. This order is measured on one key across 161 finished turns (2026-10-23/24), not assumed:
    ///
    /// | model | turns served | median | p90 | failures | median time to fail |
    /// |---|---|---|---|---|---|
    /// | `gemini-3.6-flash` | 73 | **10.5s** | 17.8s | 136 | **1.5s** |
    /// | `gemini-3.1-flash-lite` | 62 | 14.5s | 47.8s | **9** | 5.2s |
    /// | `gemini-3.8-flash` | 25 | 24.2s | 61.6s | 116 | 4.8s |
    /// | `gemini-flash-lite-latest` | 1 | 51.4s | — | 0 | — |
    ///
    /// So: the fastest model first, because its refusal costs 1.5s and trying it is nearly free.
    /// **The reliable one second**, because that is where the chain lands after the first refusal —
    /// and because the hedge asks this slot alongside the leader, the partner is now the model least
    /// likely to be contended rather than the one with the highest number in its name. `3.8-flash`
    /// dropped to third on its own numbers: a 24s median and a 61s p90 mean it cannot win inside a
    /// 12-second slice, so keeping it second spent a slice on it every single turn. Pro stays last:
    /// measured 55s and still came back contended.
    public static let geminiFreeModels: [BrainModel] = [
        BrainModel(id: "gemini-3.6-flash", displayName: "Gemini 3.6 Flash",
                   visionCapable: true, costPerMTokIn: 0, costPerMTokOut: 0),
        BrainModel(id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash Lite",
                   visionCapable: true, costPerMTokIn: 0, costPerMTokOut: 0),
        BrainModel(id: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash",
                   visionCapable: true, contextTokens: 200_000,
                   costPerMTokIn: 0, costPerMTokOut: 0),
        BrainModel(id: "gemini-flash-lite-latest", displayName: "Gemini Flash Lite (latest)",
                   visionCapable: true, costPerMTokIn: 0, costPerMTokOut: 0),
        BrainModel(id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro",
                   visionCapable: true, contextTokens: 200_000,
                   costPerMTokIn: 0, costPerMTokOut: 0),
    ]

    /// The model a turn starts on when nothing has been chosen. Same measurement as the chain:
    /// the tier that has never refused a request on this account.
    public static let defaultFreeModelID = "gemini-3.6-flash"

    public static let gemini = BrainProvider(
        id: "gemini",
        displayName: "Google Gemini",
        transport: .geminiInteractions,
        baseURL: geminiBase,
        models: geminiFreeModels,
        isFree: true,
        notes: "Free tier. ~1,066 image tokens per full-screen screenshot. Sometimes returns 503 high demand; Chunks falls back automatically."
    )

    /// Present but unconfigured. Its `*-free` models are **client-locked to the OpenCode
    /// app** — an external caller gets `403 FreeTierError` — so they are listed as
    /// unreachable rather than quietly offered.
    public static let openCodeZen = BrainProvider(
        id: "opencode-zen",
        displayName: "OpenCode Zen (optional)",
        transport: .openAICompatible,
        baseURL: URL(string: "https://opencode.ai/zen/v1")!,
        models: [
            BrainModel(id: "deepseek-v4-flash-vision-exp", displayName: "DeepSeek V4 Flash Vision",
                       visionCapable: true, costPerMTokIn: 0.14, costPerMTokOut: 0.28),
            BrainModel(id: "gpt-6-luna", displayName: "GPT-6 Luna",
                       visionCapable: true, contextTokens: 272_000,
                       costPerMTokIn: 0.10, costPerMTokOut: 0.50),
        ],
        isFree: false,
        notes: "Needs credits. 30+ models on one key — useful when you want to switch brains. The *-free* models are client-locked to the OpenCode app and cannot be reached from Chunks."
    )

    // MARK: - Local, offline brains

    /// Ollama on this Mac. No key, no network.
    ///
    /// `models` is empty on purpose: what a local server can do depends entirely on which
    /// weights the user has pulled, so the list is discovered from the server itself at run
    /// time (`/v1/models`) rather than guessed from a catalogue. A provider with no models
    /// means "not running", and `BrainSelection` says so instead of failing as an empty chain.
    public static let ollama = BrainProvider(
        id: "ollama",
        displayName: "Ollama (this Mac)",
        transport: .openAICompatible,
        baseURL: URL(string: "http://localhost:11434/v1")!,
        models: [],
        isFree: true,
        notes: "Works with no internet. Needs a vision model pulled for screen answers, e.g. llava, qwen2.5vl, minicpm-v or gemma3."
    )

    public static let lmStudio = BrainProvider(
        id: "lm-studio",
        displayName: "LM Studio (this Mac)",
        transport: .openAICompatible,
        baseURL: URL(string: "http://localhost:1234/v1")!,
        models: [],
        isFree: true,
        notes: "Works with no internet. Start the server with CORS enabled and a vision model loaded, or Chunks can read the screen at all."
    )

    /// Names that are known to read images, matched against what a local server advertises.
    ///
    /// This is a *guess with a source*, not a capability claim: local servers publish model names
    /// and nothing about their modalities. A match means Chunks will send the screenshot without a
    /// warning; no match means `nil` — unknown — and the turn still runs, but says out loud that
    /// the model has not been verified to see. Assuming `false` here would disable the product's
    /// core feature for every local model, which is the failure invariant 5 was written to avoid.
    public static let localVisionNameMarkers = [
        "llava", "vision", "-vl", "minicpm-v", "gemma3", "phi4-multimodal", "moondream",
        "qwen-vl", "pixtral", "glm-4v", "internvl", "molmo", "skywork-vi", "llama4",
        "apriel", "nanobanana", "coca", "janus",
    ]

    public static func localVisionGuess(modelID: String) -> Bool? {
        let lowered = modelID.lowercased()
        return localVisionNameMarkers.contains { lowered.contains($0) } ? true : nil
    }

    /// Turn a server's advertised model names into a usable list, ordered so that anything known
    /// to read images comes first — a vision turn should not have to fail its way down the list.
/// A model a local server advertised, with whatever the server itself said about it.
    ///
    /// Ollama's `/api/tags` answers with a `capabilities` array that includes `vision`, which is
    /// authoritative in a way a name never is: `gemma4:e2b-it-qat` on this Mac sees images, and
    /// `qwen3:14b` does not, and no marker list could have told Chunks that. The name heuristic
    /// stays as the fallback for servers that report nothing.
    public struct LocalModelDescriptor: Equatable, Sendable {
        public let name: String
        /// What the server reported. nil means the server did not say.
        public let reportsVision: Bool?

        public init(name: String, reportsVision: Bool?) {
            self.name = name
            self.reportsVision = reportsVision
        }
    }

    public static func localModels(from descriptors: [LocalModelDescriptor]) -> [BrainModel] {
        let models = descriptors.map { descriptor in
            BrainModel(id: descriptor.name, displayName: descriptor.name,
                       visionCapable: descriptor.reportsVision
                        ?? localVisionGuess(modelID: descriptor.name))
        }
        let visionFirst = models.filter { $0.visionCapable == true }
        let rest = models.filter { $0.visionCapable != true }
        return visionFirst + rest
    }
    public static func localModels(discovered names: [String]) -> [BrainModel] {
        let models = names.map { name in
            BrainModel(id: name, displayName: name,
                       visionCapable: localVisionGuess(modelID: name))
        }
        // Stable partition: verified-looking first, everything else in the server's own order.
        let visionFirst = models.filter { $0.visionCapable == true }
        let rest = models.filter { $0.visionCapable != true }
        return visionFirst + rest
    }

    /// A local provider with its models discovered. Keeps the registry's identity (id, base URL,
    /// display name) and replaces only the model list.
    public static func localProvider(_ base: BrainProvider, discovered names: [String]) -> BrainProvider {
        BrainProvider(id: base.id, displayName: base.displayName, transport: base.transport,
                      baseURL: base.baseURL, models: localModels(discovered: names),
                      isFree: base.isFree, notes: base.notes)
    }

    public static let all: [BrainProvider] = [gemini, openCodeZen, ollama, lmStudio]

    public init() {}

    public func provider(id: String) -> BrainProvider? {
        ProviderRegistry.all.first { $0.id == id }
    }

    // MARK: - Routing

    /// Models to try, in order, for a turn that needs vision.
    ///
    /// Starts at `preferred` if it is vision-capable, then walks the provider's list.
    /// Models whose capability is still unknown are **excluded** — Chunks probes first.
    /// Sending a screenshot to an unverified model is exactly the silent failure the
    /// capability flag exists to prevent.
    public func visionFallbackChain(provider: BrainProvider, preferred: String?) -> [BrainModel] {
        let eligible = provider.models.filter { $0.visionCapable == true }
        return ProviderRegistry.preferring(eligible, preferred)
    }

    /// Models to try for a turn that needs no image (e.g. "remind me what that Xcode
    /// panel was"). Any model qualifies.
    public func textFallbackChain(provider: BrainProvider, preferred: String?) -> [BrainModel] {
        ProviderRegistry.preferring(provider.models, preferred)
    }

    /// Move `preferred` to the front if present, otherwise preserve declaration order.
    ///
    /// Done by index rather than a `sorted(by:)`: a comparator that returns `false` for
    /// everything except the preferred element is not a strict weak ordering, and the sort
    /// is then free to reorder the remaining models unpredictably.
    private static func preferring(_ models: [BrainModel], _ preferred: String?) -> [BrainModel] {
        guard let preferred,
              let index = models.firstIndex(where: { $0.id == preferred }) else { return models }
        var out = models
        let chosen = out.remove(at: index)
        out.insert(chosen, at: 0)
        return out
    }

    /// Resolve a turn's routing, honouring a capability requirement.
    ///
    /// Returns the chain plus a human-readable note when the preferred model was *not*
    /// usable, so the caller can say so out loud rather than quietly doing something else.
    public func resolve(provider: BrainProvider,
                        preferred: String?,
                        needsVision: Bool) -> (chain: [BrainModel], warning: String?) {
        let chain = needsVision
            ? visionFallbackChain(provider: provider, preferred: preferred)
            : textFallbackChain(provider: provider, preferred: preferred)

        guard !chain.isEmpty else {
            return ([], needsVision
                    ? "\(provider.displayName) has no verified image-capable model."
                    : "\(provider.displayName) has no models available.")
        }

        var warning: String?
        if let preferred, !chain.contains(where: { $0.id == preferred }) {
            let model = provider.model(named: preferred)
            if needsVision {
                warning = "\(model?.displayName ?? preferred) can't be verified for images, so I'm using \(chain[0].displayName) instead."
            } else {
                warning = "\(model?.displayName ?? preferred) isn't available, so I'm using \(chain[0].displayName) instead."
            }
        }
        return (chain, warning)
    }
}
