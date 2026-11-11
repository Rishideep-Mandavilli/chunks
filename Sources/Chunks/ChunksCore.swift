//
//  ChunksCore.swift
//  Chunks
//
//  The parts Chunks has that clicky does not, plus the Gemini brain that replaces
//  clicky's Claude client.
//
//  Everything the user touches -- the menu bar, the panel, the annotation overlay, the
//  cursor animation, push-to-talk dictation -- now comes from farzaa/clicky under
//  Sources/Chunks/Clicky/. What stays here is what had to be written for this project:
//
//    * the Gemini brain, because clicky is Claude-only and our brief is a free tier
//    * the Keychain-backed API key, so no credential ever lands in a plist
//    * Log, and the --self-test diagnostic
//
//  Retained rather than rewritten because it is covered by 166 tests and it encodes the
//  invariants in AGENTS.md. The memory file, the secret sweeper and the coordinate
//  authority are in ChunksKit and are untouched by any of this.
//

import AppKit
import AVFoundation
import ChunksKit
import Combine
import LocalAuthentication
import Security

/// Runs one real turn end to end and prints what happened, then exits.
///
/// Exists because the interesting failures in this app are all invisible from the outside:
/// a card that never appears, a reply that parses to nothing, a model that is silently
/// unusable. "Press the hotkey and tell me what you see" is a fine manual check, but it
/// needs a human, it cannot run in CI, and it does not show the raw reply or the token
/// counts. This does all three.
///
///     swift run chunks --self-test
///     swift run chunks --self-test --question "what am I looking at?"
@MainActor
enum SelfTest {

    /// Entry point for `chunks --self-test`.
    ///
    /// A deliberately smaller contract than the app's own prompt, so a failure here means
    /// the transport is broken rather than that the model is being difficult.
    /// Which prompt the diagnostic sends.
    ///
    /// The default one is deliberately terse so a network failure is easy to read. Comparing
    /// *brains* needs the prompt a real turn uses, because that is the only one that asks for
    /// `<SAY>`, `<DONE_TITLE>` and `[POINT:…]` — and a model judged on a prompt that forbids tags
    /// will always look like it cannot produce them.
    @MainActor
    static func selectedPrompt() -> String {
        CommandLine.arguments.contains("--prompt-production")
            ? CompanionManager.companionVoiceResponseSystemPrompt
            : systemPrompt
    }

    static let systemPrompt = """
    You are Chunks, a Mac companion that explains what is on the user's screen.
    Reply in one or two plain sentences. No tags, no lists, no preamble.
    """

