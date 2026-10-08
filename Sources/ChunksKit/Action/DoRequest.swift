import Foundation

/// A tool the model wants run: something outside the screen it can ask Chunks to change.
///
/// Deliberately **not** a general "command" type. Each tool here was chosen because its whole
/// effect fits in one sentence the user can read before approving it — which is the bar the
/// confirm card sets. Typing, deleting, dragging and shell commands are absent because no
/// one-line question honestly describes what they would do.
public enum DoRequest: Equatable, Sendable {

    /// Launch an app that is already installed. Opening is reversible and reveals nothing, so it
    /// is the one act that can be allowed for an app permanently.
    case openApp(name: String)

    /// Set the system output volume, 0...100 percent.
    case setVolume(percent: Int)

    /// Open a web address in a browser — the honest way to do "open youtube in chrome".
    ///
    /// Deliberately not a `[TYPE]` into the address bar plus a Return. Handing the URL to
    /// `NSWorkspace` makes the browser open it in a new tab of the window the user already has,
    /// which means no keystroke leaves Chunks, nothing is submitted on their behalf, and a page
    /// that takes three seconds to load cannot make the next step land on the wrong pixel. The
    /// typing route also has to guess where the address bar is, which is the aim problem this
    /// codebase already measured.
    ///
    /// `browser` is nil for "whatever you use"; the card says "your browser" rather than naming
    /// an app Chunks has not chosen.
    case openURL(url: String, browser: String?)

    /// `[DO:open_app:Notes]`, `[DO:set_volume:40]`, `[DO:open_url:youtube.com|Chrome]`.
    ///
    /// Tolerant of the whole space the model writes in: lower-case tool names, stray spaces, a
    /// percent sign, `"50%"`, `"half"`. A malformed body returns `nil` and the parser fails open
    /// by showing the tag, so the user sees what the model meant instead of nothing happening.
    public static func parse(_ inner: String) -> DoRequest? {
        let body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = body.firstIndex(of: ":") else { return nil }
        let tool = body[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
        let argument = body[body.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard !tool.isEmpty, !argument.isEmpty else { return nil }

        switch tool {
        case "open_app", "open", "launch":
            let name = argument.trimmingCharacters(in: .whitespaces)
            // An app name with a slash or a leading dot is a path, and a path is how a prompt
            // injection reaches something other than /Applications.
            guard !name.contains("/"), !name.hasPrefix("."), name.count <= 60 else { return nil }
            return .openApp(name: name)

        case "set_volume", "volume":
            guard let percent = DoRequest.volumePercent(in: argument) else { return nil }
            return .setVolume(percent: percent)

        case "open_url", "open_website", "go_to", "url":
            let parts = argument.components(separatedBy: "|")
            guard let url = DoRequest.normalizedURL(parts[0]) else { return nil }
            return .openURL(url: url, browser: parts.count > 1 ? DoRequest.browserName(parts[1]) : nil)

        default:
            return nil
        }
    }

    /// A web address from whatever the model wrote: `youtube.com`, `https://getpocket.com/`.
    ///
    /// Anything that is not http(s) is refused rather than clamped — `file:`, `javascript:`, and
    /// `data:` are all one string away from being a web address to a model that was asked to open
    /// a site. A host without a dot in it is a word, not a domain, which is what stops
    /// `[DO:open_url:Notes]` from becoming a search for the literal text "Notes".
    static func normalizedURL(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= 200, !text.contains(where: { $0.isWhitespace })
        else { return nil }

        let withScheme: String
        if text.hasPrefix("https://") || text.hasPrefix("http://") {
            withScheme = text
        } else if text.contains("://") || text.hasPrefix("file:") || text.hasPrefix("javascript:") {
            return nil
        } else {
            withScheme = "https://" + text
        }
        guard let host = URLComponents(string: withScheme)?.host, host.contains(".") else { return nil }
        return withScheme
    }

    /// The address as the card and the spoken line show it: no scheme.
    ///
    /// The stored string keeps `https://` because that is what gets opened; "Open https://
    /// youtube.com in Chrome?" is a sentence nobody reads out loud, and the user scans the host
    /// either way.
    static func displayURL(_ url: String) -> String {
        guard let scheme = url.range(of: "://") else { return url }
        return String(url[scheme.upperBound...])
    }

    /// The browser half of an `open_url` body, or nil when it is not a plain name.
    static func browserName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), name.count <= 60
        else { return nil }
        return name
    }

    /// Percent from whatever the model wrote: `40`, `40%`, `0.4`, `40 percent`.
    ///
    /// A bare `0...1` decimal is read as a *fraction* (`0.4` → 40), because that is how models
    /// reach for volume constantly, and reading it as 0.4 percent would set the machine to mute
    /// while the card said "40".
    static func volumePercent(in text: String) -> Int? {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "percent", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value >= 0 else { return nil }
        let percent = value <= 1 ? value * 100 : value
        let rounded = Int(percent.rounded())
        guard rounded <= 100 else { return nil }
        return rounded
    }
}

/// What the card asks, in the user's language.
///
/// Kept apart from the request because the wording is UI, and the request is the thing being
/// approved: if the two ever disagree, the user approved something other than what they read.
public enum ToolLayer {

    /// The question for the card. One line, present tense, names the exact effect.
    public static func question(for request: DoRequest) -> String {
        switch request {
        case .openApp(let name):
            return "Open \(name)?"
        case .setVolume(let percent):
            return "Set the volume to \(percent)%?"
        case .openURL(let url, let browser):
            return "Open \(DoRequest.displayURL(url)) in \(browser ?? "your browser")?"
        }
    }

    /// Whether running this changes something outside the app's own windows.
    ///
    /// Both current tools do, so both are asked about; the distinction exists so "allowed
    /// without asking" stays a deliberate decision rather than the default for new tools.
    public enum Effect: Equatable, Sendable {
        case changesSystemState
    }

    public static func effect(of request: DoRequest) -> Effect {
        switch request {
        case .openApp, .setVolume, .openURL:
            return .changesSystemState
        }
    }

    /// One line confirming what happened, after the shell ran it.
    public static func outcomeLine(for request: DoRequest, succeeded: Bool) -> String {
        switch request {
        case .openApp(let name):
            return succeeded ? "Opened \(name)." : "Could not open \(name)."
        case .setVolume(let percent):
            return succeeded ? "Volume set to \(percent)%." : "The volume refused to change."
        case .openURL(let url, let browser):
            let target = browser ?? "your browser"
            return succeeded ? "Opened \(DoRequest.displayURL(url)) in \(target)."
                             : "Nothing opened \(DoRequest.displayURL(url))."
        }
    }
}
