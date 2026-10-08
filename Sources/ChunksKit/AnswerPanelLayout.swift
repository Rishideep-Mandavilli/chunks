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

    public static let speechLineHeight: CGFloat = 20
    public static let detailLineHeight: CGFloat = 16
    public static let statusRowHeight: CGFloat = 16
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

    /// Whether the card is asking about a press, or reporting the answer to that question.
    ///
    /// A pending press is asked about *on the card the answer is written on*, in one line of
    /// question and one row of two buttons. Like the memory footnote, the height is fixed and
    /// the view caps the question at one line, so the number the window is sized from and the
    /// number the buttons actually occupy cannot drift apart.
    public enum CardConfirmation: Equatable, Sendable {
        /// Nothing asked.
        case none
        /// "Press Send in Mail?" with Allow / Not now.
        case question
        /// The one line saying what happened after the answer.
        case result
    }

    public static let confirmQuestionHeight: CGFloat = 16
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
                               confirmation: CardConfirmation = .none,
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
            + statusRowHeight
            + speechLines * speechLineHeight
        if detailLines > 0 {
            height += sectionGap + detailLines * detailLineHeight
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
        case .result:
            height += sectionGap + confirmQuestionHeight
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