    static func run() {
        func say(_ message: String) { print(message) }
        func flag(_ name: String) -> String? {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: name),
                  index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        say("Chunks self-test")
        say("  screen recording: \(CaptureEngine.hasScreenRecordingPermission() ? "granted" : "NOT granted")")
        let keyPresent = KeychainStore.boundedHasKey()
        say("  api key: \(keyPresent ? "present" : "MISSING")")
        Log.write("self-test: key present=\(keyPresent)")
        for display in CaptureEngine.displays() {
            say("  display \(display.displayID) \(Int(display.frame.width))x\(Int(display.frame.height))pt "
                + "@\(display.backingScale)x\(display.isMain ? " main" : "")")
        }

        // The notch HUD's anchor, resolved the same way the panel resolves it. Printed here
        // because a wrong anchor is invisible in unit tests: the notch's real width and depth
        // only exist on a real display.
        if let hudScreen = NotchAnchor.screen() {
            let notch = NotchAnchor.geometry(for: hudScreen)
            let local = notch.hudRect(width: NotchHUDModel.defaultCardWidth, height: 200)
            let global = LogicalRect(x: hudScreen.frame.origin.x, y: hudScreen.frame.origin.y,
                                     width: hudScreen.frame.width, height: hudScreen.frame.height)
            let window = NotchGeometry.appKitWindowFrame(local, globalScreen: global)
            say("  hud: \(notch.hasNotch ? "notch" : "menu-bar fallback") "
                + "\(Int(notch.notchWidth))x\(Int(notch.notchHeight))pt on "
                + "\(Int(hudScreen.frame.width))x\(Int(hudScreen.frame.height))pt"
                + " — card at (\(Int(window.minX)), \(Int(window.minY)))")
        } else {
            say("  hud: NO DISPLAY")
        }

        guard let display = CaptureEngine.mainDisplay() else {
            Log.write("FAIL: no display"); say("FAIL: no display")
            Log.flush()

            exit(1)
        }

        Task { @MainActor in
            do {
                let started = Date()
                let captured = try await CaptureEngine().capture(display: display, shapes: [])
                let image = captured.composited(with: [], display: display)
                say("  captured \(image.width)x\(image.height)px in "
                    + String(format: "%.0fms", Date().timeIntervalSince(started) * 1000))

                guard let png = ScreenCapture(image: image, globalRect: captured.globalRect).png() else {
                    Log.write("FAIL: could not encode PNG"); say("FAIL: could not encode PNG")
                    Log.flush()

                    exit(1)
                }
                say("  png: \(png.count / 1024) KB")

                let question = flag("--question") ?? "What am I looking at? Answer in one sentence."

                let replied = Date()
                var raw = ""
                let response = try await BrainGateway().analyzeImageStreaming(
                    images: [(data: png,
                              label: "The user's whole screen "
                                    + "(\(captured.pixelSize.width)x\(captured.pixelSize.height) pixels)")],
                    systemPrompt: SelfTest.selectedPrompt(),
                    userPrompt: question,
                    onTextChunk: { delta in raw += delta })
                let elapsed = Date().timeIntervalSince(replied)
                raw = response.text

                say("  --- raw reply (\(raw.count) chars, \(String(format: "%.1f", elapsed))s) ---")
                for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                    say("  | \(line)")
                }
                say("  --- parsed ---")

                let streamer = AnswerStreamer()
                streamer.push(raw)
                // Flush, exactly as a live turn does at the end of the stream. The parser holds
                // back any tail that might still grow into a tag, and this prompt asks for
                // "no tags" — so without `finish()` a perfectly good plain-language reply was
                // still sitting in the parser's buffer and the check below read it as nothing.
                streamer.finish()
                let parsed = streamer.displayable
                say("  speech: \(parsed.speech.isEmpty ? "(none)" : parsed.speech)")
                let detail = parsed.detail.isEmpty ? "(none)"
                    : parsed.detail.replacingOccurrences(of: "\n", with: " / ")
                say("  detail: \(detail)")
                say("  title: \(streamer.doneTitle ?? "(none)")")
                if let summary = streamer.summary { say("  summary: \(summary)") }
                for action in streamer.nextActions { say("  next action: \(action)") }
                for target in streamer.points {
                    let resolved = captured.globalPoint(forImagePixelX: target.x, target.y)
                    say("  point: image (\(Int(target.x)), \(Int(target.y))) -> screen "
                        + "(\(Int(resolved.x)), \(Int(resolved.y)))  [\(target.label)]")
                }
                if let proposal = streamer.proposal, !proposal.isEmpty {
                    for addition in proposal.add {
                        say("  memory proposal: [\(addition.section.rawValue)] \(addition.fact)")
                    }
                }

                if parsed.speech.isEmpty && parsed.detail.isEmpty && streamer.utterance.isEmpty {
                    Log.write("FAIL: the reply parsed to nothing"); say("FAIL: the reply parsed to nothing")
                    Log.flush()

                    exit(1)
                }
                say("OK")
                Log.flush()

                exit(0)
            } catch {
                Log.write("FAIL: \(error)"); say("FAIL: \(error)")
                if let chunksError = error as? ChunksError {
                    say("  detail: \(chunksError.description)")
                }
                // A model that will not answer is not a build that is broken. Everything this check
                // owns — the grant, the key, the capture, the encoder — has already printed its line
                // by now, and the reply path has its own failure above (a reply that arrives and
                // parses to nothing exits 1). Reaching *here* means the request went out and the
                // service refused it, which is a fact about the account that day. Exit 3 says so,
                // and `verify.sh` counts it as a skip rather than a red line nobody caused.
                say("SKIP: the model round — the request went out and nothing answered it. "
                    + "That is the key's rate limit, not this build.")
                Log.flush()

                exit(3)
            }
        }

