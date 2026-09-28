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
    public static let defaultWidth: CGFloat = 460
    public static let minimumHeight: CGFloat = 96
    public static let maximumHeight: CGFloat = 420

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
                               width: CGFloat = defaultWidth,
                               inset: CGFloat = inset) -> CGFloat {
        let textWidth = width - 2 * inset
        let speechLines = lines(speech, font: speechFont, lineHeight: speechLineHeight, width: textWidth)
        let detailLines = lines(detail, font: detailFont, lineHeight: detailLineHeight, width: textWidth)
        let chips: CGFloat = pointCount <= 0 ? 0 : CGFloat(pointCount) * chipHeight + 10

        let height = inset * 2
            + statusRowHeight
            + speechLines * speechLineHeight
            + (detailLines > 0 ? detailLines * detailLineHeight + 10 : 0)
            + chips

        // Clamped, not merely bounded: a reply long enough to exceed the maximum is real,
        // and silently returning it unclamped would make the panel grow until it covered
        // the screen the user was asking about.
        return min(maximumHeight, max(minimumHeight, height))
    }
}
