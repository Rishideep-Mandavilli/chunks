import ChunksTestHarness
import Foundation
@testable import ChunksKit

/// Agent ink: the model draws and writes on the screen while it explains. The pure half — parsing the
/// `[DRAW:]` body, the grid→shape geometry, and the streamer collecting marks — is tested here; the
/// AppKit overlay and its safety properties are checked by the render probe and the gate.
public enum DrawTests {

    static func register() {
        TestRunner.currentSuite = "Draw"

        test("every draw kind parses, and a malformed or out-of-grid body is refused") {
            expect(DrawRequest.parse("circle|100,200,300,150")?.kind == .circle, "circle parses")
            expect(DrawRequest.parse("rect|0,0,500,500")?.kind == .rect, "rect parses")
            expect(DrawRequest.parse("arrow|10,10,900,900")?.kind == .arrow, "arrow parses")
            expect(DrawRequest.parse("line|0,0,100,100")?.kind == .line, "line parses")
            expect(DrawRequest.parse("pin|500,500")?.kind == .pin, "pin parses")
            expect(DrawRequest.parse("underline|0,0,100,20")?.kind == .underline, "underline parses")
            expect(DrawRequest.parse("highlight|0,0,100,100")?.kind == .highlight, "highlight parses")
            expect(DrawRequest.parse("text|100,100|Send here")?.words == "Send here", "text carries words")
            expect(DrawRequest.parse("squiggle|0,0,1,1") == nil, "an unknown kind is refused")
            expect(DrawRequest.parse("circle|100,200") == nil, "a bbox needs four numbers")
            expect(DrawRequest.parse("circle|1001,0,10,10") == nil, "outside the 0-1000 grid is refused")
            expect(DrawRequest.parse("text|0,0|") == nil, "empty words is not a label")
            expect(DrawRequest.parse("text|0,0|" + String(repeating: "x", count: 90)) == nil,
                   "an over-long label is refused, not drawn")
        }

        test("the grid maps to a shape once, with the flip supplied by the caller") {
            // Identity map: grid == display-local, so the geometry is directly checkable.
            let id: (Double, Double) -> LogicalPoint = { LogicalPoint(x: $0, y: $1) }
            let circle = DrawRequest.parse("circle|100,200,300,100")!.shape(map: id)
            if case .ellipse(let c, let rx, let ry) = circle {
                expectEqual(c.x, 250, "circle centre is the bbox centre")
                expectEqual(c.y, 250, "circle centre y")
                expectEqual(rx, 150, "radiusX is half the width")
                expectEqual(ry, 50, "radiusY is half the height")
            } else { expect(false, "circle must become an ellipse") }
            let arrow = DrawRequest.parse("arrow|10,20,300,400")!.shape(map: id)
            if case .arrow(let f, let t) = arrow {
                expectEqual(f.x, 10, "arrow tail"); expectEqual(t.y, 400, "arrow head")
            } else { expect(false, "arrow must stay an arrow") }
            let text = DrawRequest.parse("text|5,6|hi")!.shape(map: id)
            if case .text(let p, let w) = text {
                expectEqual(p.x, 5, "text anchor"); expectEqual(w, "hi", "text words survive")
            } else { expect(false, "text must stay text") }
        }

        test("new shapes have a usable bounding box and the eraser hits topmost first") {
            let pin = AnnotationShape.pin(LogicalPoint(x: 100, y: 100))
            expect(pin.boundingBox.width > 0, "a pin is a disc, not a 1x1 point")
            let words = AnnotationShape.text(LogicalPoint(x: 0, y: 0), "hello")
            expect(words.boundingBox.width > 0, "written words have extent")
            var session = AnnotationSession()
            session.add(.rect(LogicalRect(x: 0, y: 0, width: 100, height: 100)))
            session.add(pin)
            expect(session.shape(at: LogicalPoint(x: 100, y: 100)) == pin, "topmost mark is the pin")
            expect(session.erase(at: LogicalPoint(x: 100, y: 100)), "eraser removes the pin")
            expect(session.shapes.count == 1, "only the topmost mark went")
        }

        test("colour, freeform path, arc and emoji parse and carry through to the shape") {
            let id: (Double, Double) -> LogicalPoint = { LogicalPoint(x: $0, y: $1) }
            let blue = DrawRequest.parse("circle:blue|100,200,300,100")
            expect(blue?.color == .blue, "a colour after the colon is parsed")
            if case .tinted(_, let c)? = blue?.shape(map: id) { expect(c == .blue, "the shape is tinted") }
            else { expect(false, "coloured circle must be a tinted shape") }
            expect(DrawRequest.parse("circle:bogus|0,0,10,10") == nil, "an unknown colour is refused")

            let path = DrawRequest.parse("path:purple|10,10 50,60 90,10")
            expect(path?.kind == .path, "freeform path parses")
            expect(path?.points.count == 3, "all path points are kept")
            if case .tinted(.path(let pts), .purple)? = path?.shape(map: id) {
                expectEqual(pts.count, 3, "the tinted path keeps its points")
            } else { expect(false, "path must map to a tinted .path") }
            expect(DrawRequest.parse("path|10,10") == nil, "a path needs at least two points")

            let arc = DrawRequest.parse("arc:orange|0,0,100,100,0,180")
            expect(arc?.kind == .arc, "arc parses")
            if case .tinted(.arc(_, _, _, let s, let e), .orange)? = arc?.shape(map: id) {
                expectEqual(s, 0, "arc start"); expectEqual(e, 180, "arc end (a smile)")
            } else { expect(false, "arc must map to a tinted .arc") }

            let emoji = DrawRequest.parse("text|500,500|😊")
            expect(emoji?.words == "😊", "emoji survive as words and render as real glyphs")
        }

        test("the parser and streamer collect DRAW marks and fail open on a bad one") {
            let parser = ResponseParser()
            let events = parser.feed("look [DRAW:circle|100,200,300,150] here [DRAW:pin|500,500]")
            let draws = events.compactMap { if case .draw(let d) = $0 { return d } else { return nil } }
            expectEqual(draws.count, 2, "both marks are collected")
            let streamer = AnswerStreamer()
            streamer.push("[DRAW:text|10,10|Send] and [DRAW:bogus|0,0]")
            expectEqual(streamer.draws.count, 1, "the good mark is kept")
            expect(streamer.detail.contains("[DRAW:bogus"), "a malformed DRAW is shown, not swallowed")
            streamer.reset()
            expect(streamer.draws.isEmpty, "reset clears the ink")
        }
    }
}