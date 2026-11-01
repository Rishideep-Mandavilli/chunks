import Foundation
import IOKit.pwr_mgt

/// Holds the one power assertion Chunks ever asks for: do not idle-sleep while something is waiting
/// to be said.
///
/// Deliberately `kIOPMAssertionTypePreventUserIdleSystemSleep` rather than the display type. The
/// system has to stay runnable so the minute clock keeps ticking and a reminder arrives at the hour
/// he named; the screen does not have to stay lit, and keeping it lit would be a claim on his battery
/// for a reason nobody asked for. This is a request, not a guarantee — the kernel answers with a
/// status code, and `set` reports that code back rather than assuming the hold took, because a row
/// that says "holding" about an assertion macOS refused is the same lie `LoginItem` documents.
///
/// No daemon, no profile, nothing outside this process: when Chunks quits the assertion is gone with
/// it, which is the whole reason the scheduler is in-process in the first place.
@MainActor
enum SleepAssertion {

    /// Whether Chunks is holding one *right now*, read from what the system answered.
    static private(set) var isHolding = false

    static private var assertion: IOPMAssertionID = 0

    /// Ask for one, or release the one we hold. Returns the state the machine actually agreed to.
    @discardableResult
    static func set(_ hold: Bool) -> Bool {
        if hold {
            guard !isHolding else { return true }
            var id: IOPMAssertionID = 0
            let reason = "Chunks is waiting to tell you something" as CFString
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id)
            guard status == kIOReturnSuccess else {
                Log.write("awake: the machine refused the request (\(status))")
                isHolding = false
                return false
            }
            assertion = id
            isHolding = true
            Log.write("awake: holding — the Mac will not idle-sleep while something waits")
            return true
        }
        guard isHolding else { return false }
        IOPMAssertionRelease(assertion)
        assertion = 0
        isHolding = false
        Log.write("awake: released — nothing is waiting any more")
        return false
    }
}
