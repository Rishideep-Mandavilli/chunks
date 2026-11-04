import AppKit
import ChunksKit
import Combine
import SwiftUI

/// What the notch HUD currently has to say.
///
/// A view model rather than view state because two things need the same numbers: the
/// SwiftUI view draws it, and `NotchPanelManager` sizes the `NSPanel` from it. A borderless
/// panel does not resize itself to fit its content, so if the height lives only in the view
/// the window ends up too short and the card clips — the failure `AnswerPanelLayout` exists
/// to prevent, reintroduced one layer up.
///
/// `@MainActor` because every mutation comes from either the streaming callback or a window
/// lifecycle event, both of which are main-actor work.
@MainActor
final class NotchHUDModel: ObservableObject {

    enum Phase: Equatable {
        /// Nothing to show. The panel is hidden, so the notch is only a notch.
        case idle
        /// Push-to-talk is held; the capture is being taken or transcribed.
        case listening
        /// A request is in flight and no text has arrived yet.
        case thinking
        /// Text is streaming or the reply is complete.
        case result
        /// A one-line hint with no turn in flight — the intro showing where the hot key is.
        /// Separate from `.thinking` because a pill that reads "hold control + option to
        /// talk" while nothing is in flight must not render as if it were working.
        case status(String)
        /// The turn ended without an answer. Shown rather than swallowed, because a HUD
        /// that silently returns to idle reads as "it ignored you".
        case failed(String)
    }

    /// Default card width. Fixed, not fitted to content: a HUD that changes width as text
    /// streams in jitters on every delta, and the notch it is attached to does not move.
    static let defaultCardWidth: CGFloat = 360

    /// Height of the compact status pill's content row, excluding the cutout zone.
    static let pillContentHeight: CGFloat = 30

    /// The phase a turn is genuinely in, named in the words the card shows.
    ///
    /// Set by whoever is doing the work and never inferred from a timer or a guess. What this
    /// replaces is a pill that read "Thinking" for the whole of a turn whether the request had been
    /// sent, was still being transcribed, or had already died in the retry chain — the one case the
    /// user cannot check from the outside, which is exactly why the row has to be told rather than
    /// assumed.
    enum Stage: Equatable {
        case listening
        case transcribing
        case askingModel
        case streaming
        case acting
        case waitingForYou
        case answered
        /// The turn ended without an answer. Its own case rather than a reuse of `.answered`,
        /// because the whole point of the stage line is that it reports what the work is doing, and
        /// "Answered" over a failure is the lie this file has already had to fix once.
        case failed

        var label: String {
            switch self {
            case .listening: return "Listening"
            case .transcribing: return "Reading that back"
            case .askingModel: return "Asking the model"
            case .streaming: return "Answering"
            case .acting: return "Doing it"
            case .waitingForYou: return "Waiting for you"
            case .answered: return "Answered"
            case .failed: return "Could not answer"
            }
        }
    }

    /// One step of a plan that has already happened, with its place in the plan when there is one.
    struct ActLine: Equatable {
        var text: String
        var step: Int?
        var of: Int?
    }

    @Published var phase: Phase = .idle

    @Published private(set) var stage: Stage = .listening

    /// The steps that have run this turn, oldest first.
    ///
    /// Stacked rather than overwritten because the failure the user reported was a plan that
    /// looked like it had done one thing: each outcome line replaced the last, so "Pressed Search"
    /// was gone by the time "Typed 3 characters" arrived and nothing said the plan was four steps
    /// deep.
    @Published private(set) var actLines: [ActLine] = []

    /// How long this turn has been running, ticking while work is in flight and held at its final
    /// value once the answer lands.
    @Published private(set) var elapsed: TimeInterval = 0

    /// What he said, kept on the card under the stage while the answer is written.
    @Published private(set) var spokenQuestion: String = ""

    /// What the microphone is hearing, newest bar last, each 0...1.
    ///
    /// Only live while the pill is `.listening`. It exists for the gap the caption cannot cover:
    /// between the press and the first partial transcript there is no text to show, and "…" is
    /// indistinguishable from a microphone that never opened. A row that moves only when he does is
    /// the difference between *waiting* and *stuck* — said with real audio rather than an animation
    /// that breathes on its own.
    @Published private(set) var waveform: [CGFloat] = WaveformMeter().heights

