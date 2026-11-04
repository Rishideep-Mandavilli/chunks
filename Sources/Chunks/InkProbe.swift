import AppKit
import ChunksKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

/// `Chunks --probe-ink` — the marks that stay on screen, measured on the real display.
///
/// Four claims are worth a probe rather than a reading of the code, and three of them have already
/// been wrong in this codebase in a different costume:
///
/// 1. **The layer is inert.** A display-sized window that takes clicks is what locked his Mac on
///    2026-10-11, so click-through, no key window, no main window and the activation guard are read
///    off the live panel and asserted — and the check asks AppKit's own window list which of this
///    app's windows would receive a click at the ink's centre, because `ignoresMouseEvents = true` in
///    the source and `true` on the panel that is actually up are two different facts.
/// 2. **No capture sees it.** The marks reach the model burned into the crop; a live copy arriving in
///    a screenshot as well would be the same ink twice, once over his real screen. Measured with two
///    captures of one rectangle, before and after, counting the ink's own colour — on the strictest
///    route there is (`CaptureEngine`'s unfiltered rect capture), because the live whole-screen route
///    already excludes every window this app owns.
/// 3. **It goes away.** Cleared on demand, and cleared by its own limit when nothing clears it. Ink
///    that outlives the turn points at whatever moved underneath it.
/// 4. **It is on the display it was drawn on**, and refuses one it cannot find.
///
/// Read-only: nothing is pressed, nothing is asked of a model, and no window is moved. It does need
/// Screen Recording, so it runs from the signed bundle and SKIPs (exit 3) when the grant or the awake
/// display is missing — a red line for a locked machine teaches everyone to ignore red lines.
@MainActor
enum InkProbe {

    static var isRequested: Bool { CommandLine.arguments.contains("--probe-ink") }

    /// Start on the main thread and never return.
    ///
    /// AppKit windows belong to the main *thread*, and in a shell-launched process the main actor is
    /// a pool thread until `NSApplication` runs: the first version of this probe built its panel
    /// inside `Task { @MainActor }` and died with "NSWindow should only be instantiated on the main
    /// thread". Running the application is what makes the main thread the main actor's executor —
    /// the arrangement the live app has — and the bundle is `LSUIElement`, so nothing activates and
    /// no dock icon appears while the probe measures.
    static func start() -> Never {
        guard Thread.isMainThread else {
            print("ink probe: not on the main thread at start — refusing to guess where AppKit is")
            exit(1)
        }
        DispatchQueue.main.async {
            Task { @MainActor in
                await measure()
                finish()
            }
        }
        NSApplication.shared.run()
        // Unreachable: `run` never returns while the probe is alive, and the loop is what makes this
        // function's `Never` honest if it ever did.
        while true { Thread.sleep(forTimeInterval: 3600) }
    }

    private static var failures: [String] = []
    private static var checks = 0