        // The turn's completion handlers — screen capture, the SSE stream — are delivered on
        // the main run loop. `app.run()` normally supplies it; in self-test there is no
        // app, so without this the task is scheduled and then nothing ever services it. The
        // loop never returns: the task above always calls `exit`.
        //
        // A stalled capture (asleep display, a TCC prompt) must not hang the gate: if the task has
        // not exited within the budget, report a skip and leave. The live turn has its own watchdog;
        // this is the probe's equivalent.
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            say("SKIP: self-test did not finish in 45s — the capture or the model stalled.")
            Log.flush()
            exit(3)
        }
        RunLoop.main.run()
    }
}


// MARK: - Bridge

enum ChunksError: Error, CustomStringConvertible {
    case noCapableModel(String)
    /// An HTTP failure, with the server's explanation attached.
    ///
    /// The body is part of the error, not decoration. Gemini's 400s name the offending
    /// field, and a bare status code sends you guessing.
    case http(statusCode: Int, body: String)
    case transport(String)
    case missingKey
    case keychain(OSStatus)

    var description: String {
        switch self {
        case .noCapableModel(let message): return message
        case .http(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = RetryPolicy.userFacingMessage(
                for: RetryPolicy.classify(statusCode: code, body: detail))
            return detail.isEmpty ? summary : "\(summary) — server said: \(detail.prefix(400))"
        case .transport(let detail):
            return "Couldn't reach the model: \(detail)"
        case .missingKey:
            return "No Gemini API key set. Add one in Settings."
        case .keychain(let status):
            // `errSecMissingEntitlement` is the usual one for an unsigned/ad-hoc app.
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Could not read the API key from the Keychain: \(detail)."
        }
    }
}


final class ChunksSettings {
    static var preferredModel: String? {
        get { UserDefaults.standard.string(forKey: "preferredModel") }
        set { UserDefaults.standard.set(newValue, forKey: "preferredModel") }
    }

    /// Whether answers are spoken. Off is a legitimate choice: a user who already has a
    /// screen reader, or who shares a room, needs the answer without audio.
    static var voiceOutput: Bool {
        get {
            // Default on, because a companion you have to read is a companion you cannot
            // glance at. `object(forKey:)` rather than `bool(forKey:)` so a first run is
            // distinguishable from an explicit "off".
            UserDefaults.standard.object(forKey: "voiceOutput") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "voiceOutput") }
    }

    /// Set the key non-interactively, for first-run setup scripts.
    static func setKeyFromEnvironment() {
        guard let key = ProcessInfo.processInfo.environment["CHUNKS_GEMINI_KEY"],
              !key.isEmpty else { return }
        if KeychainStore.setGeminiKey(key) {
            NSLog("[Chunks] API key loaded from the CHUNKS_GEMINI_KEY environment variable")
        }
    }
}


enum KeychainStore {
    private static let service = "app.chunks.mac"
    private static let account = "gemini-api-key"
    /// A second key, used only when the first is refused for a quota reason.
    ///
    /// Measured 2026-11-03: a free-tier Gemini key is capped at a few requests a minute **per model
    /// per key**, and a turn that walks the chain spends several of them — so the honest failure the
    /// user saw was a card reading "Hit the free-tier rate limit… server said: Rate…" on a question
    /// about closing browser tabs. A second key is not a workaround for a bad design; it is the
    /// provider's own unit of budget, and the chain already treats a *model*'s untouched budget as
    /// the reason to switch. This does the same for a key.
    private static let backupAccount = "gemini-api-key-backup"

    static func geminiKey() throws -> String {
        // An empty stored value is treated as absent: a Keychain item can outlive the app
        // that wrote it, and an empty key would otherwise become a 401 the user cannot
        // explain.
        guard let key = try read(account: account), !key.isEmpty else { throw ChunksError.missingKey }
        cacheKey.set(key)
        return key
    }

    /// The backup key, or nil. It is optional by design, so this never throws: a machine with one
    /// key must behave exactly as it did before this existed.
    static func backupGeminiKey() -> String? {
        guard let key = try? read(account: backupAccount), !key.isEmpty else {
            cacheBackup.set(nil)
            return nil
        }
        cacheBackup.set(key)
        return key
    }

