//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import ChunksKit
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var keyInput: String = ""
    @State private var isEditingKey: Bool = false
    @State private var keyMessage: String?
    @State private var backupInput: String = ""
    @State private var backupMessage: String?
    @State private var removeHovering: UUID?
    /// Fact ids are strings, so the memory row cannot share the routine row's hover state.
    @State private var forgetHovering: String?
    @State private var isAddingRoutine = false
    @State private var routineTitle = ""
    @State private var routinePrompt = ""
    @State private var routineTime = "08:00"
    @State private var routineCadenceChoice = 0
    @State private var routineMessage: String?
    @State private var isAddingReminder = false
    @State private var reminderDraftText = ""
    @State private var reminderDraftWhen = "40 min"
    @State private var reminderMessage: String?

    /// Draws the sections a granted, onboarded machine would hide.
    ///
    /// Only the render probe sets it. Without this the panel's most important section — the one a
    /// first run lives in — cannot be looked at offscreen, because the machine it is rendered on
    /// has already granted everything.
    var showsEverySection: Bool = false

    /// The panel's colour vocabulary, resolved to the dots warm-paper tokens.
    ///
    /// Surfaces, ground, lines and ink move to `DS.Dots`; the four state colours and the ink action
    /// object stay on `DS.Colors`, because they are shared with the notch card and already clear the
    /// graphic floor on warm paper (asserted in `Palette.Dots.graphicPairs`). Keeping one alias here
    /// means the reskin is a change of *resolution*, not eighty edits that can drift apart.
    private enum C {
        static var ground: Color { DS.Dots.paper }
        static var background: Color { DS.Dots.paper }
        static var raised: Color { DS.Dots.raised }
        static var surface1: Color { DS.Dots.raised }
        static var sunken: Color { DS.Dots.sunken }
        static var surface2: Color { DS.Dots.sunken }
        static var hover: Color { DS.Dots.hover }
        static var surface3: Color { DS.Dots.hover }
        static var pressed: Color { DS.Dots.pressed }
        static var surface4: Color { DS.Dots.pressed }
        static var line: Color { DS.Dots.line }
        static var borderSubtle: Color { DS.Dots.line }
        static var lineStrong: Color { DS.Dots.lineStrong }
        static var borderStrong: Color { DS.Dots.lineStrong }
        static var lineControl: Color { DS.Colors.lineControl }
        static var ink: Color { DS.Dots.ink }
        static var textPrimary: Color { DS.Dots.ink }
        static var inkMuted: Color { DS.Colors.inkMuted }
        static var textSecondary: Color { DS.Colors.inkMuted }
        static var inkFaint: Color { DS.Colors.inkFaint }
        static var textTertiary: Color { DS.Colors.inkFaint }
        static var onInk: Color { DS.Colors.onInk }
        static var action: Color { DS.Colors.action }
        static var actionHover: Color { DS.Colors.actionHover }
        static var accent: Color { DS.Colors.accent }
        static var accentHover: Color { DS.Colors.accentHover }
        static var accentText: Color { DS.Colors.accentText }
        /// The deep activity step — the only blue that clears 4.5:1 on a field (5.49 on sea, 5.97 on
        /// sand). The bright one measures 4.24 and 4.60 there, which is a fail at 11 pt.
        static var linkOnField: Color { DS.Dots.link }
        static var textOnAccent: Color { DS.Colors.textOnAccent }
        static var success: Color { DS.Colors.success }
        static var successText: Color { DS.Colors.successText }
        static var warning: Color { DS.Colors.warning }
        static var warningText: Color { DS.Colors.warningText }
        static var destructive: Color { DS.Colors.destructive }
        static var destructiveText: Color { DS.Colors.destructiveText }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader

            // The middle scrolls; the header and the footer do not.
            //
            // The window is 380 pt tall and the content was a plain stack, so with the permissions
            // section open — the one state a first run is guaranteed to be in — the API key row and
            // the footer were drawn below the bottom edge. A control the user cannot see is not
            // merely off-screen, it does not exist: this is the difference between a panel that
            // looks broken and one that is.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    // The copy a first run reads, on the sand field — the one block in the panel
                    // that is a promise rather than a control.
                    permissionsCopySection
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dotsCard(DS.Dots.sand, radius: DS.CornerRadius.large)

                    // The switches and the model live on paper, because they are the part he
                    // operates; the fields are for reading, the paper is for doing.
                    VStack(spacing: 0) {
                        modelPickerRow
                        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
                            || showsEverySection {
                            DotsDashRule()
                            actingRow
                            DotsDashRule()
                            brainRow
                            DotsDashRule()
                            loginRow
                            DotsDashRule()
                            keepAwakeRow
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .dotsCard(C.raised, radius: DS.CornerRadius.large, hatched: false)

                    if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
                        || showsEverySection {
                        // Routines sit on the sea itself — the same fill as the ground, defined only
                        // by its dashed edge, exactly as the reference draws it. Memory sits on sand.
                        routinesSection
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dotsCard(DS.Dots.sea, radius: DS.CornerRadius.large)

                        memorySection
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dotsCard(DS.Dots.sand, radius: DS.CornerRadius.large)
                    }

                    if !companionManager.allPermissionsGranted || showsEverySection {
                        settingsSection
                            .padding(12)
                            .dotsCard(C.raised, radius: DS.CornerRadius.large, hatched: false)
                    }

                    if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                        startButton
                    }

                    // The two things that open something else — the history window and the key —
                    // share one paper sheet at the foot of the scroll, as they do in the reference.
                    VStack(spacing: 0) {
                        windowRow
                        DotsDashRule()
                        apiKeyRow
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dotsCard(C.raised, radius: DS.CornerRadius.large, hatched: false)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            // A panel this short ends mid-row, and a Grant pill sliced in half by the fold looks
            // like a broken control rather than a scroll position. The fade is the honest reading:
            // content continues, and the last thing on screen is never cut. `allowsHitTesting(false)`
            // because a gradient over the bottom row would swallow the tap that row is waiting for.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [DS.Dots.sea.opacity(0), DS.Dots.sea],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
                    .allowsHitTesting(false)
            }

            footerSection
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(DS.Dots.sea)
                .overlay(DS.Dots.HatchPattern().allowsHitTesting(false))
        }
        .frame(width: 320)
        .background(panelBackground)
        // Read the login state when the panel opens rather than trusting the value from launch:
        // System Settings can change it while Chunks is running, and it is the only place a
        // `.needsApproval` registration can be finished.
        .onAppear { companionManager.refreshLoginState() }
        .onExitCommand {
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        }
    }

    // MARK: - Header

    /// The sky band, with the sand clouds sitting on its bottom edge.
    ///
    /// No traffic lights: this is a borderless status panel, and three coloured circles that do
    /// nothing are a lie about what the surface can do. The mockup draws them because it is framed
    /// as a window; the window itself (⌃A) has real ones.
    private var panelHeader: some View {
        ZStack(alignment: .bottomTrailing) {
            DS.Dots.sky
            DS.Dots.CloudBand(squash: 0.8)
                .frame(width: 210, height: 30)
                .padding(.trailing, 44)
                .padding(.bottom, 0)

            HStack {
                HStack(spacing: 8) {
                    // No glow. The dark palette haloed the dot because a small coloured mark on black
                    // needs help; on a field the same blur reads as a smudge, and DESIGN.md bans one.
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 9, height: 9)

                    Text("Chunks")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(C.ink)
                }

                Spacer()

                Text(statusText)
                    .font(DS.Fonts.label)
                    .foregroundColor(C.ink)

                Button(action: {
                    NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(C.ink)
                        .frame(width: 26, height: 24)
                        .background(C.raised)
                        // The visible mark stays 26×24; the target around it is 34. A glyph-sized hit
                        // area in the corner of a panel is the classic mis-tap, and this one closes
                        // the panel rather than answering a question.
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .dotsSolidBorder(radius: DS.CornerRadius.small)
                .pointerCursor()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(height: 62)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hold \(BuddyPushToTalkShortcut.pushToTalkDisplayText) to talk.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(C.textSecondary)
                Text("\(PanelShortcut.displayText) opens and closes this panel.")
                    .font(.system(size: 11))
                    .foregroundColor(C.textTertiary)
                // Stated here because the gesture has no button: it fires from anywhere, so the only
                // place its keys can be read is the panel. Two people — including me, twice — have
                // tested it with the wrong chord and concluded the feature was dead.
                Text("\(CircleShortcut.displayText) chooses a region to explain.")
                    .font(.system(size: 11))
                    .foregroundColor(C.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Chunks.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(C.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(C.textSecondary)

                Text("Some permissions were revoked. Grant every row below to keep using Chunks.")
                    .font(.system(size: 11))
                    .foregroundColor(C.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("This is Chunks.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(C.textSecondary)

                Text("Hold the hot key, ask about what is on your screen, and Chunks explains it.")
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                // Was `destructiveText` red. The line is a promise, not a failure, and in this
                // language a saturated colour means exactly one of four states — an amber or red
                // paragraph that means nothing turns the palette into decoration again.
                Text("Nothing runs in the background. Chunks only takes a screenshot when you hold the hot key. Transcripts stay on your Mac and Chunks keeps no analytics.")
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Button(action: {
                companionManager.triggerOnboarding()
            }) {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(C.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(C.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - API Key

    /// The one field the app cannot run without.
    ///
    /// Upstream shipped a Cloudflare proxy and the key lived server-side, so clicky's UI
    /// never asked for one; every "add a key from the Chunks menu" message in this codebase
    /// pointed at a menu that does not exist. Writing to the Keychain is the only path that
    /// keeps the key out of UserDefaults, a plist, and the shell history.
    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "key")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(companionManager.hasApiKey ? C.textTertiary : C.warning)
                        .frame(width: 16)

                    Text("Gemini API key")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(C.textSecondary)
                }

                Spacer()

                if companionManager.hasApiKey && !isEditingKey {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(C.success)
                            .frame(width: 6, height: 6)
                        Text("Saved")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(C.success)
                    }

                    Button(action: { isEditingKey = true }) {
                        Text("Change")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(C.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                } else {
                    Button(action: { companionManager.refreshApiKeyState() }) {
                        Text("Check")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(C.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            if isEditingKey || !companionManager.hasApiKey {
                SecureField("AIza…  pasted from aistudio.google.com", text: $keyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(C.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(C.hover)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(C.borderSubtle, lineWidth: 0.5)
                    )
                    .onSubmit(saveKey)

                HStack {
                    if let keyMessage {
                        Text(keyMessage)
                            .font(.system(size: 11))
                            .foregroundColor(C.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button(action: saveKey) {
                        Text("Save to Keychain")
                            .font(.system(size: 11, weight: .semibold))
                            // The disabled state used to be white on 40% blue, which on a bone panel
                            // measured as nothing at all. A disabled control is still a control: it
                            // has to be readable, and say "off" by being ink-on-paper rather than by
                            // being invisible.
                            .foregroundColor(keyIsHeld ? C.onInk : C.inkMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                // Ink when it can be pressed, paper when it cannot. The activity
                                // blue is reserved for work in flight, and a save button is not
                                // that — the same reason the card's Allow is ink.
                                Capsule()
                                    .fill(keyIsHeld ? C.action : C.sunken)
                                    .overlay(Capsule().strokeBorder(keyIsHeld ? C.ink
                                                                            : C.lineControl,
                                                                    lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            // A second key, and the reason it is here rather than a bigger number in a settings file:
            // the free tier is capped a few requests a minute *per key*, so a turn that walks the whole
            // model chain can spend them all and answer "Could not answer — hit the free-tier rate
            // limit". Measured on his Mac 2026-11-03. A second key has its own untouched budget, and
            // Chunks now spends it before giving up. Optional by design: with nothing stored here the
            // app behaves exactly as it did.
            if companionManager.hasApiKey {
                HStack(spacing: 8) {
                    Text(companionManager.hasBackupKey ? "Backup key stored" : "Backup key (optional)")
                        .font(.system(size: 11))
                        .foregroundColor(C.textTertiary)
                    if companionManager.hasBackupKey {
                        Button("Remove") {
                            companionManager.clearBackupKey()
                            backupMessage = "Backup key removed."
                        }
                        .font(.system(size: 11))
                        .foregroundColor(C.textSecondary)
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                    Spacer()
                }
                if !companionManager.hasBackupKey {
                    HStack(spacing: 8) {
                        SecureField("second AIza…  used only when the first is rate-limited",
                                    text: $backupInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(C.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .fill(C.sunken)
                            )
                            .onSubmit(saveBackupKey)
                        Button("Save") { saveBackupKey() }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(C.textSecondary)
                            .buttonStyle(.plain)
                            .pointerCursor()
                            .disabled(backupInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let backupMessage {
                    Text(backupMessage)
                        .font(.system(size: 10))
                        .foregroundColor(C.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func saveBackupKey() {
        let trimmed = backupInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if companionManager.saveBackupKey(trimmed) {
            backupInput = ""
            backupMessage = "Stored. Chunks uses it only when the first key is refused for a quota."
        } else {
            backupMessage = "The Keychain refused the write. Rebuild with a signing identity and try again."
        }
    }

    private func saveKey() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if companionManager.saveApiKey(trimmed) {
            keyInput = ""
            keyMessage = nil
            isEditingKey = false
        } else {
            keyMessage = "The Keychain refused the write. Rebuild with a signing identity and try again."
        }
    }

    // MARK: - Permissions

    // MARK: - Permissions

    /// The five grants, read from the manager, as the model the rows are drawn from.
    private var permissionState: PermissionState {
        PermissionState(microphone: companionManager.hasMicrophonePermission,
                        accessibility: companionManager.hasAccessibilityPermission,
                        inputMonitoring: companionManager.hasInputMonitoringPermission,
                        screenRecording: companionManager.hasScreenRecordingPermission,
                        screenContent: companionManager.hasScreenContentPermission)
    }

    private var settingsSection: some View {
        VStack(spacing: 2) {
            sectionTag("PERMISSIONS", field: DS.Dots.sea)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            // One row, five times. The section used to be five hand-written views of about seventy
            // lines each, and they had already drifted apart: two offered Restart, one offered
            // Find App, the granted tick was two different greens, and the helper that was supposed
            // to unify them was never called. What a permission *is*, what it says when it is
            // missing and what you can do about it now all come from `PermissionState`, so the next
            // grant added here cannot be written in a different dialect.
            ForEach(PermissionState.rows(for: permissionState)) { row in
                permissionRow(row)
            }
        }
    }

    private func permissionRow(_ row: PermissionRow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: row.symbol)
                .font(DS.Fonts.label)
                // Amber says "this one is missing", which is a state; a granted row gets no colour
                // at all. The old list painted the mark of a missing grant amber *and* green-ticked
                // the same row when it was there, so the mark meant two things depending on size.
                .foregroundColor(row.isGranted ? C.inkMuted : C.warning)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(DS.Fonts.label)
                    .foregroundColor(C.textPrimary)
                Text(row.purpose)
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            if row.isGranted {
                HStack(spacing: 4) {
                    Circle().fill(C.success).frame(width: 6, height: 6)
                    Text(row.stateWord)
                        .font(DS.Fonts.micro)
                        .foregroundColor(C.successText)
                }
            } else {
                HStack(spacing: 5) {
                    ForEach(row.actions, id: \.self) { action in
                        panelPill(action.title,
                                  primary: action == .grant,
                                  help: action.help) {
                            apply(action, to: row)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowHovered == row.id ? C.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
        .contentShape(Rectangle())
        .onHover { inside in
            rowHovered = inside ? row.id : (rowHovered == row.id ? nil : rowHovered)
        }
    }

    @State private var rowHovered: PermissionRow.Kind?

    /// The small action pill. Ink for the one thing to do, paper for the alternatives — the same
    /// pair of weights the card's Allow and Not now use, so a user who learned one reads the other.
    private func panelPill(_ title: String, primary: Bool, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Fonts.micro)
                .foregroundColor(primary ? C.onInk : C.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .physical(primary ? C.action : C.raised,
                          radius: 999,
                          elevation: .raised,
                          edge: primary ? C.ink : C.lineControl)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }

    /// What each button actually does — the same switch the setup window's buttons run, so the
    /// two surfaces cannot drift into disagreeing about what "Restart" means.
    private func apply(_ action: PermissionRow.Action, to row: PermissionRow) {
        PermissionActions.apply(action, to: row, via: companionManager)
    }

    /// A section heading as a small field-filled tag: ink on sea / sky / sand.
    ///
    /// The three measured fields are grounds, never marks — so they appear here *behind* ink text
    /// (9.3–13.6:1, legal at 10 pt) rather than as a coloured dot or rule on the paper, which the
    /// contrast suite forbids at 1.16–1.70:1.
    private func sectionTag(_ title: String, field: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DS.Dots.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(field)
            // A control, so a solid edge — the mockup's tags are pills with a drawn outline, not
            // dashed like the cards they sit on. `fixedSize` because a tag that wraps to "MEMO / RY"
            // in a 320 pt panel is a broken label, not a small one.
            .fixedSize()
            .dotsSolidBorder(radius: 8)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func openSettings(_ scheme: String) {
        PermissionActions.openSettings(scheme)
    }

    private var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(C.textSecondary)

            Spacer()

            Menu {
                ForEach(ProviderRegistry.geminiFreeModels, id: \.id) { model in
                    Button {
                        companionManager.setSelectedModel(model.id)
                    } label: {
                        if model.id == companionManager.selectedModel {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
            } label: {
                Text(ProviderRegistry.geminiFreeModels
                        .first(where: { $0.id == companionManager.selectedModel })?
                        .displayName ?? companionManager.selectedModel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(C.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(DS.Dots.sea)
                    .dotsSolidBorder(radius: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    /// Whether the notch asks before Chunks presses a control or runs a tool.
    ///
    /// Off by default, because the ask is what the user objected to: they named a thing on
    /// screen and got a question about it instead of an action. The row exists so the switch is
    /// a visible choice rather than a Keychain-style secret — and the copy says plainly that
    /// turning it off does not unlock secure fields or password apps, which `PolicyGate` still
    /// refuses whatever this says.
    private var actingRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Ask before acting")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(C.textSecondary)
                Text(companionManager.askBeforeActing
                        ? "Shows Allow / Not now in the notch first."
                        : "Acts on what you name. Secure fields still refuse.")
                    .font(.system(size: 10))
                    .foregroundColor(C.textTertiary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.askBeforeActing },
                set: { companionManager.setAskBeforeActing($0) }))
                .labelsHidden()
                .accessibilityLabel("Ask before acting")
                .toggleStyle(.switch)
                .tint(DS.Dots.teal)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }


    /// Start with the Mac, or not.
    ///
    /// The state is read back from `SMAppService` rather than stored, because macOS can refuse a
    /// registration, and because the user can flip the same switch in System Settings without this
    /// app ever hearing about it. A row that showed what was last asked for would be a row that
    /// lies — worst of all in the `.needsApproval` case, where it is registered and does nothing.
    /// The row that opens the history window.
    ///
    /// In the panel rather than only on a hot key because "where did my last answer go" is a
    /// question people have before they know a chord exists — and the panel is the one surface
    /// they have already found.
    private var windowRow: some View {
        Button(action: {
            companionManager.openWindow?()
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(C.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("History")
                        .font(DS.Fonts.label)
                        .foregroundColor(C.textSecondary)
                    Text("Every answer, and a box to type in")
                        .font(DS.Fonts.meta)
                        .foregroundColor(C.textTertiary)
                }
                Spacer()
                Text(WindowShortcut.displayText)
                    .font(DS.Fonts.micro)
                    .foregroundColor(C.textTertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(companionManager.openWindow == nil)
    }

    private var loginRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Open at login")
                    .font(DS.Fonts.label)
                    .foregroundColor(C.textSecondary)
                Text(loginDetail)
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.launchesAtLogin },
                set: { companionManager.setLaunchAtLogin($0) }))
                .labelsHidden()
                .accessibilityLabel("Open Chunks at login")
                .toggleStyle(.switch)
                .tint(DS.Dots.teal)
                .controlSize(.small)
                .disabled(isLoginUnavailable)
        }
        .padding(.vertical, 4)
    }

    private var isLoginUnavailable: Bool {
        if case .unavailable = companionManager.loginState { return true }
        return false
    }

    private var loginDetail: String {
        switch companionManager.loginState {
        case .off: return "Starts only when you open it."
        case .on: return "Starts when you log in."
        case .needsApproval: return "Turn it on in System Settings › Login Items."
        case .unavailable: return "Not available from a command-line build."
        }
    }

    /// Keep the Mac runnable while something is waiting to be said.
    ///
    /// Off by default, because a switch that quietly claims the machine's battery is not something to
    /// do uninvited, and the failure it prevents — a reminder armed for 20:00 that never arrives
    /// because the laptop dozed at 19:40 — is at least an honest miss. The detail line says what the
    /// app is *doing* (`SleepPolicy.describe`), not what was last asked for, in the same spirit as
    /// the login row: an assertion macOS refused would otherwise read as a hold that took.
    private var keepAwakeRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Stay awake for schedules")
                    .font(DS.Fonts.label)
                    .foregroundColor(C.textSecondary)
                Text(companionManager.sleepLine)
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.keepAwakeForSchedules },
                set: { companionManager.keepAwakeForSchedules = $0 }))
                .labelsHidden()
                .accessibilityLabel("Keep the Mac awake while schedules are armed")
                .toggleStyle(.switch)
                .tint(DS.Dots.teal)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Routines

    /// The schedules Chunks runs by itself.
    ///
    /// A routine is a prompt with a time attached, so it goes through the same turn a spoken
    /// question does — which means it still meets the policy gate and the consent card. That is the
    /// line to keep in view here: the row says what will be *asked*, never what will be *done*.
    /// The panel cannot hold a thirteenth routine, so it must not offer one. An "Add" whose Save is
    /// guaranteed to be refused is the same lie already refused on the routine card.
    private var routinesAreCapped: Bool {
        companionManager.routines.routines.count >= RoutinesStore.maxRoutines
    }

    private var routinesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTag("ROUTINES", field: DS.Dots.sky)
                Text("\(companionManager.routines.routines.count)/\(RoutinesStore.maxRoutines)")
                    .font(DS.Fonts.micro)
                    .foregroundColor(C.textSecondary)
                Spacer()
                Button(isAddingRoutine ? "Cancel" : "Add") {
                    isAddingRoutine.toggle()
                    routineMessage = nil
                }
                .font(DS.Fonts.meta)
                .buttonStyle(.plain)
                .foregroundColor(isAddingRoutine || !routinesAreCapped
                                 ? C.linkOnField : C.textSecondary)
                .disabled(!isAddingRoutine && routinesAreCapped)
                .padding(4)
                .contentShape(Rectangle())
            }
            .padding(.top, 10)

            if companionManager.routines.routines.isEmpty && !isAddingRoutine {
                // Empty states teach here rather than saying "nothing": the concept is new, and the
                // reassurance that it cannot act unattended is the thing that makes it safe to add.
                Text("Nothing scheduled. A routine asks Chunks something at a time you set — it still asks before it presses anything. Say \"in ten minutes remind me to stretch\" for a one-off.")
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(companionManager.routines.routines) { routine in
                routineRow(routine)
            }

            // Things armed to say themselves once, in the same section because they share one
            // promise — Chunks speaking when nobody asked. The delete is a button for the same reason
            // memory's is: a waiting list nobody can shorten is a dead end, and a cap with no way to
            // make room under it is the refusal the panel already refuses to be.
            if !companionManager.reminders.reminders.isEmpty {
                // Its own heading because the two kinds differ in the way that matters here: a
                // routine is a question Chunks asks itself on a schedule, and this is one sentence it
                // says once and forgets. Grouping them without a line would read as one list.
                Text("WAITING TO SAY ONCE · \(companionManager.reminders.reminders.count)/"
                     + "\(ReminderStore.maxReminders)")
                    .font(DS.Fonts.micro)
                    .foregroundColor(C.textSecondary)
                    .padding(.top, 4)
            }
            ForEach(companionManager.reminders.reminders) { reminder in
                reminderRow(reminder)
            }

            if isAddingRoutine {
                routineComposer
            }

            Button(isAddingReminder ? "Cancel" : "Add a one-off reminder") {
                isAddingReminder.toggle()
                reminderMessage = nil
            }
            .font(DS.Fonts.meta)
            .buttonStyle(.plain)
            .foregroundColor(C.linkOnField)
            .padding(.top, 2)

            if isAddingReminder {
                reminderComposer
            }

            if routinesAreCapped && !isAddingRoutine {
                Text("Chunks keeps \(RoutinesStore.maxRoutines) routines at most. Remove one to add another.")
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = routineMessage {
                Text(message)
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.destructiveText)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Memory

    /// What Chunks knows about him, in the open.
    ///
    /// The file is capped at 2 KB and never truncated — at the cap writes are refused and he is
    /// asked (invariant 4). That rule only works if the delete is a button here: a meter that says
    /// "full" with no way to make room is the same dead end as a card with no answer.
    private var memoryIsFull: Bool {
        companionManager.memoryBytes + MemoryStore.typicalFactReserve > MemoryStore.byteCap
    }

    private var fractionFull: Double {
        Double(companionManager.memoryBytes) / Double(MemoryStore.byteCap)
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The sand header strip: tag, meter, count, and the one link. The facts themselves sit
            // on a paper sheet inset below it, which is how the mockup separates "what Chunks knows"
            // from "the controls for it".
            HStack(spacing: 8) {
                sectionTag("MEMORY", field: DS.Dots.sandTag)
                GeometryReader { edge in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Dots.lineStrong)
                        Capsule()
                            .fill(memoryIsFull ? C.warning : DS.Dots.teal)
                            .frame(width: max(2, edge.size.width * min(1, fractionFull)))
                    }
                }
                .frame(width: 40, height: 4)
                Text("\(companionManager.memoryBytes)/\(MemoryStore.byteCap)")
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.textSecondary)
                    .monospacedDigit()
                Spacer()
                Button("Show file") { companionManager.revealMemoryFile() }
                    .font(DS.Fonts.meta)
                    .buttonStyle(.plain)
                    .foregroundColor(C.linkOnField)
                    .accessibilityLabel("Show the memory file in Finder")
            }

            // The second tier, in one line. No meter, because no cap — drawing a bar here would invite
            // him to think it can fill up. The button is the proof instead: an uncapped file he cannot
            // open is a file he has to take on trust, which is the same argument that made the memory
            // file's "Show file" row a requirement rather than a nicety.
            HStack(spacing: 8) {
                Text(companionManager.notebookCount == 0
                     ? "notebook: nothing kept yet — \"note this\" goes here, not into the 2 KB above"
                     : "notebook: \(companionManager.notebookCount) note(s), \(companionManager.notebookBytes) bytes, no limit")
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Show notebook") { companionManager.revealNotebookFile() }
                    .font(DS.Fonts.meta)
                    .buttonStyle(.plain)
                    .foregroundColor(C.linkOnField)
                    .accessibilityLabel("Show the notebook file in Finder")
            }

            VStack(alignment: .leading, spacing: 0) {
                if companionManager.memoryFacts.isEmpty {
                    Text("Nothing remembered yet. Say \"remember that I prefer X\" and it lands here — Chunks refuses to store a key or a password.")
                        .font(DS.Fonts.meta)
                        .foregroundColor(C.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                }

                ForEach(MemoryStore.Section.writable, id: \.self) { section in
                    let held = companionManager.memoryFacts.filter { $0.section == section }
                    if !held.isEmpty {
                        Text(section.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(C.textPrimary)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(held, id: \.id) { fact in
                            memoryRow(fact)
                            DotsDashRule()
                        }
                    }
                }

                if memoryIsFull {
                    Text("Memory is full at \(MemoryStore.byteCap) bytes, so Chunks has stopped writing to it. Forget something above — it never trims a fact on its own.")
                        .font(DS.Fonts.meta)
                        .foregroundColor(C.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dotsCard(C.raised, radius: DS.CornerRadius.medium, hatched: false)
        }
        .padding(.top, 6)
        .onAppear { companionManager.refreshMemory() }
    }

    private func memoryRow(_ fact: MemoryStore.Fact) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(fact.text)
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(fact.date)
                    .font(DS.Fonts.micro)
                    .foregroundColor(C.textTertiary)
            }
            Spacer(minLength: 4)
            Button {
                companionManager.forgetFact(id: fact.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(fact.id == forgetHovering
                                     ? C.destructive : C.textTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Forget \"\(fact.text)\"")
            .onHover { inside in forgetHovering = inside ? fact.id : nil }
        }
        .padding(.vertical, 2)
    }

    private func routineRow(_ routine: Routine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(routine.title)
                    .font(DS.Fonts.label)
                    .foregroundColor(C.textPrimary)
                    .lineLimit(1)
                Text(routine.cadence.phrase)
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.textTertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { routine.isEnabled },
                set: { companionManager.setRoutine($0, id: routine.id) }))
                .labelsHidden()
                // Named for *this* routine. It used to read "Open Chunks at login" — the login row's
                // label copied here — so VoiceOver announced a schedule as a startup setting.
                .accessibilityLabel("Run \"\(routine.title)\"")
                .toggleStyle(.switch)
                .tint(DS.Dots.teal)
                .controlSize(.mini)
            Button {
                companionManager.removeRoutine(id: routine.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(removeHovering == routine.id
                                     ? C.destructive : C.textTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \"\(routine.title)\"")
            .onHover { removeHovering = $0 ? routine.id : nil }
        }
        .padding(.vertical, 3)
    }

    /// One waiting reminder: what it will say, and when.
    ///
    /// The time is the stored `fireAt` rendered as a clock, not the phrase the model wrote — the row
    /// has to agree with the file, and `at 21:00` armed at 22:00 is tomorrow's 21:00. The date goes on
    /// it when it is not today, because "21:00" alone on a list he reads on a Tuesday is the same
    /// ambiguity the card was made to avoid.
    private func reminderRow(_ reminder: Reminder) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.text)
                    .font(DS.Fonts.label)
                    .foregroundColor(C.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.reminderWhen.string(from: reminder.fireAt))
                    .font(DS.Fonts.meta)
                    .foregroundColor(C.textTertiary)
            }
            Spacer()
            Button {
                companionManager.removeReminder(id: reminder.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(removeHovering == reminder.id
                                     ? C.destructive : C.textTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reminder \"\(reminder.text)\"")
            .onHover { removeHovering = $0 ? reminder.id : nil }
        }
        .padding(.vertical, 3)
    }

    private static let reminderWhen: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    /// Arm a reminder without depending on a model turn to say the tag.
    ///
    /// The reason this exists at all: a feature whose only door is a sentence a cloud model has to
    /// guess right is a feature that is off whenever the key is exhausted, the network is not, or the
    /// answer came back in the wrong shape. It goes through the *same* `addReminder` the tool calls,
    /// so the when is parsed by the same four shapes, the line is secret-swept by the same code, and
    /// the cap refuses for the same reason. No card, for the same reason the routine's Add button has
    /// none: he typed it, on his own machine, into the app he is looking at.
    private var reminderComposer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                TextField("What to say — stretch the legs", text: $reminderDraftText)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.label)
                TextField("40 min", text: $reminderDraftWhen)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.label)
                    .frame(width: 76)
                Button("Arm") { armReminderFromPanel() }
                    .font(DS.Fonts.label)
                    .buttonStyle(.plain)
                    .foregroundColor(C.accentText)
            }
            Text(reminderMessage
                 ?? "40 min · 2 hours · 3 days · at 21:00 · tomorrow at 07:30")
                .font(DS.Fonts.meta)
                .foregroundColor(reminderMessage == nil
                                 ? C.textTertiary : C.destructiveText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    private func armReminderFromPanel() {
        guard let timing = ReminderTiming.parse(reminderDraftWhen) else {
            reminderMessage = "\"\(reminderDraftWhen)\" is not a when Chunks reads."
            return
        }
        if let rejection = companionManager.addReminder(text: reminderDraftText, timing: timing) {
            reminderMessage = rejection.reason
            return
        }
        reminderDraftText = ""
        reminderDraftWhen = "40 min"
        reminderMessage = nil
        isAddingReminder = false
    }

    private var routineComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name — Standup brief", text: $routineTitle)
                .textFieldStyle(.plain)
                .font(DS.Fonts.label)
            TextField("What to ask", text: $routinePrompt)
                .textFieldStyle(.plain)
                .font(DS.Fonts.meta)

            HStack(spacing: 8) {
                Picker("", selection: $routineCadenceChoice) {
                    Text("Every day").tag(0)
                    Text("Weekdays").tag(1)
                    Text("Every").tag(2)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)

                if routineCadenceChoice == 2 {
                    TextField("30", text: $routineTime)
                        .textFieldStyle(.plain)
                        .frame(width: 40)
                    Text("min").font(DS.Fonts.meta).foregroundColor(C.textTertiary)
                } else {
                    TextField("08:00", text: $routineTime)
                        .textFieldStyle(.plain)
                        .frame(width: 56)
                }

                Spacer()

                Button("Save") { saveRoutine() }
                    .font(DS.Fonts.label)
                    .buttonStyle(.plain)
                    .foregroundColor(C.accentText)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.surface1))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(C.borderSubtle, lineWidth: 1))
    }

    private func saveRoutine() {
        let cadence: Routine.Cadence
        switch routineCadenceChoice {
        case 1: cadence = .weekdays(at: routineTime)
        case 2: cadence = .every(minutes: Int(routineTime) ?? 0)
        default: cadence = .daily(at: routineTime)
        }
        guard let rejection = companionManager.addRoutine(title: routineTitle,
                                                         prompt: routinePrompt,
                                                         cadence: cadence) else {
            routineTitle = ""
            routinePrompt = ""
            routineMessage = nil
            isAddingRoutine = false
            return
        }
        // The reason comes back as a sentence the user can act on, because "07am" and "5 minutes"
        // are both things a person types without thinking.
        routineMessage = rejection.reason
    }

    /// Whether the answer comes from this Mac or from Google.
    ///
    /// A single switch rather than a provider list, because the question the user is asking is
    /// "can it work without internet", not "which endpoint". The line under it names what was
    /// actually found locally — offline is only useful if some model here can read a screenshot,
    /// and being told "offline" while the only loaded model is text-only is how you get a confident
    /// description of a screen nobody sent.
    private var brainRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Think on this Mac")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(C.textSecondary)
                Text(companionManager.isOfflineBrainOn
                        ? companionManager.offlineBrainSummary
                        : "Asking Google Gemini. Needs internet, better answers, and it speaks.")
                    .font(.system(size: 10))
                    .foregroundColor(C.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isOfflineBrainOn },
                set: { companionManager.setOfflineBrain($0) }))
                .labelsHidden()
                .accessibilityLabel("Think on this Mac")
                .toggleStyle(.switch)
                .tint(DS.Dots.teal)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .onAppear { companionManager.refreshOfflineBrainSummary() }
    }

    // MARK: - Footer

    /// The footer is a sea band with three equal cells and a dashed rule between them, the way the
    /// reference divides its own bottom bar. The dark palette's version was three labels floating in
    /// a void with nothing to say where one ended and the next began.
    private var footerSection: some View {
        HStack(spacing: 0) {
            footerCell {
                Button(action: {
                    NSApp.terminate(nil)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .medium))
                        Text("Quit Chunks")
                            .font(.system(size: 12, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(C.ink)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if companionManager.hasCompletedOnboarding {
                DotsDashRule(vertical: true)
                    .frame(height: 30)

                footerCell {
                    Button(action: {
                        companionManager.replayOnboarding()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle")
                                .font(.system(size: 11, weight: .medium))
                            Text("See the Intro Again")
                                .font(.system(size: 12, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                        }
                        .foregroundColor(C.ink)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                DotsDashRule(vertical: true)
                    .frame(height: 30)

                footerCell {
                    Button(action: {
                        companionManager.showFirstRun?()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape.2")
                                .font(.system(size: 11, weight: .medium))
                            Text("Run Setup Again")
                                .font(.system(size: 12, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                        }
                        .foregroundColor(C.ink)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Re-open the three-step setup: permissions, brain, keep-alive.")
                }
            }
        }
    }

    /// One footer cell, given an equal share of the band so the dashed rules land at thirds rather
    /// than wherever the longest label pushed them.
    private func footerCell<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        HStack { Spacer(minLength: 2); content(); Spacer(minLength: 2) }
            .frame(maxWidth: .infinity)
    }

    // MARK: - Visual Helpers

    /// Whether the key field holds anything worth writing to the Keychain.
    private var keyIsHeld: Bool {
        !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var panelBackground: some View {
        // The panel is the sea field, hatched, with one dashed edge — the reference's sheet. The
        // sky band at the top and the sea footer at the bottom are drawn by their own views, so
        // this is only the ground the cards float on.
        RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
            .fill(DS.Dots.sea)
            .overlay(
                DS.Dots.HatchPattern()
                    .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge,
                                                style: .continuous))
            )
            .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .strokeBorder(DS.Dots.sheetEdge, lineWidth: 1.5))
            .shadow(color: DS.Shadow.contactColor, radius: DS.Shadow.contactRadius, x: 0, y: DS.Shadow.contactY)
            .shadow(color: DS.Shadow.liftColor, radius: DS.Shadow.liftRadius, x: 0, y: DS.Shadow.liftY)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return C.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return C.success
        case .listening:
            return C.accent
        case .processing, .responding:
            return C.accent
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}
