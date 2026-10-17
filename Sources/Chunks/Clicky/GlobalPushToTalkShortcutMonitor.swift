//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import ApplicationServices
import AppKit
import ChunksKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Fires on ⌃⌥⌘C so the panel can be opened without hunting for the menu-bar icon.
    /// Sent from the same tap that already sees every key event — a second, separate global
    /// monitor would need its own permission story and could desync with this one.
    let panelTogglePublisher = PassthroughSubject<Void, Never>()

    /// Fires on ⌃⌥⌘D. Sent from the same tap, and toggles the overlay: pressing the chord a
    /// second time is an exit that works even when the window never got key focus.
    let circleTogglePublisher = PassthroughSubject<Void, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    /// Bumped by the tap callback for the first few events, then stops. Main-thread only,
    /// for the same reason as the flag above.
    private var eventsSeenLogged = 0

    /// The first dozen key presses, unconditionally. Gating this on "all three modifiers are
    /// present" was my first attempt and it is useless for the question it was written for: if the
    /// assumption about the modifier bits is what's wrong, the diagnostic stays as silent as the
    /// matcher. This prints what the tap actually received. Main-thread only, like the counter
    /// above.
    private var keyDownsLogged = 0

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        // Both grants are needed, and the second one is the easy one to miss: Accessibility
        // lets the tap be created, Input Monitoring is what makes it receive anything.
        // Logging them together is the difference between "the shortcuts are broken" and a
        // line in the file that says which door is shut. The C preflights are called directly
        // because this type is not main-actor isolated and `WindowPositionManager` is.
        Log.write("event tap: accessibility=\(AXIsProcessTrusted()) "
                  + "inputMonitoring=\(CGPreflightListenEventAccess())")

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("event tap: FAILED to create CGEvent tap — grant Input Monitoring, then Restart")
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
        // "Created" is not "receiving". The proof of that is `eventsLogged`, which counts
        // the first few real events through the callback — a tap can be created and enabled
        // and still see nothing when Input Monitoring is off.
        Log.write("event tap: created and enabled")
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // A handful of events, once. Without this the log cannot tell a tap that was never
        // created from one that was created and is being starved of events — and those two
        // need different fixes.
        if eventsSeenLogged < 3 {
            eventsSeenLogged += 1
            Log.write("event tap: event type=\(eventType.rawValue) keyCode=\(eventKeyCode) "
                      + "flags=0x\(String(event.flags.rawValue, radix: 16))")
        }

        // Matched against the tap's own CGEventFlags, because that is what the pure matcher
        // consumes; converting to NSEvent.ModifierFlags first would add a second mapping to
        // get wrong, and the two raw value sets differ.
        //
        // A held key auto-repeats, and a toggle that answers every repeat flickers: the
        // 2026-10-12 19:43:35 log shows one circle chord as `overlay open` immediately followed
        // by `dismissed — chord pressed again` inside the same second. Only the press itself is
        // a toggle.
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if eventType == .keyDown, !isAutoRepeat,
           PanelShortcut.matches(keyCode: eventKeyCode, flags: event.flags) {
            Log.write("event tap: panel chord matched")
            panelTogglePublisher.send(())
        }
        if eventType == .keyDown, !isAutoRepeat,
           CircleShortcut.matches(keyCode: eventKeyCode, flags: event.flags) {
            Log.write("event tap: circle chord matched")
            circleTogglePublisher.send(())
        }

        if eventType == .keyDown, keyDownsLogged < 12 {
            keyDownsLogged += 1
            Log.write("event tap: keyDown keyCode=\(eventKeyCode) "
                + "flags=0x\(String(event.flags.rawValue, radix: 16)) "
                + "panel=\(PanelShortcut.matches(keyCode: eventKeyCode, flags: event.flags)) "
                + "circle=\(CircleShortcut.matches(keyCode: eventKeyCode, flags: event.flags))")
        }

        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}