    private static func measure() async {
        setvbuf(stdout, nil, _IONBF, 0)
        print("ink probe — the marks that stay on screen while a turn runs")
        holdDisplayAwake()
        guard let display = CaptureEngine.mainDisplay() else {
            skip("no display to draw on")
        }
        guard CGDisplayIsActive(display.displayID) != 0 else {
            skip("display \(display.displayID) is asleep or locked — a capture would be black and "
                + "every count below would be a lie")
        }
        print("display \(display.displayID) — \(Int(display.size.width))x\(Int(display.size.height))pt "
            + "at scale \(display.backingScale)")

        // A rectangle in the middle of the display, and the marks inside it. Small on purpose: a
        // whole-display capture at 2x is six million pixels to count, and the question is not "can it
        // find red anywhere" but "does the capture of *this* rectangle contain the ink".
        let region = LogicalRect(x: display.frame.minX + display.size.width / 2 - 200,
                                 y: display.frame.minY + display.size.height / 2 - 150,
                                 width: 400, height: 300)
        let local = display.space.localRect(fromGlobal: region)
        let shapes = [
            AnnotationShape.rect(LogicalRect(x: local.minX + 60, y: local.minY + 60,
                                             width: 160, height: 100)),
            AnnotationShape.pin(LogicalPoint(x: local.minX + 290, y: local.minY + 210)),
        ]

        let ink = InkLayerManager()

        guard let before = await capture(region) else {
            skip("Screen Recording is not granted to this bundle, so there is nothing to measure")
        }
        let baseline = inkPixels(in: before)
        writePNG(before, to: "/tmp/chunks-ink-before.png")
        print("capture with no ink: \(before.width)x\(before.height)px, \(baseline) ink-coloured pixel(s)")

        // The measurement is a pixel-count difference over a photograph of his live desktop, so it is
        // only meaningful while that photograph is still. A window scrolling red text under the region
        // moves the count by thousands and reads exactly like ink that never left — two gate runs on
        // 2026-11-04 failed that way while he was working at the machine. Two baselines that disagree
        // is a desktop in motion, not a broken layer: skipped and named, never failed and never
        // silently passed.
        guard let again = await capture(region) else {
            skip("the second stability capture could not be taken")
        }
        let drift = abs(inkPixels(in: again) - baseline)
        print("desktop stability: \(drift) ink-coloured pixel(s) of drift between two captures")
        if drift > 40 {
            skip("his desktop is changing under the measured region (\(drift) px of drift), so a "
                 + "pixel-count difference cannot be trusted this run")
        }

        expect(ink.show(shapes, on: display, limitSeconds: 30),
               "the ink layer opened on the display it was drawn on")
        expect(ink.isShowing, "the layer reports itself on screen")
        describe(ink.window)
        // The window server needs a moment: a list read in the same runloop turn as the order-front
        // reports "not on screen" about a window that is about to be — the overlay learned this too.
        await wait(0.6)

        // The live panel's own view, drawn into a bitmap from AppKit's side of the glass. This is the
        // instrument that separates "hidden from captures" from "hidden from everybody": a capture
        // that shows nothing is also what an invisible layer would produce, and the two need opposite
        // fixes. `cacheDisplay` asks the view, not the window server.
        expect(drawnPixels(of: ink.window) > 100,
               "the live panel's own view draws the marks — AppKit's half of the claim that he sees them")

        if let withInk = await capture(region) {
            let count = inkPixels(in: withInk)
            writePNG(withInk, to: "/tmp/chunks-ink-after.png")
            print("capture with the ink up (sharing none): \(count) ink-coloured pixel(s)")
            expect(count <= baseline + 40,
                   "the unfiltered rect capture does not see the ink while sharing is none — a live "
                   + "copy in a screenshot would be the same marks twice, once over his real screen")
        } else {
            fail("the capture with the ink up did not come back")
        }
        expect(listedInWindowServer(ink.window),
               "the window server's on-screen list carries the ink — read a beat after the order-front, "
               + "because in the same runloop turn the server reports a window that is about to be, "
               + "which is how the first version of this check failed in both directions")

        // The controlled experiment: allow sharing, and the same window must appear in both the list
        // and the capture. If it does, the marks really are composited on the display and `sharingType`
        // is the only thing that was hiding them; if it does not, the layer is invisible to everybody
        // and the feature is a lie he cannot see.
        ink.window?.sharingType = .readOnly
        await wait(0.8)
        if let readable = await capture(region) {
            let count = inkPixels(in: readable)
            print("capture with sharing allowed: \(count) ink-coloured pixel(s)")
            expect(count > baseline + 40,
                   "with sharing allowed the same window IS in the capture — so the marks are on the "
                   + "display and `sharingType` was the only thing hiding them from pictures")
        } else {
            fail("the sharing-allowed capture did not come back")
        }
        print("window server list with sharing allowed: \(listedInWindowServer(ink.window)) — the list "
            + "is not the instrument for the capture question, the capture above is")
        ink.window?.sharingType = .none
        await wait(0.8)
        if let backToNone = await capture(region) {
            let count = inkPixels(in: backToNone)
            print("capture with sharing none again: \(count) ink-coloured pixel(s)")
            expect(count <= baseline + 40,
                   "and back to none, the capture is clean again — the property is a switch, not a "
                   + "one-way door")
        } else {
            fail("the second sharing-none capture did not come back")
        }
        checkNoClickPath(ink.window, over: region)

        ink.clear(reason: "the probe asked")
        expect(!ink.isShowing, "the layer reports itself gone after a clear")
        await wait(0.5)
        if let cleared = await capture(region) {
            let count = inkPixels(in: cleared)
            print("capture after clearing: \(count) ink-coloured pixel(s)")
            expect(count <= baseline + 40,
                   "clearing the ink took the marks out of the capture (\(count) against a baseline of "
                   + "\(baseline)) — ink left in a picture is a mark the model is told about twice")
        } else {
            fail("the capture after clearing did not come back")
        }

        // The absolute limit, on a short fuse so the gate can wait for it.
        expect(ink.show(shapes, on: display, limitSeconds: 2), "the layer reopened for the limit test")
        await wait(3.2)
        expect(!ink.isShowing,
               "the ink took itself down at its own limit — a layer nothing clears ends up pointing at "
               + "whatever moved underneath it")

        // A display that is not there is refused rather than guessed at.
        let ghost = DisplayInfo(displayID: 999_999, frame: display.frame,
                                backingScale: display.backingScale, isMain: false)
        expect(!ink.show(shapes, on: ghost),
               "a display matching no NSScreen is refused — ink on the wrong monitor would sit over a "
               + "desktop the crop did not come from")
        expect(!ink.show([], on: display), "no marks means no layer")
    }

