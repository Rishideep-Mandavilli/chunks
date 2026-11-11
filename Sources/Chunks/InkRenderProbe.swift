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

    static func sampleShapes() -> [AnnotationShape] {
        [
            .ellipse(center: LogicalPoint(x: 200, y: 150), radiusX: 120, radiusY: 70),
            .rect(LogicalRect(x: 420, y: 80, width: 220, height: 120)),
            .highlight(LogicalRect(x: 700, y: 80, width: 220, height: 120)),
            .arrow(from: LogicalPoint(x: 200, y: 320), to: LogicalPoint(x: 500, y: 420)),
            .line(from: LogicalPoint(x: 560, y: 320), to: LogicalPoint(x: 860, y: 320)),
            .underline(LogicalRect(x: 560, y: 380, width: 300, height: 40)),
            .pin(LogicalPoint(x: 200, y: 560)),
            .text(LogicalPoint(x: 320, y: 540), "the Send button"),
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