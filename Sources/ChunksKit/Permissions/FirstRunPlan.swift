import Foundation

/// The order a stranger walks once, and the rule for when each step is done.
///
/// The panel already holds every control this needs — five permission rows, the key field, the
/// offline switch, the login row — but a panel of controls is not a flow: nothing in it says what
/// to do first, what unblocks what, or when the machine is actually ready to be used. This is
/// that order, as data, so the setup window can draw it and a test can prove a stranger can
/// finish it. Tier 4.3's bar is the one that shapes the rules: a buyer with no API key must still
/// leave with a working assistant, so the brain step accepts the local model as a complete
/// answer, not as a consolation.
public enum FirstRunStep: Int, CaseIterable, Sendable {
    case permissions, brain, finish

    public var title: String {
        switch self {
        case .permissions: return "Let Chunks see and hear"
        case .brain: return "Choose what answers"
        case .finish: return "Keep Chunks running"
        }
    }

    public var indexLabel: String { "Step \(rawValue + 1) of \(FirstRunStep.allCases.count)" }
}

public struct FirstRunPlan: Equatable, Sendable {
    public var permissions: PermissionState
    public var hasKey: Bool
    public var offlineBrainOn: Bool
    public var finished: Bool

    public init(permissions: PermissionState, hasKey: Bool, offlineBrainOn: Bool,
                finished: Bool) {
        self.permissions = permissions
        self.hasKey = hasKey
        self.offlineBrainOn = offlineBrainOn
        self.finished = finished
    }

    public func isComplete(_ step: FirstRunStep) -> Bool {
        switch step {
        case .permissions: return PermissionState.allGranted(for: permissions)
        // "No key, no cloud" is a product tier, not a broken state: the local switch completes
        // this step exactly as a pasted key does.
        case .brain: return hasKey || offlineBrainOn
        case .finish: return finished
        }
    }

    /// The step the window shows: the first unfinished one. You cannot skip ahead, because the
    /// brain step's summary ("what would answer on this Mac") only means something once the
    /// screen and microphone are in, and the finish step's promise only means something once
    /// something can answer.
    public var currentStep: FirstRunStep {
        FirstRunStep.allCases.first { !isComplete($0) } ?? .finish
    }

    /// Whether the whole flow is done — the only state in which the window may close itself.
    public var isComplete: Bool { FirstRunStep.allCases.allSatisfy(isComplete) }

    /// The one sentence a stranger needs before pasting a credential anywhere.
    public static let keySentence =
        "Paste a Gemini key from aistudio.google.com/apikey. It goes into your Mac's Keychain and nowhere else."

    /// The no-key path, said as a tier rather than as a fallback.
    public static let offlineSentence =
        "No key? Answer on this Mac instead — nothing leaves it, and the answers come from a model already installed."

    /// Why a step still shows "Needed" after the tick: the two grants macOS applies only on the
    /// next launch. Said here so the window, the panel and the tests all use one sentence.
    public static let restartSentence =
        "Screen Recording and Input Monitoring apply on the next launch — press Restart when you have ticked them."
}
