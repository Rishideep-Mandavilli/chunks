import Foundation

/// Whether Chunks should ask the machine not to idle-sleep.
///
/// The reason this exists is the schedule: a reminder armed for 20:00 that never arrives because the
/// Mac dozed at 19:40 is a broken promise, and the firing path deliberately refuses to speak into a
/// sleeping display rather than capture a black screen. Both are correct separately and useless
/// together unless something keeps the process runnable, which is exactly what a power assertion is.
///
/// The decision is here, in the pure layer, and the `IOPMAssertion` call is in the shell: this rule
/// is testable without a machine that sleeps.
public enum SleepPolicy {

    /// A preference, not a secret, so `UserDefaults` and no Keychain prompt — the same choice
    /// `askBeforeActing` made.
    public static let settingKey = "chunksKeepAwakeForSchedules"

    /// Hold only when he asked for it *and* something is actually waiting.
    ///
    /// The second half is what stops the app from holding his laptop awake all day on the strength of
    /// a switch he left on for one reminder: with nothing armed there is nothing to be on time for.
    public static func shouldHold(enabled: Bool, anythingArmed: Bool) -> Bool {
        enabled && anythingArmed
    }

    /// The line under the row, saying what is true rather than what was asked.
    ///
    /// A toggle that shows the wish instead of the state is the mistake `LoginItem` documents: macOS
    /// can refuse an assertion, and "On" over a refusal is a lie about why his Mac slept anyway.
    public static func describe(holding: Bool, enabled: Bool, armedCount: Int) -> String {
        if !enabled { return "Off — the Mac may sleep between scheduled things." }
        if armedCount == 0 { return "On, with nothing waiting, so the Mac sleeps normally." }
        if holding {
            return "Holding the Mac awake for \(armedCount) waiting thing\(armedCount == 1 ? "" : "s")."
        }
        return "Asked to hold, and the machine did not take the request."
    }
}
