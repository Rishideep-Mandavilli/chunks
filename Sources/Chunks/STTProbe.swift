import AVFoundation
import ChunksKit
import Foundation
import Speech

/// Every probe line goes to the terminal *and* to the log file.
///
/// A diagnostic that only prints is unreadable when the app is started by `open`, which is how it
/// has to be started for TCC to attribute the microphone and speech requests to Chunks itself
/// rather than to whatever shell launched it.
private enum Out {
    static func line(_ text: String) {
        print(text)
        Log.write(text)
    }
}

/// `Chunks --probe-stt [seconds]` — one recording, three recognition engines over the same audio.
///
/// The new Speech framework looks better on paper, which is precisely why it needs a harness:
/// recognition quality for an Indian English voice is not answerable from a header file, and the
/// last two changes in this project decided by inference each cost an evening. This runs the
/// shipping `SFSpeechRecognizer` provider and both `SpeechAnalyzer` modules *through their own
/// shipping provider*, prints every partial with the millisecond it arrived, and names the locale
/// and audio format each engine actually bound to.
///
/// Measuring the providers rather than a paraphrase of them is the point: the failure being
/// avoided is a probe that works while real dictation does not.
///
/// The microphone opens for the recording window and closes. It is never left live.
enum STTProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-stt") }

    /// `--probe-stt --check`: which models and locales this machine really has, and which engine
    /// the preference currently selects. No microphone, no recording — the half that answers "is
    /// the swap possible here" has to be runnable before anyone is asked to speak.
    static var isCheckOnly: Bool { CommandLine.arguments.contains("--check") }

    static func run() -> Never {
        // Unbuffered: this command's whole value is showing progress, and a probe that hangs with
        // its output still sitting in a stdout buffer tells you nothing about where it stopped.
        setvbuf(stdout, nil, _IONBF, 0)

        if isCheckOnly {
            if #available(macOS 26.0, *) {
                CheckReport.reportCatalog()
            }
            Out.line("probe-stt: no SpeechAnalyzer on this macOS; SFSpeechRecognizer is the only engine.")
            Log.flush()
            exit(0)
        }

        guard #available(macOS 26.0, *) else {
            Out.line("probe-stt: SpeechAnalyzer needs macOS 26 or later.")
            Log.flush()
            exit(1)
        }

        let seconds = requestedSeconds()
        Out.line("probe-stt: recording \(String(format: "%.1f", seconds))s, three engines over the same audio.")
        Out.line("probe-stt: speak now.")

        // `dispatchMain` rather than a run-loop stop: SFSpeechRecognizer delivers results on the
        // main queue, so the main thread must service it, and a stop that arrives before the loop
        // starts is simply lost — which is how this flag hung on its first run. The watchdog is
        // the honest version of waiting: a transcript that never arrives is reported as a
        // timeout, not as silence.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 25) {
            Out.line("probe-stt: timed out waiting for an engine to answer.")
            Log.flush()
            exit(1)
        }
        Task {
            await STTProbeSession.record(seconds: seconds)
            Log.flush()
            exit(0)
        }
        dispatchMain()
    }

    private static func requestedSeconds() -> Double {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-stt") else { return 8 }
        let next = index + 1
        guard CommandLine.arguments.indices.contains(next),
              let parsed = Double(CommandLine.arguments[next]),
              parsed > 0, parsed <= 60 else { return 8 }
        return parsed
    }
}

@available(macOS 26.0, *)
private enum CheckReport {
    static func reportCatalog() {
        let key = BuddyTranscriptionProviderFactory.enginePreferenceKey
        Out.line("check: SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable)")
        Out.line("check: preference \(key)="
            + (UserDefaults.standard.string(forKey: key) ?? "unset"))

        Task {
            Out.line("check: system locale \(Locale.autoupdatingCurrent.identifier)")
            for (label, supported, installed) in [
                ("DictationTranscriber",
                 await DictationTranscriber.supportedLocales.map(\.identifier),
                 await DictationTranscriber.installedLocales.map(\.identifier)),
                ("SpeechTranscriber",
                 await SpeechTranscriber.supportedLocales.map(\.identifier),
                 await SpeechTranscriber.installedLocales.map(\.identifier))
            ] {
                Out.line("check: \(label) supports \(supported.count), has \(installed.count) downloaded")
                Out.line("       installed: \(installed.sorted().joined(separator: ", "))")
            }
            for probe in ["en_IN", "te_IN", "hi_IN"] {
                let equivalent = await DictationTranscriber.supportedLocale(
                    equivalentTo: Locale(identifier: probe)
                )
                Out.line("check: dictation \(probe) -> \(equivalent?.identifier ?? "unavailable")")
            }
            Log.flush()
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            Out.line("check: the model catalog never answered.")
            Log.flush()
            exit(1)
        }
        dispatchMain()
    }
}

/// Shared zero point and buffer tally, so every engine's latency is measured from the same first
/// buffer — and so a tap that installs without error but delivers nothing shows up as `buffers=0`
/// instead of being mistaken for silence.
private final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var startTime: Date?
    private var buffersSeen = 0

    /// True only on the first buffer, which is when the zero point is set.
    @discardableResult
    func markBuffer() -> Bool {
        lock.lock()
        buffersSeen += 1
        let isFirst = startTime == nil
        if isFirst { startTime = Date() }
        lock.unlock()
        return isFirst
    }

    var bufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffersSeen
    }

    var elapsedMilliseconds: Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let startTime else { return nil }
        return Int(Date().timeIntervalSince(startTime) * 1000)
    }
}

