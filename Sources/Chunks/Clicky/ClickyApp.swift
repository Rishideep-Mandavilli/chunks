//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import Combine
import ServiceManagement
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    /// There is no `main.swift` — SwiftUI's `@main` owns the process entry point — so a
    /// command-line flag has to be intercepted here or it is dead code that only looks wired
    /// up. `chunks --self-test` was silently just launching the app for exactly this reason.
    ///
    /// `SelfTest.run()` never returns: it drives the run loop itself and exits with a status.
    init() {
        // The probes are the developer's harness, not a surface for whoever holds the machine: they
        // name any point on the screen, print which file a sentence resolves to, and read one end to
        // end. In a release build they are inert unless `CHUNKS_DEV=1`, so sharing the app does not
        // ship a door. `--self-test` stays open — it reports only what this build can see.
        if !AXProbe.developmentToolsAllowed, AXProbe.developmentFlagRequested {
            print("Chunks: the --probe-* and --render-* tools are development-only. "
                + "Run a debug build, or set CHUNKS_DEV=1, to use them.")
            exit(2)
        }
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.run()
        }
        if let point = AXProbe.requestedPoint() {
            AXProbe.run(at: point)
        }
        if let crop = AXProbe.requestedCropAim() {
            AXProbe.runCrop(crop: crop.crop, aim: crop.aim)
        }
        if let target = AXProbe.requestedReveal() {
            AXProbe.runReveal(target)
        }
        if AXProbe.isVoiceProbeRequested {
            AXProbe.runVoiceProbe()
        }
        if AXProbe.isMicProbeRequested {
            AXProbe.runMicProbe()
        }
        if AXProbe.isRequested {
            AXProbe.runDesktop()
        }
        if let body = AXProbe.requestedSemanticBody() {
            AXProbe.runSemantic(body)
        }
        if let app = AXProbe.requestedFieldApp() {
            AXProbe.runFields(app)
        }
        if let app = AXProbe.requestedControlApp() {
            AXProbe.runControls(app)
        }
        if let request = AXProbe.requestedCandidates() {
            AXProbe.runCandidates(request.target, aim: request.aim)
        }
        if AXProbe.isCommandProbeRequested {
            AXProbe.runCommandProbe()
        }
        if AXProbe.isMemoryProbeRequested {
            AXProbe.runMemoryProbe()
        }
        if let body = AXProbe.requestedReminderBody() {
            AXProbe.runReminder(body)
        }
        if AXProbe.isAwakeProbeRequested {
            if Thread.isMainThread {
                MainActor.assumeIsolated { AXProbe.runAwakeProbe() }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { AXProbe.runAwakeProbe() }
                }
            }
        }
        if UIRenderProbe.isRequested {
            // Hopped to the main thread and then the run loop is spun, because drawing an
            // `NSHostingView` offscreen is main-thread work and this `init` is not guaranteed to
            // run on main. `run` never returns: a probe that also opened the menu bar item would
            // leave a second Chunks in the dock for whoever read the output.
            // Synchronous, and it never returns: an async hop would let `init` carry on into the
            // single-instance guard, which stands this copy down before the render is ever drawn.
            let path = UIRenderProbe.requestedPath()
            if Thread.isMainThread {
                MainActor.assumeIsolated { UIRenderProbe.run(to: path) }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { UIRenderProbe.run(to: path) }
                }
            }
        }
        if UIRenderProbe.isPanelRequested {
            // Constructs a `CompanionManager`, which is what the delegate does at launch anyway;
            // the probe exits before `start()`, so no event tap, no prompt and no request runs.
            let path = UIRenderProbe.requestedPanelPath()
            if Thread.isMainThread {
                MainActor.assumeIsolated { UIRenderProbe.runPanel(to: path) }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { UIRenderProbe.runPanel(to: path) }
                }
            }
        }
        if UIRenderProbe.isWindowRequested {
            // The same main-thread hop and the same never-returning `run`, for the same reason:
            // the window's layout is a visual claim, and a shell cannot screenshot it.
            let path = UIRenderProbe.requestedWindowPath()
            if Thread.isMainThread {
                MainActor.assumeIsolated { UIRenderProbe.runWindow(to: path) }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { UIRenderProbe.runWindow(to: path) }
                }
            }
        }
        if UIRenderProbe.isSetupRequested {
            let path = UIRenderProbe.requestedSetupPath()
            if Thread.isMainThread {
                MainActor.assumeIsolated { UIRenderProbe.runSetup(to: path) }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { UIRenderProbe.runSetup(to: path) }
                }
            }
        }
        if STTProbe.isRequested {
            STTProbe.run()
        }
        if FileReadProbe.isRequested {
            MainActor.assumeIsolated { FileReadProbe.run() }
        }
        if FileFindProbe.isRequested {
            MainActor.assumeIsolated { FileFindProbe.run() }
        }
        if PromptProbe.isRequested {
            MainActor.assumeIsolated { PromptProbe.run() }
        }
        if ProtocolProbe.isRequested {
            MainActor.assumeIsolated { ProtocolProbe.run() }
        }
        if ThinkingProbe.isRequested {
            MainActor.assumeIsolated { ThinkingProbe.run() }
        }
        if AnnotationSafetyProbe.isRequested {
            // Hopped to the main thread, not `assumeIsolated`. This `init` is not guaranteed to run
            // on main and on 2026-10-12 it did not: every probe line was logged `[bg]`, meaning the
            // overlay was built on a background thread. A window created off-main never enters the
            // window server's on-screen list, so the probe was measuring its own bug and reporting
            // the overlay as unreachable by clicks.
            AnnotationSafetyProbe.start()
        }
        if ScreenShot.isRequested {
            ScreenShot.run()
        }
    }

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private let companionManager: CompanionManager

    /// Built in `init` rather than at launch so the notch can be handed a way to open the
    /// panel before anything else runs — and because a default property initializer cannot
    /// read another instance property, which is what decides the order here.
    private let menuBarPanelManager: MenuBarPanelManager

    private var notchPanelManager: NotchPanelManager?

    private var appWindowManager: AppWindowManager?
    private var firstRunWindow: FirstRunWindow?

    /// Kept because a Combine subscription without a handle is cancelled the instant it is made.
    private var windowToggleCancellable: AnyCancellable?

    override init() {
        companionManager = CompanionManager()
        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch (chunks shell)")
        // Which bundle this actually is. TCC keys Screen Recording and Accessibility on the
        // app's signature, and this project has left several differently-signed copies of
        // Chunks in the privacy list over its builds — so when a grant "doesn't take", the
        // first question is whether the row that was ticked is the bundle that is running.
        Log.write("bundle: \(Bundle.main.bundlePath) "
                  + "id=\(Bundle.main.bundleIdentifier ?? "none") "
                  + "pid=\(ProcessInfo.processInfo.processIdentifier)")
        // One instance, always. Two Chunks processes is not cosmetic: the event tap that decides
        // ⌃⌥ and ⌃⌥⌘D belongs to whichever process created it first, so the copy whose menu-bar
        // icon you can see may not be the copy hearing your keyboard. That is what "the shortcut
        // does nothing at all" turned out to be worth protecting against — the staged bundle
        // (`~/.chunks-build`) and the installed one (`~/Applications`) are both `app.chunks.mac`,
        // so refuse to run twice instead of leaving the ambiguity to be debugged from a log.
        // The comparison needs an identifier to compare. A bare SwiftPM binary has none —
        // `Bundle.main.bundleIdentifier` is nil there — and `nil == nil` is true for every other
        // process that also lacks one, so a probe run from `.build/debug` was standing down in front
        // of `/usr/sbin/universalaccessd`. Measured 2026-10-27. Two copies of the *same signed app*
        // is the ambiguity this guard exists to refuse; an unrelated system daemon is not.
        let thisBundle = Bundle.main.bundleIdentifier
        let alreadyRunning: [NSRunningApplication] = thisBundle.map { identifier in
            NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == identifier
                    && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
        } ?? []
        if let existing = alreadyRunning.first {
            Log.write("chunks: already running as pid \(existing.processIdentifier) from "
                + "\(existing.bundleURL?.path ?? "an unknown bundle") — this copy is standing down")
            // Terminating loses whatever the async writer has not reached the file yet, and the
            // line lost is precisely the one that proves a second copy refused to run — checked
            // 2026-10-12: the guard worked, the stand-down was the last line missing.
            Log.flush()
            NSApp.terminate(nil)
            return
        }

        print("🎯 Chunks: Starting...")
        print("🎯 Chunks: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        setupNotchHUD()
        setUpAppWindow()

        // Look at the notch without running a turn: no microphone, no event tap, no API call,
        // and no login-item registration. Quit-and-relaunch is the early `return`, not a
        // conditional around `start()`, because the rest of this method is all permission
        // plumbing — and the permissions are precisely what is not working while someone is
        // using this flag.
        if CommandLine.arguments.contains("--show-hud") {
            companionManager.hud.showHint("hold \(BuddyPushToTalkShortcut.pushToTalkDisplayText) to talk",
                                          for: nil)
            Log.write("hud hint shown (--show-hud)")
            return
        }

        companionManager.start()
        // One line per permission, each with its own value. This used to print
        // `allPermissionsGranted` under all four labels, so the log read as four missing
        // grants when only one was — exactly the wrong evidence while debugging a grant
        // that does not stick.
        Log.write("permission accessibility: \(companionManager.hasAccessibilityPermission)")
        Log.write("permission screen_recording: \(companionManager.hasScreenRecordingPermission)")
        Log.write("permission microphone: \(companionManager.hasMicrophonePermission)")
        Log.write("permission screen_content: \(companionManager.hasScreenContentPermission)")
        // The fifth row, and the one that was missing: without it the keyboard event tap is
        // silent, so both hot keys look broken while every other permission reads granted.
        Log.write("permission input_monitoring: \(companionManager.hasInputMonitoringPermission)")
        // Not logged here: the keychain answer arrives after an off-main-thread read, and a
        // launch-time guess said `MISSING` on a machine that had a key. `refreshApiKeyState`
        // logs the real one when it lands.
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager.showPanelOnLaunch()
        }
        // Launch-at-login is a choice, not a default. This used to call
        // `SMAppService.mainApp.register()` on every launch once onboarding was done, which made
        // each rebuilt binary a new login item — an ad-hoc signature is a different app to macOS —
        // and left entries in System Settings that could never run. The row in the panel now owns
        // it, and `LoginItem` reads the state back instead of remembering a wish.
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Put the notch HUD on screen and connect its taps back to the pipeline.
    ///
    /// The HUD's content belongs to `CompanionManager`, which is the only thing that knows
    /// when a turn starts, streams and ends; this type owns the window that draws it. Driving
    /// the HUD from here instead — off `voiceState`, say — would put a second opinion about
    /// what the card says somewhere the pipeline cannot see it.
    private func setupNotchHUD() {
        let manager = NotchPanelManager(model: companionManager.hud)
        manager.onSelectAction = { [weak companionManager] suggestion in
            Task { @MainActor in
                companionManager?.ask(text: suggestion, source: .chip)
            }
        }
        // The pill's one job beyond status: take the user to the panel. Cheaper than making
        // them find the menu-bar icon, and the only route from the notch to the key field.
        companionManager.hud.openPanel = { [weak menuBarPanelManager] in
            menuBarPanelManager?.toggle()
        }
        notchPanelManager = manager
    }

    /// The window that holds the history, and the chord that opens it.
    ///
    /// Subscribed here rather than inside `AppWindowManager` because the event tap is already the
    /// delegate's business — a manager holding its own second monitor would be a second permission
    /// story for the same keystrokes.
    private func setUpAppWindow() {
        let manager = AppWindowManager(companionManager: companionManager)
        // The panel's row and the notch both reach the same `show()` through this closure, so
        // there is one definition of "open the window".
        companionManager.openWindow = { [weak manager] in
            manager?.show()
        }
        windowToggleCancellable = companionManager.globalPushToTalkShortcutMonitor
            .windowTogglePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak manager] in
                manager?.toggle()
            }
        appWindowManager = manager
        // The setup flow: shown on first launch, re-openable from the panel row, and closed only
        // by Done. It is a separate window from the history window on purpose — a stranger's
        // first screen should not also be the app's deepest surface.
        let firstRun = FirstRunWindow(manager: companionManager)
        companionManager.showFirstRun = { [weak firstRun] in firstRun?.show() }
        firstRunWindow = firstRun
        firstRun.showIfNeeded()
    }
}
