import ChunksKit
import ChunksTestHarness
import Foundation

/// Tests for the notch's microphone meter.
///
/// The one failure worth preventing is a row that moves when nothing is happening — the criticism
/// this project already makes of other assistants' "ready" animations. Everything below is aimed at
/// that, plus the arithmetic that keeps the row inside a 30 pt pill.
public enum WaveformMeterTests {

    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    public static func register() {
        TestRunner.currentSuite = "Waveform meter"

        test("a quiet room draws stubs, not a waveform") {
            var meter = WaveformMeter()
            for index in 0..<40 {
                meter.ingest(0.002, at: start.addingTimeInterval(Double(index) * 0.01))
            }
            expect(!meter.isVocalising,
                   "room hiss was read as a voice, so the pill would dance while he said nothing")
            expectEqual(meter.heights.allSatisfy { $0 == WaveformMeter.idleHeight }, true,
                        "a silent bar must sit at the stub, not at zero where it would flicker")
        }

        test("one loud window is one tall bar") {
            var meter = WaveformMeter()
            meter.advance(by: WaveformMeter.height(for: 0.5))
            let tallest = meter.heights.max() ?? 0
            expect(tallest > 0.8,
                   "a normal speaking level drew \(tallest) — too small to read from across a desk")
        }

        test("the row is time, not one level drawn nine ways") {
            var meter = WaveformMeter()
            meter.advance(by: 1.0)
            for _ in 0..<(WaveformMeter.barCount - 1) { meter.advance(by: 0) }
            // The loud window has scrolled to the far left and everything since is quiet.
            expectEqual(meter.heights.first ?? 0, 1,
                        "the oldest sample should still be visible until nine more push it off")
            expectEqual(meter.heights.last ?? 0, WaveformMeter.idleHeight,
                        "the newest bar is what just happened, and nothing just happened")
        }

        test("readings faster than the window do not scroll it") {
            var meter = WaveformMeter()
            let before = meter.samples
            for index in 0..<10 {
                meter.ingest(0.4, at: start.addingTimeInterval(Double(index) * 0.002))
            }
            expectEqual(meter.samples, before,
                        "20 ms of samples advanced the row, so it would run faster than he speaks")
        }

        test("a window keeps its peak, not its average") {
            // One shout inside a quiet window has to be visible. Averaged against the silence either
            // side of it, a syllable flattens into a hum.
            var meter = WaveformMeter()
            meter.ingest(0.01, at: start)
            meter.ingest(0.9, at: start.addingTimeInterval(0.02))
            meter.ingest(0.01, at: start.addingTimeInterval(0.05))
            expect((meter.samples.last ?? 0) > 0.9,
                   "the loud sample was diluted by the silence around it")
        }

        test("the row is always exactly as wide as the pill allows") {
            var meter = WaveformMeter()
            expectEqual(meter.heights.count, WaveformMeter.barCount)
            for index in 0..<50 {
                meter.advance(by: CGFloat(index % 5) / 5)
                expectEqual(meter.samples.count, WaveformMeter.barCount,
                            "the buffer grew past the bar count, so the row would grow too")
            }
            // Nine bars at 2 pt with 1 pt gaps is 26 pt — narrower than the 7 pt dot plus the 8 pt
            // gap it replaces, which is why the pill's height never has to change for this.
            expect(WaveformMeter.barCount * 3 - 1 <= 30,
                   "the meter is wide enough to change the pill's geometry")
        }

        test("resetting flattens it") {
            var meter = WaveformMeter()
            meter.advance(by: 1)
            meter.advance(by: 1)
            meter.reset()
            expect(!meter.isVocalising, "a closed microphone left a waveform on screen")
        }

        test("the curve matches the cursor's, so one sound is one height") {
            expectEqual(WaveformMeter.height(for: 0), 0,
                        "no signal has to mean no bar, whatever the curve says")
            let mid = WaveformMeter.height(for: 0.2)
            let loud = WaveformMeter.height(for: 0.6)
            expect(loud > mid, "the mapping went backwards, so loud looked quiet")
            expect(WaveformMeter.height(for: 5) <= 1,
                   "a hot input escaped the top of the bar instead of clamping to it")
            // The same numbers `BlueCursorWaveformView` uses. If one changes, the two surfaces
            // disagree about whether he is being heard, and only one of them can be right.
            expectEqual(WaveformMeter.gain, 2.85)
            expectEqual(WaveformMeter.curve, 0.76)
            expectEqual(WaveformMeter.silenceFloor, 0.008)
        }
    }
}
