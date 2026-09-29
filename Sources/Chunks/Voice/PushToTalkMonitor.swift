//
//  PushToTalkMonitor.swift
//  Chunks
//
//  Adapted from farzaa/clicky — leanring-buddy/GlobalPushToTalkShortcutMonitor.swift
//  MIT, Copyright (c) 2026 Farza. See THIRD-PARTY-NOTICES.md.
//
//  Captures the push-to-talk shortcut while Chunks runs in the background.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

/// Watches for the hold-to-talk shortcut, system-wide.
///
/// Uses a **listen-only** `CGEvent` tap rather than an `NSEvent` global monitor. Two
/// reasons, and the second is the important one:
///
/// 1. A listen-only tap cannot consume the event, so a bug in Chunks can never swallow a
///    keystroke the user meant for another app. An `NSEvent` monitor that also goes deaf
///    whenever Chunks becomes frontmost, which is why the earlier version needed *two*
///    monitors and still misbehaved around the status menu.
/// 2. macOS disables a tap whose callback takes too long, and reports it via
///    `.tapDisabledByTimeout`. Without the re-enable branch below the hotkey silently dies
///    for the rest of the session, with nothing logged. This is the failure that makes a
///    tap look broken for no visible reason.
@MainActor
final class PushToTalkMonitor: ObservableObject {

    enum Transition {
        case pressed
        case released
    }

    var onTransition: ((Transition) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Published so the menu-bar icon can drop back to idle the instant the key comes up,
    /// rather than waiting for the async dictation pipeline to report back.
    @Published private(set) var isPressed = false

    /// Keys that make up the shortcut: Control and Option, both modifier-only.
    private static let requiredFlags: NSEvent.ModifierFlags = [.control, .option]

    init() {}

    deinit {
        // `stop()` touches CF objects only, so it is safe from any thread.
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
    }

    func start() {
        // Already running. Restarting resets `isPressed`, and the permission poller calls
        // `start()` periodically — restarting would kill the listening indicator mid-press.
        guard eventTap == nil else { return }

        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        // The C callback has no Swift context, so the monitor is passed through `userInfo`
        // and recovered with `Unmanaged`. Safe because `deinit` invalidates the tap, which
        // is what stops the callback from firing with a dead pointer.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<PushToTalkMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap runs on the main run loop, so this is already the main thread.
            MainActor.assumeIsolated {
                monitor.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("pushToTalk: could not create the event tap — is Chunks missing Input Monitoring?")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            Log.write("pushToTalk: could not create a run loop source for the event tap")
            return
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("pushToTalk: listening for control+option")
    }

    func stop() {
        isPressed = false
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The timeout case is the whole reason this class is worth vendoring. macOS turns
        // the tap off when the callback overruns, and the only way back is to re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.write("pushToTalk: tap was disabled by the system, re-enabling")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }

        guard type == .flagsChanged else { return }

        // The event's own flags, not `NSEvent.modifierFlags`. The latter is a live global
        // query read after an async hop, by which time the user may already have let go,
        // and it no longer describes the transition that fired this callback.
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let held = flags.isSuperset(of: Self.requiredFlags)
        guard held != isPressed else { return }

        isPressed = held
        Log.write("pushToTalk: \(held ? "pressed" : "released")")
        onTransition?(held ? .pressed : .released)
    }
}
