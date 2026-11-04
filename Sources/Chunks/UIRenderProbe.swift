import AppKit
import ChunksKit
import SwiftUI

/// `--render-ui <path.png>` — draw the notch's real views offscreen so the design can be looked at.
///
/// Verification of a visual change here cannot be a screenshot: Screen Recording belongs to the
/// signed app, and a capture taken from a shell is wallpaper. So this builds the shipping
/// `NotchHUDView` in an `NSHostingView`, sizes it to the exact height `NotchPanelManager` would
/// give the window — `model.contentHeight`, which is `AnswerPanelLayout`'s arithmetic — caches it
/// into a bitmap, and writes one file with every state in it.
///
/// It is a review artifact, not a product surface: the labels are drawn on the grey ground
/// beside each card, never inside one, and the fixtures are ordinary replies rather than claims.
enum UIRenderProbe {

    static var isRequested: Bool { CommandLine.arguments.contains("--render-ui") }

    static var isWindowRequested: Bool { CommandLine.arguments.contains("--render-window") }

    static var isSetupRequested: Bool { CommandLine.arguments.contains("--render-setup") }

    static var isPanelRequested: Bool { CommandLine.arguments.contains("--render-panel") }

    static func requestedPath() -> String {
        flagPath(after: "--render-ui", fallback: ".impeccable/review/notch-card.png")
    }

    static func requestedPanelPath() -> String {
        flagPath(after: "--render-panel", fallback: ".impeccable/review/panel.png")
    }

    static func requestedWindowPath() -> String {
        flagPath(after: "--render-window", fallback: ".impeccable/review/app-window.png")
    }

    static func requestedSetupPath() -> String {
        flagPath(after: "--render-setup", fallback: ".impeccable/review/setup.png")
    }

    static var isCaptionRequested: Bool { CommandLine.arguments.contains("--render-caption") }

    static func requestedCaptionPath() -> String {
        flagPath(after: "--render-caption", fallback: ".impeccable/review/caption.png")
    }