    private static func describe(_ window: NSWindow?) {
        guard let window else {
            fail("there is no window to describe")
            return
        }
        let frame = window.frame
        let facts = [
            "visible=\(window.isVisible)",
            "level=\(window.level.rawValue)",
            "clickThrough=\(window.ignoresMouseEvents)",
            "key=\(window.canBecomeKey)",
            "main=\(window.canBecomeMain)",
            "movable=\(window.isMovable)",
            "sharing=\(window.sharingType.rawValue)",
            "frame=\(Int(frame.width))x\(Int(frame.height))pt",
        ]
        print("the live panel: " + facts.joined(separator: " "))
        expect(window.ignoresMouseEvents,
               "the ink is click-through — a layer that took a click would be the 2026-10-11 lockup again")
        expect(!window.canBecomeKey && !window.canBecomeMain,
               "the ink can never take the keyboard or the menu bar")
        expect(!window.isMovable, "the ink cannot be dragged off the marks it is restating")
        expect(window.isVisible,
               "AppKit reports the panel visible and on a display — its half of the claim that he sees "
               + "the marks, the window server's list being deliberately out of the question below")
    }

    /// Whether the window server's on-screen list carries this window, matched by identity rather than
    /// by assuming it is first.
    ///
    /// Measured 2026-11-03: the list carries the ink whether sharing is none or allowed, while a
    /// capture sees it only when sharing is allowed — so the list answers "is it on the screen" and
    /// the capture answers "is it in a picture", and the two must not be swapped. Reading the list in
    /// the same runloop turn as the order-front reports a window that is not there yet, which is how
    /// the first version of this check failed in both directions on the same evening.
    private static func listedInWindowServer(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return listed.contains { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
    }

    /// Ink pixels in the live panel's own content view, drawn by AppKit rather than captured by the
    /// window server.
    private static func drawnPixels(of window: NSWindow?) -> Int {
        guard let view = window?.contentView else { return 0 }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return 0 }
        return inkPixels(in: image)
    }

