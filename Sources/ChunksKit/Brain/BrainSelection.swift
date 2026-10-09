import Foundation

/// Which brain a turn goes to, decided before any network call.
///
/// The rule that shapes this type: **choosing a local server and having it be down must never
/// fall back to the cloud.** Chunks already sends screenshots to a model, but the user picked
/// "offline" on purpose — quietly uploading the screen because a loopback port was closed would
/// be the worst possible way to honour that choice. So an unavailable local brain is an error the
/// user reads, not a substitution.
///
/// Everything here is pure: the shell hands in stored preferences and whatever the local server
/// advertised, and gets back a provider, a model, and the sentence to say if the answer is not
/// what the user asked for.
public struct BrainSelection: Equatable, Sendable {
    public let providerID: String
    /// nil means "any model that can do the turn", which for Gemini is the measured free-tier chain.
    public let modelID: String?

    public static let cloudDefault = BrainSelection(providerID: "gemini", modelID: nil)

    public init(providerID: String, modelID: String?) {
        self.providerID = providerID
        self.modelID = modelID
    }

    public struct Resolution: Sendable {
        public let provider: BrainProvider
        public let model: BrainModel?
        /// A sentence for the user when what is about to happen is not what a naive reading of the
        /// settings would suggest. Never nil-and-unmentioned when set.
        public let notice: String?
        /// True when the turn must not proceed: the chosen brain cannot do it.
        public let isBlocked: Bool
    }

    public static func resolve(storedProviderID: String?,
                               storedModelID: String?,
                               discoveredModels: [String: [ProviderRegistry.LocalModelDescriptor]] = [:],
                               providers: [BrainProvider] = ProviderRegistry.all,
                               needsVision: Bool) -> Resolution {
        var notice: String?

        let requestedID = storedProviderID?.trimmingCharacters(in: .whitespaces).lowercased()
        var provider = providers.first { $0.id == requestedID }
        if provider == nil, let requestedID, !requestedID.isEmpty {
            notice = "I don't know the brain called \"\(requestedID)\" — using Google Gemini instead."
            provider = providers.first { $0.id == cloudDefault.providerID }
        }
        guard let chosen = provider ?? providers.first(where: { $0.id == cloudDefault.providerID })
                ?? providers.first else {
            return Resolution(provider: ProviderRegistry.gemini, model: nil,
                              notice: "No brain providers are configured.", isBlocked: true)
        }

        // A local provider carries no catalogue: what it can do comes from the server's own
        // answer, capability included, rather than from a list of model names.
        let effective = modelList(for: chosen, discovered: discoveredModels)
        let working = effective.isEmpty ? chosen : BrainProvider(
            id: chosen.id, displayName: chosen.displayName, transport: chosen.transport,
            baseURL: chosen.baseURL, models: effective, isFree: chosen.isFree, notes: chosen.notes)

        guard !working.models.isEmpty else {
            return Resolution(provider: working, model: nil,
                              notice: "\(working.displayName) is not answering on \(working.baseURL.host ?? "localhost"). "
                                + "Start it, or switch back to Gemini.",
                              isBlocked: true)
        }

        let named = storedModelID.flatMap { working.model(named: $0) }
        var model: BrainModel?
        if working.isLoopback {
            // A local server has no measured chain to fall back through, so one model has to be
            // chosen here. If the named one is absent, say so rather than quietly switching.
            if let storedModelID, named == nil {
                notice = "\(working.displayName) has no model called \"\(storedModelID)\" "
                    + "— using what it does have."
            }
            model = named ?? firstUsable(in: working, needsVision: needsVision, notice: &notice)
            if needsVision, let model, model.visionCapable != true {
                notice = "\(model.displayName) has not been verified to read images. "
                    + "If its answer looks invented, pick a vision model (llava, qwen2.5vl, minicpm-v, gemma3)."
            }
        } else {
            // Cloud: `nil` deliberately hands the choice to the measured fallback chain, which is
            // what keeps a Gemini turn behaving exactly as it did before any of this existed.
            model = named
        }

        return Resolution(provider: working, model: model, notice: notice, isBlocked: false)
    }

    /// The model list a provider can actually use right now: its own for a cloud provider,
    /// whatever the local server just advertised for a local one.
    private static func modelList(
        for provider: BrainProvider,
        discovered: [String: [ProviderRegistry.LocalModelDescriptor]]) -> [BrainModel] {
        guard provider.models.isEmpty, let discovered = discovered[provider.id] else {
            return provider.models
        }
        return ProviderRegistry.localModels(from: discovered)
    }

    private static func firstUsable(in provider: BrainProvider, needsVision: Bool,
                                    notice: inout String?) -> BrainModel? {
        if needsVision {
            if let verified = provider.models.first(where: { $0.visionCapable == true }) {
                return verified
            }
            // Nothing looks like a vision model. Do not silently answer from a text-only brain:
            // say what is about to happen and let the user decide whether to read a guess.
            notice = "No \(provider.displayName) model looks able to see. "
                + "Pull a vision model, or ask something that needs no screenshot."
            return provider.models.first
        }
        return provider.models.first
    }
}

extension BrainProvider {
    /// True when this brain runs on the user's own Mac.
    ///
    /// Decides whether Chunks may choose a model itself (a local server has no measured fallback
    /// chain) and whether a key is required at all. A host that is absent is not "local" — that is
    /// a malformed URL, and treating it as loopback would hide a configuration typo behind a
    /// connection refused.
    public var isLoopback: Bool {
        switch baseURL.host?.lowercased() {
        case "localhost", "127.0.0.1", "::1", "[::1]": return true
        default: return false
        }
    }
}
