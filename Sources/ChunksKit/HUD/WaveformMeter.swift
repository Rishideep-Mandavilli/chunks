import Foundation

/// A rolling meter of what the microphone is hearing, as bars.
///
/// Pure, on purpose: the shape of a waveform is the one part of this that can be tested without a
/// microphone, and the failure mode it exists to prevent — bars that move when nobody is making a
/// sound — is exactly the kind of thing a unit test catches and a screenshot does not.
///
/// It is a *time* buffer, not one level drawn nine ways. Each bar is what the mic did in one window,
/// so the row shows when he started talking and when he stopped, which is the information the pill
/// was missing: during the 1.7 s before the first word appears, "…" says nothing and a live meter
/// says the microphone is open and hearing you.
public struct WaveformMeter: Equatable, Sendable {

    /// How many windows the pill shows. Nine at 2 pt wide and 1 pt apart is 26 pt — narrower than
    /// the dot and caption it replaces, so the pill's height never changes.
    public static let barCount = 9

    /// One bar's worth of time. Nine of them is ~400 ms of history, which is long enough to see a
    /// syllable and short enough that the row is never showing something he did two seconds ago.
    public static let window: TimeInterval = 0.045

    /// Below this the microphone is idle hiss, not a voice.
    ///
    /// Measured against the cursor's meter, which has used this floor in production: subtracting it
    /// is what stops a silent room from drawing a flat line of noise.
    public static let silenceFloor: CGFloat = 0.008

    /// The gain and the curve are the ones `BlueCursorWaveformView` already uses, so the same sound
    /// looks the same height on the cursor and in the notch. Two mappings of one level is how two
    /// surfaces end up disagreeing about whether he is being heard.
    public static let gain: CGFloat = 2.85
    public static let curve: CGFloat = 0.76

    /// The stub a silent bar draws. Static, not animated: a meter that is listening and quiet should
    /// look present and flat, and vanishing-then-returning bars jitter more than they read.
    public static let idleHeight: CGFloat = 0.10

    /// Newest last, each 0...1 — the order a left-to-right row draws them in.
    public private(set) var samples: [CGFloat]

    private var windowPeak: CGFloat = 0
    private var windowStarted: Date?

    public init(samples: [CGFloat] = Array(repeating: 0, count: WaveformMeter.barCount)) {
        self.samples = samples
    }

    /// Feed one reading from the engine.
    ///
    /// Readings arrive far faster than one per window, so the window keeps its **peak**: the loudest
    /// moment of a syllable is what a person expects to see, and averaging it against the silence
    /// either side of it would flatten speech into a hum.
    public mutating func ingest(_ level: CGFloat, at date: Date) {
        let eased = Self.height(for: level)
        windowPeak = max(windowPeak, eased)

        guard let started = windowStarted else {
            windowStarted = date
            return
        }
        guard date.timeIntervalSince(started) >= Self.window else { return }

        advance(by: windowPeak)
        windowPeak = 0
        windowStarted = date
    }

    /// Push one bar's worth of history, oldest falling off. Split out so a test can drive the row
    /// without inventing timestamps for every bar.
    public mutating func advance(by height: CGFloat) {
        samples.append(min(max(height, 0), 1))
        if samples.count > Self.barCount {
            samples.removeFirst(samples.count - Self.barCount)
        }
    }

    /// Back to a flat, quiet row. Called when the microphone closes, so nothing on screen can be
    /// mistaken for audio that is no longer being taken.
    public mutating func reset() {
        samples = Array(repeating: 0, count: Self.barCount)
        windowPeak = 0
        windowStarted = nil
    }

    /// The levels the view draws: 0...1, with the silent ones lifted to the stub.
    public var heights: [CGFloat] {
        samples.map { $0 <= Self.silenceFloor ? Self.idleHeight : max($0, Self.idleHeight) }
    }

    /// Whether anything in the window was a voice rather than room.
    public var isVocalising: Bool {
        samples.contains { $0 > Self.silenceFloor }
    }

    /// Raw engine level → bar height, with the floor taken out and the curve applied.
    public static func height(for level: CGFloat) -> CGFloat {
        let lifted = max(level - silenceFloor, 0)
        return pow(min(lifted * gain, 1), curve)
    }
}
