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

    @Published var phase: Phase = .idle

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

    /// What happened after the user answered, in the row the question occupied.
    @Published private(set) var confirmResult: String?

    /// Where the user's answer goes.
    ///
    /// Set by `CompanionManager`, which owns the consent gate and the driver. The model shows
    /// a question and never decides what answering it means — same reason it does not own the
    /// memory file.
    var onConfirmAnswer: ((ConsentGate.Outcome) -> Void)?

    private var confirmation: AnswerPanelLayout.CardConfirmation {
        if confirmQuestion != nil { return .question }
        if confirmResult != nil { return .result }
        return .none
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
        // The user's own words, as the recognizer hears them. Falling back to "Listening"
        // is deliberate: an empty pill looks like a crashed app, and silence while the mic
        // is open is more informative than a half-word.
        case .listening: return caption.isEmpty ? "Listening" : caption
        case .thinking: return headline.isEmpty ? "Thinking" : headline
        case .result: return headline
        case .failed(let message): return message
        }
    }

    /// Height of everything below the cutout zone.
    ///
    /// Delegated to `AnswerPanelLayout` for the card, deliberately: this type must not own a
    /// second idea of how tall a card is.
    var contentHeight: CGFloat {
        guard showsCard else { return Self.pillContentHeight }
        let measured = AnswerPanelLayout.measure(
            speech: speech,
            detail: detail,
            pointCount: points.count,
            actionCount: actions.count,
            hasNote: memoryNote != nil,
            confirmation: confirmation,
            width: cardWidth)
        return max(AnswerPanelLayout.minimumHeight, measured)
    }

    // MARK: - Turn lifecycle

    /// Open the HUD for a new turn and clear the previous reply.
    func beginListening() {
        clearContent()
        phase = .listening
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
    }

    /// Show a one-line hint with no turn in flight.
    ///
    /// Used by the intro so the notch is part of the first-run experience instead of
    /// appearing for the first time by accident three turns later. `seconds` dismisses it
    /// automatically; `nil` holds it until the next turn, which is what a no-permissions
    /// preview wants — there is no next turn to time against.
    func showHint(_ line: String, for seconds: Double?) {
        clearContent()
        phase = .status(line)
        hintTask?.cancel()
        guard let seconds else { return }
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            if case .status = self.phase { self.dismiss() }
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
        let whatTheySaid = caption
        clearContent()
        headline = whatTheySaid
        phase = .thinking
    }

    /// Adopt whatever is safe to display so far.
    ///
    /// Assignment, not appending: a partial tag can resolve into speech rather than detail
    /// mid-stream, so the accumulated strings from `AnswerStreamer` are the whole truth at
    /// every point, not increments.
    func apply(_ streamer: AnswerStreamer) {
        let display = streamer.displayable
        speech = display.speech
        detail = AnswerPanelLayout.boundedDetail(display.detail)
        points = streamer.points
        actions = streamer.nextActions
        headline = streamer.doneTitle ?? firstLine(display.speech)

        // Only become a card once there is something to put on one. A reply that so far holds
        // nothing but a half-parsed tag, or only a `[POINT]`, would otherwise show an empty
        // card with "Answer" as its title while the model is still deciding.
        let showsSomething = !display.speech.isEmpty || !display.detail.isEmpty
            || !points.isEmpty || !actions.isEmpty
        if showsSomething { phase = .result }
    }

    /// Close a successful turn. Falls back to the spoken line when the model produced no
    /// card content at all, so a reply that is only `<SAY>` still shows something.
    func finish(from streamer: AnswerStreamer) {
        apply(streamer)
        if speech.isEmpty && detail.isEmpty {
            let utterance = streamer.utterance
            speech = utterance
            if headline.isEmpty { headline = firstLine(utterance) }
        }
        phase = .result
    }

    func fail(_ message: String) {
        clearContent()
        // The message is the card's body, not its status line: it is the only content, and
        // putting it in the status slot would leave a 96 pt card with one small line at the
        // top and nothing under it.
        speech = message
        phase = .failed(message)
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

    func dismiss() {
        phase = .idle
        hintTask?.cancel()
        hintTask = nil
        clearContent()
    }

    // MARK: - Asking about a press

    /// Put the question on the card.
    ///
    /// The wording names the control the *hit test* found, not the one the model described, so
    /// the user is approving what is about to be pressed.
    func askConfirm(_ question: String) {
        confirmResult = nil
        confirmQuestion = question
        phase = .result
    }

    /// Route the user's answer to whoever owns the act.
    ///
    /// The question is cleared *before* the handler runs: a handler that closes or redraws the
    /// card must not find an unanswered question still sitting there and be told "not now" for
    /// the act the user just approved. Answering while nothing is asked does nothing at all,
    /// which is what makes a double tap on Allow press one control rather than two.
    func answerConfirm(_ outcome: ConsentGate.Outcome) {
        guard confirmQuestion != nil else { return }
        confirmQuestion = nil
        onConfirmAnswer?(outcome)
    }

    /// Replace the question row with one line about what happened.
    func reportConfirm(_ line: String) {
        confirmQuestion = nil
        let bounded = AnswerPanelLayout.boundedDetail(line,
                                                      budget: AnswerPanelLayout.noteCharacterBudget)
        confirmResult = bounded.isEmpty ? nil : bounded
        if phase == .idle { phase = .result }
    }

    private var hintTask: Task<Void, Never>?

    private func clearContent() {
        // A press question that loses its card without an answer was never approved, and the
        // owner of the act has to be told so. Leaving it pending would let a stale request be
        // answered by the *next* card that happens to ask — dismissing a request is a denial,
        // not a pause.
        if confirmQuestion != nil {
            confirmQuestion = nil
            onConfirmAnswer?(.denied)
        }
        confirmResult = nil
        headline = ""
        speech = ""
        detail = ""
        actions = []
        points = []
        caption = ""
        memoryNote = nil
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
