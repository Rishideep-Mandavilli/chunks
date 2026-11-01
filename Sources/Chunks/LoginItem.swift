import Foundation
import ServiceManagement

/// Whether Chunks starts at login — a state, a control, and an honest read-back.
///
/// The app used to call `SMAppService.mainApp.register()` on every launch once onboarding was
/// done. That is a login item the user never asked for, reported only to `print()` (unreadable for
/// an app started by `open`), with no way back except finding the row in System Settings. It also
/// interacted with the build story badly: an ad-hoc-signed rebuild is a *different app* to macOS,
/// so re-registering on every launch filled the login list with entries that could never run.
///
/// `SMAppService` is also the one permission macOS may refuse silently. A registration can come
/// back as `.requiresUserApproval` — registered, and inert until the user flips the switch — and a
/// toggle that read that as "on" would be lying about the machine's state.
enum LoginItem {

    enum State: Equatable {
        case off
        case on
        case needsApproval
        /// `SMAppService` exists only for a properly bundled app with a real signature, so a bare
        /// SwiftPM binary — which is what `swift run` gives you — cannot answer this question at
        /// all. Saying so beats showing a switch that does nothing.
        case unavailable(String)

        var isEnabled: Bool { self == .on }
    }

    private static var service: SMAppService { SMAppService.mainApp }

    static var state: State {
        switch service.status {
        case .notRegistered: return .off
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        @unknown default: return .unavailable("macOS reported a status this build does not know")
        }
    }

    /// Ask macOS to start (or stop) launching Chunks at login, and return the state it actually
    /// ended in. Never the state that was requested.
    static func set(enabled: Bool) -> State {
        if enabled {
            guard state != .on else { return .on }
            do {
                try service.register()
            } catch {
                Log.write("login: register failed — \(error.localizedDescription)")
                return state == .on ? .on : .unavailable(error.localizedDescription)
            }
        } else {
            guard state != .off else { return .off }
            do {
                try service.unregister()
            } catch {
                Log.write("login: unregister failed — \(error.localizedDescription)")
                return state
            }
        }
        let settled = state
        Log.write("login: \(enabled ? "requested" : "removed") — macOS says \(describe(settled))")
        return settled
    }

    static func describe(_ state: State) -> String {
        switch state {
        case .off: return "not registered"
        case .on: return "on"
        case .needsApproval: return "registered, waiting for you in System Settings"
        case .unavailable(let why): return "unavailable (\(why))"
        }
    }
}
