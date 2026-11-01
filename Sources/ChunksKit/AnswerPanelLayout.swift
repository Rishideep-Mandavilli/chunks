import AppKit
import Foundation

/// How tall the answer card needs to be for a given reply.
///
/// Lives in ChunksKit rather than next to the view because it is arithmetic, and
/// arithmetic is testable. The failure it prevents is quiet and nasty: a card sized too
/// small clips the answer, and a clipped answer does not look truncated — it looks like
/// the model stopped mid-thought, which the user cannot distinguish from a real answer.
public enum AnswerPanelLayout {

    public static let speechFont = NSFont.systemFont(ofSize: 15, weight: .medium)
    public static let detailFont = NSFont.systemFont(ofSize: 12)
    public static let statusFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// The stage row's voice: the same weight as the headline it shares a line with, one point
    /// larger, because it is the only thing on the card that says whether anything is happening.
    public static let stageFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// The question he spoke, held under the stage. Quietest type on the card on purpose — it is
    /// context, not content, and the answer must not compete with it.
    public static let questionFont = NSFont.systemFont(ofSize: 11)
    /// One act outcome. Medium at 11 pt because it is a record of something that happened, read at
    /// a glance rather than scanned as prose.
    public static let timelineFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    public static let speechLineHeight: CGFloat = 20
    public static let detailLineHeight: CGFloat = 16
    public static let statusRowHeight: CGFloat = 16

    /// Row 1 of the card: the phase the turn is genuinely in, and how long it has been in it.
    ///
    /// Taller than a plain text row because it carries two things on one line — the stage on the
    /// left and a right-aligned elapsed time in tabular figures — and a 16 pt row makes those two
    /// collide at the HUD's width.
    public static let stageRowHeight: CGFloat = 18

    /// The question he spoke, held on the card under the stage while the answer is written.
    ///
    /// It used to live only on the pill and then vanish, which is exactly when it is most needed:
    /// a five-step plan is hard to read if the sentence it is carrying out is no longer on screen.
    public static let questionRowHeight: CGFloat = 16

    /// One line of the act timeline: what a step did, and which step of how many.
    public static let timelineRowHeight: CGFloat = 18
    public static let timelineGap: CGFloat = 8

    /// What a timeline row pays for everything beside its text: the 2 pt rule, its gap, the
    /// spacer and the "4/5" step label. Measurement and the view subtract the same number, so a
    /// row that wraps to a second line in the view wraps in the arithmetic too.
    public static let timelineGutter: CGFloat = 34

    /// How many lines one act row occupies: one, or two when the row carries a refusal that names
    /// the vocabulary that exists — the field list sits at the *end* of that sentence, and a single
    /// line with middle truncation read as "Chunks found no field calle…earch", neither half of it.
    public static func timelineRowCount(for text: String, width: CGFloat) -> CGFloat {
        min(2, lines(text, font: timelineFont, lineHeight: timelineRowHeight,
                     width: width - timelineGutter))
    }

    /// How many act lines the card shows before folding the older ones into "+N earlier".
    ///
    /// Four is the ceiling because the card is capped at 420 pt and a long plan must not push the
    /// answer, the chips or the ask row off the bottom — the thing that can be clipped is the thing
    /// the user cannot act on.
    public static let maxVisibleTimelineRows = 4

    /// How many rows the card draws for a plan of `total` steps: the newest ones, plus a fold line
    /// when anything was folded away.
    ///
    /// The fold line is a row. Counting only the visible steps is how a five-step plan got a window
    /// 18 pt shorter than its own content, and the Ask row at the bottom was clipped — the exact
    /// failure this type was written to prevent, reintroduced by a new block that did not ask it.
    /// Height of the timeline block, gap included, for the exact rows the card will draw: the
    /// visible ones at their own wrapped line counts, plus the one folded "+N earlier" row.
    public static func timelineHeight(rows: [String], folded: Bool, width: CGFloat) -> CGFloat {
        let drawn = rows.reduce(0) { $0 + timelineRowCount(for: $1, width: width) * timelineRowHeight }
            + (folded ? timelineRowHeight : 0)
        return drawn == 0 ? 0 : timelineGap + drawn
    }

    public static let chipHeight: CGFloat = 26
    public static let inset: CGFloat = 14