    /// Which of this app's windows would actually take a click at the ink's centre.
    ///
    /// Asked of AppKit's own list rather than of the source, because the property that matters is the
    /// one on the panel that is up: a click-through window cannot hold the machine, and that is the
    /// whole reason this surface is allowed to be display-sized.
    private static func checkNoClickPath(_ window: NSWindow?, over region: LogicalRect) {
        guard let window else { return }
        // AppKit's space is bottom-left and the region is top-left, so the point is flipped once here
        // rather than compared across the two conventions.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? region.minY + region.height
        let appKitPoint = CGPoint(x: region.minX + region.width / 2,
                                  y: primaryHeight - (region.minY + region.height / 2))
        let takers = NSApp.windows.filter { candidate in
            candidate.isVisible
                && !candidate.ignoresMouseEvents
                && candidate.frame.contains(appKitPoint)
        }
        let names = takers.map { $0.className }.joined(separator: ", ")
        print("windows of this app that would take a click there: \(names.isEmpty ? "none" : names)")
        expect(!takers.contains { $0 === window },
               "the ink is not in the set of windows that would take a click at its own centre")
    }

    // MARK: Capturing and counting

    private static func capture(_ region: LogicalRect) async -> CGImage? {
        guard let display = CaptureEngine.mainDisplay(), awake(display) else {
            skip("the display slept mid-probe — a capture of a sleeping display is black, so every "
                + "count in this run would be a lie about the ink")
        }
        do {
            let shot = try await CaptureEngine().capture(globalRect: region)
            return shot.image
        } catch {
            print("capture failed — \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            return nil
        }
    }

    /// A display can fall asleep in the middle of a probe that takes eight seconds and generates no
    /// input, and a capture of a sleeping display is black: the "sharing none shows nothing" assertions
    /// would pass on a picture of nothing and the sharing-allowed one would fail on the same nothing.
    /// Measured 2026-11-03, twice, in the gate.
    private static func awake(_ display: DisplayInfo) -> Bool {
        CGDisplayIsActive(display.displayID) != 0 && CGDisplayIsAsleep(display.displayID) == 0
    }

    /// Holds the display awake for the probe's own few seconds.
    ///
    /// The probe generates no input, and a display that sleeps mid-run turns every capture black —
    /// which is how the gate failed this check twice on a machine that was doing nothing wrong. The
    /// assertion dies with the process, so there is nothing to remember to release.
    private static func holdDisplayAwake() {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Chunks ink probe — a few seconds of captures" as CFString, &id)
        print("display hold: \(status == kIOReturnSuccess ? "taken" : "refused (\(status))")")
    }

    /// Pixels of the ink's own colour. Loose on purpose: the mark is (1.0, 0.24, 0.32) but a capture
    /// is colour-managed and a stroke's edge is blended with whatever was behind it, so a strict
    /// match would count the middle of the line and miss the rest of it.
    private static func inkPixels(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return 0 }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var count = 0
        for index in stride(from: 0, to: bytes.count - 3, by: 4) {
            let red = Int(bytes[index])
            let green = Int(bytes[index + 1])
            let blue = Int(bytes[index + 2])
            // The ink's own colour is (255, 61, 82), and the box is tight on purpose: the first
            // matcher was loose enough to count 3784 pixels of his wallpaper as ink before any mark
            // existed, which turned "does the capture see the ink" into a comparison of two noisy
            // numbers. A 3 pt stroke at 2x is six pixels wide, so its middle is pure colour and a
            // tight box still counts it.
            if red > 225 && abs(green - 61) < 35 && abs(blue - 82) < 35 {
                count += 1
            }
        }
        return count
    }