    private var meter = WaveformMeter()

    /// One reading from the dictation engine.
    ///
    /// Ignored outside `.listening` on purpose: a meter that kept scrolling after the microphone
    /// closed would be showing audio nobody is taking.
    func ingestAudioLevel(_ level: CGFloat, at date: Date = Date()) {
        guard case .listening = phase else { return }
        let before = meter.samples
        meter.ingest(level, at: date)
        // Published only when a bar actually moved. The engine reads far faster than a window fills,
        // and re-rendering the pill on every sample is CPU spent on nothing.
        if before != meter.samples { waveform = meter.heights }
    }

    /// Flat and quiet: the honest state of an open microphone with nothing in it yet.
    private func resetWaveform() {
        meter.reset()
        waveform = meter.heights
    }

    /// A fixed row for `--render-ui`, which has no microphone to feed the meter.
    func setWaveformForRendering(_ levels: [CGFloat]) {
        waveform = levels
    }

    /// The display's cutout depth, injected by `NotchPanelManager`. The view pads its top by
    /// exactly this much; getting it wrong puts the answer behind the bezel.
    @Published var notchHeight: CGFloat = 0

    /// Actual HUD width, injected by `NotchPanelManager` after clamping to the display.
    /// The view and `contentHeight` both use it, so the card never measures text at a width
    /// it is not being drawn at.
    @Published var cardWidth: CGFloat = NotchHUDModel.defaultCardWidth

    @Published private(set) var headline: String = ""
    @Published private(set) var speech: String = ""
    @Published private(set) var detail: String = ""
    @Published private(set) var actions: [String] = []
    @Published private(set) var points: [PointTarget] = []

    /// What the user has said so far in this press, as the speech recognizer hears it.
    ///
    /// Shown because a companion that appears to listen but shows nothing is indistinguishable
    /// from one that is not listening at all: the pill used to read "Listening" for the whole
    /// of a sentence, which is the one piece of feedback that cannot be faked.
    @Published private(set) var caption: String = ""

    /// What the memory store did about this turn's proposal, as one short line.
    ///
    /// Lives here rather than going straight to a log because invariant 3 requires the user
    /// to see refusals: a fact that was silently dropped is indistinguishable from one that
    /// was never offered.
    @Published private(set) var memoryNote: String? = nil

    /// The press waiting for an answer, phrased as one line. `nil` when the card is not asking.
    ///
    /// A separate surface rather than a system dialog because the question is about *this*
    /// answer: the user needs the explanation and the permission question on the same card,
    /// not two windows competing for focus.
    @Published private(set) var confirmQuestion: String?

    /// Which step of a plan the question is, when the act is part of one.
    ///
    /// Carried as data, not spliced into the sentence. The question used to read `Press Send in
    /// WhatsApp? (step 5 of 5)` while the timeline beside it said the same fact as bare `5/5` digits
    /// and the fold line said a third thing; one fact gets one place and one shape, and the sentence
    /// the user is answering stops carrying a parenthetical.
    @Published private(set) var confirmStep: Int?
    @Published private(set) var confirmStepTotal: Int?

    /// Where the user's answer goes.
    ///
    /// Set by `CompanionManager`, which owns the consent gate and the driver. The model shows
    /// a question and never decides what answering it means — same reason it does not own the
    /// memory file.
    var onConfirmAnswer: ((ConsentGate.Outcome) -> Void)?

    /// Where "Ask again" goes, on a card that failed.
    ///
    /// Also the manager's, not the model's: the HUD does not know what a turn is, only that one
    /// ended without an answer.
    var onRetry: (() -> Void)?

    /// Where an outcome line goes to be said aloud, when it answered a live question.
    ///
    /// The model knows only that a question was on the card and is now a record line; saying it is
    /// the manager's, which owns the voice.
    var onReported: ((String) -> Void)?

    /// Whether the card is showing a failure, which is the one state that offers a retry.
    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Whether a failed card actually has its way back on it.
    ///
    /// Both halves are required. The row is only real if somebody owns the re-ask — the HUD does not
    /// know what a turn is — and a handler left over from an earlier turn would offer a way back into
    /// a question he is no longer looking at.
    var canRetry: Bool { isFailed && onRetry != nil }

