//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import AppKit
import ChunksKit
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    /// Input Monitoring, the grant the keyboard event tap actually needs. Distinct from
    /// Accessibility, and missing from this app until both shortcuts turned out dead on a
    /// machine whose Accessibility row was ticked.
    @Published private(set) var hasInputMonitoringPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Intro

    /// Text streamed character-by-character on the cursor during the intro.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    /// The intro used to be a hosted video of clicky's mascot, streamed over HLS from
    /// Mux, with a copyrighted Final Fantasy theme as background music. Both are gone: the
    /// video was somebody else's brand, it phoned home before the user agreed to anything,
    /// and Chunks' own answer surface is the notch. What remains is typed on the cursor and
    /// scheduled locally — `startIntroSequence()`.
    private var introTasks: [Task<Void, Never>] = []

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Gemini, behind the same interface clicky's Claude client had.
    private lazy var claudeAPI: BrainGateway = {
        let gateway = BrainGateway()
        // The persisted choice only matters if it reaches the gateway built on first use;
        // UserDefaults by itself would let a pick survive the panel and not the turn.
        gateway.model = self.selectedModel
        return gateway
    }()

    private lazy var ttsClient: LocalTTSClient = {
        return LocalTTSClient()
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// Long-term memory of the user: injected into every prompt, written only through
    /// `propose`, which sweeps for secrets and enforces the size cap before disk.
    ///
    /// Its contents are re-read from the file at the start of each turn rather than trusted
    /// from this property — see `companionPromptWithMemory()`.
    private let memoryStore = MemoryStore(fileURL: MemoryStore.defaultURL())

    /// The notch HUD's content. Owned here because the pipeline is the only thing that knows
    /// when a turn starts, streams, finishes and fails; `NotchPanelManager` watches this and
    /// does the window work.
    let hud = NotchHUDModel()

    /// One press the model proposed, resolved to a real point, waiting for the user's answer.
    ///
    /// Singular because there is one act per turn and one unanswered question per card. Holding
    /// the resolved point rather than the raw tag means the press cannot drift onto a different
    /// control between asking and answering.
    ///
    /// The gate holds the *request*; this holds the machine state needed to honour it. A
    /// `[DO:…]` needs neither of those, which is why the two are separate types.
    private struct PendingPress {
        var act: ActionRequest
        var axPoint: CGPoint
        var bundleID: String?
        var element: AXElementInfo
    }

    private var pendingPress: PendingPress?

    /// What one step of a plan did — the answer to "may the next step run?".
    ///
    /// A line of text is not enough to decide that. "Finder would not press O'Reilly" and "Pressed
    /// Pluralsight." are the same *kind* of string, and a plan that read one as success would keep
    /// clicking on a screen that never changed.
    private enum StepOutcome {
        /// The act happened. Its line has already reached the card.
        case done(line: String)
        /// A card is open and nobody has answered it yet. The rest of the plan waits behind it.
        case asked
        /// Refused, unresolvable, or an act that did not happen. Nothing after this may run.
        case stopped(line: String)
    }

    /// The steps left in a plan whose current step is on the card, and the captures they were
    /// aimed with. Kept together so an answer can advance the plan rather than just perform one act.
    private struct PendingProgram {
        var steps: [ActionRequest]
        /// How many steps have already run, so the card can say "step 3 of 5" truthfully.
        var doneCount: Int
        var totalCount: Int
        var screenCaptures: [CompanionScreenCapture]
    }

    private var pendingProgram: PendingProgram?

    /// How long to let the screen settle between two steps of a plan.
    ///
    /// A press that opens a chat and the type that follows it are aimed at the same screenshot, and
    /// the second element usually does not exist until the first app has drawn a new frame. Half a
    /// second survived a real launch when this was measured; it did not survive WhatsApp's, and a
    /// step resolved against a window still animating in reads the desktop and refuses a control the
    /// user can see. One second is the wait that covers a cold launch without making a plan feel
    /// stalled; a step that still cannot resolve stops the plan rather than clicking whatever
    /// appeared next.
    static let stepSettleDelay: UInt64 = 1_000_000_000

    /// How long a plan waits before photographing the screen for its next round.
    ///
    /// Longer than `stepSettleDelay` on purpose: this one waits for an *app* the previous round
    /// launched, not for a control inside an app that is already up. A screenshot taken mid-swoosh
    /// shows the model a desktop it has just been told is WhatsApp, and it answers by giving up on
    /// the plan.
    static let planRecaptureDelay: UInt64 = 1_500_000_000

    /// How many looks at the screen one spoken request may spend.
    ///
    /// "Open WhatsApp, search for Dad, message him HI" cannot be aimed at a single screenshot: the
    /// search box does not exist until WhatsApp is open, and the send button does not exist until
    /// something is typed. So a turn may say what still has to happen, Chunks looks again, and the
    /// plan carries on without being asked twice. Bounded because a model that keeps promising a
    /// next step is otherwise a loop with a voice.
    static let maxPlanRounds = 4

    /// The round of the current plan, and whether this turn is one of its own continuations.
    private var planRound = 0
    private var isContinuingPlan = false

    /// The yes/no state machine. Kept separate from the card's view state so "answering twice
    /// does nothing twice" is a tested rule rather than a hope about SwiftUI's tap handling.
    private var consentGate = ConsentGate()

    /// Apps the user chose "always allow" for. Deliberately not persisted: an allowance that
    /// outlives the run it was granted in is a permission nobody re-checked, and the settings
    /// row to review it does not exist yet.
    private var alwaysAllowedBundleIDs: Set<String> = []

    /// Whether the card asks before a press or a tool runs.
    ///
    /// The user asked for Chunks to act on what they say rather than stop and request
    /// permission, so the default is *not* to ask, and it is persisted because it is a standing
    /// preference rather than a decision about one control. It changes only the `.needsConsent`
    /// branch of `PolicyGate`: the forbidden rules (secure fields, Keychain, password managers)
    /// still refuse, and a press whose target moved before it landed is still dropped.
    @Published var askBeforeActing: Bool = UserDefaults.standard.object(forKey: "askBeforeActing") == nil
        ? false
        : UserDefaults.standard.bool(forKey: "askBeforeActing")

    func setAskBeforeActing(_ enabled: Bool) {
        askBeforeActing = enabled
        UserDefaults.standard.set(enabled, forKey: "askBeforeActing")
        // Logged because it is a standing instruction that changes what a press *does*, so a
        // later log line like `act: acting without a card` is unreadable without knowing when the
        // switch moved.
        Log.write("acting: ask before acting = \(enabled)")
    }

    /// Where Chunks does its thinking: this Mac, or Google.
    ///
    /// Reads the same `UserDefaults` key `BrainGateway` routes on, so the switch in the panel and
    /// the turn that follows it cannot disagree — the failure this avoids is a UI that says
    /// "offline" while the screenshots go to a cloud anyway.
    @Published var isOfflineBrainOn: Bool = UserDefaults.standard.string(
        forKey: BrainSettings.providerKey) == ProviderRegistry.ollama.id

    /// What the machine would actually use, once discovered. Shown under the switch, because
    /// "offline" means nothing if there is no model here that can see the screen.
    @Published private(set) var offlineBrainSummary = "checking this Mac\u{2026}"

    func setOfflineBrain(_ enabled: Bool) {
        isOfflineBrainOn = enabled
        UserDefaults.standard.set(enabled ? ProviderRegistry.ollama.id : ProviderRegistry.gemini.id,
                                  forKey: BrainSettings.providerKey)
        // The model preference is dropped rather than remembered: the point of the switch is to
        // pick whatever is loaded and able to see, and a stale name from a previous pull would
        // resolve to "no model called X" on a machine that has one.
        if enabled { UserDefaults.standard.removeObject(forKey: BrainSettings.modelKey) }
        LocalBrainDiscovery.invalidate()
        Log.write("brain: offline switched \(enabled ? "on" : "off")")
        refreshOfflineBrainSummary()
    }

    /// Ask the local servers what they have, and say what would be used.
    ///
    /// Called when the panel appears and whenever the switch moves, so a model pulled five minutes
    /// ago shows up without restarting the app.
    func refreshOfflineBrainSummary() {
        Task { @MainActor in
            var sawAny = false
            for candidate in [ProviderRegistry.ollama, ProviderRegistry.lmStudio] {
                let descriptors = await LocalBrainDiscovery.descriptors(for: candidate)
                guard !descriptors.isEmpty else { continue }
                sawAny = true
                let models = ProviderRegistry.localModels(from: descriptors)
                if let vision = models.first(where: { $0.visionCapable == true }) {
                    offlineBrainSummary = "\(candidate.displayName) \u{2014} \(vision.id). Nothing leaves this Mac."
                    return
                }
                if let first = models.first {
                    offlineBrainSummary = "no model in \(candidate.displayName) can see images "
                        + "(\(first.id) is text-only). Pull a vision model."
                    return
                }
            }
            offlineBrainSummary = sawAny
                ? "a local server answered but listed no models."
                : "no local server answering \u{2014} start Ollama, or switch back."
        }
    }

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var circleCancellable: AnyCancellable?
    /// The overlay while it is on screen. Held so ⌃⌘D a second time can take it down — the
    /// exit that does not depend on this window ever having received key focus.
    /// The drawing surface covering the screen, if there is one. The chord is a toggle, so this is
    /// how a second press knows what to close.
    private var activeOverlay: AnnotationOverlayWindow?

    /// The markup panel the user is drawing on, if there is one.
    private var activeMarkup: CropMarkupWindow?

    /// One macOS selection in flight at a time. Its crosshair belongs to the system, so Chunks
    /// cannot close it — only refuse to start a second.
    private var isSelectingRegion = false
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Tap-versus-hold state for ⌃⌥. A tap arms the dictation and a second tap sends it, so a
    /// sentence no longer needs Control held for its whole length; a hold still means what it
    /// always meant.
    private var talkArmer = TalkArmer()
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when every permission the pipeline needs is granted: accessibility (posting and
    /// reading the UI), screen recording, microphone, the screen-content picker, and input
    /// monitoring (the keyboard tap). Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission
            && hasScreenContentPermission && hasInputMonitoringPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The model a turn starts on. Persisted to UserDefaults.
    ///
    /// clicky shipped this as a Claude preference ("claude-sonnet-4-6"), and a stored value
    /// from that build would otherwise come back as the preferred model of every turn here —
    /// which the gateway answers by logging "isn't available" and falling through the chain.
    /// So a value that is not one of Chunks' models is discarded rather than honoured.
    @Published var selectedModel: String = {
        let stored = UserDefaults.standard.string(forKey: "selectedClaudeModel")
        if let stored, ProviderRegistry.geminiFreeModels.contains(where: { $0.id == stored }) {
            return stored
        }
        return ProviderRegistry.defaultFreeModelID
    }()

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether a Gemini API key is in the Keychain, from `KeychainStore`'s cache.
    ///
    /// Nothing else in the app can tell the user "add a key" — every model call fails
    /// with a message pointing at a Settings pane that does not exist in this app. This
    /// is the value the panel's key row renders.
    @Published private(set) var hasApiKey = false

    /// Store a key in the Keychain and publish the result. Returns false when the write
    /// fails, which for an ad-hoc-signed build means `securityd` refused the item.
    func saveApiKey(_ key: String) -> Bool {
        guard KeychainStore.setGeminiKey(key) else { return false }
        refreshApiKeyState()
        return true
    }

    /// Read the Keychain off the main thread and publish the answer — and log it.
    ///
    /// The log line has to come from the *answer*, not from the cache at launch time. The cache
    /// is empty until this refresh returns, so a launch-time read said `api key: MISSING` on a
    /// machine with a key in the Keychain — and "the rebuild ate my key" is precisely the report
    /// the signing work was done to rule out, so a false line here costs real debugging time.
    func refreshApiKeyState() {
        KeychainStore.refreshInBackground { [weak self] in
            self?.hasApiKey = KeychainStore.isKeyConfigured
            Log.write("api key: \(KeychainStore.isKeyConfigured ? "present" : "MISSING")")
        }
    }

    func start() {
        refreshAllPermissions()
        refreshApiKeyState()
        print("🔑 Chunks start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // The recogniser is expensive to wake and cheap to keep; the microphone is the opposite,
        // and is a thing the user can hear themselves into. Warm one at launch, open the other on
        // the press.
        buddyDictationManager.warmUpTranscriber()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
            Log.write("cursor: shown at launch")
        } else {
            // The cursor is either on the screen or it is not, and until this line existed the
            // log could not tell those apart — so "the buddy doesn't work" had no evidence behind
            // it. Naming the guard that failed is the difference between a bug report and a fix.
            Log.write("cursor: NOT shown at launch — onboarding=\(hasCompletedOnboarding) "
                + "permissions=\(allPermissionsGranted) enabled=\(isClickyCursorEnabled)")
        }
    }

    /// Triggers the onboarding sequence — dismisses the panel and brings the overlay up so
    /// the welcome line, the pointing demo and the talk prompt play in order.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Show the overlay for the first time — the greeting starts the welcome animation,
        // which hands off to the intro when it finishes
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self,
                                         greeting: true)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        // Tear down any existing overlays and recreate them with the greeting this time
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self,
                                         greeting: true)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        cancelIntro()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadInputMonitoring = hasInputMonitoringPermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility
        hasInputMonitoringPermission = WindowPositionManager.hasInputMonitoringPermission()

        // The tap needs both grants: Accessibility for it to exist, Input Monitoring for
        // anything to arrive. Starting it on Accessibility alone is what left every keyboard
        // shortcut dead with no error anywhere.
        if currentlyHasAccessibility && hasInputMonitoringPermission {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes. `Log.write`, not `print` — output from an
        // app launched by `open` goes nowhere anyone can read, which is exactly how the
        // missing Input Monitoring grant stayed invisible.
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission
            || previouslyHadInputMonitoring != hasInputMonitoringPermission {
            Log.write("permissions changed — accessibility: \(hasAccessibilityPermission) "
                      + "screen_recording: \(hasScreenRecordingPermission) "
                      + "microphone: \(hasMicrophonePermission) "
                      + "screen_content: \(hasScreenContentPermission) "
                      + "input_monitoring: \(hasInputMonitoringPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                                                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                        Log.write("cursor: shown by permission poll (it was not on screen)")
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    /// Quits and reopens the app bundle so a Screen Recording grant takes effect.
    ///
    /// macOS reads the screen-capture entitlement once, at launch. `CGPreflight`
    /// keeps returning false for the process that was running while the user
    /// approved in System Settings, which is why the onboarding list can appear
    /// stuck even though the checkmark is on. Handing the relaunch to `open` goes
    /// through launchd, so it survives this process terminating.
    ///
    /// Only works when running from a real `.app`. Under `swift run` there is no
    /// bundle to reopen, so it quits and says so rather than failing silently.
    func restartToApplyPermissions() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            Log.write("restart: not running from an app bundle ( \(bundle.path) ) — quit and rerun manually")
            NSApp.terminate(nil)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path arrives as a positional parameter instead of being interpolated
        // into a shell string, so a folder named with quotes or spaces cannot break
        // the command or run something else.
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$1\"", "chunks-relaunch", bundle.path]
        do {
            try task.run()
        } catch {
            Log.write("restart: could not schedule relaunch (\(error.localizedDescription))")
        }
        NSApp.terminate(nil)
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                        // Same reason for the HUD: the press said "Listening", nothing was
                        // heard, and no turn will arrive to replace it. Guarded on the phase
                        // so a card from the previous answer survives a silent press.
                        if self.hud.phase == .listening {
                            self.hud.dismiss(reason: "press heard nothing")
                        }
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        circleCancellable = globalPushToTalkShortcutMonitor
            .circleTogglePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.toggleCircleToExplain()
            }
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // The manager owns the truth about whether audio is flowing; the armer only models
            // the gesture. If they disagree because a dictation ended by some other route — an
            // error, the fallback timer, the panel's own mic button — the armer must forget it,
            // or the next press is read as a stop for a session that is already gone.
            if !buddyDictationManager.isDictationInProgress { talkArmer.reset() }
            switch talkArmer.press(at: Date()) {
            case .stopAndSubmit:
                ClickyAnalytics.trackPushToTalkReleased()
                pendingKeyboardShortcutStartTask?.cancel()
                pendingKeyboardShortcutStartTask = nil
                buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
                return
            case .ignore:
                return
            default:
                break
            }
            guard !buddyDictationManager.isDictationInProgress else {
                talkArmer.reset()
                return
            }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil
            cancelIntro()

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            ttsClient.stopPlayback()
            clearDetectedElementLocation()

            // A new press replaces whatever the HUD was showing, including a card the user
            // has not dismissed.
            hud.beginListening()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { [weak self] partialTranscript in
                        // Live captions on the notch. Upstream deliberately hid partial
                        // transcripts and left the cursor's waveform as the only feedback,
                        // which asks the user to trust a squiggle with their words. The
                        // recogniser calls this off the main actor, so hop before touching
                        // the HUD.
                        Task { @MainActor [weak self] in
                            self?.hud.showCaption(partialTranscript)
                        }
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        // Keep the finished question on the pill while the request is in
                        // flight; `beginThinking` carries it over as the status line.
                        Task { @MainActor [weak self] in
                            self?.hud.showCaption(finalTranscript)
                        }
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToBrainWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            let arming = talkArmer.release(at: Date())
            if arming == .stayArmed {
                // The tap opened the mic and the tap closes nothing: keep recording, keep the
                // caption live on the pill, and let the next words join the same dictation.
                return
            }
            // The press that ended an armed dictation produces this release as the second half of
            // one gesture. Skipped only while nothing is recording — the manager's state outranks
            // the armer's model here, because the one failure allowed never is an out-of-sync
            // armer leaving the microphone open with no way to close it.
            if arming == .ignore && !buddyDictationManager.isDictationInProgress { return }

            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    /// Internal, not private, so `--self-test --prompt-production` can measure a brain against the
    /// prompt Chunks actually sends. The default self-test prompt says "no tags", and a model that
    /// obeys it correctly looks like one that cannot follow the reply protocol — which is exactly
    /// the wrong conclusion I drew about the local models on 2026-10-09.
    static let companionVoiceResponseSystemPrompt = """
    you're chunks, a friendly always-on companion that lives in the notch of the user's mac. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech and shown on a small card under the notch, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two spoken sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — the depth belongs in the shown detail, which has no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech. that rule is for what goes inside <SAY>; the shown detail may use plain lines, steps and names, because nobody reads a transcript out loud.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text.

    aim with a 0–1000 grid stretched over the screenshot, not with pixels: x=0 is its left edge and x=1000 its right edge, y=0 the top and y=1000 the bottom. the middle of the picture is (500,500); a control in the bottom right corner is around (920,960). the pixel size in the image label tells you what the picture is, not what to answer in — Chunks rescales your grid point onto the real display, whose size is different again. answering in pixels is what put a press on the row *below* the one the user named, and made an input bar at the bottom of the screen look like nothing was there at all.

    format: [POINT:x,y:label] where x,y are whole numbers from 0 to 1000 in that grid, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    acting on a control:
    you can ask for ONE real control on screen to be pressed. it is a request, never something you do: Chunks hit-tests the point, decides whether the press is allowed, and tells the user what happened. the "acting, right now" rules further down say whether the user is asked first or it simply runs — follow those for how you word it.
    format: [ACT:x,y:label] — the same coordinate space and the same rules as [POINT:…], including :screenN. last in the reply.
    emit it when the user's own words name a physical act on something you can see: "click send", "open the screenshot on my desktop", "hit play", "dismiss this", "ok do it". a file icon, a folder, a thumbnail, a menu item and a window button are all controls to press — an instruction to *open* something visible is an [ACT] request, never a description of how to open it by hand.
    do not invent one: if the user asked *how* to do something, point at it and explain instead; if nothing should be pressed, leave the tag out entirely — there is no [ACT:none].

    typing into a field:
    you can ask for text to be typed into ONE field you can see. it is the same kind of request as a press, about words instead of a control.
    format: [TYPE:x,y:label|the exact text] — same coordinate space and rules as [ACT:…], and the text goes after the `|` verbatim, with no quotes around it.
    emit it when the user names text to put somewhere: "tell him good night", "type 42 in that box", "search for raycast". point at the *input field*, not the send button, and never include the send or return key: the tag types, it does not submit, and pressing send afterwards would be a second act the card cannot hold.
    a send button usually does not exist yet. in WhatsApp and most chat apps the control at the right of the input row is a microphone until there is text in the box, so an [ACT] aimed at "send button" on an empty field is aimed at a control the app has not published — type first, and press send in the turn after, when it is real.
    if the user wants the message sent, say so out loud and offer it as the follow-up tap, or queue the send as the next act in the same reply — see *several acts in order*.
    a search box that only shows the word "Search" is not a field yet — it is a control that *opens* one. Press it with an [ACT] first and put the [TYPE] after it in the same plan; typing straight into it is refused, because the field does not exist until something is pressed.
    you cannot delete or replace what is already in a field, type into two fields, or type into a password box; those come back refused, so do not dress one up as a press.

    moving a list:
    you can ask for one list or page on screen to be scrolled. same kind of request as a press, about movement instead of a click.
    format: [SCROLL:x,y:label|down] — aim inside the list that should move, and after the `|` write up, down, left or right, with a number of pages only when the user asked for more than one ("scroll down 3").
    emit it when the user asks to look further: "scroll down", "keep going", "find the older messages", "is there anything below this". you get a fresh screenshot on the next turn, so "find X in that list" is: scroll, say you are looking, and answer from what comes back — never claim you found it in the same breath as scrolling.
    "scroll down until you find the invoice" is a scroll, and the finding happens on the turn after it, when the screen has moved.

    several acts in order:
    when one request needs more than one thing done to the screen, write the tags in the order they should happen, all at the end of the reply: `[ACT:…]` then `[TYPE:…]` then `[ACT:…]`. Chunks runs them as a plan, re-finding each target on the live screen before it acts, and **stops at the first step that does not happen** — so a plan is only as good as its next step's name.
    use it for the requests that are obviously a sequence: "message Nitesh that good night in whatsapp" is press the search box, type the name, press the result, type the message, press send. five tags, one reply, in that order.
    keep each step's label something you can see in the screenshot you were given, and never plan past a step whose result you cannot predict — a plan that assumes a dialog will look a certain way is a guess, and the guess is what stops it.
    a `[DO:…]` tool does not join a plan: if a reply queues acts, the tool is dropped.

    running a tool:
    three things *outside* the screen you can ask for: open an installed app, open a web address, or change the system volume. these are requests too, and Chunks runs them or asks first by the same "acting, right now" rules as a press.
    format: [DO:open_app:Notes], [DO:open_url:youtube.com], [DO:open_url:youtube.com|Chrome] or [DO:set_volume:40]. the app name is the name as it appears in /Applications, never a path. the volume is a whole percent from 0 to 100. at most one per reply, at the very end, and only when the user asked for that exact thing ("open spotify", "turn it down").
    [DO:open_app:…] is for an app that is *not* on the screen. when the thing to open is visible — an icon on the desktop, a thumbnail, a window — press it with [ACT:…] instead. "open the screenshot on my desktop" is an [ACT] on that icon, never a [DO] that launches some app whose name appears in the picture.
    "open youtube in chrome", "go to github", "open the gmail site" are one [DO:open_url:…] with the browser named after the `|`. that is the whole request: Chunks hands the address to the browser, which opens it in a new tab of the window that is already there. never do it by clicking the browser's icon, typing in the address bar and pressing enter — three acts the card cannot hold, an address bar whose position you would be guessing at, and a page that loads slower than the next click.
    there is no tool for a timer, focus modes, or shell commands, and typing is not a tool either — it is the [TYPE:…] tag above. if you emit one of those the tag is shown to the user as plain text and nothing happens — so don't invent one, and never wrap a command in this tag.
    if the user asks for two acts in one turn, emit the one that has to happen first and say the other comes next: the card can only hold one question, and the one it doesn't ask about will not run.

    reply structure:
    your answer appears on screen as a card AND is read aloud, and those are not the same text. use these tags:
    - <SAY>…</SAY> wraps what you want heard. keep it to the spoken answer — the way you'd actually say it out loud.
    - anything you write OUTSIDE those tags is shown on the card but never spoken. put the longer expansion there: the exact steps, the shortcut, the names of the menus, the code. this is where a thorough explanation belongs, so going deep does not mean talking for two minutes.
    - <DONE_TITLE>three words max</DONE_TITLE> names what you just found or did, in the past tense ("Found color inspector", "Fixed the comma"). it labels the card. when the reply ends in an act request, name the readiness instead of a result — "Ready to send", never "Message sent".
    - <SUMMARY>one short line</SUMMARY> is the last thing said aloud when you finish — the completion line, not a recap of the whole answer.
    - <NEXT_ACTIONS> holds up to three follow-ups the user can tap, one per line starting with "- ". only real next steps that you can actually act on. if there is nothing worth offering, leave the block out entirely.

    order: <SAY> first, then any shown detail, then <DONE_TITLE>, <SUMMARY>, <NEXT_ACTIONS>, <MEMORY>, then the act tags — [POINT:…], [ACT:…], [TYPE:…], [SCROLL:…] or [DO:…] — in the order they should happen, and <CONTINUE> last of all.
    emit every step you can aim at *this* screenshot. most of the time that is one step, because a press changes the screen the next press was aimed at — but a plan whose steps are all visible now (fill a field, then press the button beside it) is emitted as several tags in one reply, and Chunks runs them in order.
    when the request still has a step you cannot aim, because the window it needs is not open yet, close the reply with <CONTINUE>what still has to happen</CONTINUE> on one line. Chunks does the steps it can, looks at the screen again, and lets you finish without the user saying it twice. if the whole request is done, leave the tag out — an empty promise to continue is a loop.

    memory:
    you remember things about the user across conversations, in a small file the app owns. you never write that file — you emit a proposal and the app validates and merges it.
    <MEMORY>{"add":[{"section":"You","fact":"uses raycast as a launcher"}],"prune":["writes in python"]}</MEMORY>
    - section is one of "You" (who they are, their tools, their projects), "Corrections" (times they told you that you got something wrong), "Standing preferences" (how they always want answers), "Notes".
    - one short plain sentence per fact. no newlines, no quotes inside the fact.
    - prune removes stored facts by substring. use it when the user says they no longer do something.
    - propose memory only for things worth knowing next week. never propose what is on their screen, and never propose something they are only asking about. it's fine to send no <MEMORY> block at all — most turns should not.
    - never store a password, token or api key. the app refuses those and tells the user; don't route around the refusal by paraphrasing the secret.
    - the file is capped and small. when the app reports it full, it will ask the user to delete something — do not split a fact into smaller pieces to squeeze it in.
    - below, under "what i know about this user", are the facts already stored. use them without repeating them back, and never propose one that is already there.

    examples:
    - user asks how to color grade in final cut:
      <SAY>you'll want the color inspector — it's up in the top right of the toolbar.</SAY>
      click it and you get three panels: the color board for presets, the wheels for lift gamma and gain, and the curves tab for fine control. shortcut is command option 9.
      <DONE_TITLE>Found color inspector</DONE_TITLE>
      <SUMMARY>Pointed at the color inspector.</SUMMARY>
      <NEXT_ACTIONS>
      - explain the color wheels
      - what do curves give me over wheels
      </NEXT_ACTIONS>
      [POINT:860,45:color inspector]
    - user says "click the send button for me" (you request the press; the "acting, right now" rules say whether to word it as asking or as doing):
      <SAY>pressing send now — it's the one at the bottom of the message window.</SAY>
      the message goes out as soon as it lands, so check the address line first if it matters.
      <DONE_TITLE>Ready to send</DONE_TITLE>
      <SUMMARY>The press is on its way.</SUMMARY>
      [ACT:760,930:send button]
    - user says "tell him good night" with a chat open and its input box empty (the send button does not exist until something is typed, so this reply types and hands the send to the next look):
      <SAY>typing good night into that message box now.</SAY>
      the message box is at the bottom right, and it's empty, so nothing gets overwritten. say the word and i'll press send next.
      <DONE_TITLE>Ready to type</DONE_TITLE>
      <SUMMARY>Those words are on their way in.</SUMMARY>
      <NEXT_ACTIONS>
      - press send
      </NEXT_ACTIONS>
      [TYPE:620,965:message box|good night]
      <CONTINUE>press send in the chat window</CONTINUE>
    - user says "open whatsapp, search for dad, and message him HI" with WhatsApp closed (you can aim the open; the search box and the message field do not exist yet, so they are not yours to guess coordinates for):
      <SAY>opening whatsapp — then i'll need a look to find dad.</SAY>
      three steps: open, search, type and send. each one needs the screen the one before it leaves behind.
      <DONE_TITLE>Opening WhatsApp</DONE_TITLE>
      <SUMMARY>WhatsApp is on its way up.</SUMMARY>
      [DO:open_app:WhatsApp]
      <CONTINUE>search for Dad in WhatsApp, then type HI into the message box and press send</CONTINUE>
    - user says "scroll down until you find the invoice" (one act: the scroll; the finding happens next turn, on a screen that has moved):
      <SAY>scrolling that list down a few pages — i'll spot the invoice in the next look.</SAY>
      if it is older than a week it may be under the "load earlier" row at the bottom, which is a second scroll.
      <DONE_TITLE>Scrolling the list</DONE_TITLE>
      <SUMMARY>Ask me again once it settles.</SUMMARY>
      [SCROLL:120,600:chat list|down 3]
    - user says "it's too loud, turn it down" (one tool request, and you never say it already happened):
      <SAY>dropping the volume to 30.</SAY>
      i picked 30 because the meter reads near full, tell me a number if you had one in mind.
      <DONE_TITLE>Ready to lower volume</DONE_TITLE>
      <SUMMARY>Volume is on its way down.</SUMMARY>
      [DO:set_volume:30]
    - user asks what html is, nothing on screen to point at:
      <SAY>html is the skeleton of every web page — it marks up what each bit of content actually is.</SAY>
      headings, paragraphs, links, images. css then styles that structure and javascript makes it react.
      <DONE_TITLE>Explained html</DONE_TITLE>
      <SUMMARY>Happy to go into the box model next.</SUMMARY>
      [POINT:none]
    - user says "remember that i use raycast, not spotlight" (the escaping matters: one json string per fact, no newlines):
      <SAY>got it, raycast not spotlight.</SAY>
      <MEMORY>{"add":[{"section":"Standing preferences","fact":"uses raycast instead of spotlight"}],"prune":[]}</MEMORY>
      <DONE_TITLE>Remembered Raycast</DONE_TITLE>
      <SUMMARY>Added that to what i know about you.</SUMMARY>
      [POINT:none]
    """

    // MARK: - AI Response Pipeline

    /// The system prompt for one turn: the fixed rules, how acting works *right now*, and what the
    /// store currently knows.
    ///
    /// Assembled per turn instead of cached, for three reasons. The store's contents change the
    /// moment a proposal is written, so a prompt built at launch would make the app forget
    /// everything it learned on its second answer — the "I use Raycast" test in the plan.
    /// Re-reading from disk picks up edits made outside this process: the memory file is plain
    /// markdown the user can open in Finder and change, and the file is the source of truth rather
    /// than this instance's copy. And the acting rules follow `askBeforeActing`, because a prompt
    /// that says "the card will ask" on a machine where asking is switched off makes the model
    /// promise a question the user will never see — which is exactly what happened on the first
    /// Pluralsight turn.
    private func companionPromptWithMemory() -> String {
        memoryStore.load()
        let known = memoryStore.injectedBlock()
        return Self.companionVoiceResponseSystemPrompt
            + "\n\n" + Self.actingRules(askBeforeActing: askBeforeActing)
            + "\n\nwhat i know about this user (from earlier turns):\n"
            + (known.isEmpty ? "(nothing yet)" : known)
    }

    /// The paragraph that tells the model what happens to an `[ACT]`, `[TYPE]` or `[DO]` after it replies.
    ///
    /// Split out of the fixed prompt because it is the only part that changes with a user setting,
    /// and getting it wrong is not a wording nit: with asking off, "i'll ask you to allow it" is a
    /// lie, and with asking on, "i opened it" claims an act the user has not yet agreed to.
    ///
    /// Both positions carry the same honesty rule because the model breaks it on both: asked to
    /// send a WhatsApp message it said "i've typed it into the input field and clicked the send
    /// icon" in the same breath as Chunks printed "that app did not expose a control at that
    /// point". What is inside `<SAY>` is a *promise about a request*, and the only past tense in a
    /// reply belongs to the outcome line Chunks appends after the act actually ran.
    static func actingRules(askBeforeActing: Bool) -> String {
        askBeforeActing
            ? """
            acting, right now: the user is asked first.
            an [ACT:…], [TYPE:…] or [DO:…] puts one question on the card — "Press send in Mail?", "Type \\"good night\\" into the message box in WhatsApp?", "Open Notes?" — with Allow and Not now, and nothing happens until the user picks Allow. Say that you are asking, never that it is done: "i'll ask you to press send", not "i pressed send".
            the card holds one question at a time, so a plan of several tags is asked about one step at a time — "Press Search in WhatsApp? (step 1 of 5)" — and a "not now" on any step drops the steps after it.
            your words are not the act. you cannot know whether the user will allow it, or whether the control is even there, so never say a thing is typed, sent, opened or clicked — the app finishes the sentence with what really happened, and that line is the only past tense here.
            """
            : """
            acting, right now: the user has switched asking off, so you act instead of asking.
            an [ACT:…], [TYPE:…] or [DO:…] runs straight away — Chunks presses the control, types the text or runs the tool, then says out loud whether it worked. So say what you are doing ("opening pluralsight", "typing that in now"), and never say "i'll ask you to allow it", "allow it on the card", or "tap Allow" — there is no card to tap, and promising one makes the user wait for a question that is never coming.
            it is still not you doing it: Chunks decides whether the act happens, refuses anything unsafe, and reports an act that failed. So never claim a result you did not get told — "i'll open it" is right, "it's saved", "i sent it" and "i've typed it" are guesses, and they are guesses the user can see contradicted one line below.
            emit your tags in order and Chunks runs them as a plan, stopping at the first step that does not happen. secure text fields, Keychain and password windows are refused even now, and an act the app refuses comes back as a refusal the user hears.
            """
    }

    /// Merge the model's proposed memory change and show what actually happened.
    ///
    /// This is the only path from a reply to the memory file, and every write goes through
    /// `MemoryStore.propose`, which runs the secret sweep, the malformed check, the dedupe and
    /// the capacity check first. Invariant 2 is why the prompt tells the model it cannot write
    /// the file: it genuinely cannot, and a hijacked turn that offers to "remember" an API key
    /// produces a refusal on the card rather than a credential on disk.
    private func applyMemory(_ proposal: MemoryProposal) {
        guard !proposal.isEmpty else { return }

        let outcomes = proposal.add.map {
            memoryStore.propose(section: $0.section, text: $0.fact)
        }
        let pruned = proposal.prune.reduce(0) { $0 + memoryStore.remove(matching: $1) }

        let line = MemoryReport.line(for: outcomes, pruned: pruned)
        hud.reportMemory(line)
        if let line { Log.write("memory: \(line)") }
    }

    // MARK: - Acting on a control

    /// Turn the model's act proposal into a refusal, a question, or a press.
    ///
    /// The hit test runs **before** the question is asked, so the card can name the control that
    /// will actually be pressed rather than the one the model thought it saw. Asking "Press Run?"
    /// and then pressing a menu item is the failure this ordering prevents.
    ///
    /// Nothing here reaches `AXTDriver` without either a policy rule allowing it or the user
    /// answering the card. That is invariant-grade: the model proposes, and a rule it cannot
    /// talk its way past decides.
    /// Returns the one line that has to be *said* to the user, or `nil` when the card asked.
    ///
    /// The caller needs that string, for two different reasons. A refusal, because the model's
    /// own words have usually just promised "I'll ask you to allow it", and a card that silently
    /// never asks leaves the user hearing a promise with nothing after it. An auto-press, because
    /// with asking switched off there is no card at all — the line about what happened is the only
    /// trace that anything ran.
    @discardableResult
    private func offerAct(_ act: ActionRequest,
                          screenCaptures: [CompanionScreenCapture],
                          position: (index: Int, of: Int)? = nil) async -> StepOutcome {
        // Both ends of the mapping, because "nothing there" has two very different causes: the
        // model aimed at the wrong place, or Chunks translated the aim wrongly. Without the
        // image coordinates in the log there is no way to tell them apart after the fact.
        Log.write("act: model asked for image (\(Int(act.target.x)), \(Int(act.target.y))) "
            + "\"\(act.label)\"")
        guard let axPoint = actPoint(act, screenCaptures: screenCaptures) else {
            let reason = "Chunks could not work out which screen that was on."
            hud.reportConfirm(reason)
            Log.write("act: no screen for \(act.label)")
            return .stopped(line: reason)
        }
        guard AXTDriver.isTrusted() else {
            let reason = AXTDriver.PressResult.permissionMissing.userFacingReason
            hud.reportConfirm(reason)
            Log.write("act: accessibility not granted")
            return .stopped(line: reason)
        }
        if act.textToType != nil {
            return await offerType(act, at: axPoint, position: position)
        }
        if let intent = act.scrollIntent {
            return await offerScroll(act, direction: intent.direction, pages: intent.pages,
                                     at: axPoint, position: position)
        }
        // The pixel first, the name second: a model aiming a few points off an icon is a
        // rounding error, not a wrong request, and the element it *named* is the one it meant.
        guard let target = AXTDriver.target(label: act.label, at: axPoint) else {
            // Say which of the two failures this was, because the fix is different for each:
            // nothing at the point means the aim or the mapping is off, something unpressable
            // means the app has not published that surface to Accessibility.
            let reason: String
            if let element = AXTDriver.elementAt(axPoint) {
                reason = AXTDriver.PressResult.notPressable(element: element).userFacingReason
                Log.write("act: nothing pressable at \(axPoint) — role=\(element.role ?? "-") "
                    + "named \"\(element.elementLabel)\", asked \"\(act.label)\"")
            } else {
                reason = AXTDriver.PressResult.noElement(containing: axPoint).userFacingReason
                Log.write("act: nothing found at \(axPoint)")
            }
            hud.reportConfirm(reason)
            return .stopped(line: reason)
        }
        let element = target.info
        if target.snapped {
            // Logged every time, because a press that moved to a neighbouring control has to be
            // reconstructable from the log alone — the card will not have shown it.
            Log.write("act: aim missed, answered by name — \"\(act.label)\" → "
                + "\(element.role ?? "-")/\(element.elementLabel) at "
                + "\(element.frame.map { "(\($0.midX), \($0.midY))" } ?? "-")")
        }
        if AXTDriver.aimNamesSomethingElse(label: act.label, element: element) {
            // The other direction: the aim found a control, the control has a name, and that name
            // is not what the user asked for. With asking off there is no card to catch it, so the
            // log carries it and the outcome line names the control that was actually pressed.
            Log.write("act: aim names \"\(element.elementLabel)\", asked for \"\(act.label)\"")
        }

        let bundleID = bundleID(of: element)
        let decision = PolicyGate.decide(target: element.policyTarget(bundleID: bundleID),
                                         alwaysAllowedBundleIDs: alwaysAllowedBundleIDs,
                                         askBeforePressing: askBeforeActing)

        switch decision {
        case .forbidden(let reason):
            // Refused rather than asked: presenting a forbidden press as a yes/no question
            // would make "Allow" a lie.
            hud.reportConfirm(reason)
            Log.write("act: forbidden — \(reason)")
            return .stopped(line: reason)

        case .allowedWithoutAsking:
            // Nobody was asked, so the card's one line of what happened is the only place the
            // user can learn the press ran — and the model's spoken sentence will already have
            // promised it. So that line is also returned, to be said.
            let result = await runAct(act, at: axPoint, approved: element)
            return result.happened ? .done(line: result.line) : .stopped(line: result.line)

        case .needsConsent:
            consentGate.cancel()
            consentGate.stage(.press(act))
            pendingPress = PendingPress(act: act, axPoint: axPoint, bundleID: bundleID, element: element)
            hud.onConfirmAnswer = { [weak self] outcome in
                self?.answerAct(outcome)
            }
            let appName = PolicyGate.displayName(of: element.policyTarget(bundleID: bundleID))
            hud.askConfirm(Self.pressQuestion(elementLabel: element.elementLabel, appName: appName,
                                             position: position))
            Log.write("act: asking — \(appName)/\(element.elementLabel) at \(axPoint)")
        }
        return .asked
    }

    /// The card's question for a press, with the plan's position when there is a plan.
    ///
    /// "Step 2 of 4" is on the card because a plan is approved one step at a time, and a user who
    /// tapped Allow twice needs to know the card is going to ask again.
    static func pressQuestion(elementLabel: String, appName: String,
                              position: (index: Int, of: Int)?) -> String {
        let base = "Press \(elementLabel) in \(appName)?"
        guard let position else { return base }
        return "\(base) (step \(position.index) of \(position.of))"
    }

    /// Run a reply's act tags in order — one spoken request, several acts.
    ///
    /// This exists because of the sentence users actually say: "message Nitesh that good night in
    /// whatsapp" is a search, an open, a type and a send, and a card that could hold one of them
    /// could never do any of it. Every step still travels the whole chain on its own — resolved
    /// against the *live* tree, refused by `PolicyGate`, and asked about one at a time when asking
    /// is switched on — and the plan **stops at the first step that does not happen**, because the
    /// steps after it were aimed at a screen this step would have changed.
    ///
    /// With asking off — the default, and the standing instruction on this machine — the plan runs
    /// end to end and each step's own line reaches the card, so the user can hear where it got to.
    @discardableResult
    private func offerProgram(_ steps: [ActionRequest],
                              screenCaptures: [CompanionScreenCapture],
                              doneCount: Int = 0,
                              totalCount: Int? = nil) async -> StepOutcome {
        guard let first = steps.first else { return .stopped(line: "Nothing was left to do.") }
        let total = totalCount ?? steps.count
        let many = total > 1
        if many {
            Log.write("program: \(steps.count) step(s) left of \(total) — "
                + steps.map(\.label).joined(separator: ", "))
        }
        for (index, step) in steps.enumerated() {
            let position = many ? (index + 1 + doneCount, total) : nil
            let outcome = await offerAct(step, screenCaptures: screenCaptures, position: position)
            switch outcome {
            case .asked:
                // A card is open for this step. Whatever comes next waits behind it, and a denial
                // drops it — see `answerAct`.
                pendingProgram = PendingProgram(steps: Array(steps[(index + 1)...]),
                                                doneCount: doneCount + index,
                                                totalCount: total,
                                                screenCaptures: screenCaptures)
                return .asked

            case .done(let line):
                guard index + 1 < steps.count else { return .done(line: line) }
                // Let the app draw the screen the next step is aimed at before resolving it.
                try? await Task.sleep(nanoseconds: Self.stepSettleDelay)

            case .stopped(let line):
                if index + 1 < steps.count {
                    let dropped = steps.count - index - 1
                    Log.write("program: stopped at step \(index + 1 + doneCount)/\(total) — \(line)")
                    return .stopped(line: "\(line) The other \(dropped) step(s) did not run.")
                }
                return .stopped(line: line)
            }
        }
        return .stopped(line: "Nothing was left to do.")
    }

    /// The user answered the card. Act on an approval, do nothing on a denial.
    private func answerAct(_ outcome: ConsentGate.Outcome) {
        guard let request = consentGate.resolve(outcome) else {
            pendingPress = nil
            pendingProgram = nil
            return
        }
        switch request {
        case .press(let act):
            // The gate and this slot are always armed together, so a press the gate handed back
            // with no resolved point is a question this shell never asked — and there is no
            // safe press to perform without one.
            guard let pending = pendingPress else { return }
            pendingPress = nil
            if outcome == .alwaysAllowed, let bundleID = pending.bundleID {
                // In memory only, for this run. Persisting an allowance would outlive the decision
                // the user actually made, and the row to manage it does not exist yet.
                alwaysAllowedBundleIDs.insert(bundleID)
                Log.write("act: always-allow recorded for \(bundleID)")
            }
            if case .denied = outcome {
                // "Not now" on step 2 of 4 is not a pause: the steps after it were aimed at a
                // screen this step would have changed, so the plan is over.
                let remaining = pendingProgram?.steps.count ?? 0
                pendingProgram = nil
                if remaining > 0 {
                    let line = "You said not now, so the other \(remaining) step(s) did not run."
                    hud.reportConfirm(line)
                    Log.write("program: denied at a step — \(remaining) dropped")
                }
                return
            }
            // Not awaited: this runs from the card's button handler, and an act that has to wait
            // a second to find out whether it landed must not stall the answer animation. The
            // outcome line reaches the card and the log from inside `runAct` either way.
            let program = pendingProgram
            pendingProgram = nil
            Task {
                let result = await runAct(act, at: pending.axPoint, approved: pending.element)
                guard result.happened, let program, !program.steps.isEmpty else { return }
                try? await Task.sleep(nanoseconds: Self.stepSettleDelay)
                _ = await self.offerProgram(program.steps,
                                            screenCaptures: program.screenCaptures,
                                            doneCount: program.doneCount,
                                            totalCount: program.totalCount)
            }

        case .tool(let tool):
            pendingPress = nil
            pendingProgram = nil
            runTool(tool)
        }
    }

    /// Perform an act the user has already been asked about (or that needs no asking).
    ///
    /// One door for every verb, because the consent decision, the card and the spoken outcome line
    /// are the same on both sides of it: only what runs at the end differs. It answers with whether
    /// the act *happened* as well as what to say, because a plan has to know which of the two it
    /// is being told about.
    private func runAct(_ act: ActionRequest, at axPoint: CGPoint,
                        approved: AXElementInfo) async -> (line: String, happened: Bool) {
        if act.textToType != nil {
            return await typeAct(act, at: axPoint, approved: approved)
        }
        if let intent = act.scrollIntent {
            return await scrollAct(act, direction: intent.direction, pages: intent.pages,
                                   at: axPoint, approved: approved)
        }
        return await pressAct(act, at: axPoint, approved: approved)
    }

    /// Put a `[TYPE:…]` through the same policy and consent chain a press uses.
    ///
    /// The question is worded differently on purpose. A press card names a control the user can see
    /// ("Press Send?"); a type card has to show the *words* about to go somewhere, because the
    /// control's own name says nothing about what will land in it.
    private func offerType(_ act: ActionRequest, at axPoint: CGPoint,
                           position: (index: Int, of: Int)? = nil) async -> StepOutcome {
        guard let text = act.textToType else {
            return .stopped(line: "That ask was not a type act.")
        }
        guard let field = AXTDriver.typeTarget(label: act.label, at: axPoint) else {
            var reason = AXTDriver.TypeResult.noField(containing: axPoint).userFacingReason
            // The common case has a name for it. Measured 2026-10-05 on WhatsApp's search box: the
            // point holds an `AXStaticText "Search"` that answers `AXPress` and is not a field —
            // the field only exists after it is pressed. "There is no text field there" is true and
            // useless; the useful sentence says what to do instead.
            if let opener = AXTDriver.target(label: act.label, at: axPoint) {
                reason = "\(opener.info.elementLabel) is not a field yet — press it first, "
                    + "then type in the next step."
            }
            hud.reportConfirm(reason)
            Log.write("type: no field at \(axPoint) — asked \"\(act.label)\"")
            return .stopped(line: reason)
        }
        let element = field.info
        Log.write("type: \(field.snapped ? "aim missed, answered by name" : "field") — "
            + "\"\(act.label)\" → \(element.role ?? "-")/\(element.elementLabel) at "
            + "\(element.frame.map { "(\($0.midX), \($0.midY))" } ?? "-")")

        let bundleID = bundleID(of: element)
        let decision = PolicyGate.decide(target: element.policyTarget(bundleID: bundleID),
                                         alwaysAllowedBundleIDs: alwaysAllowedBundleIDs,
                                         askBeforePressing: askBeforeActing)
        switch decision {
        case .forbidden(let reason):
            hud.reportConfirm(reason)
            Log.write("type: forbidden — \(reason)")
            return .stopped(line: reason)

        case .allowedWithoutAsking:
            let result = await typeAct(act, at: axPoint, approved: element)
            return result.happened ? .done(line: result.line) : .stopped(line: result.line)

        case .needsConsent:
            consentGate.cancel()
            consentGate.stage(.press(act))
            pendingPress = PendingPress(act: act, axPoint: axPoint, bundleID: bundleID,
                                        element: element)
            hud.onConfirmAnswer = { [weak self] outcome in
                self?.answerAct(outcome)
            }
            let appName = PolicyGate.displayName(of: element.policyTarget(bundleID: bundleID))
            let field = AXTDriver.fieldLabel(for: element)
            var question = "Type \"\(text)\" into \(field) in \(appName)?"
            if let position { question += " (step \(position.index) of \(position.of))" }
            hud.askConfirm(question)
            Log.write("type: asking — \(appName)/\(field) \(text.count) characters")
        }
        return .asked
    }

    /// Type into the approved field — *only* if that field is still the one at those pixels.
    ///
    /// The same re-read a press gets, and then one more check the press path does not need: the
    /// driver will not post a character until the field it was aimed at is the field the app says
    /// has focus, because keystrokes go wherever the cursor is and not where they were sent.
    private func typeAct(_ act: ActionRequest, at axPoint: CGPoint,
                         approved: AXElementInfo) async -> (line: String, happened: Bool) {
        guard let text = act.textToType else { return ("Nothing was typed.", false) }
        guard let now = AXTDriver.typeTarget(label: act.label, at: axPoint), now.info == approved
        else {
            let line = "That field moved or closed, so Chunks did not type into it."
            hud.reportConfirm(line)
            Log.write("type: field gone or drifted at \(axPoint) — approved \(approved.elementLabel)")
            return (line, false)
        }
        let result = AXTDriver.type(text, into: now)
        hud.reportConfirm(result.userFacingReason)
        Log.write("type: \(act.label) → \(result.userFacingReason)")
        return (result.userFacingReason, result.didType)
    }

    /// Put a `[SCROLL:…]` through the same policy and consent chain a press uses.
    ///
    /// The question names the *scroller* the hit test found rather than the row the model aimed
    /// at, because that is the thing that will move: "Scroll chat list down?" is checkable against
    /// the screen, "Scroll Nitesh down?" is not.
    private func offerScroll(_ act: ActionRequest, direction: ActionRequest.ScrollDirection,
                             pages: Int, at axPoint: CGPoint,
                             position: (index: Int, of: Int)? = nil) async -> StepOutcome {
        guard let scroller = AXTDriver.scrollTarget(direction: direction, label: act.label,
                                                    at: axPoint) else {
            let reason = AXTDriver.ScrollResult.noScrollableElement(
                containing: axPoint).userFacingReason
            hud.reportConfirm(reason)
            Log.write("scroll: nothing scrollable at \(axPoint) — asked \"\(act.label)\"")
            return .stopped(line: reason)
        }
        let element = scroller.info
        Log.write("scroll: \(scroller.snapped ? "aim missed, found the scroller by search" : "scroller") — "
            + "\"\(act.label)\" → \(element.role ?? "-")/\(element.elementLabel) "
            + "verb=\(scroller.action) pagesPerStep=\(scroller.movesPages ? "page" : "line")")

        let bundleID = bundleID(of: element)
        let decision = PolicyGate.decide(target: element.policyTarget(bundleID: bundleID),
                                         alwaysAllowedBundleIDs: alwaysAllowedBundleIDs,
                                         askBeforePressing: askBeforeActing)
        switch decision {
        case .forbidden(let reason):
            hud.reportConfirm(reason)
            Log.write("scroll: forbidden — \(reason)")
            return .stopped(line: reason)

        case .allowedWithoutAsking:
            let result = await scrollAct(act, direction: direction, pages: pages, at: axPoint,
                                         approved: element)
            return result.happened ? .done(line: result.line) : .stopped(line: result.line)

        case .needsConsent:
            consentGate.cancel()
            consentGate.stage(.press(act))
            pendingPress = PendingPress(act: act, axPoint: axPoint, bundleID: bundleID,
                                        element: element)
            hud.onConfirmAnswer = { [weak self] outcome in
                self?.answerAct(outcome)
            }
            var question = ActionRequest.scrollQuestion(elementLabel: act.label,
                                                        direction: direction, pages: pages)
            if let position { question += " (step \(position.index) of \(position.of))" }
            hud.askConfirm(question)
            Log.write("scroll: asking — \(element.elementLabel) \(direction.phrase) \(pages)")
        }
        return .asked
    }

    /// Scroll the approved list — *only* if the same list is still there.
    private func scrollAct(_ act: ActionRequest, direction: ActionRequest.ScrollDirection,
                           pages: Int, at axPoint: CGPoint,
                           approved: AXElementInfo) async -> (line: String, happened: Bool) {
        guard let now = AXTDriver.scrollTarget(direction: direction, label: act.label, at: axPoint),
              now.info == approved else {
            let line = "That list moved or closed, so Chunks did not scroll it."
            hud.reportConfirm(line)
            Log.write("scroll: scroller gone or drifted at \(axPoint) — approved \(approved.elementLabel)")
            return (line, false)
        }
        let result = AXTDriver.scroll(direction, pages: pages, into: now)
        hud.reportConfirm(result.userFacingReason)
        Log.write("scroll: \(act.label) → \(result.userFacingReason)")
        return (result.userFacingReason, result.didScroll)
    }

    /// Press the approved control — *only* if the same control is still there.
    ///
    /// A card can sit open while the app relayouts, a dialog closes, or a list scrolls, and with
    /// asking switched off the gap between resolving and pressing is shorter but not zero. So the
    /// target is resolved again and compared element-for-element before anything runs: Chunks
    /// never presses whatever moved under the pixels that were asked about.
    ///
    /// Returns the line now on the card, so a caller that pressed without asking can say it too.
    ///
    /// Awaits up to two and a half seconds after an app that answered the press with an error,
    /// because the error code is the target's bookkeeping and not its behaviour: a live press of a
    /// desktop icon returned `-25205` *and* launched the app — the user's own screenshot showed its
    /// privacy dialog — and Chunks told them the app had refused it. The check therefore compares
    /// what was running and focused before the press to what is after, instead of asking whether
    /// the pressed element's own app came forward: that pid is Finder's for every desktop icon.
    @discardableResult
    private func pressAct(_ act: ActionRequest, at axPoint: CGPoint,
                          approved: AXElementInfo) async -> (line: String, happened: Bool) {
        guard let now = AXTDriver.target(label: act.label, at: axPoint) else {
            let line = "That control moved or closed, so Chunks did not press it."
            hud.reportConfirm(line)
            Log.write("act: target gone at \(axPoint) — approved \(approved.elementLabel)")
            return (line, false)
        }
        if now.info != approved {
            let line = "That control moved or closed, so Chunks did not press it."
            hud.reportConfirm(line)
            Log.write("act: target drifted — approved \(approved.role ?? "-")/"
                      + "\(approved.elementLabel), now \(now.info.role ?? "-")/\(now.info.elementLabel)")
            return (line, false)
        }
        // Read *before* pressing: after the press the answer is already contaminated by the very
        // activation this check is looking for.
        let snapshotBefore = AXTDriver.pressSnapshot()
        let pressed = AXTDriver.press(now)
        let result: AXTDriver.PressResult
        if case .actionFailed(let code, let action, _, let element) = pressed,
           AXTDriver.isAmbiguousFailure(code),
           await AXTDriver.waitForLanding(label: act.label, before: snapshotBefore) {
            // Logged before the reclassification, so the audit trail keeps the code the app
            // actually returned even though the user is told the truth: it opened.
            Log.write("act: \(action) returned \(code) but the effect happened anyway — "
                      + "element \(element.appName ?? "pid \(element.pid)")/"
                      + "\(element.elementLabel), asked for \(act.label)")
            result = .landedByEffect(element: element, action: action, code: code)
        } else {
            result = pressed
        }
        hud.reportConfirm(result.userFacingReason)
        Log.write("act: \(act.label) → \(result.userFacingReason)")
        return (result.userFacingReason, result.didPress)
    }

    // MARK: - Running a tool

    /// Put a `[DO:…]` proposal on the same card a press uses, and stop there.
    ///
    /// There is no `PolicyGate` step because a tool has no on-screen target to classify — the
    /// policy is the type itself: `DoRequest` only has cases whose entire effect fits in the
    /// sentence `ToolLayer.question(for:)` produces. Anything the model invents fails to parse
    /// and reaches the user as text, never as a run.
    private func offerTool(_ request: DoRequest) {
        if !askBeforeActing {
            // The same standing instruction that skips the press question. `DoRequest` still has
            // to have parsed into an effect that fits one sentence, so what runs here is exactly
            // what `ToolLayer.question(for:)` would have described.
            Log.write("tool: acting — \(ToolLayer.question(for: request))")
            runTool(request)
            return
        }
        consentGate.cancel()
        consentGate.stage(.tool(request))
        pendingPress = nil
        hud.onConfirmAnswer = { [weak self] outcome in
            self?.answerAct(outcome)
        }
        let question = ToolLayer.question(for: request)
        hud.askConfirm(question)
        Log.write("tool: asking — \(question)")
    }

    /// Run what the user just approved, and say in one line whether it happened.
    private func runTool(_ request: DoRequest) {
        Task {
            let succeeded = await ToolRunner.run(request)
            let line = ToolLayer.outcomeLine(for: request, succeeded: succeeded)
            hud.reportConfirm(line)
            Log.write("tool: \(line)")
        }
    }

    /// Acts the model proposed that the card never asked about.
    ///
    /// One card holds one question, so a reply carrying more than one proposal is a malformed
    /// reply and the extras are not run. This is the only trace that they were requested at all
    /// — without it, "the model asked for three things and I was asked about one" is invisible.
    /// Log what a reply asked for that this turn will not do.
    ///
    /// A plan longer than `ActionRequest.maxProgramSteps` is truncated rather than refused, and a
    /// tool proposed alongside a plan is dropped. Both have to be visible in the log, because the
    /// model's own words will already have promised every part of it.
    private func logUnaskedProposals(streamer: AnswerStreamer, ranSteps: Int) {
        let acts = streamer.actionRequests.count
        var dropped: [String] = []
        if acts > ranSteps { dropped.append("\(acts - ranSteps) step(s) past the plan limit") }
        if acts > 0, !streamer.toolRequests.isEmpty {
            dropped.append("\(streamer.toolRequests.count) tool request(s) behind a plan")
        }
        guard !dropped.isEmpty else { return }
        Log.write("act: dropped, never asked — \(dropped.joined(separator: "; "))")
    }

    private func bundleID(of element: AXElementInfo) -> String? {
        NSRunningApplication(processIdentifier: pid_t(element.pid))?.bundleIdentifier
    }

    /// Resolve an act target into the space the Accessibility hit test works in: global
    /// **top-left** logical points.
    ///
    /// This goes through `ScreenshotGeometry` and nowhere else, because the model's numbers are
    /// proportions of the *resized* screenshot it was shown. Reusing the cursor trailer's
    /// hand-rolled scaling here would be the Retina double-offset bug invariant 1 names, and it
    /// would land the press somewhere plausible rather than failing.
    private func actPoint(_ act: ActionRequest,
                          screenCaptures: [CompanionScreenCapture]) -> CGPoint? {
        let target = act.target
        guard !screenCaptures.isEmpty else { return nil }
        let capture: CompanionScreenCapture = {
            if target.display >= 1, target.display <= screenCaptures.count {
                return screenCaptures[target.display - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures[0]
        }()

        guard let appKit = ScreenshotGeometry.appKitGlobalPoint(
            x: target.x,
            y: target.y,
            imageWidth: Double(capture.screenshotWidthInPixels),
            imageHeight: Double(capture.screenshotHeightInPixels),
            displayFrame: capture.displayFrame
        ) else { return nil }

        // Only the exception is logged: an answer over 1000 means the model used the image's pixel
        // dimensions instead of the grid the prompt asks for, and an aim that then lands somewhere
        // odd is a different bug from a model that mis-saw the screen.
        if ScreenshotGeometry.aimSpace(x: target.x, y: target.y) == .imagePixels {
            Log.write("act: \(act.label) answered in image pixels, not the 0–1000 grid")
        }

        // The screen that owns the global origin is `NSScreen.screens.first`; its height is the
        // only number that turns AppKit's bottom-left Y into the top-left Y AX hit-tests in.
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? capture.displayFrame.height)
        return ScreenshotGeometry.axGlobalPoint(appKitGlobalPoint: appKit,
                                                primaryScreenHeight: primaryHeight)
    }

    /// ⌃⌥⌘D: start a circle-to-explain, or close the markup panel that is already open.
    func toggleCircleToExplain() {
        Log.write("annotate: chord received")
        if let activeOverlay {
            self.activeOverlay = nil
            activeOverlay.dismissByChord()
            return
        }
        if let activeMarkup {
            self.activeMarkup = nil
            activeMarkup.dismissByChord()
            return
        }
        // The selection step is owned by macOS, whose crosshair takes Escape as cancel; a second
        // chord while one is in flight would queue a second question about a screen that has not
        // finished being chosen.
        guard !isSelectingRegion else {
            Log.write("annotate: a selection is already in flight — ignored")
            return
        }
        // The chord starts with Control, which is the talk key. Without this, reaching for
        // ⌃⌥⌘D arms a dictation on the way in, and the drawing session and a live microphone
        // would both be waiting on the same Return key — one of them gets an answer the user
        // never asked for. Discarded, not submitted: an unfinished dictation is not a question.
        if buddyDictationManager.isDictationInProgress {
            buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
            Log.write("annotate: cancelled the dictation the chord's Control had started")
        }
        beginCircleToExplain()
    }

    /// The region the user selected, waiting for the one turn that will explain it.
    ///
    /// Consumed once on purpose: a stale crop would make the next three questions all be about a
    /// rectangle drawn a minute ago, which is worse than not remembering.
    private var pendingRegionCapture: CompanionScreenCapture?

    private func consumePendingRegionCapture() -> CompanionScreenCapture? {
        defer { pendingRegionCapture = nil }
        return pendingRegionCapture
    }

    /// ⌃⌥⌘D: draw on the live screen, and ask about what was circled.
    func beginCircleToExplain() {
        guard let screen = NSScreen.main, let display = CaptureEngine.mainDisplay() else {
            Log.write("annotate: cannot draw — no display to draw on, falling back to the selector")
            beginRegionSelection()
            return
        }
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        let overlay = AnnotationOverlayWindow(display: display) { [weak self] shapes, spoken in
            guard let self else { return }
            self.activeOverlay = nil
            guard !shapes.isEmpty else {
                Log.write("annotate: nothing drawn, no question asked")
                return
            }
            Task { @MainActor in await self.explainCircledRegion(shapes: shapes, spoken: spoken,
                                                                screen: screen, display: display) }
        }
        // Read before the surface closes: `onDismissed` discards an uncommitted dictation, and a
        // transcript read after that is empty — which would silently replace the question he
        // actually spoke with the default one.
        overlay.transcriptProvider = { [weak self] in
            self?.buddyDictationManager.currentTranscriptText ?? ""
        }
        overlay.onDismissed = { [weak self, weak overlay] in
            if let overlay, self?.activeOverlay === overlay { self?.activeOverlay = nil }
            self?.discardDrawingDictation()
        }
        activeOverlay = overlay
        guard overlay.show() else {
            activeOverlay = nil
            Log.write("annotate: the surface refused to open — using the system selector instead")
            beginRegionSelection()
            return
        }
        startDrawingDictation()
    }

    /// Open the microphone with the drawing surface, so the question is spoken over the mark
    /// instead of typed afterwards or guessed at from a default.
    ///
    /// Chunks submits it, not the dictation session: `Return` reads the transcript, cancels the
    /// session, and asks with the crop attached. Letting the session submit on stop would fire a
    /// turn before the region had been captured, and the model would answer about the whole screen
    /// rather than the part he drew on.
    private func startDrawingDictation() {
        guard !buddyDictationManager.isDictationInProgress else { return }
        Task { @MainActor in
            await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                currentDraftText: "",
                updateDraftText: { [weak self] partialTranscript in
                    Task { @MainActor [weak self] in self?.hud.showCaption(partialTranscript) }
                },
                submitDraftText: { finalTranscript in
                    // Never reached: the session is cancelled, not stopped, by every exit this
                    // surface has. An empty closure is the honest place to say so.
                    Log.write("annotate: dictation tried to submit on its own — ignored, "
                        + "\(finalTranscript.prefix(60))")
                }
            )
            Log.write("annotate: microphone open with the drawing surface")
        }
    }

    /// Silence the microphone without asking anything — every exit that is not `Return`.
    ///
    /// A dictation left running past the surface would submit its transcript to the *next* thing he
    /// does, which is the failure the tap-to-arm work already had to design around.
    private func discardDrawingDictation() {
        guard buddyDictationManager.isDictationInProgress else { return }
        buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
        Log.write("annotate: microphone discarded with the surface")
    }

    /// Crop around the marks, composite them into the capture, and ask about exactly that.
    ///
    /// `RegionResolver` decides the crop — the same maths the unit tests cover — rather than a
    /// rectangle computed here, so what the model is shown and what the tests assert cannot drift.
    private func explainCircledRegion(shapes: [AnnotationShape], spoken: String, screen: NSScreen,
                                      display: DisplayInfo) async {
        do {
            let shot = try await CaptureEngine().capture(display: display, shapes: shapes)
            let image = shot.composited(with: shapes, display: display)
            guard let png = ScreenCapture(image: image, globalRect: shot.globalRect).png() else {
                hud.fail("The circled region could not be read.")
                return
            }
            let region = RegionResolver.resolve(shapes: shapes, displaySize: display.size)
            Log.write("annotate: \(shapes.count) mark(s) → crop x=\(Int(region.minX)) "
                + "y=\(Int(region.minY)) w=\(Int(region.width)) h=\(Int(region.height)) "
                + "→ \(image.width)x\(image.height)px")
            pendingRegionCapture = CompanionScreenCapture(
                imageData: png,
                label: "The region the user circled on their screen",
                isCursorScreen: true,
                displayWidthInPoints: Int(screen.frame.width),
                displayHeightInPoints: Int(screen.frame.height),
                displayFrame: screen.frame,
                screenshotWidthInPixels: image.width,
                screenshotHeightInPixels: image.height)
            // His words if he spoke any; the standing question if he only drew. Both are real
            // gestures — the surface must not need a keyboard to be useful.
            ask(text: spoken.isEmpty
                ? "What is the part I circled, and what is it for?"
                : spoken)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.write("annotate: capture failed — \(detail)")
            hud.fail("Chunks could not capture the region you circled.")
        }
    }

    /// The fallback gesture, and the one that works today: macOS chooses the region with its own
    /// crosshair, then Chunks marks up the crop in a panel. Used when the display-sized surface
    /// cannot be shown, because that surface's hold on the mouse is the thing still in question.
    func beginRegionSelection() {
        guard let screen = NSScreen.main else {
            Log.write("annotate: refused — no main screen")
            hud.fail("Chunks cannot see the screen to choose a region on.")
            return
        }
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        isSelectingRegion = true
        Task { @MainActor in
            defer { self.isSelectingRegion = false }
            guard let png = await RegionSelector.capture() else { return }
            self.beginMarkup(for: png, on: screen)
        }
    }

    /// The drawing step, in a panel the size of the crop.
    ///
    /// Deliberately not a display-sized surface — `CropMarkupWindow` carries the three measurements
    /// that settled that argument. The crop is frozen, so what the user draws on cannot move under
    /// his pen, and nothing of Chunks' covers his desktop while he does it.
    private func beginMarkup(for png: Data, on screen: NSScreen) {
        guard let rep = NSBitmapImageRep(data: png), rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            Log.write("annotate: the selection could not be read — \(png.count) bytes")
            hud.fail("Chunks could not read the region you selected.")
            return
        }
        let pixelSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        guard let markup = CropMarkupWindow(
            png: png, pixelSize: pixelSize,
            onSubmit: { [weak self] marked in
                guard let self else { return }
                self.activeMarkup = nil
                self.explainSelectedRegion(png: marked, screen: screen)
            },
            onCancel: { [weak self] in self?.activeMarkup = nil }
        ) else {
            Log.write("annotate: the crop could not be opened — \(png.count) bytes")
            hud.fail("Chunks could not open the region you selected.")
            return
        }
        activeMarkup = markup
        markup.show(on: screen)
    }

    /// Ask about the crop, with the user's marks already burned into it.
    ///
    /// The image arrives cropped and marked, so no `RegionResolver` maths runs on this path — the
    /// crop is the user's own selection and the marks are his own, both in that image's pixel space.
    private func explainSelectedRegion(png: Data, screen: NSScreen) {
        guard let image = NSBitmapImageRep(data: png), image.pixelsWide > 0, image.pixelsHigh > 0 else {
            Log.write("annotate: the selection could not be read — \(png.count) bytes")
            hud.fail("Chunks could not read the region you selected.")
            return
        }
        pendingRegionCapture = CompanionScreenCapture(
            imageData: png,
            label: "The region the user selected and drew on",
            isCursorScreen: true,
            displayWidthInPoints: Int(screen.frame.width),
            displayHeightInPoints: Int(screen.frame.height),
            displayFrame: screen.frame,
            screenshotWidthInPixels: image.pixelsWide,
            screenshotHeightInPixels: image.pixelsHigh)
        Log.write("annotate: region selected — \(image.pixelsWide)x\(image.pixelsHigh)px, asking")
        ask(text: "What is the part I selected, and what is it for?")
    }

    /// Run a turn from typed or tapped text instead of the microphone — this is what a tapped
    /// suggestion chip on the HUD calls.
    ///
    /// The question goes down the same path a spoken one would, so the card, the conversation
    /// history and the next round of suggestions behave identically whichever way the turn
    /// started.
    func ask(text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        lastTranscript = question
        sendTranscriptToBrainWithScreenshot(transcript: question)
    }

    /// Runs one turn: capture the screens, ask the model, stream the answer onto the notch
    /// HUD, point the cursor at whatever the reply names, and read the completion line aloud.
    ///
    /// The reply is parsed once, by `AnswerStreamer`, and everything downstream is a consumer
    /// of what it resolves to — the card shows `speech`/`detail`/chips, the speaker gets
    /// `utterance`, the cursor takes `points.first`. Nothing re-reads the raw text, so a tag
    /// cannot be half-handled by one consumer and missed by another.
    private func sendTranscriptToBrainWithScreenshot(transcript: String) {
        // A request from the user restarts the plan budget; a continuation of the plan already
        // running spends it. Recognised by the flag rather than by the words, so a user who says
        // "continue" still gets a fresh four rounds.
        if isContinuingPlan {
            isContinuingPlan = false
        } else {
            planRound = 0
        }
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing
            hud.beginThinking()

            // Carried out of the `do` so the next round of a plan can start after the speech has
            // finished, rather than over the top of it.
            var pendingContinuation: String?
            var planStepCompleted = false

            do {
                // A circled region replaces the whole-screen capture for exactly one turn.
                let regionCapture = self.consumePendingRegionCapture()
                let screenCaptures: [CompanionScreenCapture]
                if let regionCapture {
                    screenCaptures = [regionCapture]
                } else {
                    // Capture all connected screens so the AI has full context
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                }

                guard !Task.isCancelled else { return }

                // Each image is labelled with its own size *and* the grid to aim in, because the
                // space a reply comes back in is decided at the picture, not in a prompt the model
                // has already scrolled past. `ScreenshotGeometry` owns both halves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = ScreenshotGeometry.coordinateSpaceNote(
                        imageWidth: capture.screenshotWidthInPixels,
                        imageHeight: capture.screenshotHeightInPixels)
                    return (data: capture.imageData, label: capture.label + " " + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                // One parser for the whole reply, fed as the deltas arrive. `AnswerStreamer`
                // holds back the ambiguous tail of a split tag, so markup never reaches the
                // card — and the returned raw text is not parsed a second time, because a
                // second parse is a second opinion about what the model said.
                let streamer = AnswerStreamer()

                _ = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: companionPromptWithMemory(),
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { delta in
                        streamer.push(delta)
                        hud.apply(streamer)
                    }
                )

                guard !Task.isCancelled else { return }

                streamer.finish()
                if streamer.hasAnything {
                    hud.finish(from: streamer)
                } else {
                    // A 200 response that parses to nothing is a real outcome, and an empty
                    // card would look like the HUD broke rather than like the model stalled.
                    hud.fail("The model replied without saying anything.")
                }

                // Memory is applied once the reply is complete, never mid-stream: a partially
                // received `<MEMORY>` block is not a proposal, and validating fragments is how
                // half a fact becomes a stored fact.
                if let proposal = streamer.proposal {
                    applyMemory(proposal)
                }

                // What gets read aloud is the model's own completion line: `<SUMMARY>` when it
                // offered one, otherwise the `<SAY>` text. The raw reply is markup and must
                // never reach the speaker.
                let spokenText = streamer.utterance
                // A crop has no honest route back to screen coordinates: `ScreenshotGeometry`
                // maps an aim as a proportion of the display the image covers, and a crop covers a
                // fraction of it. Pointing there would land somewhere plausible and wrong, so the
                // answer is kept and the pointing is skipped, out loud.
                let point = regionCapture == nil ? streamer.points.first : nil
                if regionCapture != nil, streamer.points.first != nil {
                    Log.write("annotate: reply named a point inside a crop — pointing skipped, "
                        + "a crop has no screen coordinate to aim at")
                }

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                if point != nil {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = point?.display,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let point, let targetScreenCapture,
                   let globalLocation = ScreenshotGeometry.appKitGlobalPoint(
                        x: point.x,
                        y: point.y,
                        imageWidth: Double(targetScreenCapture.screenshotWidthInPixels),
                        imageHeight: Double(targetScreenCapture.screenshotHeightInPixels),
                        displayFrame: targetScreenCapture.displayFrame) {
                    // The same call an `[ACT]` goes through, so the triangle the user watches and
                    // the press the driver aims cannot disagree about where a number landed. The
                    // vendored version of this scaled by `displayWidthInPoints` and clamped to the
                    // image's own pixel size, which was a second coordinate authority.
                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = targetScreenCapture.displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: point.label)
                    print("🎯 Element pointing: (\(Int(point.x)), \(Int(point.y))) → \"\(point.label)\"")
                } else {
                    print("🎯 Element pointing: no element")
                }

                // An act is offered only once the reply is complete: mid-stream the card is
                // still being written, and a question that moves between deltas is a question
                // the user cannot read, let alone answer.
                //
                // Several act tags in one reply are an ordered plan, not a choice between them —
                // "message Nitesh that good night" is four acts and a card that could hold one
                // would do none of them. A tool proposed alongside the plan is *not* run: an
                // unanswered request fails toward doing nothing, never toward doing both.
                var actOutcome: String?
                var planAdvanced = false
                let proposed = streamer.actionRequests
                if !proposed.isEmpty {
                    let program = Array(proposed.prefix(ActionRequest.maxProgramSteps))
                    switch await offerProgram(program, screenCaptures: screenCaptures) {
                    case .done(let line):
                        actOutcome = line
                        // Every step this reply could aim has happened. That is the only state in
                        // which looking again is safe: a stopped plan means the screen is not the
                        // one the remaining steps were aimed at, and pressing on from there is how
                        // an assistant types into the wrong window.
                        planAdvanced = true
                    case .stopped(let line):
                        actOutcome = line
                    case .asked: break
                    }
                    logUnaskedProposals(streamer: streamer, ranSteps: program.count)
                } else if let tool = streamer.toolRequests.first {
                    offerTool(tool)
                    // With asking off the tool has already run, so the plan moved. With asking on
                    // there is a card outstanding, and the next look would be asking about a
                    // screen the user has not yet agreed to change.
                    planAdvanced = !consentGate.isPending
                    logUnaskedProposals(streamer: streamer, ranSteps: 1)
                }
                pendingContinuation = streamer.continuation
                // A round that asked for nothing to happen is not a failed step — it is a look that
                // found nothing yet. Once a plan is genuinely under way, that deserves another look
                // instead of an apology, because a cold launch can beat even the recapture delay.
                // Outside a plan it does not: a model that merely mentions `<CONTINUE>` after an
                // ordinary answer must not spend four model calls on itself.
                planStepCompleted = planAdvanced || (planRound > 0 && proposed.isEmpty
                    && streamer.toolRequests.isEmpty)

                // Save this exchange to conversation history, with the tags resolved rather
                // than stripped: what the user was *shown* is what the next turn has to
                // remember, and the detail is where a thorough answer put its steps.
                let shownAnswer = [streamer.speech, streamer.detail]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: shownAnswer.isEmpty ? spokenText : shownAnswer
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                //
                // What happened to the act is said, not just written to the card. A refusal,
                // because the model has usually spent its spoken sentence promising "I'll ask you
                // to allow it", so a card that silently never asks reads as the feature being
                // broken rather than as the spot being empty. And a press that ran without a
                // question, because with asking off there is no card — the one line the driver
                // returns is the only place the user learns anything happened at all.
                var saying = spokenText
                if let outcome = actOutcome,
                   !outcome.isEmpty {
                    saying += saying.isEmpty ? outcome : " " + outcome
                }
                if !saying.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await ttsClient.speakText(saying)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted, and the new press already
                // put the HUD back into its listening state.
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                Log.write("turn failed: \(Log.userMessage(for: error))")
                hud.fail(Log.userMessage(for: error))
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
                // After the speech, not during it: the next round starts a new card and cuts off
                // whatever is still being said, so a plan that continued here would talk over
                // itself and the user would hear half of each step.
                continuePlanIfNeeded(remaining: pendingContinuation, stepCompleted: planStepCompleted)
            }
        }
    }

    /// Carry a multi-step request into the next look at the screen.
    ///
    /// The step's own line has already been spoken and the card already shows it, so what arrives
    /// next reads as a continuation rather than a new answer. Bounded by `maxPlanRounds`, and only
    /// taken when the step actually happened — see the caller.
    private func continuePlanIfNeeded(remaining: String?, stepCompleted: Bool) {
        guard let remaining, !remaining.isEmpty else { return }
        guard stepCompleted else {
            Log.write("plan: not continuing — the last step did not complete: \(remaining)")
            return
        }
        guard planRound < Self.maxPlanRounds else {
            Log.write("plan: stopped at \(Self.maxPlanRounds) rounds with this left — \(remaining)")
            hud.fail("I stopped after \(Self.maxPlanRounds) steps. Say the word and I'll carry on.")
            return
        }
        planRound += 1
        isContinuingPlan = true
        Log.write("plan: round \(planRound) of \(Self.maxPlanRounds) — \(remaining)")
        Task { @MainActor in
            // Let whatever the last step opened finish drawing before it is photographed again —
            // logged, because "it captured too early" is only diagnosable if the log says when the
            // look actually happened.
            Log.write("plan: recapturing in \(String(format: "%.1f", Double(Self.planRecaptureDelay) / 1_000_000_000))s")
            try? await Task.sleep(nanoseconds: Self.planRecaptureDelay)
            ask(text: "Continue: \(remaining)")
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I can't reach the model right now. Chunks will try again in a moment."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    // MARK: - Onboarding Intro

    /// The three beats a new user gets, timed locally with no network asset: the cursor
    /// says who it is, it flies to something real on screen so the pointing is visible
    /// before it is trusted, then it says how to talk.
    ///
    /// Called by `BlueCursorView` once the typed welcome line has faded.
    func startIntroSequence() {
        cancelIntro()
        // The notch gets the first thing it is going to say, so the surface a user will
        // rely on for the rest of the app is introduced before it is needed.
        hud.showHint("hold control + option to talk", for: 12)

        introTasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled else { return }
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self.performOnboardingDemoInteraction()
        })
        introTasks.append(Task { [weak self] in
            // Long enough for the flight to the element and the phrase over it to be read.
            try? await Task.sleep(for: .seconds(7.0))
            guard let self, !Task.isCancelled else { return }
            self.startOnboardingPromptStream()
        })
    }

    func cancelIntro() {
        introTasks.forEach { $0.cancel() }
        introTasks.removeAll()
    }

    /// Streams the "hold the hot key" prompt onto the cursor, then fades itself out.
    ///
    /// Timed with a `Timer` rather than a `Task` because it is a character-by-character
    /// typewriter: cancelling mid-word is the behaviour we want when the user starts talking
    /// early, and the press handler already dismisses the bubble.
    private func startOnboardingPromptStream() {
        let message = "hold control + option and ask about anything on screen"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're chunks, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    aim with a 0–1000 grid over the screenshot: x=0 is the left edge, x=1000 the right edge, y=0 the top, y=1000 the bottom. the middle is (500,500). not pixels — the picture's pixel size in the label is not the space to answer in.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = ScreenshotGeometry.coordinateSpaceNote(
                    imageWidth: cursorScreenCapture.screenshotWidthInPixels,
                    imageHeight: cursorScreenCapture.screenshotHeightInPixels)
                let labeledImages = [(data: cursorScreenCapture.imageData,
                                      label: cursorScreenCapture.label + " " + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                // The one mapping the whole app uses, so the demo's triangle flies to the same
                // pixel an `[ACT]` would be aimed at.
                guard let globalLocation = ScreenshotGeometry.appKitGlobalPoint(
                    x: Double(pointCoordinate.x),
                    y: Double(pointCoordinate.y),
                    imageWidth: Double(cursorScreenCapture.screenshotWidthInPixels),
                    imageHeight: Double(cursorScreenCapture.screenshotHeightInPixels),
                    displayFrame: cursorScreenCapture.displayFrame
                ) else {
                    print("🎯 Onboarding demo: the capture reported no size")
                    return
                }

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = cursorScreenCapture.displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
