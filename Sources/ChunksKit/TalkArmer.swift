import Foundation

/// What a push-to-talk key event should do, once taps and holds are told apart.
public enum TalkArmingAction: Equatable {
    /// Start a dictation, as push-to-talk always has.
    case beginListening
    /// The key came up inside a tap: keep the microphone open and wait for more speech.
    case stayArmed
    /// End the dictation and send what was heard.
    case stopAndSubmit
    /// Nothing to do — a duplicate, or an event that belongs to no dictation.
    case ignore
}

/// Tap-to-arm layered over hold-to-talk, so both work and neither needs a settings switch.
///
/// Holding Control for the length of a sentence is the ergonomics the user objected to; a tap
/// that arms and a second tap that sends fixes that. A pure tap-first design cannot be dropped
/// onto a keyboard he has been using for weeks, so a hold longer than the threshold still means
/// exactly what it meant yesterday: releasing stops and sends. That keeps the change reversible
/// mid-sentence — hold when you want the old behaviour, tap when you don't — instead of teaching
/// one gesture and forgetting the other.
///
/// The machine deliberately knows nothing about `AVAudioEngine` or the HUD: the timing rule is
/// the part that fails silently when wrong (a lost release leaves the microphone open), so it is
/// the part worth testing.
public struct TalkArmer {
    /// How long a press may last and still count as a tap.
    ///
    /// 350 ms is above a double-tap's individual stroke and below the time it takes to decide to
    /// keep holding, so a deliberate hold is never mistaken for an accidental arm.
    public static let defaultTapThresholdSeconds: Double = 0.35

    public let tapThresholdSeconds: Double

    /// True between a tap that armed the session and the event that ends it.
    public private(set) var isArmed = false

    private var pressStart: Date?
    private var isRecording = false
    /// The press that ended an armed dictation also produces a release; that release belongs to
    /// a session that is already over, and stopping twice would be a second submit.
    private var swallowNextRelease = false

    public init(tapThresholdSeconds: Double = TalkArmer.defaultTapThresholdSeconds) {
        self.tapThresholdSeconds = tapThresholdSeconds
    }

    public mutating func press(at date: Date) -> TalkArmingAction {
        if isArmed {
            reset()
            swallowNextRelease = true
            return .stopAndSubmit
        }
        if isRecording { return .ignore }

        isRecording = true
        pressStart = date
        return .beginListening
    }

    public mutating func release(at date: Date) -> TalkArmingAction {
        if swallowNextRelease {
            swallowNextRelease = false
            return .ignore
        }
        guard isRecording, let startedAt = pressStart else { return .ignore }

        let heldSeconds = date.timeIntervalSince(startedAt)
        pressStart = nil

        // Short: stay open and wait, so the next words land in the same dictation.
        if heldSeconds < tapThresholdSeconds {
            isArmed = true
            return .stayArmed
        }

        isRecording = false
        return .stopAndSubmit
    }

    /// Forget everything. Called when the dictation ends by some other route — an error, the
    /// fallback timer, a send — because an armer that still believes it is armed turns the next
    /// press into a stop for a session that does not exist, which reads as a dead hotkey.
    public mutating func reset() {
        isArmed = false
        isRecording = false
        pressStart = nil
        swallowNextRelease = false
    }
}