    private var confirmation: AnswerPanelLayout.CardConfirmation {
        // Only a live question takes the block's height now. What happened after the answer is a
        // timeline row, counted with the timeline, so the same outcome cannot be paid for twice.
        confirmQuestion != nil ? .question : .none
    }

    var isVisible: Bool { phase != .idle }

    private var showsCard: Bool {
        switch phase {
        case .result, .failed: return true
        case .idle, .listening, .thinking, .status: return false
        }
    }

    /// The status line shown in pill form.
    var statusLine: String {
        switch phase {
        case .idle: return ""
        case .status(let hint): return hint
        // The user's own words, as the recognizer hears them. Falling back to the stage is
        // deliberate: an empty pill looks like a crashed app, and silence while the mic
        // is open is more informative than a half-word.
        case .listening: return caption.isEmpty ? stage.label : caption
        case .thinking: return stage.label
        case .result: return headline.isEmpty ? stage.label : headline
        case .failed(let message): return message
        }
    }

    /// Whether the pill carries an elapsed figure beside its text.
    ///
    /// Off while his own words are on screen: a timer next to a live transcript reads as though the
    /// transcript were being timed, and the number the user cares about starts when the words stop.
    var showsElapsed: Bool {
        switch phase {
        case .idle, .status: return false
        case .listening: return caption.isEmpty
        case .thinking, .result, .failed: return true
        }
    }

    /// Whether the card is waiting on him right now.
    ///
    /// This is the one state that reorders the card: a turn that is asking has exactly one thing for
    /// him to do, and the record of what already ran must not sit above it.
    var isAsking: Bool { confirmQuestion != nil }

    /// The act lines the card draws, newest last, with the older ones folded away.
    ///
    /// While the card is asking, every step that ran folds into the one line: the ask moves directly
    /// under the stage row, so the tap is the second thing he sees rather than the sixth. Nothing is
    /// lost — the fold line counts them, and the full record is in the window's transcript.
    var visibleActLines: [ActLine] {
        if isAsking { return [] }
        return Array(actLines.suffix(AnswerPanelLayout.maxVisibleTimelineRows))
    }

    /// How many steps ran that the card is not showing.
    var foldedActCount: Int {
        max(0, actLines.count - visibleActLines.count)
    }

    /// The chips the card offers: none while it is asking.
    ///
    /// The same rule as the act rows, for the same reason and with the same evidence — a reply that
    /// ends "say the word and it goes" and then draws a chip labelled "press send" beside a question
    /// reading "Press Send in WhatsApp?" states one fact in two shapes, and the weaker shape is a
    /// second tap that does what the first one does. The suggestions come back with the answer.
    var visiblePointCount: Int { isAsking ? 0 : points.count }
    var visibleActionCount: Int { isAsking ? 0 : actions.count }

    /// The elapsed readout. One decimal while a turn is in flight, so a 1.4-second answer does not
    /// spend most of its life reading "1s"; a whole number once it has settled, because the precise
    /// figure is not the point any more.
    var elapsedText: String {
        elapsed < 10
            ? String(format: "%.1fs", elapsed)
            : String(format: "%.0fs", elapsed)
    }

    /// Whether this turn has spent the budget the model chain is built to stop at.
    ///
    /// The number is the only place this can be said: a card that reads "61s" in the same grey as "4s"
    /// asks the user to know the ceiling by heart, and a turn past it is not slow — it is the promise
    /// failing, which is the thing the dot is supposed to be colouring.
    var overBudget: Bool { elapsed > BrainGateway.turnBudgetSeconds }

    /// Height of everything below the cutout zone.
    ///
    /// Delegated to `AnswerPanelLayout` for the card, deliberately: this type must not own a
    /// second idea of how tall a card is.
    var contentHeight: CGFloat {
        guard showsCard else { return Self.pillContentHeight }
        let measured = AnswerPanelLayout.measure(
            speech: speech,
            detail: detail,
            pointCount: visiblePointCount,
            actionCount: visibleActionCount,
            hasNote: memoryNote != nil,
            hasDraft: draft != nil,
            hasRetry: canRetry,
            confirmation: confirmation,
            question: spokenQuestion,
            timelineTexts: visibleActLines.map { $0.text },
            timelineTotal: actLines.count,
            width: cardWidth)
        return max(AnswerPanelLayout.minimumHeight, measured)
    }