    /// Vertical breathing room between sections.
    ///
    /// Generous on purpose. A live run put a point chip right on top of the last line of
    /// the headline, and the cause was the sections being packed tightly enough that any
    /// small difference between the measured line count and the drawn one became a visible
    /// overlap rather than a merely tight gap.
    public static let sectionGap: CGFloat = 12
    public static let chipGap: CGFloat = 14
    public static let defaultWidth: CGFloat = 460
    public static let minimumHeight: CGFloat = 96
    public static let maximumHeight: CGFloat = 420

    /// Room for the memory footnote — what the store did about the model's proposal.
    ///
    /// Two lines of secondary type, and the view puts `lineLimit(2)` on it, so the card's
    /// height and the note's ceiling agree instead of the note clipping.
    public static let noteHeight: CGFloat = 32

    /// How much of a footnote the card can show.
    public static let noteCharacterBudget = 150

    /// Room for a drafted message: a scrollable viewport, its well, and Copy outside the scroll.
    ///
    /// The 56 pt viewport does not include the well's padding. Omitting those two 6 pt insets made
    /// the view 12 pt taller than its measurement, stealing space from Copy and the consent row.
    public static let draftTextHeight: CGFloat = 56
    public static let draftTextHorizontalInset: CGFloat = 9
    public static let draftTextVerticalInset: CGFloat = 6
    public static var draftWellHeight: CGFloat {
        draftTextHeight + 2 * draftTextVerticalInset
    }
    /// The row's height is `confirmButtonRowHeight`, because the draft's button *is* that button
    /// style at a narrower width — one fewer number to keep in agreement with the view.
    public static let draftButtonRowHeight: CGFloat = confirmButtonRowHeight
    public static let draftGap: CGFloat = 6

    /// The whole draft block. The section gap above it is counted separately by `measure`.
    public static var draftHeight: CGFloat {
        draftWellHeight + draftGap + draftButtonRowHeight
    }

    /// Whether the card is asking about a press.
    ///
    /// A pending press is asked about *on the card the answer is written on*, in one line of
    /// question and one row of two buttons. Like the memory footnote, the height is fixed and
    /// the view caps the question at two lines, so the number the window is sized from and the
    /// number the buttons actually occupy cannot drift apart.
    ///
    /// There is deliberately no case for *after* the answer: what a press did is a timeline row,
    /// counted with the timeline. Reserving a question block for it left 64 pt of dead space.
    public enum CardConfirmation: Equatable, Sendable {
        /// Nothing asked.
        case none
        /// "Press Send in Mail?" with Allow / Not now.
        case question
    }

    /// Two lines, because a question that names a control, an app and a step in a plan does not fit
    /// in one at 332 pt: `Type "good night" into Compose message in WhatsApp? (step 2 of 5)`. A
    /// question the user cannot read in full is a question they answer from the shape of it.
    public static let confirmQuestionHeight: CGFloat = 32
    public static let confirmButtonRowHeight: CGFloat = 28
    public static let confirmGap: CGFloat = 8

    /// Room for the whole question block: the line the user reads and the row they tap.
    public static var confirmHeight: CGFloat {
        confirmQuestionHeight + confirmGap + confirmButtonRowHeight
    }

    /// How many characters of detail the card will show.
    ///
    /// The model likes to answer with a long bulleted list, and an unbounded amount of it
    /// turns a glanceable card into a wall of small type with the point chips pushed off
    /// the bottom. Bounding it makes the card predictable whatever the model says.
    public static let detailCharacterBudget = 420

    /// The same argument for the spoken line, which is drawn larger.
    ///
    /// `measure` counts every line of `speech`, and then clamps the total at `maximumHeight` — so a
    /// long `<SAY>` did not make the card taller, it pushed the chips, the Allow row and the memory
    /// footnote below the bottom edge of the window with nothing to show they were there. This is
    /// the same class of bug as the fold line that once clipped an Ask row: the ceiling and the
    /// allowance have to be the same number, on every block.
    ///
    /// The voice still says all of it. Only the card is bounded, and it says so with the ellipsis.
    public static let speechCharacterBudget = 200

