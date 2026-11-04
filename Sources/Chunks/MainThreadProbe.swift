import AppKit
import ChunksKit
import Foundation

/// `Chunks --probe-mainthread` — is the main thread free while Accessibility work runs?
///
/// The crash this measures is not in our code. Three reports in one evening (2026-11-03/04) faulted in
/// the same place — `SerialExecutor.isMainExecutor` / `_isSameExecutor` / `swift_getObjectType`, the
/// runtime's answer to "am I on the main actor?". Twice the caller was ours, a `MainActor.assumeIsolated`
/// inside a timer block, and those were hopped and grepped for. The third, at 00:53, was SwiftUI's:
/// `NSHostingView.mouseEntered` → `HoverEventDispatcher` → its own `assumeIsolated`, on a main thread
/// that had been blocked inside a main-actor task by the act path moments before. That call site is not
/// ours and no grep can see it, so what has to change is the *state of the thread* — nothing may block
/// the main thread from inside a task's scope, which is also the rule `AGENTS.md` already states about
/// the notch freezing while he watches.
///
/// So this measures the mechanism, with a wait long enough to see. A 20 ms repeating timer on the main
/// run loop records how late each firing lands while the same 150 ms wait — the driver's own
/// `webActionRetryDelay`, the pause a Chromium retry costs — runs (a) inline on the main thread, which
/// is how the act path used to run it, and (b) detached, which is how `CompanionManager.driver(…)` runs
/// every Accessibility call now. Inline must show the stall, or the sampler is blind; detached must not,
/// or the hop is not moving the work off the thread.
///
/// The static half of the same rule is asserted by `verify.sh`: every `AXTDriver.` call in the shell is
/// inside a `driver { }` hop or is a pure accessor. A probe cannot catch a new call site added on the
/// main thread; a grep can.
///
/// Read-only: nothing is pressed, typed, posted or moved.
@MainActor
enum MainThreadProbe {

    static var isRequested: Bool { CommandLine.arguments.contains("--probe-mainthread") }

    /// How often the sampler ticks, and how much lateness still counts as "the thread was free".
    static let sampleInterval: TimeInterval = 0.02
    static let freeThresholdMilliseconds: Double = 60
    /// The wait being measured: `AXTDriver.webActionRetryDelay`, the pause a lazy Chromium surface costs.
    static let standInWait: TimeInterval = 0.15

    static func start() -> Never {
        if Thread.isMainThread {
            MainActor.assumeIsolated { run() }
        }
        DispatchQueue.main.async {
            Task { @MainActor in run() }
        }
        while true { Thread.sleep(forTimeInterval: 3600) }
    }

    private static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        print("main-thread probe — does a wait inside the act path stall the main run loop?")

        let inlineStall = measureInline()
        print("  \(Int(standInWait * 1000)) ms waited inline on the main thread: worst timer lateness "
            + "\(Int(inlineStall * 1000)) ms")
        let detachedStall = measureDetached()
        print("  the same wait detached, as the act path runs it: worst timer lateness "
            + "\(Int(detachedStall * 1000)) ms")

        var failures: [String] = []
        if inlineStall < standInWait / 2 {
            failures.append("the sampler did not see a \(Int(standInWait * 1000)) ms block on its own "
                + "thread (\(Int(inlineStall * 1000)) ms) — it cannot clear the hop either, so this run "
                + "proves nothing")
        }
        if detachedStall > freeThresholdMilliseconds / 1000 {
            failures.append("the detached wait still stalled the main loop by "
                + "\(Int(detachedStall * 1000)) ms — work that blocks is running on the main thread "
                + "again, and that is the state a SwiftUI callback then crashes in")
        }
        if detachedStall * 4 > inlineStall {
            failures.append("detached (\(Int(detachedStall * 1000)) ms) is not clearly better than "
                + "inline (\(Int(inlineStall * 1000)) ms) — the hop is not moving the work off the thread")
        }

        for failure in failures { print("  FAIL  \(failure)") }
        if failures.isEmpty {
            print("  PASS  the main run loop stays free (\(Int(detachedStall * 1000)) ms) through a "
                + "wait that costs \(Int(inlineStall * 1000)) ms when it runs on that thread")
        }
        Log.flush()
        exit(failures.isEmpty ? 0 : 1)
    }

    /// Blocks the main thread the way an unhopped Accessibility call does, and reports the worst
    /// lateness the sampler saw.
    private static func measureInline() -> Double {
        let timer = startSampler()
        Thread.sleep(forTimeInterval: standInWait)
        // The fires the block prevented are the measurement. A repeating timer delivers its missed
        // fires when the loop turns again, so the loop gets a moment *first* and the timer is
        // invalidated after — invalidating first cancels exactly the fires being counted, which is
        // how the second version of this probe reported a 150 ms block as 0 ms of lateness.
        let lateness = drain()
        timer.invalidate()
        return lateness
    }

    /// Runs the same wait on another thread, spinning the main run loop while it goes, and reports the
    /// worst lateness the sampler saw.
    private static func measureDetached() -> Double {
        let timer = startSampler()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: MainThreadProbe.standInWait)
            finished.signal()
        }
        // Waiting by turning the run loop, not by blocking it: a `semaphore.wait()` here would measure
        // the probe's own stall and report it as the app's.
        let deadline = Date().addingTimeInterval(10)
        while finished.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(MainThreadProbe.sampleInterval))
        }
        let lateness = drain()
        timer.invalidate()
        return lateness
    }

    /// Turns the main run loop long enough for any queued fire to land, then reads the sampler.
    private static func drain() -> Double {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.15))
        return MainThreadSampler.worstLateness()
    }

    private static func startSampler() -> Timer {
        MainThreadSampler.arm(from: Date())
        let timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { _ in
            // Recorded here, not through a hop: a hopped tick would not land while the thread is
            // blocked, which is the very thing being measured, and the first version of this probe
            // duly reported a 150 ms block as 0 ms of lateness. The callback touches one nonisolated
            // sampler and asserts nothing about the main actor — the rule that made the crash go away
            // is not "never run on the main thread", it is "never *assume* the main actor here".
            MainThreadSampler.tickNow(Date())
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// The sampler's state, deliberately nonisolated for the reason above: a single main-thread timer
/// writes it and the probe reads it after that timer is invalidated.
enum MainThreadSampler {
    private static var lastTick = Date.distantPast
    private static var armedAt = Date.distantPast
    private static var worst: TimeInterval = 0

    static func arm(from date: Date) {
        armedAt = date
        lastTick = date
        worst = 0
    }

    static func tickNow(_ now: Date) {
        guard now > armedAt else { return }
        let lateness = now.timeIntervalSince(lastTick) - MainThreadProbe.sampleInterval
        if lateness > worst { worst = lateness }
        lastTick = now
    }

    static func worstLateness() -> Double { max(0, worst) }
}
