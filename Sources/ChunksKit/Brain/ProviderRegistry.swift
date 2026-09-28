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
        models.first { $0.id == name }
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
    /// `visionCapable` values are from live probes: a synthetic shape image was described
    /// correctly by each of these, and a real 3420x2214 screenshot was read correctly.
    ///
    /// Order matters — `fallbackChain` walks it. Newest first, because that is what the
    /// user wants; the flash-lite tiers at the end are what absorbs `503 high demand`.
    public static let geminiFreeModels: [BrainModel] = [
        BrainModel(id: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash",
                   visionCapable: true, contextTokens: 200_000,
                   costPerMTokIn: 0, costPerMTokOut: 0),
        BrainModel(id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro",
                   visionCapable: true, contextTokens: 200_000,
                   costPerMTokIn: 0, costPerMTokOut: 0),
        BrainModel(id: "gemini-3.6-flash", displayName: "Gemini 3.6 Flash",
                   visionCapable: true, costPerMTokIn: 0, costPerMTokOut: 0),
        BrainModel(id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash Lite",
                   visionCapable: true, costPerMTokIn: 0, costPerMTokOut: 0),
        BrainModel(id: "gemini-flash-lite-latest", displayName: "Gemini Flash Lite (latest)",
                   visionCapable: true, costPerMTokIn: 0, costPerMTokOut: 0),
    ]

    /// Rate limit observed on the free tier: 5 requests/minute per model.
    public static let freeTierRequestsPerMinute = 5

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

    public static let all: [BrainProvider] = [gemini, openCodeZen]

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