    /// `--render-caption <path.png>` — the speech caption, drawn the way the panel draws it.
    ///
    /// A caption is a surface nobody has looked at until it is rendered: its width, its distance above
    /// the Dock, and what a long answer does to two lines are all things a screenshot settles and a
    /// passing test does not. Both shapes are drawn — a normal line and one that has been cut at a word
    /// boundary — because the cut is the case that can go wrong silently.
    @MainActor
    static func runCaption(to path: String) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let lines = [
            "Pressed Send.",
            CaptionLine.shaped("I opened the invoice, read the total, and found it is later than the "
                                + "date on the purchase order you showed me earlier in this "
                                + "conversation, so you may want to check that before you reply") ?? "…",
            CaptionLine.shaped(String(repeating: "word ", count: 80)) ?? "…",
        ]
        let width: CGFloat = 720
        let rowHeight: CGFloat = 96
        let canvas = NSImage(size: NSSize(width: width + 40,
                                          height: rowHeight * CGFloat(lines.count) + 24))
        canvas.lockFocus()
        NSColor(calibratedWhite: 0.16, alpha: 1).set()
        NSRect(x: 0, y: 0, width: width + 40,
               height: rowHeight * CGFloat(lines.count) + 24).fill()
        for (index, line) in lines.enumerated() {
            let model = CaptionModel()
            model.text = line
            let host = NSHostingView(rootView: CaptionView(model: model))
            host.frame = NSRect(x: 20, y: 12 + CGFloat(lines.count - 1 - index) * rowHeight,
                                width: width, height: rowHeight - 12)
            // SwiftUI draws nothing into a bare offscreen hosting view — the first attempt produced a
            // blank image and a plausible byte count, which is exactly how a render check lies. The
            // working recipe, copied from the notch renderer: attach a window that is never ordered
            // front, then cache the display into a bitmap rep and draw that.
            let rect = host.frame
            host.frame = NSRect(x: 0, y: 0, width: rect.width, height: rect.height)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            rep.draw(in: NSRect(x: 20, y: 12 + CGFloat(lines.count - 1 - index) * rowHeight,
                                width: rect.width, height: rect.height))
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("render-caption: could not draw the caption")
            exit(1)
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try png.write(to: url)
            print("render-caption: wrote \(lines.count) caption rows to \(url.path)")
        } catch {
            print("render-caption: could not write \(url.path): \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    private static func flagPath(after flag: String, fallback: String) -> String {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return fallback }
        return CommandLine.arguments[index + 1]
    }

    /// The cutout depth of the built-in display this machine reports, so the render shows the card
    /// hanging from a real notch rather than an invented one.
    private static var notchHeight: CGFloat { 33 }

    @MainActor
    static func run(to path: String) -> Never {
        let width = NotchHUDModel.defaultCardWidth
        let states: [(label: String, model: NotchHUDModel)] = [
            ("1 · listening, mid-sentence", listening()),
            ("2 · waiting on the model", waiting()),
            ("3 · answering, a plan of six, asking about step 6", answering()),
            ("4 · a turn that failed", failed()),
            ("5 · adding a routine from a spoken sentence", routineAsking()),
            ("6 · listening, and the room is quiet", listeningQuiet()),
            ("7 · a reminder that arrived late", reminderFired()),
            ("8 · maximum draft · 340 characters", draftReady()),
            ("9 · maximum draft + confirmation", draftReady(asking: true)),
            ("10 · typed words offered for copy", typedForCopy()),
        ]

        let gutter: CGFloat = 26
        // Each render carries its own 33 pt cutout band at the top, so a gap smaller than that
        // paints one card's black notch over the previous card's buttons — which reads as a
        // clipped Ask row and is nothing of the sort.
        let gap: CGFloat = 44
        var frames: [(label: String, model: NotchHUDModel, view: NSHostingView<AnyView>, window: NSWindow, height: CGFloat)] = []
        for state in states {
            state.model.cardWidth = width
            state.model.notchHeight = notchHeight
            let height = state.model.contentHeight + notchHeight
            let view = NSHostingView(rootView: AnyView(
                NotchHUDView(model: state.model)
                    .environment(\.hudLayoutProbeEnabled, true)
            ))
            let rect = NSRect(x: 0, y: 0, width: width, height: height)
            // SwiftUI's native scroll document stays zero-sized without a window. Attach one but
            // never order it front or make it key: this remains an offscreen, permission-free probe.
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            view.frame = rect
            view.layoutSubtreeIfNeeded()
            frames.append((state.label, state.model, view, window, height))
        }
        if let first = frames.first {
            HoverBindings.describe(first.view, surface: "the notch card, which is up while he works")
        }

        let totalHeight = frames.reduce(gutter) { $0 + $1.height + gap } + gap
        let canvas = NSImage(size: NSSize(width: width + gutter * 2 + 150, height: totalHeight))
        canvas.lockFocus()
        NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).setFill()
        NSBezierPath(rect: canvas.size.rect).fill()

        var y = totalHeight - gutter
        var draftChecks = 0
        var draftConfirmationChecks = 0
        var draftLayoutPassed = true
        var tapChecks = 0
        var tapPassed = true
        for frame in frames.reversed() {
            y -= frame.height
            frame.view.layoutSubtreeIfNeeded()
            guard let rep = frame.view.bitmapImageRepForCachingDisplay(in: frame.view.bounds) else {
                print("render-ui: FAIL could not draw \(frame.label)")
                exit(1)
            }
            frame.view.cacheDisplay(in: frame.view.bounds, to: rep)
            rep.draw(in: NSRect(x: gutter, y: y, width: width, height: frame.height))
            if frame.model.draft != nil {
                draftChecks += 1
                if frame.model.confirmQuestion != nil { draftConfirmationChecks += 1 }
                let passed = checkDraftLayout(in: frame.view, model: frame.model,
                                              isMaxDraft: frame.label.contains("maximum draft"))
                draftLayoutPassed = passed && draftLayoutPassed
            }
            // The two taps the card can be waiting on: the answers to a question, and the one way
            // back out of a failure. Both are checked on every state that draws them, because a
            // control below the bottom edge of the window is a control that simply cannot be used,
            // and the sizing arithmetic lives in a different file from the drawing.
            if frame.model.confirmQuestion != nil || frame.model.canRetry {
                tapChecks += 1
                tapPassed = checkTapTargets(in: frame.view, model: frame.model,
                                            label: frame.label) && tapPassed
            }
            NSAttributedString(string: frame.label, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
            ]).draw(at: NSPoint(x: gutter + width + 14, y: y + frame.height - 22))
            y -= gap
        }
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("render-ui: could not draw the HUD states")
            exit(1)
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try png.write(to: url)
            print("render-ui: wrote \(states.count) states to \(url.path)")
        } catch {
            print("render-ui: could not write \(url.path): \(error.localizedDescription)")
            exit(1)
        }
        let passed = draftLayoutPassed && tapPassed && draftChecks == 3 && draftConfirmationChecks == 1
        print("render-ui: draft-layout \(passed ? "PASS" : "FAIL") (\(draftChecks) fixtures, 340 characters, 360pt)")
        print("render-ui: tap-targets \(tapPassed ? "PASS" : "FAIL") (\(tapChecks) fixtures with a "
              + "question or a way back)")
        exit(passed ? 0 : 1)
    }

    /// These rects come from native background views laid out on the actual SwiftUI controls, not
    /// from `measure`. A missing marker is a failure, never a skipped assertion. Nothing is shown
    /// or pressed: the host's bounds are the exact content/window bounds used by NotchPanelManager.
    @MainActor
    private static func checkDraftLayout(in host: NSView, model: NotchHUDModel,
                                         isMaxDraft: Bool) -> Bool {
        let name = model.confirmQuestion == nil ? "draft" : "draft+confirmation"
        var failures: [String] = []
        func require(_ condition: Bool, _ reason: String) {
            if !condition { failures.append(reason) }
        }
        func descendants(of view: NSView) -> [HUDLayoutProbeView] {
            let own = (view as? HUDLayoutProbeView).map { [$0] } ?? []
            return own + view.subviews.flatMap { descendants(of: $0) }
        }
        let markers = descendants(of: host)
        func marker(_ part: HUDLayoutProbePart) -> HUDLayoutProbeView? {
            let matches = markers.filter { $0.part == part }
            require(matches.count == 1, "expected one \(part.rawValue) marker, got \(matches.count)")
            return matches.count == 1 ? matches[0] : nil
        }
        func bounds(of view: NSView) -> NSRect { view.convert(view.bounds, to: host) }
        func contains(_ outer: NSRect, _ inner: NSRect) -> Bool {
            !inner.isEmpty && inner.origin.x.isFinite && inner.origin.y.isFinite
                && inner.width.isFinite && inner.height.isFinite
                && outer.insetBy(dx: -0.5, dy: -0.5).contains(inner)
        }
        guard let content = marker(.cardContent), let block = marker(.draftBlock),
              let copy = marker(.draftCopy), let viewport = marker(.draftViewport),
              let text = marker(.draftText) else {
            print("render-ui: \(name) FAIL - \(failures.joined(separator: "; "))")
            return false
        }
        let visibleContent = bounds(of: content).intersection(host.bounds).intersection(host.visibleRect)
        let copyBounds = bounds(of: copy)
        if isMaxDraft {
            require(model.draft?.count == 340 && ResponseParser.maxDraftCharacters == 340,
                    "fixture must reach the real 340-character parser cap")
        }
        require(host.bounds.width == 360, "fixture must use the shipping 360pt width")
        require(abs(host.bounds.height - model.contentHeight - model.notchHeight) <= 0.5,
                "host resized away from the shipping window height")
        require(host.window?.contentLayoutRect.size == host.bounds.size,
                "host does not match the native window's visible content size")
        require(host.window?.isVisible == false, "the render window must never be shown")
        require(abs(block.bounds.height - AnswerPanelLayout.draftHeight) <= 0.5,
                "drawn draft block \(block.bounds.height) != measured \(AnswerPanelLayout.draftHeight)")
        require(contains(visibleContent, copyBounds), "Copy falls outside visible content/window")
        require(copyBounds.width >= 80 && copyBounds.height >= 26, "Copy lost its usable hit area")
        require(contains(visibleContent, bounds(of: viewport)), "draft viewport is clipped")
        require(abs(viewport.bounds.height - AnswerPanelLayout.draftTextHeight) <= 0.5,
                "draft viewport was compressed")
        if isMaxDraft {
            require(text.bounds.height > viewport.bounds.height,
                    "maximum draft text was truncated or did not overflow")
        } else {
            require(text.bounds.height <= viewport.bounds.height + 0.5,
                    "short typed text must sit inside the well without claiming overflow")
        }

        var ancestor = text.superview
        while let view = ancestor, !(view is NSScrollView) { ancestor = view.superview }
        if let scroll = ancestor as? NSScrollView, let document = scroll.documentView {
            if isMaxDraft {
                require(document.bounds.height > scroll.contentView.bounds.height,
                        "draft cannot scroll to its last line (document=\(document.bounds), clip=\(scroll.contentView.bounds))")
                let origin = scroll.contentView.bounds.origin
                scroll.contentView.scroll(to: NSPoint(x: origin.x,
                    y: document.bounds.maxY - scroll.contentView.bounds.height))
                require(scroll.contentView.bounds.origin.y > origin.y, "native draft scroll did not move")
                require(bounds(of: copy) == copyBounds, "scrolling the text moved Copy")
                scroll.contentView.scroll(to: origin)
            }
            require(!copy.isDescendant(of: scroll), "Copy scrolls away with the draft")
        } else {
            require(false, "draft text has no native scroll view")
        }
        if model.confirmQuestion != nil {
            for part in [HUDLayoutProbePart.allow, .deny] {
                if let button = marker(part) {
                    require(contains(visibleContent, bounds(of: button)), "\(part.rawValue) falls outside visible content/window")
                    require(button.bounds.height >= 26, "\(part.rawValue) lost its usable hit area")
                    require(!bounds(of: button).intersects(copyBounds), "\(part.rawValue) overlaps Copy")
                }
            }
        }
        let passed = failures.isEmpty
        print("render-ui: \(name) \(passed ? "PASS" : "FAIL") - Copy=\(copyBounds) visible=\(visibleContent) "
              + "window=\(host.bounds.size) block=\(block.bounds.height) text=\(text.bounds.height) viewport=\(viewport.bounds.height)"
              + (passed ? " scroll=PASS" : " - \(failures.joined(separator: "; "))"))
        return passed
    }

    /// The taps a card cannot afford to lose: the two answers to a question, and the one way back
    /// out of a failure.
    ///
    /// The sizing arithmetic lives in `AnswerPanelLayout.measure` and the drawing lives in
    /// `NotchHUDView`, and nothing but a real layout pass proves they still agree. A control below the
    /// bottom edge of the window is a control that cannot be used — and the buried Ask row this
    /// surface was designed against is exactly that failure, so it is checked against the native
    /// rects SwiftUI laid out, never against the numbers that reserved them.
    @MainActor
    private static func checkTapTargets(in host: NSView, model: NotchHUDModel,
                                       label: String) -> Bool {
        func descendants(of view: NSView) -> [HUDLayoutProbeView] {
            let own = (view as? HUDLayoutProbeView).map { [$0] } ?? []
            return own + view.subviews.flatMap { descendants(of: $0) }
        }
        let markers = descendants(of: host)
        var failures: [String] = []
        let visible = host.bounds.intersection(host.visibleRect)
        if abs(host.bounds.height - model.contentHeight - model.notchHeight) > 0.5 {
            failures.append("the window is not the height the arithmetic reserved")
        }
        let expected: [HUDLayoutProbePart] = (model.confirmQuestion != nil
                                                ? [.allow, .deny] : [])
            + (model.canRetry ? [.retry] : [])
        for part in expected {
            let matches = markers.filter { $0.part == part }
            guard let view = matches.first, matches.count == 1 else {
                failures.append("\(part.rawValue): expected one marker, got \(matches.count)")
                continue
            }
            let rect = view.convert(view.bounds, to: host)
            if rect.isEmpty || !visible.contains(rect) {
                failures.append("\(part.rawValue) is outside the window (\(rect) in \(visible))")
            }
            if view.bounds.height < 26 {
                failures.append("\(part.rawValue) lost its usable hit area "
                                + "(\(view.bounds.height))")
            }
        }
        // A card that failed must not also be holding a question: the two taps mean opposite things.
        if model.canRetry, model.confirmQuestion != nil {
            failures.append("a failed card is asking a question at the same time")
        }
        let passed = failures.isEmpty
        print("render-ui: taps \(passed ? "PASS" : "FAIL") - \(label) "
              + "window=\(host.bounds.size) \(expected.map { $0.rawValue }.joined(separator: "+"))"
              + (passed ? "" : " - \(failures.joined(separator: "; "))"))
        return passed
    }

    /// `--render-setup <path.png>` — the three first-run steps, side by side.
    ///
    /// A stranger's first screen is the one surface in this app that has never been looked at,
    /// and the flow is only honest if all three steps actually draw: the permission rows with
    /// two still missing, the brain step with no key and the local switch offered, and the
    /// keep-alive step with its Done button. Each fixture also asserts the plan's own rule —
    /// that this state opens on this step — so a render that quietly shows the wrong step fails
    /// rather than printing a pretty picture of a bug.
    @MainActor
    static func runSetup(to path: String) -> Never {
        let size = NSSize(width: 560, height: 520)
        let gap: CGFloat = 28
        let partial = PermissionState(microphone: true, accessibility: false,
                                      inputMonitoring: false, screenRecording: false,
                                      screenContent: false)
        let granted = PermissionState(microphone: true, accessibility: true,
                                      inputMonitoring: true, screenRecording: true,
                                      screenContent: true)
        let fixtures: [(label: String, plan: FirstRunPlan, expect: FirstRunStep,
                        offline: String, login: String)] = [
            ("1 · two grants missing", FirstRunPlan(permissions: partial, hasKey: false,
                                                    offlineBrainOn: false, finished: false),
             .permissions, "", "off"),
            ("2 · no key yet", FirstRunPlan(permissions: granted, hasKey: false,
                                            offlineBrainOn: false, finished: false),
             .brain, "Ollama — gemma4. Nothing leaves this Mac.", "off"),
            ("3 · ready to finish", FirstRunPlan(permissions: granted, hasKey: true,
                                                 offlineBrainOn: false, finished: false),
             .finish, "", "registered, waiting for you in System Settings"),
        ]
        var failures: [String] = []
        var views: [(String, NSHostingView<AnyView>)] = []
        for fixture in fixtures {
            let model = FirstRunModel(fixturePlan: fixture.plan,
                                      offlineSummary: fixture.offline,
                                      loginDescription: fixture.login)
            if model.plan.currentStep != fixture.expect {
                failures.append("\(fixture.label): plan opened on \(model.plan.currentStep), not \(fixture.expect)")
            }
            views.append((fixture.label, NSHostingView(rootView: AnyView(
                FirstRunWindowView(model: model).frame(width: size.width, height: size.height)
            ))))
        }

        let canvas = NSImage(size: NSSize(width: CGFloat(views.count) * size.width + gap * CGFloat(views.count + 1),
                                          height: size.height + gap * 2))
        canvas.lockFocus()
        NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).setFill()
        NSBezierPath(rect: canvas.size.rect).fill()
        for (offset, entry) in views.enumerated() {
            let origin = NSPoint(x: gap + CGFloat(offset) * (size.width + gap), y: gap)
            entry.1.frame = NSRect(origin: origin, size: size)
            entry.1.layoutSubtreeIfNeeded()
            guard let rep = entry.1.bitmapImageRepForCachingDisplay(in: NSRect(origin: .zero, size: size)) else {
                failures.append("\(entry.0): could not cache the step")
                continue
            }
            entry.1.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)
            rep.draw(in: NSRect(origin: origin, size: size))
            NSAttributedString(string: entry.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
            ]).draw(at: NSPoint(x: origin.x, y: origin.y + size.height + 8))
        }
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("render-setup: could not draw the setup steps")
            exit(1)
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try png.write(to: url)
        } catch {
            print("render-setup: could not write \(url.path): \(error.localizedDescription)")
            exit(1)
        }
        let passed = failures.isEmpty
        print("render-setup: \(passed ? "PASS" : "FAIL") - 3 steps at 560x520"
              + (passed ? "" : " - \(failures.joined(separator: "; "))"))
        exit(passed ? 0 : 1)
    }

    /// `--render-window <path.png>` — the app window, both states, side by side.
    ///
    /// The window is the one surface here that can be *read* rather than watched, so its layout is
    /// checked the same way the card's is: the shipping `CompanionWindowView` drawn offscreen into
    /// a file. Left is a afternoon of turns including one still running; right is the empty state,
    /// because a first run is the state most likely to be seen and least likely to be designed for.
    @MainActor
    static func runWindow(to path: String) -> Never {
        let size = NSSize(width: 860, height: 560)
        let gap: CGFloat = 28

        let busy = CompanionWindowModel()
        // Built through the real tree builder rather than by hand, so the render shows what the
        // grouping rule actually produces on these questions — which is the only way to see a chat
        // split in the wrong place without running a turn.
        busy.reload(from: windowStore())
        let running = NotchHUDModel()
        running.beginListening()
        running.showCaption("what does this diff do")
        running.beginThinking()
        running.setElapsedForRendering(4.6)

        let left = NSHostingView(rootView: AnyView(
            CompanionWindowView(model: busy, hud: running)
                .frame(width: size.width, height: size.height)
        ))
        let right = NSHostingView(rootView: AnyView(
            CompanionWindowView(model: CompanionWindowModel(), hud: NotchHUDModel())
                .frame(width: size.width, height: size.height)
        ))
        let views = [("1 · a afternoon of turns, one still running", left),
                     ("2 · nothing asked yet", right)]
        HoverBindings.describe(left, surface: "the app window")

        let canvas = NSImage(size: NSSize(width: size.width * 2 + gap * 3,
                                          height: size.height + gap * 2))
        canvas.lockFocus()
        NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).setFill()
        NSBezierPath(rect: canvas.size.rect).fill()

        for (offset, entry) in views.enumerated() {
            let origin = NSPoint(x: gap + CGFloat(offset) * (size.width + gap), y: gap)
            entry.1.frame = NSRect(origin: origin, size: size)
            entry.1.layoutSubtreeIfNeeded()
            guard let rep = entry.1.bitmapImageRepForCachingDisplay(in: NSRect(origin: .zero,
                                                                               size: size)) else {
                continue
            }
            entry.1.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)
            rep.draw(in: NSRect(origin: origin, size: size))
            NSAttributedString(string: entry.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
            ]).draw(at: NSPoint(x: origin.x, y: origin.y + size.height + 8))
        }
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("render-window: could not draw the window")
            exit(1)
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try png.write(to: url)
            print("render-window: wrote the window to \(url.path)")
        } catch {
            print("render-window: could not write \(url.path): \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// `--render-panel <path.png>` — the menu-bar panel, both states, stacked.
    ///
    /// The panel is the first screen of the app and the only surface that was never drawable
    /// offscreen — which is how its permission rows were allowed to drift into five dialects of one
    /// sentence. It is hosted at the exact size `MenuBarPanelManager` gives the real panel, so what
    /// this shows is what that window clips or does not.
    @MainActor
    static func runPanel(to path: String) -> Never {
        let manager = CompanionManager()
        let width: CGFloat = 320
        let height: CGFloat = 380
        let gap: CGFloat = 26
        // Two states, because one is not enough to see the panel. The first is the shipping size:
        // TCC belongs to the signature, so a shell-rendered binary always reads as "not set up",
        // and the permissions section is open either way. The second is the same content drawn
        // tall — the panel scrolls, so ROUTINES and MEMORY exist below the fold and had never been
        // looked at, which is the difference between a section that ships and one that works.
        let states: [(label: String, showAll: Bool, height: CGFloat)] = [
            ("the menu-bar panel · its real 380pt height, so the list scrolls", true, height),
            ("the same panel drawn tall · ROUTINES and MEMORY are below the fold at 380pt",
             true, 760),
        ]

        var views: [(label: String, view: NSHostingView<AnyView>, height: CGFloat)] = []
        for entry in states {
            let hosted = NSHostingView(rootView: AnyView(
                CompanionPanelView(companionManager: manager, showsEverySection: entry.showAll)
                    .frame(width: width, height: entry.height)
            ))
            hosted.frame = NSRect(x: 0, y: 0, width: width, height: entry.height)
            hosted.layoutSubtreeIfNeeded()
            if views.isEmpty { HoverBindings.describe(hosted, surface: "the menu-bar panel") }
            views.append((entry.label, hosted, entry.height))
        }

        let tallest = states.map(\.height).max() ?? height
        let canvas = NSImage(size: NSSize(width: width + gap * 2,
                                          height: CGFloat(states.count) * (tallest + 20)
                                            + gap * CGFloat(states.count + 1)))
        canvas.lockFocus()
        NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).setFill()
        NSBezierPath(rect: canvas.size.rect).fill()

        var y = canvas.size.height - gap
        for entry in views.reversed() {
            let panelHeight = entry.height
            y -= panelHeight
            entry.1.frame = NSRect(x: gap, y: y, width: width, height: panelHeight)
            if let rep = entry.1.bitmapImageRepForCachingDisplay(
                in: NSRect(x: 0, y: 0, width: width, height: panelHeight)) {
                entry.1.cacheDisplay(in: NSRect(x: 0, y: 0, width: width, height: panelHeight), to: rep)
                rep.draw(in: NSRect(x: gap, y: y, width: width, height: panelHeight))
            }
            NSAttributedString(string: entry.label, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
            ]).draw(at: NSPoint(x: gap, y: y + panelHeight + 7))
            y -= gap + 20
        }
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("render-panel: could not draw the panel")
            exit(1)
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try png.write(to: url)
            print("render-panel: wrote the panel to \(url.path)")
        } catch {
            print("render-panel: could not write \(url.path): \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    /// A history with three sittings and four threads, assembled the way the app assembles one.
    ///
    /// Ordinary replies, not claims about this machine. The questions are written so the grouping
    /// rule has to be exercised to get them right: a task, a pointer follow-up that shares no words
    /// with it, a change of subject that must start a second thread, and a "the second line" that
    /// must not.
    private static func windowStore() -> ConversationStore {
        let now = Date()
        func ago(_ minutes: Int) -> Date { now.addingTimeInterval(TimeInterval(-minutes * 60)) }

        let earlier = ConversationSession(startedAt: ago(3 * 24 * 60 + 40), start: .restored)
        // Both of these sit *before* the first turn they hold, which is not a detail: a session
        // dated later than its own thread renders as "Today 00:32" over a row reading "23:52", and
        // the first thing a render review does is look for a bug in the day label.
        let evening = ConversationSession(startedAt: ago(21 * 60), start: .wake)
        let open = ConversationSession(startedAt: ago(95), start: .launch)
        let sessions = [earlier, evening, open]

        func turn(_ minutes: Int, _ asked: String, _ headline: String, _ answer: String,
                  _ session: ConversationSession, _ source: ConversationTurn.Source = .voice,
                  _ acts: [String] = []) -> ConversationTurn {
            ConversationTurn(asked: asked, answered: answer, headline: headline,
                             at: ago(minutes), source: source, acts: acts,
                             sessionID: session.id)
        }

        let turns = [
            turn(3 * 24 * 60 + 20, "remember that I use raycast instead of alfred",
                 "Remembered Raycast", "noted — raycast over alfred.", earlier),
            turn(20 * 60 + 40, "read the build log and tell me why it failed",
                 "Reading build log", """
                 The archive step failed before signing, so the error at the bottom of the log is a \
                 consequence, not the cause. What actually broke is line 214: the resource fork \
                 check refuses to sign a bundle whose Finder metadata changed underneath it.
                 """, evening, .typed, ["Read ~/Downloads/build.log (24 KB)."]),
            turn(90, "open whatsapp and search for sathvik", "Found Sathvik", """
                 WhatsApp is open with his chat on screen. Say the message and I'll put it in the \
                 box — sending it stays yours.
                 """, open, .voice,
                 ["Opened WhatsApp.", "Pressed Search.", "Typed 8 characters into Search."]),
            turn(86, "type good night and leave it for me", "Ready to send", """
                 Typed it into the compose box. It is not sent — that one is yours to press.
                 """, open, .voice, ["Typed good night into Compose message."]),
            turn(48, "why is the certificate warning showing in chrome",
                 "Explained the certificate warning", """
                 It is a certificate warning from your own dev server, not from the browser's \
                 store. The line that matters is the second one — the host name in the request is \
                 `localhost:5173` while the certificate was issued for `127.0.0.1`, so the two \
                 never match. Regenerate it with the host name you actually type.
                 """, open),
            turn(44, "what does the second line mean", "Broke down the host name", """
                 The second line names the two things that have to agree and do not: the name you \
                 typed, and the name the certificate was issued for.
                 """, open),
        ]

        let assigned = ConversationStore.assignChats(to: turns)
        return ConversationStore(turns: assigned.turns, sessions: sessions,
                                 chats: assigned.chats,
                                 currentSessionID: open.id,
                                 currentChatID: assigned.chats.last?.id)
    }

    // MARK: - Fixtures

    @MainActor private static func listening() -> NotchHUDModel {
        let model = NotchHUDModel()
        model.beginListening()
        model.showCaption("open whatsapp, search for dad, and")
        model.setWaveformForRendering([0.15, 0.4, 0.75, 1.0, 0.55, 0.25, 0.8, 0.45, 0.2])
        model.setElapsedForRendering(1.2)
        return model
    }

    /// A second listening state, because the difference between these two rows is the whole point of
    /// the meter: same pill, same stage line, and one of them says the microphone is open.
    @MainActor private static func listeningQuiet() -> NotchHUDModel {
        let model = NotchHUDModel()
        model.beginListening()
        model.setWaveformForRendering(Array(repeating: 0, count: WaveformMeter.barCount))
        model.setElapsedForRendering(0.4)
        return model
    }

    @MainActor private static func waiting() -> NotchHUDModel {
        let model = NotchHUDModel()
        model.beginListening()
        model.showCaption("open whatsapp, search for dad, and message him hi")
        model.beginThinking()
        model.setElapsedForRendering(4.6)
        return model
    }

    /// The state that matters most: an answer streaming while a plan runs underneath it, and the
    /// card asking about the step that cannot be undone.
    @MainActor private static func answering() -> NotchHUDModel {
        let model = NotchHUDModel()
        model.beginListening()
        model.showCaption("open whatsapp, search for dad, and message him hi")
        model.beginThinking()

        let streamer = AnswerStreamer()
        streamer.push("""
        <SAY>found dad's chat — the message is in the box, say the word and it goes.</SAY>
        the plan ran five steps: launch, search, type the name, open the chat, type the message. \
        send is the sixth and it is a commitment, so it is asked about rather than run.
        <DONE_TITLE>Messaging Dad</DONE_TITLE>
        <NEXT_ACTIONS>
        - press send
        - change the words first
        </NEXT_ACTIONS>
        """)
        streamer.finish()
        model.apply(streamer)

        // Five steps that ran, and the sixth is the one being asked about — the counts on this card
        // must agree, because "+5 done" beside "Step 5 of 5" is one fact stated two ways and one of
        // them is wrong. The step travels as data, not inside the sentence.
        model.beginStep(index: 1, of: 6)
        model.reportConfirm("Opened WhatsApp.")
        model.beginStep(index: 2, of: 6)
        model.reportConfirm("Pressed Search.")
        model.beginStep(index: 3, of: 6)
        model.reportConfirm("Typed 3 characters into Search.")
        model.beginStep(index: 4, of: 6)
        model.reportConfirm("Pressed Dad.")
        model.beginStep(index: 5, of: 6)
        model.reportConfirm("Typed hi into Compose message.")

        model.askConfirm("Press Send in WhatsApp?", step: 6, of: 6)
        model.setElapsedForRendering(9.3)
        return model
    }

    /// The longest question the routine tool can produce and still be offered, drawn at full size.
    ///
    /// `DoRequest.maxQuestionCharacters` is an arithmetic claim about two lines of 12 pt on a 360 pt
    /// card, and the only way to check a claim about rendered text is to render it.
    @MainActor private static func routineAsking() -> NotchHUDModel {
        let model = NotchHUDModel()
        model.beginListening()
        model.showCaption("every morning at eight, brief me on what is open")
        model.beginThinking()

        let streamer = AnswerStreamer()
        streamer.push("""
        <SAY>ready to put it on the schedule — every morning at eight, i'll look at the screen and brief you. tap allow and it's set.</SAY>
        a routine is a question you are asking yourself later, so it goes through the same turn a
        spoken one does: it sees the screen then, and still has to ask before it presses anything.
        <DONE_TITLE>Ready to schedule</DONE_TITLE>
        """)
        streamer.finish()
        model.apply(streamer)

        let request = DoRequest.addRoutine(title: "Morning glance",
                                           cadence: .daily(at: "08:00"),
                                           prompt: "brief me on what is open on my screen")
        model.askConfirm(ToolLayer.question(for: request))
        model.setElapsedForRendering(6.8)
        return model
    }

    /// A reminder that arrived half an hour after it was due.
    ///
    /// Drawn rather than reasoned about because the surface is new: a card with no stage line, no
    /// timer and one sentence of body has to look like an announcement, not like an answer that
    /// failed — and only the picture says which one it is.
    @MainActor private static func reminderFired() -> NotchHUDModel {
        let model = NotchHUDModel()
        model.showReminder("call the bank about the statement",
                           lateNote: "It was due at 09:00.")
        return model
    }

    /// Real prose at the parser's limit, not a shortened sample or padding that trims away.
    private static let maximumDraft = """
    Hi Dad — Thursday at seven works for me. I'll bring the photos from last month so we can look \
    through them after dinner. Please let me know if you'd like me to pick up anything on the way. \
    I may be ten minutes late if the train is delayed, but I'll send you a quick update before I \
    leave. Looking forward to catching up with you both again.
    """

    /// The maximum draft alone and above a consent row, both through the shipping parser and model.
    @MainActor private static func draftReady(asking: Bool = false) -> NotchHUDModel {
        let model = NotchHUDModel()
        model.beginListening()
        model.showCaption("write him a reply about Thursday")
        model.beginThinking()
        let streamer = AnswerStreamer()
        streamer.push("""
        <SAY>here are the words — they are on the card with a Copy button, and you send them.</SAY>
        <DRAFT>\(maximumDraft)</DRAFT>
        <DONE_TITLE>Reply drafted</DONE_TITLE>
        """)
        streamer.finish()
        model.apply(streamer)
        if asking { model.askConfirm("Open WhatsApp?") }
        model.setElapsedForRendering(7.4)
        return model
    }

    /// The words a finished type act landed in a field, offered in the copy well.
    ///
    /// He asked for this the day he watched a reply get typed into a chat he might have wanted in
    /// two places: the field is a bad place to copy from, and the card line that says the words
    /// landed does not let him take them anywhere else. The well scrolls, so a typed text longer
    /// than the viewport still copies whole.
    @MainActor private static func typedForCopy() -> NotchHUDModel {
        let model = NotchHUDModel()
        model.beginListening()
        model.showCaption("write him a reply saying I'll be there at seven")
        model.beginThinking()
        let streamer = AnswerStreamer()
        streamer.push("""
        <SAY>typing that for you now, then you can press the send button.</SAY>
        <DONE_TITLE>Ready to send</DONE_TITLE>
        """)
        streamer.finish()
        model.apply(streamer)
        model.reportConfirm("Typed 55 characters into Compose message.")
        model.offerTypedTextForCopy("i will be there at 7 o'clock — send it when you're ready")
        model.setElapsedForRendering(11.0)
        return model
    }

    @MainActor private static func failed() -> NotchHUDModel {
        let model = NotchHUDModel()
        model.beginListening()
        model.showCaption("what is this error on my screen")
        model.beginThinking()
        model.fail("Hit the free-tier rate limit — this key allows a few requests a minute.")
        // The render shows the row; the real handler is the manager's `failTurn`. Without this the
        // recovery is reserved by the arithmetic and inspected by nobody, which is how a control that
        // cannot be tapped ships.
        model.onRetry = {}
        model.setElapsedForRendering(61.0)
        return model
    }
}

/// Backgrounds inherit the actual laid-out control's size without proposing a size of their own.
/// Native conversion back into the host also includes SwiftUI's placement and any scroll offset.
/// Disabled in the shipping view; the renderer enables them without replacing the real controls.
enum HUDLayoutProbePart: String {
    case cardContent, draftBlock, draftCopy, draftViewport, draftText, allow, deny, retry
}

private struct HUDLayoutProbeEnabled: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var hudLayoutProbeEnabled: Bool {
        get { self[HUDLayoutProbeEnabled.self] }
        set { self[HUDLayoutProbeEnabled.self] = newValue }
    }
}

