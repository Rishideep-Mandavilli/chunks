import Foundation

/// The line Chunks shows at the bottom of the screen while it is speaking.
///
/// This is the read-back of **its own** words. The notch already shows the reply as text, but the notch
/// is 360 pt wide at the top of a display you may not be looking at, and a sentence spoken over three
/// seconds is easy to lose — especially the part that matters, which is usually the end. A caption at
/// the bottom is where your eyes already are when an app is doing something on your screen.
///
/// Pure, and in ChunksKit for the reason everything else here is: the rule that decides *what he reads*
/// should be checkable without a display, and the case that actually goes wrong is the cut. A caption
/// that truncates mid-word turns "I pressed the Send button" into "I pressed the Send but…", which is a
/// different sentence about an act on his machine. So the budget is spent at a word boundary, and the
/// ellipsis is only there when something really was left out.
public enum CaptionLine {

    /// Two lines at the bottom of a display, at the size the HUD uses.
    public static let maxCharacters = 156

    /// The caption to show, or nil when there is nothing to show.
    ///
    /// Whitespace-only is nil rather than an empty box: a caption row that appears and says nothing is
    /// read as "it is about to speak" and then nothing follows, which is the false status this app has
    /// been trained to refuse.
    public static func shaped(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxCharacters { return trimmed }

        // Cut at the last word boundary before the budget. A caption with no space in it at all — one
        // long token, a path, a URL — is cut at the budget rather than dropped, because showing half a
        // long word still tells him it is talking.
        let head = String(trimmed.prefix(maxCharacters))
        if let lastSpace = head.lastIndex(of: " ") {
            let beforeSpace = String(head[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            if beforeSpace.count >= minTailCharacters {
                return beforeSpace + "…"
            }
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Below this, a word-boundary cut has lost so much that the uncut prefix is the better caption.
    ///
    /// Measured against the failure it prevents: for a sentence whose first space is at character 3 —
    /// "x y z …" — cutting at the boundary would show "x y…" and drop almost the whole budget. The
    /// tail floor is what makes the boundary rule greedy rather than silly.
    static let minTailCharacters = 40
}