    private static func writePNG(_ image: CGImage, to path: String) {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png,
                                                                       properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("  wrote \(path) (\(png.count / 1024) KB) — open it, a count is not a picture")
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Verdicts

    private static func expect(_ condition: Bool, _ why: String) {
        checks += 1
        if condition {
            print("  PASS  \(why)")
        } else {
            fail(why)
        }
    }

    private static func fail(_ why: String) {
        print("  FAIL  \(why)")
        failures.append(why)
    }

    private static func skip(_ why: String) -> Never {
        print("SKIP: \(why)")
        Log.flush()
        exit(3)
    }

    private static func finish() -> Never {
        print("ink probe: \(checks - failures.count)/\(checks) checks passed")
        if failures.isEmpty {
            print("PASS")
        } else {
            for failure in failures { print("  failed: \(failure)") }
            print("FAIL")
        }
        Log.flush()
        exit(failures.isEmpty ? 0 : 1)
    }
}

/// `Chunks --render-ink <path>` — every mark, drawn offscreen, to look at.
///
/// The ink is a visual claim, and a shell cannot screenshot it: Screen Recording belongs to the
/// signed app, and a capture taken here is wallpaper. So the real `InkView` is drawn into a bitmap at
/// its real size over a desk-like ground and written to a file — the same recipe the caption render
/// uses, including the window it needs, because SwiftUI and AppKit views both draw nothing into a bare
/// offscreen surface.
///
/// This is the check that catches a mark nobody can see: a 3 pt stroke and a 5 pt dot are numbers
/// until they are on a background that fights them.
@MainActor
enum InkRenderProbe {

    static var isRequested: Bool { CommandLine.arguments.contains("--render-ink") }

    static var requestedPath: String {
        let fallback = ".impeccable/review/ink.png"
        guard let index = CommandLine.arguments.firstIndex(of: "--render-ink") else { return fallback }
        let next = index + 1
        guard CommandLine.arguments.indices.contains(next),
              !CommandLine.arguments[next].hasPrefix("--") else { return fallback }
        return CommandLine.arguments[next]
    }

    static func start() -> Never {
        let path = requestedPath
        if Thread.isMainThread {
            MainActor.assumeIsolated { run(to: path) }
        } else {
            // Sync onto the main thread, not a hop to the main actor: the view and window this draws
            // are AppKit objects, and in a shell-launched process the main actor is a pool thread.
            DispatchQueue.main.sync { MainActor.assumeIsolated { run(to: path) } }
        }
        while true { Thread.sleep(forTimeInterval: 3600) }
    }

    private static func run(to path: String) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let width: CGFloat = 900
        let height: CGFloat = 560

        // One of every mark he can draw, laid out so none of them overlaps: the point of the picture
        // is what each one looks like on a background that is not a test harness.
        var wobble: [LogicalPoint] = []
        for step in 0..<40 {
            wobble.append(LogicalPoint(x: 60 + Double(step) * 4,
                                       y: 90 + sin(Double(step) / 3) * 26))
        }
        let shapes: [AnnotationShape] = [
            .stroke(wobble),
            .ellipse(center: LogicalPoint(x: 640, y: 110), radiusX: 130, radiusY: 62),
            .rect(LogicalRect(x: 60, y: 250, width: 260, height: 150)),
            .arrow(from: LogicalPoint(x: 400, y: 400), to: LogicalPoint(x: 560, y: 280)),
            .pin(LogicalPoint(x: 760, y: 330)),
            .pin(LogicalPoint(x: 820, y: 470)),
        ]

        let view = InkView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.shapes = shapes
        // A desk-like ground rather than white: white is the friendliest possible backdrop for a red
        // mark, and the question is whether it survives a real one.
        view.backdrop = NSColor(calibratedWhite: 0.22, alpha: 1)

        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("render-ink: the surface could not be drawn")
            exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("render-ink: the drawing could not be encoded")
            exit(1)
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try png.write(to: url)
        } catch {
            print("render-ink: could not write \(url.path) — \(error)")
            exit(1)
        }
        print("render-ink: \(shapes.count) marks drawn into \(url.path) "
            + "(\(Int(width))x\(Int(height))pt, \(png.count / 1024) KB)")
        print("render-ink: pen, circle, box, arrow and two pins — a pin is a solid dot with a pale "
            + "ring, the same mark the model is shown")
        Log.flush()
        exit(0)
    }
}