final class HUDLayoutProbeView: NSView {
    var part: HUDLayoutProbePart = .cardContent
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct HUDLayoutProbeMarker: NSViewRepresentable {
    let part: HUDLayoutProbePart
    func makeNSView(context: Context) -> HUDLayoutProbeView {
        let view = HUDLayoutProbeView(frame: .zero)
        view.part = part
        return view
    }
    func updateNSView(_ view: HUDLayoutProbeView, context: Context) {}
}

private struct HUDLayoutProbeModifier: ViewModifier {
    @Environment(\.hudLayoutProbeEnabled) private var enabled
    let part: HUDLayoutProbePart

    func body(content: Content) -> some View {
        content.background {
            if enabled {
                HUDLayoutProbeMarker(part: part)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func hudLayoutProbe(_ part: HUDLayoutProbePart) -> some View {
        modifier(HUDLayoutProbeModifier(part: part))
    }
}

private extension NSSize {
    var rect: NSRect { NSRect(origin: .zero, size: self) }
}

/// SwiftUI's hover bindings, counted on a real hosted view.
///
/// Measured rather than grepped, because the crash is not in code we can see: on 2026-11-04 the app
/// died 16 seconds after an answer with a SIGSEGV inside `NSHostingView.mouseEntered` →
/// `HoverEventDispatcher.receiveEvents` → `ViewResponder.hitTest` → `MainActor.assumeIsolated`,
/// faulting in the runtime's main-executor check — the same check that killed it twice on
/// 2026-11-03 from our own timer blocks. Those call sites are gone and a grep keeps them gone, but
/// SwiftUI's assertion is reached only because *some* view asked for hover, so the thing to prove is
/// that nothing does. A tracking area owned by a class from SwiftUI's own bundle is the dispatcher's
/// footprint: no bindings, no area, no path into the crashing function.
enum HoverBindings {

    /// Tracking areas SwiftUI installed for itself, over the whole view tree.
    static func count(in view: NSView) -> Int {
        var total = 0
        for area in view.trackingAreas where isSwiftUI(area.owner) { total += 1 }
        for sub in view.subviews { total += count(in: sub) }
        return total
    }

    static func describe(_ view: NSView, surface: String) {
        let owners = Set(view.subviews.flatMap { $0.trackingAreas }.compactMap { area in
            area.owner.map { NSStringFromClass(type(of: $0)) }
        })
        print("hover: \(surface) — \(count(in: view)) SwiftUI-owned tracking area(s)"
            + (owners.isEmpty ? "" : ", owners seen: \(owners.joined(separator: ", "))"))
    }

    private static func isSwiftUI(_ owner: AnyObject?) -> Bool {
        guard let owner else { return false }
        let bundle = Bundle(for: type(of: owner)).bundleIdentifier ?? ""
        return bundle.hasPrefix("com.apple.SwiftUI")
    }
}