    /// How much of the user's own words fit on the notch pill.
    ///
    /// The pill is one line at the HUD's width; a caption that wraps turns a status pill
    /// into a second card in the middle of a sentence, and the card arrives anyway a moment
    /// later carrying the whole reply. 52 characters is what fits at 12 pt inside a 360 pt
    /// pill, which is most spoken questions before the ellipsis.
    public static let captionCharacterBudget = 52

    /// Clamp detail to what the card can show, marking anything dropped.
    ///
    /// Truncating is acceptable here specifically because the *whole* answer is also spoken
    /// aloud and its first line is the headline — a card showing a readable summary beats
    /// one showing the first half of a list nobody can finish reading. The full text is in
    /// the menu.
    public static func boundedDetail(_ detail: String,
                                     budget: Int = detailCharacterBudget) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > budget else { return trimmed }

        // Cut at a line boundary when one is reasonably close, so the truncation does not
        // slice a sentence in half.
        var cut = String(trimmed.prefix(budget))
        if let lastNewline = cut.lastIndex(of: "\n"),
           cut.distance(from: cut.startIndex, to: lastNewline) > budget / 2 {
            cut = String(cut[..<lastNewline])
        }
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Wrapped line count for a string at a given width and line height.
    public static func lines(_ text: String, font: NSFont, lineHeight: CGFloat, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let height = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil).height
        return max(1, ceil(height / lineHeight))
    }

    public static func measure(speech: String,
                               detail: String,
                               pointCount: Int,
                               actionCount: Int = 0,
                               hasNote: Bool = false,
                               hasDraft: Bool = false,
                               confirmation: CardConfirmation = .none,
                               question: String = "",
                               timelineTexts: [String] = [],
                               timelineTotal: Int = 0,
                               width: CGFloat = defaultWidth,
                               inset: CGFloat = inset) -> CGFloat {
        let textWidth = width - 2 * inset
        let speechLines = lines(speech, font: speechFont, lineHeight: speechLineHeight, width: textWidth)
        let detailLines = lines(detail, font: detailFont, lineHeight: detailLineHeight, width: textWidth)

        // The same arithmetic as `AnswerPanelView.draw`, in the same order with the same
        // constants. Two independent versions of "how tall is this card" is how the drawn
        // content and the card disagree, and the disagreement is only ever visible on a
        // real screen with real text in it.
        //
        // Point targets and follow-up actions are the same widget: one line, `chipHeight`
        // tall, in one stack. Counting them separately and adding once is deliberate, so a
        // reply with three points and two suggested next actions reserves five chip rows
        // rather than the three it would get from `max`.
        var height = inset * 2
            + stageRowHeight
            + speechLines * speechLineHeight
        // The spoken question is counted where the card draws it: directly under the stage,
        // above the answer. Omitting it is how a card gets sized 16 pt short of its own content
        // and clips the first line of the reply instead of the question.
        if !question.isEmpty {
            height += questionRowHeight
        }
        if detailLines > 0 {
            height += sectionGap + detailLines * detailLineHeight
        }
        height += timelineHeight(rows: timelineTexts, folded: timelineTotal > timelineTexts.count,
                                 width: textWidth)
        // The drafted message is counted where the card draws it — under the answer, above the chips —
        // so a reply with a draft in it is sized for the Copy button instead of cutting it off.
        if hasDraft {
            height += sectionGap + draftHeight
        }
        let chipCount = max(0, pointCount) + max(0, actionCount)
        if chipCount > 0 {
            height += chipGap + CGFloat(chipCount) * chipHeight
        }
        // Counted between the chips and the footnote because that is the order the card draws
        // them in. A question the user cannot reach because the window is too short is the same
        // class of bug as a clipped answer — the press simply never gets asked.
        switch confirmation {
        case .none:
            break
        case .question:
            height += sectionGap + confirmHeight
        }
        // The memory footnote is the last thing the card draws, so it is the last thing
        // counted. Its height is fixed rather than measured because the view caps it at two
        // lines: the ceiling and the allowance have to be the same number.
        if hasNote {
            height += sectionGap + noteHeight
        }

        // Clamped, not merely bounded: a reply long enough to exceed the maximum is real,
        // and silently returning it unclamped would make the panel grow until it covered
        // the screen the user was asking about.
        return min(maximumHeight, max(minimumHeight, height))
    }
}
