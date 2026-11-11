import Foundation

/// One thing Chunks wants to draw on the user's screen, in the model's 0–1000 aim grid.
///
/// The agent-ink counterpart of `[POINT:]`: the model explains *and* shows, by circling, boxing,
/// arrowing, underlining, highlighting, pinning, or writing words over the thing it is talking about.
/// Coordinates are fractions of the picture (the same grid as `[ACT:]`), so the shell maps them through
/// `ScreenshotGeometry` exactly once — invariant 1 — and the ink lands on the real control.
///
/// Pure and unit-testable: parsing and the grid→shape geometry live here; the AppKit rendering and the
/// passive overlay live in the shell.
public struct DrawRequest: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case circle, rect, arrow, line, underline, highlight, pin, text
    }
    public let kind: Kind
    /// Grid numbers: bbox (x,y,w,h) for region kinds, two points for arrow/line, one point for pin/text.
    public let a: LogicalPoint
    public let b: LogicalPoint
    public let size: LogicalSize
    public let words: String

    public static let maxWords = 80
    public static let gridEdge: Double = 1000

    /// Parse the body of `[DRAW:…]`. Returns nil for an unknown kind or malformed numbers so the
    /// parser fails open (the tag is shown as text) rather than drawing something unread.
    public static func parse(_ inner: String) -> DrawRequest? {
        let body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sep = body.firstIndex(of: "|") else { return nil }
        let kindRaw = body[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
        let rest = body[body.index(after: sep)...].trimmingCharacters(in: .whitespaces)

        let kind: Kind
        switch kindRaw {
        case "circle", "ellipse", "oval": kind = .circle
        case "rect", "box", "rectangle": kind = .rect
        case "arrow": kind = .arrow
        case "line": kind = .line
        case "underline": kind = .underline
        case "highlight": kind = .highlight
        case "pin", "dot", "point": kind = .pin
        case "text", "write", "label": kind = .text
        default: return nil
        }

        func nums(_ s: String) -> [Double]? {
            let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var out: [Double] = []
            for p in parts {
                guard let v = Double(p), v.isFinite, v >= 0, v <= gridEdge else { return nil }
                out.append(v)
            }
            return out
        }

        switch kind {
        case .circle, .rect, .underline, .highlight:
            guard let n = nums(rest), n.count == 4 else { return nil }
            return DrawRequest(kind: kind, a: LogicalPoint(x: n[0], y: n[1]),
                               b: LogicalPoint(x: n[0], y: n[1]),
                               size: LogicalSize(width: n[2], height: n[3]), words: "")
        case .arrow, .line:
            guard let n = nums(rest), n.count == 4 else { return nil }
            return DrawRequest(kind: kind, a: LogicalPoint(x: n[0], y: n[1]),
                               b: LogicalPoint(x: n[2], y: n[3]),
                               size: LogicalSize(width: 0, height: 0), words: "")
        case .pin:
            guard let n = nums(rest), n.count == 2 else { return nil }
            return DrawRequest(kind: kind, a: LogicalPoint(x: n[0], y: n[1]),
                               b: LogicalPoint(x: n[0], y: n[1]),
                               size: LogicalSize(width: 0, height: 0), words: "")
        case .text:
            guard let bar = rest.firstIndex(of: "|") else { return nil }
            let coord = rest[..<bar].trimmingCharacters(in: .whitespaces)
            let words = rest[rest.index(after: bar)...].trimmingCharacters(in: .whitespaces)
            guard let n = nums(coord), n.count == 2, !words.isEmpty,
                  words.count <= maxWords else { return nil }
            return DrawRequest(kind: kind, a: LogicalPoint(x: n[0], y: n[1]),
                               b: LogicalPoint(x: n[0], y: n[1]),
                               size: LogicalSize(width: 0, height: 0), words: String(words))
        }
    }

    /// Build the display-local shape, given a map from grid coordinates to display-local logical
    /// points (the shell supplies it via `ScreenshotGeometry`, so the flip happens exactly once).
    public func shape(map: (Double, Double) -> LogicalPoint) -> AnnotationShape {
        let p = map(a.x, a.y)
        switch kind {
        case .circle:
            let c = map(a.x + size.width / 2, a.y + size.height / 2)
            let rx = abs(map(a.x + size.width, a.y).x - p.x) / 2
            let ry = abs(map(a.x, a.y + size.height).y - p.y) / 2
            return .ellipse(center: c, radiusX: max(rx, 4), radiusY: max(ry, 4))
        case .rect:
            return .rect(LogicalRect(x: p.x, y: p.y,
                                     width: abs(map(a.x + size.width, a.y).x - p.x),
                                     height: abs(map(a.x, a.y + size.height).y - p.y)))
        case .highlight:
            return .highlight(LogicalRect(x: p.x, y: p.y,
                                          width: abs(map(a.x + size.width, a.y).x - p.x),
                                          height: abs(map(a.x, a.y + size.height).y - p.y)))
        case .underline:
            return .underline(LogicalRect(x: p.x, y: p.y,
                                          width: abs(map(a.x + size.width, a.y).x - p.x),
                                          height: abs(map(a.x, a.y + size.height).y - p.y)))
        case .arrow:
            return .arrow(from: p, to: map(b.x, b.y))
        case .line:
            return .line(from: p, to: map(b.x, b.y))
        case .pin:
            return .pin(p)
        case .text:
            return .text(p, words)
        }
    }
}