import Foundation
import ChunksKit

/// Where the owner's Nod server lives and the token that dispatches to it.
///
/// The address is a preference (a tailnet URL, not a secret) so it lives in UserDefaults; the dispatch
/// token is a credential and lives in the Keychain. The bridge is only offered once both are present,
/// so a half-configured bridge is a refusal in words rather than a request that cannot authenticate.
enum NodBridgeSettings {
    static let urlKey = "nodBridgeURL"

    static var baseURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: urlKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else { return nil }
        return url
    }

    static var configuration: NodBridgeConfiguration? {
        guard let baseURL, let token = KeychainStore.nodBridgeToken() else { return nil }
        return NodBridgeConfiguration(baseURL: baseURL, token: token)
    }

    static var isConfigured: Bool { configuration != nil }

    @discardableResult
    static func configure(url: String, token: String) -> Bool {
        UserDefaults.standard.set(url, forKey: urlKey)
        return KeychainStore.setNodBridgeToken(token)
    }
}