    // MARK: - Turn lifecycle

    /// Open the HUD for a new turn and clear the previous reply.
    func beginListening() {
        // A reply is replaced by the next press, which is correct but was indistinguishable from
        // the card vanishing on its own. Logged so the two can be told apart after the fact.
        if case .result = phase { Log.write("hud: a new press replaced the previous reply") }
        clearContent()
        phase = .listening
        stage = .listening
        showsTimer = true
        resetWaveform()
        startClock()
    }

    /// Move the card to a named phase, because the phase is a fact about the work and only the
    /// code doing the work knows it.
    func setStage(_ newStage: Stage) {
        stage = newStage
        if newStage == .waitingForYou, case .idle = phase { phase = .result }
    }

    /// Say which step of a plan is running now, so the outcome line can carry its place.
    ///
    /// Called by the program loop rather than by the act itself: with asking switched off there is
    /// no card to number, and the line the user reads is the only place the plan's length appears.
    func beginStep(index: Int, of: Int) {
        // A one-step plan is not a plan; "1/1" would be the card claiming a structure it does not
        // have.
        currentStep = of > 1 ? (index, of) : nil
        stage = .acting
    }

    /// Put the user's words on the pill as the recognizer hears them.
    ///
    /// Only meaningful while listening; once a reply is streaming the card owns the surface
    /// and a caption overwriting it would move the text the user is reading.
    func showCaption(_ text: String) {
        let bounded = AnswerPanelLayout.boundedDetail(text,
                                                     budget: AnswerPanelLayout.captionCharacterBudget)
        guard !bounded.isEmpty else { return }
        caption = bounded
        // The same words stay on the card once it opens: the question is the only context that
        // makes a four-line act timeline mean anything.
        spokenQuestion = bounded
    }