/// Which engines have reported a final transcript, so the run stops waiting at six seconds or
/// when all of them have.
private final class RunLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var settledNames: Set<String> = []
    private let expectedNames: Set<String>

    init(expected: Set<String>) {
        expectedNames = expected
    }

    func settle(_ name: String) {
        lock.lock()
        settledNames.insert(name)
        lock.unlock()
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settledNames.isSuperset(of: expectedNames)
    }
}

private enum Transcripts {
    static func report(_ engine: String, _ elapsed: Int?, _ text: String) {
        Out.line("  [\(engine) +\(elapsed.map(String.init) ?? "-")ms] \(text)")
    }

    static func summarize(partials: Int, firstPartialMs: Int?, finalText: String) -> String {
        let first = firstPartialMs.map { "\($0)ms" } ?? "never"
        return "partials=\(partials) first=\(first) final=\"\(finalText)\""
    }
}

/// One engine's run: what it said, when it said it, and whether it ever settled.
@available(macOS 26.0, *)
private final class EngineRunner: @unchecked Sendable {
    let label: String

    private let clock: RecordingClock
    private let latch: RunLatch
    private let provider: any BuddyTranscriptionProvider
    private let lock = NSLock()
    private var session: (any BuddyStreamingTranscriptionSession)?
    private var partialCount = 0
    private var firstPartialMs: Int?
    private var finalText = ""

    init(label: String, provider: any BuddyTranscriptionProvider, clock: RecordingClock, latch: RunLatch) {
        self.label = label
        self.provider = provider
        self.clock = clock
        self.latch = latch
    }

    /// The provider is the shipping one, so this is the shipping press path minus the hotkey.
    func start() async -> Bool {
        do {
            session = try await provider.startStreamingSession(
                keyterms: ["Nitesh", "WhatsApp"],
                onTranscriptUpdate: { [weak self] text in self?.note(text, final: false) },
                onFinalTranscriptReady: { [weak self] text in self?.note(text, final: true) },
                onError: { [weak self] error in
                    guard let self else { return }
                    Transcripts.report(self.label, self.clock.elapsedMilliseconds,
                                       "error " + STTProbeSession.describe(error))
                    self.latch.settle(self.label)
                }
            )
            return true
        } catch {
            Transcripts.report(label, nil, "would not start: " + STTProbeSession.describe(error))
            return false
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        session?.appendAudioBuffer(buffer)
    }

    func finish() {
        session?.requestFinalTranscript()
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        return Transcripts.summarize(partials: partialCount, firstPartialMs: firstPartialMs, finalText: finalText)
    }

    private func note(_ text: String, final: Bool) {
        lock.lock()
        partialCount += 1
        if firstPartialMs == nil { firstPartialMs = clock.elapsedMilliseconds }
        if final { finalText = text }
        let elapsed = clock.elapsedMilliseconds
        lock.unlock()
        Transcripts.report(label, elapsed, final ? "FINAL " + text : text)
        if final { latch.settle(label) }
    }
}

@available(macOS 26.0, *)
private enum STTProbeSession {
    static func record(seconds: Double) async {
        guard await havePermissions() else { return }

        let clock = RecordingClock()
        let candidates: [(String, any BuddyTranscriptionProvider)] = [
            ("legacy", AppleSpeechTranscriptionProvider()),
            ("dictation", SpeechAnalyzerTranscriptionProvider(kind: .dictation)),
            ("transcription", SpeechAnalyzerTranscriptionProvider(kind: .transcription))
        ]
        var runners: [EngineRunner] = []
        let latch = RunLatch(expected: Set(candidates.map(\.0)))

        for (label, provider) in candidates {
            if !provider.isConfigured, let explanation = provider.unavailableExplanation {
                Out.line("probe-stt: \(label) is not usable here — \(explanation)")
                continue
            }
            let runner = EngineRunner(label: label, provider: provider, clock: clock, latch: latch)
            if await runner.start() {
                runners.append(runner)
            } else {
                Out.line("probe-stt: \(label) did not start; comparing the rest.")
            }
        }
        guard !runners.isEmpty else { return }

        let audio = AVAudioEngine()
        let inputFormat = audio.inputNode.outputFormat(forBus: 0)
        Out.line("probe-stt: input is \(String(format: "%.0fHz/%uch", inputFormat.sampleRate, inputFormat.channelCount))")
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            Out.line("probe-stt: no input device — nothing was recorded.")
            return
        }

        let feeding = runners
        audio.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            if clock.markBuffer() {
                Out.line("probe-stt: first buffer, \(buffer.frameLength) frames.")
            }
            // Handing over the live buffer is the contract the dictation manager already relies
            // on: each provider copies what it needs before its own thread reads it later.
            for runner in feeding { runner.append(buffer) }
        }

        do {
            audio.prepare()
            try audio.start()
        } catch {
            Out.line("probe-stt: the engine would not start: \(describe(error))")
            return
        }

        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        Out.line("probe-stt: window closed after \(clock.bufferCount) buffers, waiting for finals.")
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()

        for runner in runners { runner.finish() }

        let deadline = Date().addingTimeInterval(6)
        while !latch.isComplete && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if clock.bufferCount == 0 {
            Out.line("probe-stt: the tap delivered NOTHING — every transcript above is from zero "
                + "audio. Check the microphone grant; a tap can install without error and stay silent.")
        }
        for runner in runners {
            Out.line("probe-stt: " + runner.label.padding(toLength: 13, withPad: " ", startingAt: 0)
                + " " + runner.summary())
        }
    }

    private static func havePermissions() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
        let ready = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && SFSpeechRecognizer.authorizationStatus() == .authorized
        if !ready {
            Out.line("probe-stt: microphone or speech recognition is denied — grant it and re-run.")
        }
        return ready
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
