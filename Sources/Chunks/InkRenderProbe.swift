import AppKit
import ChunksKit

/// `--render-ink <path>` draws every agent-ink shape offscreen to a PNG so the drawing can be looked
/// at without a live turn; `--probe-ink` shows the passive layer briefly and asserts the four
/// properties that keep it from becoming the overlay's lock-up bug, then clears it.
enum InkRenderProbe {
    static var renderPath: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--render-ink"),
              i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }
    static var isProbeRequested: Bool { CommandLine.arguments.contains("--probe-ink") }

    static var alignPath: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--render-ink-align"),
              i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    static var replyPath: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--render-ink-reply"),
              i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    /// Run a raw model reply through the SAME parse→map→render pipeline the live turn uses, so a
    /// multi-colour / freeform reply can be looked at end-to-end (not just the hand-built samples).
    @MainActor
    static func runReply(to path: String) {
        let reply = """
        <SAY>Here is the search bar, the send button, and a smile.</SAY>
        [DRAW:circle:blue|100,100,300,150]
        [DRAW:rect:green|500,100,250,150]
        [DRAW:arrow:orange|200,400,500,500]
        [DRAW:path:purple|600,400 650,350 700,400 650,450 600,400]
        [DRAW:arc:red|750,400,150,120,0,180]
        [DRAW:text|100,600|the search bar]
        [DRAW:text|700,600|😊]
        [DRAW:pin|500,650|teal]
        """
        let streamer = AnswerStreamer()
        streamer.push(reply)
        streamer.finish()
        let draws = streamer.draws
        print("render-ink-reply: parsed \(draws.count) draw marks")
        // Mirror renderAgentInk's mapping over a synthetic 1000x700 display.
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        var shapes: [AnnotationShape] = []
        for request in draws {
            shapes.append(request.shape { x, y in
                guard let g = ScreenshotGeometry.appKitGlobalPoint(
                    x: x, y: y, imageWidth: 1000, imageHeight: 700, imageFrame: frame) else {
                    return LogicalPoint(x: 0, y: 0)
                }
                return LogicalPoint(x: g.x - frame.minX, y: frame.maxY - g.y)
            })
        }
        let view = InkView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        view.backdrop = NSColor.white
        view.shapes = shapes
        writePNG(view: view, path: path)
    }

    @MainActor
    static func writePNG(view: InkView, path: String) {
        let pdf = view.dataWithPDF(inside: view.bounds)
        guard let image = NSImage(data: pdf) else {
            print("render-ink: could not rasterize"); exit(1)
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            print("render-ink: could not allocate bitmap"); exit(1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("render-ink: encode failed"); exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: path)) }
        catch { print("render-ink: write failed \(error)"); exit(1) }
        print("render-ink: wrote \(png.count / 1024) KB to \(path)")
        exit(0)
    }

    /// Burn ink at known grid points into a live capture so the grid→screen mapping can be checked
    /// against the real desktop: a pin at (500,500) must sit at the exact centre of the display.
    @MainActor
    static func runAlign(to path: String) {
        guard let display = CaptureEngine.mainDisplay() else {
            print("render-ink-align: no display"); exit(1)
        }
        let w = display.space.displayFrame.width
        let h = display.space.displayFrame.height
        let frame = display.space.displayFrame
        let cgFrame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        func local(_ x: Double, _ y: Double) -> LogicalPoint {
            guard let g = ScreenshotGeometry.appKitGlobalPoint(
                x: x, y: y, imageWidth: w * display.space.scale,
                imageHeight: h * display.space.scale, imageFrame: cgFrame) else {
                return LogicalPoint(x: 0, y: 0)
            }
            return LogicalPoint(x: g.x - frame.minX, y: frame.maxY - g.y)
        }
        let centre = local(500, 500)
        let topLeft = local(0, 0)
        let bottomRight = local(1000, 1000)
        print("render-ink-align: display \(Int(w))x\(Int(h)) centre=(\(Int(centre.x)),\(Int(centre.y))) "
            + "topLeft=(\(Int(topLeft.x)),\(Int(topLeft.y))) bottomRight=(\(Int(bottomRight.x)),\(Int(bottomRight.y)))")
        let shapes: [AnnotationShape] = [
            .pin(centre),
            .ellipse(center: centre, radiusX: 60, radiusY: 60),
            .text(LogicalPoint(x: centre.x + 70, y: centre.y - 10), "centre 500,500"),
            .pin(topLeft), .pin(bottomRight),
        ]
        Task { @MainActor in
            do {
                let captured = try await CaptureEngine().capture(display: display)
                let burned = captured.composited(with: shapes, display: display)
                guard let png = ScreenCapture(image: burned, globalRect: captured.globalRect).png() else {
                    print("render-ink-align: encode failed"); exit(1)
                }
                try png.write(to: URL(fileURLWithPath: path))
                print("render-ink-align: wrote \(png.count / 1024) KB to \(path)")
                exit(0)
            } catch {
                print("render-ink-align: capture failed \(error)"); exit(1)
            }
        }
        RunLoop.main.run()
    }

    static func sampleShapes() -> [AnnotationShape] {
        [
            .tinted(.ellipse(center: LogicalPoint(x: 200, y: 150), radiusX: 120, radiusY: 70), .blue),
            .tinted(.rect(LogicalRect(x: 420, y: 80, width: 220, height: 120)), .green),
            .highlight(LogicalRect(x: 700, y: 80, width: 220, height: 120)),
            .tinted(.arrow(from: LogicalPoint(x: 200, y: 320), to: LogicalPoint(x: 500, y: 420)), .orange),
            .tinted(.line(from: LogicalPoint(x: 560, y: 320), to: LogicalPoint(x: 860, y: 320)), .purple),
            .underline(LogicalRect(x: 560, y: 380, width: 300, height: 40)),
            .pin(LogicalPoint(x: 200, y: 560)),
            .text(LogicalPoint(x: 320, y: 540), "the Send button"),
            // A freeform smile (curve) + two eyes, in colour — the "smiley" the model can now draw.
            .tinted(.arc(center: LogicalPoint(x: 700, y: 520), radiusX: 70, radiusY: 60,
                         start: 0, end: 180), .red),
            .tinted(.pin(LogicalPoint(x: 670, y: 490)), .red),
            .tinted(.pin(LogicalPoint(x: 730, y: 490)), .red),
            // A real emoji glyph, and a freeform heart-ish curve.
            .text(LogicalPoint(x: 850, y: 480), "😊"),
            .tinted(.path([LogicalPoint(x: 100, y: 640), LogicalPoint(x: 140, y: 600),
                           LogicalPoint(x: 180, y: 640), LogicalPoint(x: 140, y: 680),
                           LogicalPoint(x: 100, y: 640)]), .pink),
        ]
    }

    @MainActor
    static func runRender(to path: String) {
        let view = InkView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        view.backdrop = NSColor.white
        view.shapes = sampleShapes()
        // The view's PDF representation honours its flipped (top-left) coordinate system, so the
        // raster matches what the live layer shows — shapes and upright text in the right places.
        let pdf = view.dataWithPDF(inside: view.bounds)
        guard let image = NSImage(data: pdf) else {
            print("render-ink: could not rasterize the drawing"); exit(1)
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 700,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            print("render-ink: could not allocate bitmap"); exit(1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1000, height: 700))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("render-ink: could not encode PNG"); exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: path)) }
        catch { print("render-ink: write failed \(error)"); exit(1) }
        print("render-ink: wrote \(png.count / 1024) KB to \(path)")
        exit(0)
    }

    @MainActor
    static func runProbe() {
        let manager = InkLayerManager()
        guard let display = CaptureEngine.mainDisplay() else {
            print("probe-ink: no display"); exit(1)
        }
        let shown = manager.show(sampleShapes(), on: display, limitSeconds: 2)
        guard shown, let window = manager.window else {
            print("probe-ink: layer did not show"); exit(1)
        }
        let clickThrough = window.ignoresMouseEvents
        let key = window.canBecomeKey
        let main = window.canBecomeMain
        let sharing = window.sharingType == .none
        print("probe-ink: clickThrough=\(clickThrough) canBecomeKey=\(key) "
            + "canBecomeMain=\(main) excludedFromCapture=\(sharing)")
        manager.clear(reason: "probe finished")
        let ok = clickThrough && !key && !main && sharing
        print(ok ? "probe-ink: PASS — the layer is inert" : "probe-ink: FAIL — the layer can take input")
        exit(ok ? 0 : 1)
    }
}