    /// Show a one-line hint with no turn in flight.
    ///
    /// Used by the intro so the notch is part of the first-run experience instead of
    /// appearing for the first time by accident three turns later. `seconds` dismisses it
    /// automatically; `nil` holds it until the next turn, which is what a no-permissions
    /// preview wants — there is no next turn to time against.
    func showHint(_ line: String, for seconds: Double?) {
        clearContent()
        // A hint has no turn behind it, so the clock is cleared rather than merely stopped: a
        // pill reading "hold control + option to talk · 6.3s" would imply a wait nobody is in.
        stopClock()
        turnStart = nil
        elapsed = 0
        phase = .status(line)
        hintTask?.cancel()
        guard let seconds else { return }
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            if case .status = self.phase { self.dismiss(reason: "hint expired") }
        }
    }

    /// Open the full menu panel from the pill.
    ///
    /// A closure set by the shell rather than a call into `MenuBarPanelManager`, because the
    /// model is what the HUD view and the panel manager both observe — reaching backwards
    /// into the app from here would give the notch a second owner for the same window. The
    /// pill is the only surface available while a turn is on screen, so it has to be able to
    /// reach the settings the card cannot show.
    var openPanel: (() -> Void)?

    /// Open the thinking state for a request in flight.
    ///
    /// Clears the previous reply — a pill that still shows the last answer's title reads as
    /// though this turn has already been answered — but keeps what the user just said, since
    /// that is the question being waited on and it is the only text worth showing meanwhile.
    func beginThinking() {
        // The meter stops with the microphone. A row that kept scrolling here would be drawing
        // sound nobody is capturing, which is the fake-progress failure in a new costume.
        let whatTheySaid = caption
        clearContent()
        // The way back is only a way back into *that* turn. Left standing, a handler from a question
        // he has already replaced would re-ask the old one under a new failure.
        onRetry = nil
        headline = whatTheySaid
        spokenQuestion = whatTheySaid
        stage = .askingModel
        showsTimer = true
        phase = .thinking
    }

    /// Adopt whatever is safe to display so far.
    ///
    /// Assignment, not appending: a partial tag can resolve into speech rather than detail
    /// mid-stream, so the accumulated strings from `AnswerStreamer` are the whole truth at
    /// every point, not increments.
    func apply(_ streamer: AnswerStreamer) {
        let display = streamer.displayable
        // Bounded like the detail, for the reason in `speechCharacterBudget`: an unbounded speech
        // line does not grow the card, it pushes the answer buttons off the bottom of it.
        speech = AnswerPanelLayout.boundedDetail(display.speech,
                                                 budget: AnswerPanelLayout.speechCharacterBudget)
        detail = AnswerPanelLayout.boundedDetail(display.detail)
        points = streamer.points
        actions = streamer.nextActions
        draft = streamer.draftText
        headline = streamer.doneTitle ?? Self.firstLine(display.speech)
        // A first delta is the moment "Asking the model" stops being true. Stated here rather
        // than at the request, because the request can be retried onto another model twice before
        // anything arrives.
        if stage == .askingModel { stage = .streaming }

        // Only become a card once there is something to put on one. A reply that so far holds
        // nothing but a half-parsed tag, or only a `[POINT]`, would otherwise show an empty
        // card with "Answer" as its title while the model is still deciding.
        let showsSomething = !display.speech.isEmpty || !display.detail.isEmpty
            || !points.isEmpty || !actions.isEmpty || draft != nil
        if showsSomething { phase = .result }
    }

    /// Close a successful turn. Falls back to the spoken line when the model produced no
    /// card content at all, so a reply that is only `<SAY>` still shows something.
    func finish(from streamer: AnswerStreamer) {
        apply(streamer)
        if speech.isEmpty && detail.isEmpty {
            let utterance = streamer.utterance
            speech = utterance
            if headline.isEmpty { headline = Self.firstLine(utterance) }
        }
        // The clock stops when the *answer* is done, not when the model stops streaming: a reply
        // that queues four acts takes as long as the acts take, and the number the user sees has
        // to be the one they waited for.
        if actLines.isEmpty || stage == .streaming {
            stage = .answered
            stopClock()
        }
        phase = .result
    }

    func fail(_ message: String) {
        Log.writeCritical("hud: failed — \(message)")
        clearContent()
        stopClock()
                // Not `.answered`, which is what this line used to be. A turn that died is the one thing
        // the card must not claim to have finished, and everything that reads `stage` — the window's
        // live line included — was about to say "Answered" over a failure.
        stage = .failed
        // The message is the card's body, not its status line: it is the only content, and
        // putting it in the status slot would leave a 96 pt card with one small line at the
        // top and nothing under it.
        speech = message
        phase = .failed(message)
    }

    /// Show a fired reminder, with no turn behind it.
    ///
    /// A reminder is not an answer: there was no question, no capture and no model call, so this must
    /// not borrow the thinking stage or leave a clock running for work nobody is waiting on.
    /// `lateNote` is the honest half — the hour it was due, whenever the machine was asleep or the app
    /// was shut and it arrived after the fact. Saying "now" for something due at 09:00 would hide the
    /// one fact he would want to know about it.
    func showReminder(_ text: String, lateNote: String?) {
        clearContent()
        stopClock()
        turnStart = nil
        elapsed = 0
        showsTimer = false
        headline = "Reminder"
        speech = AnswerPanelLayout.boundedDetail(
            text, budget: AnswerPanelLayout.speechCharacterBudget)
        detail = lateNote ?? ""
        stage = .answered
        phase = .result
        // A card with nothing streaming into it still has to end: the notch is the notch, and a
        // reminder that owned the surface until his next press would block the next thing he asked.
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.reminderCardSeconds))
            guard let self, !Task.isCancelled, case .result = self.phase else { return }
            self.dismiss(reason: "reminder read")
        }
    }

    /// How long a fired reminder stays on the card when nobody is watching it.
    static let reminderCardSeconds: Double = 24

    /// Whether the card has a turn to time.
    ///
    /// Off for a reminder: `0.0s` beside "Reminder" is a number measuring nothing, and the row exists
    /// to answer "how long have I been waiting", which has no answer for something read after the
    /// fact.
    @Published private(set) var showsTimer = true

    /// The elapsed readout, or empty when there is no turn to time.
    var elapsedTextOrNone: String { showsTimer ? elapsedText : "" }

    /// Words Chunks wrote for him to send himself, kept whole.
    ///
    /// A separate surface from `speech` because a drafted message is the payload, not narration about
    /// it: it has to be readable in one piece and copyable in one tap. It is never spoken — reading a
    /// message aloud while he cannot see all of it is how a wrong name gets sent — and it is capped by
    /// the parser rather than clipped here, so what he reads is what he copies.
    @Published private(set) var draft: String?

    /// Where a tap on Copy goes.
    ///
    /// A closure for the same reason `onConfirmAnswer` is one: the model draws the question and never
    /// decides what answering it means. Writing the pasteboard is shell work, and the notch has to be
    /// able to hand an answer to a window without owning one.
    var onCopyDraft: (() -> Void)?

    /// He tapped Copy. Hand the words to whoever owns the pasteboard and say what happened on the
    /// card, because a button that copies in silence is indistinguishable from one that did nothing.
    func copyDraft() {
        guard draft != nil else { return }
        onCopyDraft?()
    }

    /// Offer the words a finished type act landed in a field, in the same copy well.
    ///
    /// The field is a bad place to copy from — selecting inside another app's box is his mouse
    /// against that app's selection rules — and the card line that says the words landed ("Typed 28
    /// characters into Compose message.") does not let him take them anywhere else. He asked for
    /// this the day he watched a reply get typed into a chat he might have wanted in two places.
    /// A `<DRAFT>` of his own already owns the well, so a turn that produced both keeps the draft:
    /// the words he asked Chunks to write outrank the words Chunks happened to type.
    func offerTypedTextForCopy(_ text: String) {
        guard draft == nil, !text.isEmpty else { return }
        draft = text
    }

    /// Show what the memory store did about the turn's proposal, as a footnote on the card.
    ///
    /// Called after `finish(from:)`, never during streaming: the card is showing the answer,
    /// and a "Remembered …" that appears above half-written text reads as part of the reply.
    /// A `nil` line means the store had nothing worth saying, so the footnote is removed
    /// rather than replaced with an empty row.
    func reportMemory(_ line: String?) {
        guard let line, !line.isEmpty else { memoryNote = nil; return }
        memoryNote = AnswerPanelLayout.boundedDetail(line,
                                                     budget: AnswerPanelLayout.noteCharacterBudget)
    }

    /// Close the card.
    ///
    /// Every route that can empty the notch passes a reason, because "the answer vanished" was
    /// reported while nothing in the log said who closed it — the dismissal itself was invisible.
    func dismiss(reason: String = "unspecified") {
        let leaving = phase
        phase = .idle
        hintTask?.cancel()
        hintTask = nil
        stopClock()
        clearContent()
        Log.write("hud: dismissed (from \(leaving), reason: \(reason))")
    }

    // MARK: - Asking about a press

    /// Put the question on the card.
    ///
    /// The wording names the control the *hit test* found, not the one the model described, so
    /// the user is approving what is about to be pressed.
    func askConfirm(_ question: String, step: Int? = nil, of total: Int? = nil) {
        Log.writeCritical("hud: asking — \(question.prefix(80))"
                          + (step.map { " (step \($0) of \(total ?? 0))" } ?? ""))
        confirmQuestion = question
        confirmStep = step
        confirmStepTotal = total
        stage = .waitingForYou
        phase = .result
    }

    /// Take the question and its step off the card together.
    ///
    /// Three routes clear it — an answer, an outcome line replacing it, and a dismissal that counts
    /// as a denial — and a step number left standing after the question is gone would put "Step 5 of
    /// 5" above the next turn's unrelated answer.
    private func clearConfirm() {
        confirmQuestion = nil
        confirmStep = nil
        confirmStepTotal = nil
    }

    /// Route the user's answer to whoever owns the act.
    ///
    /// The question is cleared *before* the handler runs: a handler that closes or redraws the
    /// card must not find an unanswered question still sitting there and be told "not now" for
    /// the act the user just approved. Answering while nothing is asked does nothing at all,
    /// which is what makes a double tap on Allow press one control rather than two.
    func answerConfirm(_ outcome: ConsentGate.Outcome) {
        guard confirmQuestion != nil else { return }
        clearConfirm()
        onConfirmAnswer?(outcome)
    }

    /// Add one line to the record of what this turn did to the screen.
    ///
    /// Appended rather than replacing the last line, and the row it used to occupy is gone: a
    /// plan's fourth outcome overwriting its first is what made a four-step turn look like a
    /// one-step one. The card is capped, so the view folds anything past
    /// `AnswerPanelLayout.maxVisibleTimelineRows` into "+N earlier".
    func reportConfirm(_ line: String) {
        // Whether this line is the answer to a question he just tapped on. That is the only case
        // where the line is spoken from here: with asking switched off the same sentence rides the
        // turn's own utterance, and saying it twice is a stutter. With asking on it used to reach the
        // card and never his ears — an act he approved and watched happen, in silence.
        let answeredALiveQuestion = confirmQuestion != nil
        clearConfirm()
        let bounded = AnswerPanelLayout.boundedDetail(line,
                                                      budget: AnswerPanelLayout.noteCharacterBudget)
        guard !bounded.isEmpty else { return }
        actLines.append(ActLine(text: bounded, step: currentStep?.index, of: currentStep?.of))
        currentStep = nil
        stage = .acting
        if phase == .idle { phase = .result }
        if answeredALiveQuestion { onReported?(bounded) }
    }

    private var hintTask: Task<Void, Never>?

    /// The step whose outcome line has not been reported yet.
    private var currentStep: (index: Int, of: Int)?

    private var tick: Timer?
    private var turnStart: Date?

    /// Start the turn clock. Half-second ticks, because a readout that changes once a second looks
    /// frozen for up to a second at a time — the exact impression this row exists to remove.
    private func startClock() {
        turnStart = Date()
        elapsed = 0
        tick?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            // Hopped, never asserted: `MainActor.assumeIsolated` in a timer block is what crashed the
            // app on 2026-11-03, and a clock tick is the least important work on the machine — it can
            // afford the hop. An assertion here is undefined behaviour, not a trap.
            Task { @MainActor in self?.refreshClock() }
        }
        // Added to the common mode: the run loop is busy streaming a reply, and a clock that only
        // ticks when the loop is idle is a clock that stops during the wait it is measuring.
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func refreshClock() {
        guard let turnStart else { return }
        elapsed = Date().timeIntervalSince(turnStart)
        // A hung turn used to be invisible in the record: the log went quiet at "turn: start" and
        // stayed quiet for an hour while the card counted. One durable line every five seconds while
        // the card is still thinking is the difference between a report that ends mid-turn and one
        // that shows the turn never moved.
        guard case .thinking = phase else {
            heartbeatTicks = 0
            return
        }
        heartbeatTicks += 1
        if heartbeatTicks % 10 == 0 {
            Log.writeCritical("hud: turn still thinking at \(Int(elapsed))s")
        }
    }

    private var heartbeatTicks = 0

    /// Stop ticking but keep the final figure, so "Answered · 4.2s" is the time it actually took.
    private func stopClock() {
        tick?.invalidate()
        tick = nil
        refreshClock()
    }

    /// Freeze the elapsed readout at a chosen value.
    ///
    /// Only `--render-ui` calls it. A render of a design has to be reproducible, and a card whose
    /// timer reads whatever the clock happened to be doing when the file was written cannot be
    /// compared against the next one.
    func setElapsedForRendering(_ seconds: TimeInterval) {
        stopClock()
        turnStart = nil
        elapsed = seconds
    }

    private func clearContent() {
        // A press question that loses its card without an answer was never approved, and the
        // owner of the act has to be told so. Leaving it pending would let a stale request be
        // answered by the *next* card that happens to ask — dismissing a request is a denial,
        // not a pause.
        if confirmQuestion != nil {
            clearConfirm()
            onConfirmAnswer?(.denied)
        }
        headline = ""
        speech = ""
        detail = ""
        actions = []
        points = []
        caption = ""
        memoryNote = nil
        draft = nil
        actLines = []
        currentStep = nil
        stage = .listening
    }

    /// The card's label when the model gave no `<DONE_TITLE>`.
    ///
    /// Static and shared with the history store on purpose: a turn's row in the window and the line
    /// the user just read on the card must be the same words, not two independent cuts of one answer.
    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
