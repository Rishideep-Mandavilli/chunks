import AppKit
import AVFoundation
import ChunksKit
import SwiftUI

/// What a permission row's buttons actually do, shared by the panel and the setup window.
///
/// The panel owned this switch; the setup window needs the same five buttons, and a second copy
/// would be the exact drift `PermissionRow` exists to prevent — two restart paths that disagree
/// about what restarts.
@MainActor
enum PermissionActions {
    static func apply(_ action: PermissionRow.Action, to row: PermissionRow,
                      via manager: CompanionManager) {
        switch action {
        case .restart:
            manager.restartToApplyPermissions()
        case .findApp:
            WindowPositionManager.revealAppInFinder()
            WindowPositionManager.openAccessibilitySettings()
        case .grant:
            switch row.kind {
            case .microphone:
                let status = AVCaptureDevice.authorizationStatus(for: .audio)
                if status == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                } else {
                    openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                }
            case .accessibility:
                WindowPositionManager.requestAccessibilityPermission()
            case .inputMonitoring:
                WindowPositionManager.requestInputMonitoringPermission()
            case .screenRecording:
                WindowPositionManager.requestScreenRecordingPermission()
            case .screenContent:
                manager.requestScreenContentPermission()
            }
        }
    }

    static func openSettings(_ scheme: String) {
        guard let url = URL(string: scheme) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The setup flow's live snapshot, polled while the window is open.
///
/// Permissions change in System Settings — outside this process, with no callback — so the window
/// re-reads once a second while it is visible. A flow that showed yesterday's grant state would
/// tell the user to press Restart for a tick they already gave.
@MainActor
final class FirstRunModel: ObservableObject {
    @Published var plan: FirstRunPlan
    @Published var keyDraft = ""
    @Published var keyMessage: String?

    /// Nil in the render probe, which draws the three steps from fixture plans — the same reason
    /// `CompanionWindowModel` exists: a surface that needs the live pipeline cannot be drawn
    /// offscreen, and a surface that cannot be drawn cannot be checked.
    private let manager: CompanionManager?
    private let fixtureOfflineSummary: String
    private let fixtureLoginDescription: String
    private var poll: Timer?

    /// Set by the window so "Done" can close it; the model itself never owns a surface.
    var onDone: (() -> Void)?

    init(manager: CompanionManager) {
        self.manager = manager
        self.fixtureOfflineSummary = ""
        self.fixtureLoginDescription = LoginItem.describe(.off)
        self.plan = Self.read(manager: manager)
    }

    init(fixturePlan: FirstRunPlan, offlineSummary: String, loginDescription: String) {
        self.manager = nil
        self.fixtureOfflineSummary = offlineSummary
        self.fixtureLoginDescription = loginDescription
        self.plan = fixturePlan
    }

    static func read(manager: CompanionManager) -> FirstRunPlan {
        FirstRunPlan(
            permissions: PermissionState(
                microphone: manager.hasMicrophonePermission,
                accessibility: manager.hasAccessibilityPermission,
                inputMonitoring: manager.hasInputMonitoringPermission,
                screenRecording: manager.hasScreenRecordingPermission,
                screenContent: manager.hasScreenContentPermission),
            hasKey: KeychainStore.hasKey,
            offlineBrainOn: manager.isOfflineBrainOn,
            finished: FirstRunStore.completed)
    }

    func startPolling() {
        guard manager != nil else { return }
        stopPolling()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    func stopPolling() { poll?.invalidate(); poll = nil }

    /// Re-reads the machine, keeping what the user has typed.
    func refresh() {
        guard let manager else { return }
        let draft = keyDraft, message = keyMessage
        plan = Self.read(manager: manager)
        keyDraft = draft
        keyMessage = message
    }

    func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let manager else { return }
        if manager.saveApiKey(trimmed) {
            keyDraft = ""
            keyMessage = nil
        } else {
            keyMessage = "The Keychain refused the write. Rebuild with a signing identity and try again."
        }
        refresh()
    }

    func setOffline(_ on: Bool) {
        guard let manager else {
            plan.offlineBrainOn = on
            return
        }
        manager.setOfflineBrain(on)
        refresh()
    }

    func setLogin(_ on: Bool) {
        guard let manager else { return }
        manager.setLaunchAtLogin(on)
        refresh()
    }

    func apply(_ action: PermissionRow.Action, to row: PermissionRow) {
        guard let manager else { return }
        PermissionActions.apply(action, to: row, via: manager)
    }

    var offlineSummary: String { manager?.offlineBrainSummary ?? fixtureOfflineSummary }
    var loginDescription: String {
        manager.map { LoginItem.describe($0.loginState) } ?? fixtureLoginDescription
    }
    var launchesAtLogin: Bool { manager?.launchesAtLogin ?? false }

    func finish() {
        FirstRunStore.completed = true
        Log.write("setup: Done pressed — the flow is closed and will not reopen by itself")
        refresh()
        onDone?()
    }
}

/// Whether this Mac has walked the setup flow. Keychain-free on purpose: it gates a window,
/// not a secret, and losing it should cost a repeat visit, never a key.
enum FirstRunStore {
    private static let key = "firstRunFinished"
    static var completed: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// The three-step window: grants, brain, keep-alive.
///
/// One step on screen at a time, in `FirstRunPlan`'s order, with the Continue button enabled only
/// when the plan says the step is done — so the flow cannot be walked in a way that leaves a
/// stranger at a dead end. Built to render from a plain model, which is what lets
/// `--render-setup` draw all three steps offscreen without a live pipeline.
struct FirstRunWindowView: View {
    @ObservedObject var model: FirstRunModel

    /// The setup guide's colour vocabulary, resolved to the dots warm-paper tokens — the same
    /// resolution as the panel and the window, so all three surfaces share one paper.
    private enum C {
        static var ground: Color { DS.Dots.paper }
        static var raised: Color { DS.Dots.raised }
        static var sunken: Color { DS.Dots.sunken }
        static var line: Color { DS.Dots.line }
        static var lineControl: Color { DS.Colors.lineControl }
        static var ink: Color { DS.Dots.ink }
        static var textPrimary: Color { DS.Dots.ink }
        static var inkMuted: Color { DS.Colors.inkMuted }
        static var inkFaint: Color { DS.Colors.inkFaint }
        static var onInk: Color { DS.Colors.onInk }
        static var action: Color { DS.Colors.action }
        static var warning: Color { DS.Colors.warning }
        static var warningText: Color { DS.Colors.warningText }
        static var successText: Color { DS.Colors.successText }
    }

    /// Each step wears one of the three measured fields behind its title — ink on a fill, which is
    /// the only legal way these pastels carry text. Permissions sea, brain sky, finish sand.
    private var stepField: Color {
        switch step {
        case .permissions: return DS.Dots.sea
        case .brain: return DS.Dots.sky
        case .finish: return DS.Dots.sand
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            DotsDashRule()
            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
            DotsDashRule()
            footer
        }
        .frame(width: 560, height: 520)
        .background(DS.Dots.paper)
        .overlay(DS.Dots.HatchPattern().allowsHitTesting(false))
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private var step: FirstRunStep { model.plan.currentStep }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(step.indexLabel)
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Dots.ink)
            Text(step.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(DS.Dots.ink)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stepField)
        .overlay(DS.Dots.HatchPattern().allowsHitTesting(false))
    }

    @ViewBuilder private var stepBody: some View {
        switch step {
        case .permissions: permissionsStep
        case .brain: brainStep
        case .finish: finishStep
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(PermissionState.rows(for: model.plan.permissions)) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.symbol)
                        .font(DS.Fonts.label)
                        .foregroundColor(row.isGranted ? C.inkMuted : C.warning)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(DS.Fonts.label)
                            .foregroundColor(C.textPrimary)
                        Text(row.purpose)
                            .font(DS.Fonts.meta)
                            .foregroundColor(C.inkFaint)
                    }
                    Spacer(minLength: 6)
                    if row.isGranted {
                        Text(row.stateWord)
                            .font(DS.Fonts.micro)
                            .foregroundColor(C.successText)
                    } else {
                        ForEach(row.actions, id: \.self) { action in
                            setupPill(action.title, primary: action == .grant, help: action.help) {
                                model.apply(action, to: row)
                            }
                        }
                    }
                }
                .padding(10)
                .physical(C.raised, radius: DS.CornerRadius.small, elevation: .raised,
                          edge: C.line)
            }
            Text(FirstRunPlan.restartSentence)
                .font(DS.Fonts.meta)
                .foregroundColor(C.inkFaint)
        }
    }

    private var brainStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(FirstRunPlan.keySentence)
                .font(DS.Fonts.label)
                .foregroundColor(C.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("AIza…", text: $model.keyDraft)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .physical(C.sunken, radius: DS.CornerRadius.small, elevation: .sunken,
                              edge: C.line)
                    .frame(maxWidth: .infinity)
                    .onSubmit(model.saveKey)
                setupPill("Save", primary: true, help: "Stores the key in your Mac's Keychain.") {
                    model.saveKey()
                }
            }
            if let message = model.keyMessage {
                Text(message)
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.warningText)
            }
            DotsDashRule()
            Toggle(isOn: Binding(get: { model.plan.offlineBrainOn },
                                 set: { model.setOffline($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Answer on this Mac")
                        .font(DS.Fonts.label)
                        .foregroundColor(C.textPrimary)
                    Text(FirstRunPlan.offlineSentence)
                        .font(DS.Fonts.meta)
                        .foregroundColor(C.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            Text(model.offlineSummary)
                .font(DS.Fonts.meta)
                .foregroundColor(C.inkMuted)
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { model.launchesAtLogin },
                                 set: { model.setLogin($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Start Chunks at login")
                        .font(DS.Fonts.label)
                        .foregroundColor(C.textPrimary)
                    Text("So the notch is there before you look for it. macOS may ask you to approve this once in System Settings.")
                        .font(DS.Fonts.meta)
                        .foregroundColor(C.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            Text("macOS says: \(model.loginDescription)")
                .font(DS.Fonts.meta)
                .foregroundColor(C.inkMuted)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack {
            Text(footnote)
                .font(DS.Fonts.meta)
                .foregroundColor(C.inkFaint)
            Spacer()
            if step == .finish {
                setupPill("Done", primary: true, help: "Close setup; Chunks is ready.") {
                    model.finish()
                }
            } else {
                setupPill("Continue", primary: model.plan.isComplete(step),
                          help: footnote) {
                    model.refresh()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Whether Continue moves — it does not; the machine does. The step advances when the plan's
    /// own rule says it is done, so the button's job is to re-read the grants and let the header
    /// change. The footnote says so, because a Continue that appears inert reads as a broken
    /// button. On the last step there is no next one, and saying otherwise is the kind of dead
    /// promise Tier 0 exists to delete — the render caught this line promising a step that does
    /// not exist.
    private var footnote: String {
        if step == .finish {
            return "Done closes setup. The panel can open it again."
        }
        return model.plan.isComplete(step)
            ? "Done here — the next step opens as soon as macOS agrees."
            : "Finish this step and the next one opens by itself."
    }

    private func setupPill(_ title: String, primary: Bool, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Fonts.micro)
                .foregroundColor(primary ? C.onInk : C.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .physical(primary ? C.action : C.raised,
                          radius: 999, elevation: .raised,
                          edge: primary ? C.ink : C.lineControl)
        }
        .buttonStyle(.plain)
        .disabled(title == "Continue" && !model.plan.isComplete(step))
        .help(help)
    }
}

/// The window that owns the flow, and the only thing that decides whether it is showing.
@MainActor
final class FirstRunWindow {
    private var window: NSWindow?
    let model: FirstRunModel

    init(manager: CompanionManager) {
        model = FirstRunModel(manager: manager)
        model.onDone = { [weak self] in self?.close() }
    }

    func showIfNeeded() {
        if !FirstRunStore.completed {
            Log.write("setup: first run — opening the setup window")
            show()
        }
    }

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: FirstRunWindowView(model: model))
            hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
            let window = NSWindow(contentRect: hosting.frame,
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Set up Chunks"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        Log.write("setup: showing \(model.plan.currentStep.indexLabel) — \(model.plan.currentStep.title)")
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.orderOut(nil) }
}
