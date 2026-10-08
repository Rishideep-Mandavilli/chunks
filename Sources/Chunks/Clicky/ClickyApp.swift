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
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.run()
        }
        if let point = AXProbe.requestedPoint() {
            AXProbe.run(at: point)
        }
        if AXProbe.isVoiceProbeRequested {
            AXProbe.runVoiceProbe()
        }
        if AXProbe.isRequested {
            AXProbe.runDesktop()
        }
        if STTProbe.isRequested {
            STTProbe.run()
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
        print("🎯 Chunks: Starting...")
        print("🎯 Chunks: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        setupNotchHUD()

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
        // Only once onboarding is done. Registering on every launch made each rebuilt
        // binary a login item, and an ad-hoc-signed rebuild is a different app to macOS,
        // so the list filled up with entries that could never run.
        if companionManager.hasCompletedOnboarding {
            registerAsLoginItemIfNeeded()
        }
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
                companionManager?.ask(text: suggestion)
            }
        }
        // The pill's one job beyond status: take the user to the panel. Cheaper than making
        // them find the menu-bar icon, and the only route from the notch to the key field.
        companionManager.hud.openPanel = { [weak menuBarPanelManager] in
            menuBarPanelManager?.toggle()
        }
        notchPanelManager = manager
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Chunks: registered as login item")
            } catch {
                print("⚠️ Chunks: failed to register as login item: \(error)")
            }
        }
    }

}