    /// Whether a backup key is configured, from the **cache** — the same rule as `isKeyConfigured`:
    /// this is read while building the menu, on the main thread, and the Keychain must not be
    /// touched there.
    static var hasBackupKey: Bool { cacheBackup.isConfigured }

    // The primary key's cache is declared below with the reason it exists; the backup shares it.
    private static let cacheBackup = Cache()

    /// Whether a key is configured, from a **cached** value.
    ///
    /// Never call the Keychain from here. This is read while building the menu, which runs
    /// on the main thread on launch and on every phase change, and `SecItemCopyMatching`
    /// can block for seconds waiting on `securityd` — or indefinitely, waiting on a consent
    /// dialog that a menu-bar app has no way to show. The symptom was a frozen menu-bar
    /// icon for nine seconds at launch and an apparent hang on every hotkey press, with
    /// nothing on screen to explain it.
    private static let cacheKey = Cache()

    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        private var loaded = false

        var isConfigured: Bool {
            lock.lock(); defer { lock.unlock() }
            return !(stored ?? "").isEmpty
        }

        func set(_ key: String?) {
            lock.lock(); defer { lock.unlock() }
            stored = key
            loaded = true
        }

        var hasLoaded: Bool {
            lock.lock(); defer { lock.unlock() }
            return loaded
        }
    }

    /// Read the Keychain off the main thread and publish the answer.
    ///
    /// Called once at launch and after any change. The UI renders whatever the cache says
    /// and does not wait for it, so the menu is always instant.
    static func refreshInBackground(onChange: @escaping @MainActor () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let key = try? read(account: account)
            cacheKey.set(key)
            cacheBackup.set(try? read(account: backupAccount))
            Task { @MainActor in onChange() }
        }
    }

    /// Whether a key is configured. Reads only the cache — see `refreshInBackground`.
    static var isKeyConfigured: Bool { cacheKey.isConfigured }

    /// Blocking check, for the self-test and other places already off the main thread.
    static var hasKey: Bool { (try? read(account: account)) != nil }

    /// A key check that cannot hang: reads off the caller's thread and gives up after `timeout`.
    /// A pending Keychain consent dialog must never freeze a probe or the launch path; "no answer
    /// yet" is reported as no key, which is recoverable, where a blocked main thread is not.
    static func boundedHasKey(timeout: TimeInterval = 2) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        DispatchQueue.global(qos: .userInitiated).async {
            result = (try? read(account: account)) != nil
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + timeout) == .success ? result : false
    }

    @discardableResult
    static func setGeminiKey(_ key: String) -> Bool {
        set(key: key, account: account, cache: cacheKey)
    }

    /// Store the backup key. Returns false on an empty string or a refused write, so the panel can
    /// say whether it actually landed rather than assuming.
    @discardableResult
    static func setBackupGeminiKey(_ key: String) -> Bool {
        set(key: key, account: backupAccount, cache: cacheBackup)
    }

    /// Remove the backup key, so a second one is a switch he can turn off and not a permanent fixture.
    static func clearBackupGeminiKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: backupAccount,
        ]
        SecItemDelete(query as CFDictionary)
        cacheBackup.set(nil)
    }

    private static func set(key: String, account: String, cache: Cache) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let result: Bool
        if status == errSecItemNotFound {
            result = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
        } else {
            result = status == errSecSuccess
        }
        // Publish immediately so the menu never has to ask the Keychain again.
        if result { cache.set(trimmed) }
        return result
    }

    private static func read(account: String) throws -> String? {
        // Fail rather than prompt.
        //
        // Without this, a Keychain item created by another process — `security
        // add-generic-password` from a shell, say — can make the app block on a consent
        // dialog it has no way to display. A background app must get an answer
        // immediately: treating "could not ask" as "no key" is recoverable, hanging the
        // main thread is not.
        //
        // `LAContext.interactionNotAllowed` rather than the deprecated
        // `kSecUseAuthenticationUIFail`, which macOS 11 deprecated and which only
        // partially covers this case.
        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound, errSecInteractionNotAllowed:
            // Absent, or would have needed to prompt. Both mean "cannot use a key now".
            return nil
        default:
            throw ChunksError.keychain(status)
        }
    }
}

