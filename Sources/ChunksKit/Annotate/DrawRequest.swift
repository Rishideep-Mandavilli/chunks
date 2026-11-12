import Foundation

/// One thing Chunks wants to draw on the user's screen, in the model's 0–1000 aim grid.
///
/// The agent-ink counterpart of `[POINT:]`: the model explains *and* shows, by circling, boxing,
/// arrowing, underlining, highlighting, pinning, writing words (emoji render as real glyphs), or
/// drawing a freeform path / arc in any palette colour. Coordinates are fractions of the picture (the
/// same grid as `[ACT:]`), so the shell maps them through `ScreenshotGeometry` exactly once —
/// invariant 1 — and the ink lands on the real control.
///
/// Pure and unit-testable: parsing and the grid→shape geometry live here; the AppKit rendering and the
/// passive overlay live in the shell.
public struct DrawRequest: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case circle, rect, arrow, line, underline, highlight, pin, text, path, arc
    }
    public let kind: Kind
    public let a: LogicalPoint
    public let b: LogicalPoint
    public let size: LogicalSize
    public let words: String
    public let points: [LogicalPoint]
    public let start: Double
    public let end: Double
    public let color: InkColor?

    public static let maxWords = 80
    public static let maxPathPoints = 64
    public static let gridEdge: Double = 1000

    /// Parse the body of `[DRAW:…]`. The kind may carry a colour (`circle:blue`). Returns nil for an
    /// unknown kind or malformed numbers so the parser fails open (the tag is shown as text).
    public static func parse(_ inner: String) -> DrawRequest? {
        let body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sep = body.firstIndex(of: "|") else { return nil }
        let kindToken = body[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
        let rest = body[body.index(after: sep)...].trimmingCharacters(in: .whitespaces)

        let kindName: String
        let color: InkColor?
        if let colon = kindToken.firstIndex(of: ":") {
            kindName = String(kindToken[..<colon])
            // An unknown colour must not delete the mark — draw it in the default colour instead.
            // Dropping it is how a brown trunk vanished and left a trunk-less tree.
            color = InkColor.parse(String(kindToken[kindToken.index(after: colon)...]))
        } else {
            kindName = kindToken
            color = nil
        }

        let kind: Kind
        switch kindName {
        case "circle", "ellipse", "oval": kind = .circle
        case "rect", "box", "rectangle": kind = .rect
        case "arrow": kind = .arrow
        case "line": kind = .line
        case "underline": kind = .underline
        case "highlight": kind = .highlight
        case "pin", "dot", "point": kind = .pin
        case "text", "write", "label", "emoji": kind = .text
        case "path", "draw", "freeform", "curve": kind = .path
        case "arc", "smile": kind = .arc
        default: return nil
        }

        // A colour may arrive on the kind (`circle:blue`) OR as a trailing field (`circle|…|blue`) —
        // models write both, and dropping the second is how a multicolour reply came out monochrome.
        var coordText = rest
        var trailingColor: InkColor?
        if kind != .text {
            let segs = rest.split(separator: "|", omittingEmptySubsequences: false)
            coordText = String(segs[0]).trimmingCharacters(in: .whitespaces)
            if segs.count > 1 { trailingColor = InkColor.parse(String(segs[1])) }
        }
        let effectiveColor = color ?? trailingColor

        func nums(_ s: String) -> [Double]? {
            let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var out: [Double] = []
            for p in parts {
                guard let v = Double(p), v.isFinite, v >= 0, v <= gridEdge else { return nil }
                out.append(v)
            }
            return out
        }
        func make(_ a: LogicalPoint, _ b: LogicalPoint, _ size: LogicalSize,
                  _ words: String = "", _ points: [LogicalPoint] = [],
                  _ start: Double = 0, _ end: Double = 0) -> DrawRequest {
            DrawRequest(kind: kind, a: a, b: b, size: size, words: words,
                        points: points, start: start, end: end, color: effectiveColor)
        }

        switch kind {
        case .circle, .rect, .underline, .highlight:
            guard let n = nums(coordText), n.count == 4 else { return nil }
            return make(LogicalPoint(x: n[0], y: n[1]), LogicalPoint(x: n[0], y: n[1]),
                        LogicalSize(width: n[2], height: n[3]))
        case .arrow, .line:
            guard let n = nums(coordText), n.count == 4 else { return nil }
            return make(LogicalPoint(x: n[0], y: n[1]), LogicalPoint(x: n[2], y: n[3]),
                        LogicalSize(width: 0, height: 0))
        case .pin:
            guard let n = nums(coordText), n.count == 2 else { return nil }
            return make(LogicalPoint(x: n[0], y: n[1]), LogicalPoint(x: n[0], y: n[1]),
                        LogicalSize(width: 0, height: 0))
        case .arc:
            guard let n = nums(coordText), n.count == 6 else { return nil }
            return make(LogicalPoint(x: n[0], y: n[1]), LogicalPoint(x: n[0], y: n[1]),
                        LogicalSize(width: n[2], height: n[3]), "", [], n[4], n[5])
        case .path:
            // Space-separated comma pairs: "x1,y1 x2,y2 x3,y3".
            var pts: [LogicalPoint] = []
            for token in coordText.split(separator: " ") {
                guard let n = nums(String(token)), n.count == 2 else { return nil }
                pts.append(LogicalPoint(x: n[0], y: n[1]))
                if pts.count > maxPathPoints { return nil }
            }
            guard pts.count >= 2 else { return nil }
            return make(pts[0], pts[pts.count - 1], LogicalSize(width: 0, height: 0), "", pts)
        case .text:
            guard let bar = rest.firstIndex(of: "|") else { return nil }
            let coord = rest[..<bar].trimmingCharacters(in: .whitespaces)
            let words = rest[rest.index(after: bar)...].trimmingCharacters(in: .whitespaces)
            guard let n = nums(coord), n.count == 2, !words.isEmpty,
                  words.count <= maxWords else { return nil }
            return make(LogicalPoint(x: n[0], y: n[1]), LogicalPoint(x: n[0], y: n[1]),
                        LogicalSize(width: 0, height: 0), String(words))
        }
    }

    /// Build the display-local shape, given a map from grid coordinates to display-local logical
    /// points (the shell supplies it via `ScreenshotGeometry`, so the flip happens exactly once).
    public func shape(map: (Double, Double) -> LogicalPoint) -> AnnotationShape {
        let p = map(a.x, a.y)
        let inner: AnnotationShape
        switch kind {
        case .circle:
            let c = map(a.x + size.width / 2, a.y + size.height / 2)
            let rx = abs(map(a.x + size.width, a.y).x - p.x) / 2
            let ry = abs(map(a.x, a.y + size.height).y - p.y) / 2
            inner = .ellipse(center: c, radiusX: max(rx, 4), radiusY: max(ry, 4))
        case .rect:
            inner = .rect(LogicalRect(x: p.x, y: p.y,
                                      width: abs(map(a.x + size.width, a.y).x - p.x),
                                      height: abs(map(a.x, a.y + size.height).y - p.y)))
        case .highlight:
            inner = .highlight(LogicalRect(x: p.x, y: p.y,
                                           width: abs(map(a.x + size.width, a.y).x - p.x),
                                           height: abs(map(a.x, a.y + size.height).y - p.y)))
        case .underline:
            inner = .underline(LogicalRect(x: p.x, y: p.y,
                                           width: abs(map(a.x + size.width, a.y).x - p.x),
                                           height: abs(map(a.x, a.y + size.height).y - p.y)))
        case .arrow:
            inner = .arrow(from: p, to: map(b.x, b.y))
        case .line:
            inner = .line(from: p, to: map(b.x, b.y))
        case .pin:
            inner = .pin(p)
        case .text:
            inner = .text(p, words)
        case .path:
            inner = .path(points.map { map($0.x, $0.y) })
        case .arc:
            let c = map(a.x + size.width / 2, a.y + size.height / 2)
            let rx = abs(map(a.x + size.width, a.y).x - p.x) / 2
            let ry = abs(map(a.x, a.y + size.height).y - p.y) / 2
            inner = .arc(center: c, radiusX: max(rx, 4), radiusY: max(ry, 4), start: start, end: end)
        }
        if let color { return .tinted(inner, color) }
        return inner
    }
}