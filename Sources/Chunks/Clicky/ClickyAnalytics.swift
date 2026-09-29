//
//  ClickyAnalytics.swift
//  Chunks
//
//  Stub replacing farzaa/clicky's PostHog integration.
//
//  Chunks does not ship usage analytics. It reads the user's screen and, while they hold
//  the talk key, their microphone. Telemetry on top of that would mean shipping the
//  privacy story of a screen reader with the tracking of a growth funnel, and the two
//  cannot both be what the user believes they are getting.
//
//  The call sites are left in place so the surrounding control flow is unchanged and easy
//  to follow. They compile to nothing but a log line under `CHUNKS_VERBOSE=1`.
//
//  If analytics is ever wanted it must be opt-in, aggregate-only, and must never carry a
//  transcript, a screen region, or a memory fact.
//

import Foundation

enum ClickyAnalytics {

    static func configure() { log("configure") }
    static func trackAppOpened() { log("app_opened") }
    static func trackOnboardingStarted() { log("onboarding_started") }
    static func trackOnboardingReplayed() { log("onboarding_replayed") }
    static func trackOnboardingVideoCompleted() { log("onboarding_video_completed") }
    static func trackOnboardingDemoTriggered() { log("onboarding_demo_triggered") }
    static func trackAllPermissionsGranted() { log("all_permissions_granted") }
    static func trackPushToTalkStarted() { log("push_to_talk_started") }
    static func trackPushToTalkReleased() { log("push_to_talk_released") }
    static func trackUserMessageSent() { log("user_message_sent") }
    static func trackUserMessageSent(transcript: String) { log("user_message_sent") }
    static func trackElementPointed() { log("element_pointed") }
    static func trackElementPointed(elementLabel: String?) { log("element_pointed") }
    static func trackAIResponseReceived() { log("ai_response_received") }
    static func trackResponseError() { log("response_error") }
    static func trackTTSError() { log("tts_error") }
    static func trackTTSError(error: String) { log("tts_error") }
    static func reset() { }

    /// Upstream passed the response text and the error string. Both are accepted and
    /// discarded: the first is the model's answer, which may quote the user's screen.
    static func trackAIResponseReceived(response: String) { log("ai_response_received") }
    static func trackResponseError(error: String) { log("response_error") }

    /// Upstream takes an argument label; keeping it avoids editing every call site.
    static func trackPermissionGranted(permission: String) {
        log("permission_granted", ["which": permission])
    }

    private static func log(_ name: String, _ properties: [String: Any] = [:]) {
        guard ChunksVerboseLogging.enabled else { return }
        NSLog("[Chunks/analytics-dropped] %@ %@", name, String(describing: properties))
    }
}

/// Set `CHUNKS_VERBOSE=1` to see the events that are deliberately not being sent.
enum ChunksVerboseLogging {
    static let enabled = ProcessInfo.processInfo.environment["CHUNKS_VERBOSE"] != nil
}
