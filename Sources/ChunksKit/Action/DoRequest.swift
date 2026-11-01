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

    /// Run a shortcut the user built and named: `shortcuts://run-shortcut?name=Focus`.
    ///
    /// The URL-scheme half of the same move the semantic aim makes on screen — hand the operating
    /// system a statement of intent instead of a sequence of pixels. The click route is *open
    /// Shortcuts, find the tile, press it*: three aims at a window Chunks has never seen, where a
    /// tile that moved runs a different automation from the one the card described. The scheme names
    /// one thing, and the only judgement left is whether the user's own shortcut name arrived intact.
    ///
    /// It is also why there is no `focus` tool of Chunks' own: the automation belongs to the user,
    /// and a named run is the honest way to reach it.
    case runShortcut(name: String)

    /// Start an email to an address: `mailto:`.
    ///
    /// Fills a new message in whatever owns mail and stops there. Chunks never sends, because
    /// sending is the part the user has to see and press.
    case email(to: String)

    /// Add a routine: a prompt with a time attached, which Chunks asks itself later.
    ///
    /// The panel already lets him add one; this is the other half of the same store, so "every
    /// morning at 8, brief me" said out loud lands in the schedule instead of being forgotten. It is
    /// a *standing* instruction — it fires when he is not looking — so the whole payload has to fit
    /// on the card: hence `routinePromptLimit`, which is stricter than the file's own cap because a
    /// 400-character question cannot be read in two lines and approving what one cannot read is the
    /// failure this codebase keeps having to relearn.
    case addRoutine(title: String, cadence: Routine.Cadence, prompt: String)

    /// Take a routine out of the schedule, by the name he gave it.
    case removeRoutine(title: String)

    /// Arm one thing to say, once, at a time he said in words.
    ///
    /// The other half of his schedule, which a routine cannot be: a routine is a *recurring*
    /// question Chunks asks itself, and "in ten minutes tell me to stretch" is neither recurring nor
    /// a question. Firing it writes nothing, opens nothing and calls no model — the whole effect is
    /// one line on the card and one sentence out loud, which is why the question fits the card's two
    /// lines and why this tool need not be asked about with asking switched off.
    case addReminder(text: String, timing: ReminderTiming)

    /// Take a waiting reminder out, by the words he used for it.
    case cancelReminder(text: String)

    /// Show one thing in Finder — the folder opened, or the file selected inside its parent.
    ///
    /// The tool "open the memora workspace in finder" needs, which nothing here covered: `open_app`
    /// launches Finder without saying *where*, and an `[ACT]` on a Finder window that is not on
    /// screen yet is a press aimed at a picture that does not exist.
    ///
    /// The body is a path or a name — the shell resolves a name against his folders before the card
    /// is built, so the question always names a real path and never a guess the model invented. The
    /// effect is read-only in the strictest sense: a Finder window opens and nothing on disk
    /// changes — but it *displays* what is there, so the same allow-list and credential deny-list
    /// that guard a read guard this too.
    case reveal(path: String)

    /// Run one program with fixed arguments: `caffeinate -di -t 3600`.
    ///
    /// The tool "run me the terminal command that stops sleep" needs, and the reason it is shaped
    /// the way it is: **there is no shell.** The parsed form is an argv array handed to
    /// `Process` directly, so `;`, `&&`, `|`, backticks and `$()` have no meaning to give them —
    /// they are refused as characters, not escaped. A model cannot compose a second command inside
    /// the first, which is the whole difference between a tool and a hole.
    ///
    /// It is also the one tool that is **asked about even with asking switched off**, like a control
    /// the app calls Send: an unattended command from a model is the exact thing the confirm card
    /// exists for, and "don't ask" is a standing instruction about routine acts, never a licence to
    /// execute anything a sentence produced.
    case runCommand(argv: [String])

    /// `[DO:open_app:Notes]`, `[DO:set_volume:40]`, `[DO:open_url:youtube.com|Chrome]`,
    /// `[DO:run_shortcut:Focus]`, `[DO:email:rick@studio.com]`.
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

        case "run_shortcut", "shortcut", "run_automation":
            let name = argument.trimmingCharacters(in: .whitespaces)
            guard DoRequest.shortcutNameIsValid(name) else { return nil }
            return .runShortcut(name: name)

        case "email", "mail_to", "write_to":
            let address = argument.trimmingCharacters(in: .whitespaces)
            guard DoRequest.emailAddressIsValid(address) else { return nil }
            return .email(to: address)

        case "routine_add", "add_routine", "schedule":
            let parts = argument.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 3,
                  let cadence = DoRequest.routineCadence(from: parts[1])
            else { return nil }
            guard DoRequest.routineTitleIsValid(parts[0]),
                  DoRequest.routinePromptIsValid(parts[2]) else { return nil }
            let candidate = DoRequest.addRoutine(title: parts[0], cadence: cadence,
                                                 prompt: parts[2])
            // The whole question has to fit the two lines the card gives it. Checking the parts
            // separately is not enough: a 60-character name and a 120-character question are each
            // legal and together unreadable, and approving a schedule one cannot finish reading is
            // exactly the thing this codebase keeps having to relearn.
            guard ToolLayer.question(for: candidate).count <= DoRequest.maxQuestionCharacters
            else { return nil }
            return candidate

        case "routine_remove", "remove_routine", "cancel_routine":
            let title = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard DoRequest.routineTitleIsValid(title) else { return nil }
            return .removeRoutine(title: title)

        case "remind", "reminder", "add_reminder", "set_timer", "timer":
            let parts = argument.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, let timing = ReminderTiming.parse(parts[1]),
                  DoRequest.reminderTextIsValid(parts[0]) else { return nil }
            let candidate = DoRequest.addReminder(text: parts[0], timing: timing)
            // The same rule that refuses a long routine or a long command line: the card has two
            // measured lines, and a question that runs past them is refused rather than clipped.
            guard ToolLayer.question(for: candidate).count <= DoRequest.maxQuestionCharacters
            else { return nil }
            return candidate

        case "remind_cancel", "cancel_reminder", "clear_reminder":
            let text = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard DoRequest.reminderTextIsValid(text) else { return nil }
            return .cancelReminder(text: text)

        case "reveal", "show_in_finder", "open_in_finder", "reveal_in_finder":
            let path = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard DoRequest.revealPathIsValid(path) else { return nil }
            return .reveal(path: path)

        case "run_command", "command", "shell", "terminal":
            guard let argv = DoRequest.commandArgv(in: argument) else { return nil }
            let candidate = DoRequest.runCommand(argv: argv)
            // Same discipline as a routine: the card has a measured number of lines, and a request
            // whose question runs past it is refused at parse rather than clipped in front of him.
            // Approving half a command line is approving nothing.
            guard ToolLayer.question(for: candidate).count <= DoRequest.maxQuestionCharacters else {
                return nil
            }
            return candidate

        default:
            return nil
        }
    }

    /// A routine question short enough to read on the card that asks for it.
    ///
    /// The file allows 400 characters because the panel has room; the card has two lines. Refusing
    /// the long one is right — a schedule added from a question the user could not finish reading is
    /// not a schedule he agreed to.
    public static let routinePromptLimit = 120

    /// The longest confirm question the card can show in full.
    ///
    /// `AnswerPanelLayout.confirmQuestionHeight` is two lines of 12 pt medium across a 360 pt card,
    /// which measures out at about 50 characters a line. Past that the text is clipped, and a
    /// clipped question is an approval given for words nobody saw.
    public static let maxQuestionCharacters = 100

    static func routineTitleIsValid(_ title: String) -> Bool {
        guard !title.isEmpty, title.count <= RoutinesStore.maxTitleCharacters,
              !title.contains("|"), !title.contains(where: { $0.isNewline || $0 == "\t" })
        else { return false }
        return title == title.trimmingCharacters(in: .whitespaces)
    }

    static func routinePromptIsValid(_ prompt: String) -> Bool {
        guard !prompt.isEmpty, prompt.count <= routinePromptLimit,
              !prompt.contains("|"), !prompt.contains(where: { $0.isNewline || $0 == "\t" })
        else { return false }
        return prompt == prompt.trimmingCharacters(in: .whitespaces)
    }

    /// What a reminder's one line may be.
    ///
    /// `|` is the field separator inside the tag, so a text containing one would be two arguments
    /// by the time the parser split it — and a reminder whose words silently lost their second half
    /// is a note that says the opposite of what he asked for. The length ceiling is the store's, so
    /// the model's tag, the panel's row and the file all refuse for the same number.
    static func reminderTextIsValid(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= ReminderStore.maxTextCharacters,
              !text.contains("|"), !text.contains(where: { $0.isNewline || $0 == "\t" })
        else { return false }
        return text == text.trimmingCharacters(in: .whitespaces)
    }

    /// `daily at 08:00`, `every day at 8:00`, `weekdays at 09:30`, `every 30 minutes`,
    /// `every 2 hours` — and nothing else.
    ///
    /// Deliberately not a general time parser. A cadence the model words some other way is refused
    /// at parse time and shown as text, which is the safe failure: a routine that fires at a time
    /// Chunks guessed is a notification at the wrong hour, and the schedule is still editable in the
    /// panel from there.
    static func routineCadence(from text: String) -> Routine.Cadence? {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard let lead = words.first else { return nil }

        if lead == "every", words.count >= 3, words[1].allSatisfy(\.isNumber),
           let amount = Int(words[1]) {
            let unit = words[2]
            if unit.hasPrefix("min") { return .every(minutes: amount) }
            if unit.hasPrefix("h") { return .every(minutes: amount * 60) }
            // "every day at …" falls through to the daily branch below.
            if unit != "day" { return nil }
        }

        let weekdaysOnly: Bool
        var rest = Array(words.dropFirst())
        switch lead {
        case "weekdays", "weekday": weekdaysOnly = true
        case "daily", "every": weekdaysOnly = false
        default: return nil
        }
        if rest.first == "day" { rest = Array(rest.dropFirst()) }
        if rest.first == "at" { rest = Array(rest.dropFirst()) }
        guard let (hour, minute) = RoutinesStore.timeOfDay(from: rest.joined(separator: " "))
        else { return nil }
        // Re-rendered as `HH:mm` so a routine written as "8:00" stores the same shape the panel
        // writes, and the card shows the time the scheduler will actually use.
        let at = String(format: "%02d:%02d", hour, minute)
        return weekdaysOnly ? .weekdays(at: at) : .daily(at: at)
    }

    /// A shortcut name worth sending at all.
    ///
    /// The encoding is handled by `URLComponents`, so a name containing `&` or `=` cannot smuggle a
    /// second query item in — refusing those would only lose real shortcut names, which people do
    /// call "Focus & Deep work". What stays refused is what no human named: an empty or absurdly
    /// long string, a path-shaped one, control characters, and a name the model padded with spaces,
    /// since the card has to show the same words Shortcuts is asked to find.
    static func shortcutNameIsValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 60, !name.contains("/") else { return false }
        if name.contains(where: { $0.isNewline || $0 == "\t" }) { return false }
        return name == name.trimmingCharacters(in: .whitespaces)
    }

    /// What `[DO:reveal:…]` will accept as its argument: a path, or one name to look for.
    ///
    /// A path is checked against the allowed roots later, by the same code that guards a read — but
    /// only *after* the shell has expanded and standardised it, which needs a home directory this
    /// pure function must not assume. What is refused here is the shape no resolution can make safe:
    /// a nested scheme (`file://…` would be handed to whatever owns URLs rather than to Finder), a
    /// string with a newline in it (two paths are not one question), a leading `-` (a flag to an
    /// argument parser somewhere down the line), and anything long enough that the card cannot show
    /// where it is about to look.
    static func revealPathIsValid(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= revealPathLimit else { return false }
        if path.contains(where: { $0.isNewline || $0 == "\t" }) { return false }
        if path.contains("://") || path.hasPrefix("-") { return false }
        return path == path.trimmingCharacters(in: .whitespaces)
    }

    /// Long enough for a real deep path, short enough to read on the card in one line.
    public static let revealPathLimit = 200

    // MARK: - One command, no shell

    /// Characters that would give a shell something to interpret.
    ///
    /// `Process` is handed an argv array, so none of these *would* be interpreted — but a model that
    /// writes them believes it is composing something, and the honest answer is to refuse the tag and
    /// let the user read it, not to run a third of what it meant.
    static let commandMetacharacters = Set(";&|<>`$\n\\")

    /// Programs Chunks will not run whatever the arguments.
    ///
    /// Three kinds: things that destroy (`rm`, `dd`, `diskutil`, `mv`), things that escalate or
    /// reconfigure the machine (`sudo`, `defaults`, `security`, `codesign`, `chown`), and things that
    /// move data off it (`curl`, `wget`, `ssh`, `scp`, and the package managers that fetch and run).
    /// A command line fits one sentence on a card; these do not fit one honest question.
    public static let deniedPrograms: Set<String> = [
        "rm", "rmdir", "mv", "dd", "mkfs", "diskutil", "tmutil", "chown", "chmod", "shred",
        "sudo", "su", "doas", "defaults", "security", "codesign", "csrutil", "nvram", "kickstart",
        "kill", "killall", "pkill", "shutdown", "halt", "reboot", "logout",
        "curl", "wget", "nc", "telnet", "ssh", "scp", "sftp", "rsync",
        "brew", "npm", "npx", "pip", "pip3", "gem", "cargo", "swiftpm",
    ]

    /// The longest command line the card can show in full: `maxQuestionCharacters` minus the
    /// "Run …?" wrapped around it. The two are one rule, not two — a longer line would be caught by
    /// the question check anyway, and a limit nobody can derive from the other is a limit that drifts.
    public static let commandLimit = maxQuestionCharacters - 5

    /// The program names are looked up in this PATH and nowhere else.
    public static let commandSearchPaths = ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]

    /// Parse `[DO:run_command:…]` into an argv array, or nil when it is not exactly one command.
    ///
    /// Quoting is supported for arguments with spaces — `osascript -e "tell app …"` is a real shape —
    /// and nothing else is: no redirection, no chaining, no substitution, no path to the program.
    public static func commandArgv(in text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= commandLimit else { return nil }
        if trimmed.contains(where: { commandMetacharacters.contains($0) }) { return nil }

        var argv: [String] = []
        var current = ""
        var quote: Character?
        for character in trimmed {
            if let opened = quote {
                if character == opened {
                    argv.append(current); current = ""; quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                if !current.isEmpty { argv.append(current); current = "" }
                quote = character
                continue
            }
            if character == " " || character == "\t" {
                if !current.isEmpty { argv.append(current); current = "" }
                continue
            }
            current.append(character)
        }
        if quote != nil { return nil }        // an unclosed quote is a truncated command
        if !current.isEmpty { argv.append(current) }

        guard let program = argv.first, argv.count >= 2, argv.count <= 9 else { return nil }
        // A bare name only. `/Users/x/thing` or `./build.sh` is a program chosen by a path the user
        // cannot see on the card, and the search paths exist so that the visible name is the whole
        // decision.
        guard !program.contains("/"), program == program.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        guard !deniedPrograms.contains(program) else { return nil }
        // Arguments may still name a denied program's subject, but the program is what decides the
        // blast radius, and `caffeinate` has no argument that damages a disk.
        return argv
    }

    /// An email address, checked for the two things that make it one: an `@`, and a dotted domain.
    ///
    /// Deliberately weak on everything else — the only job here is to stop `[DO:email:hey]` from
    /// opening a compose window whose To field is nonsense, and to refuse anything that looks like
    /// two addresses or a scheme rather than one recipient. A colon is what makes the second: a
    /// model that writes `mailto:x@y.com` into the argument is trying to nest a scheme inside the
    /// scheme, and the address it hands the mail app is not the one the user said.
    static func emailAddressIsValid(_ address: String) -> Bool {
        guard !address.isEmpty, address.count <= 120,
              !address.contains(where: { $0.isWhitespace }), !address.contains(":")
        else { return false }
        let parts = address.components(separatedBy: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { return false }
        return !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".") && !address.contains("/")
    }

    /// The `shortcuts://` URL for an approved run, or nil when the name cannot be encoded.
    ///
    /// Built through `URLComponents` rather than string concatenation: a shortcut called
    /// "Focus & Deep work" has to arrive as one name, and hand-stitching a query is how a space
    /// or an ampersand becomes a different request.
    static func shortcutURL(name: String) -> URL? {
        guard shortcutNameIsValid(name) else { return nil }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    /// The `mailto:` URL for an approved address.
    static func mailtoURL(address: String) -> URL? {
        guard emailAddressIsValid(address) else { return nil }
        return URL(string: "mailto:" + address)
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
        case .runShortcut(let name):
            return "Run the shortcut \"\(name)\"?"
        case .email(let address):
            return "Start an email to \(address)?"
        case .addRoutine(let title, let cadence, let prompt):
            // The prompt is in the question because the prompt *is* the routine: approving a time
            // without seeing what gets asked at it would be agreeing to something unread.
            return "Add \"\(title)\" — \(cadence.inSentence) — asking \"\(prompt)\"?"
        case .removeRoutine(let title):
            return "Remove the routine \"\(title)\"?"
        case .addReminder(let text, let timing):
            return "Remind \"\(text)\" \(timing.phrase)?"
        case .cancelReminder(let text):
            return "Cancel the reminder \"\(text)\"?"
        case .reveal(let path):
            return "Show \(revealLabel(path)) in Finder?"
        case .runCommand(let argv):
            return "Run \(argv.joined(separator: " "))?"
        }
    }

    /// Whether this tool is asked about even when the user has switched asking off.
    ///
    /// The same standing-instruction rule that keeps a Send button behind a card: "don't ask" means
    /// "do not interrupt me for routine navigation", never "execute anything a sentence produced".
    /// A command line is the one tool whose effect cannot be undone by pressing Not now later.
    ///
    /// A reminder is not on that list, and the reason is worth keeping visible: firing one writes
    /// nothing, opens nothing, captures nothing and calls no model — it is one line on a card and one
    /// sentence out loud. The card at arming is the consent, and it still happens whenever asking is
    /// on.
    public static func alwaysAsks(_ request: DoRequest) -> Bool {
        if case .runCommand = request { return true }
        return false
    }

    /// The line reported after a reminder was armed, naming the moment the file holds.
    ///
    /// Separate from `outcomeLine(for:succeeded:)` because the request carries the *phrase* he used
    /// and the schedule carries the *date*, and only the date is worth reporting: `at 21:00` written
    /// at 22:00 fires tomorrow, and a report that repeats the phrase would hide that.
    public static func reminderArmedLine(text: String, fireAt: Date, now: Date = Date()) -> String {
        "Reminder armed — \(text) \(ReminderStore.spoken(fireAt: fireAt, now: now))."
    }

    /// The name a reveal's card shows: the thing itself, and the folder it lives in.
    ///
    /// Lives with the policy (`RevealPolicy`) because both are decided from the same path, and the
    /// card must describe exactly what the resolver was allowed to open.
    static func revealLabel(_ path: String) -> String { RevealPolicy.label(for: path) }

    /// Whether running this changes something outside the app's own windows.
    ///
    /// Both current tools do, so both are asked about; the distinction exists so "allowed
    /// without asking" stays a deliberate decision rather than the default for new tools.
    public enum Effect: Equatable, Sendable {
        case changesSystemState
    }

    public static func effect(of request: DoRequest) -> Effect {
        switch request {
        case .openApp, .setVolume, .openURL, .runShortcut, .email, .addRoutine, .removeRoutine,
             .addReminder, .cancelReminder, .reveal, .runCommand:
            return .changesSystemState
        }
    }

    /// One line confirming what happened, after the shell ran it.
    public static func outcomeLine(for request: DoRequest, succeeded: Bool,
                                   commandStillRunning: Bool = false) -> String {
        switch request {
        case .openApp(let name):
            return succeeded ? "Opened \(name)." : "Could not open \(name)."
        case .setVolume(let percent):
            return succeeded ? "Volume set to \(percent)%." : "The volume refused to change."
        case .openURL(let url, let browser):
            let target = browser ?? "your browser"
            return succeeded ? "Opened \(DoRequest.displayURL(url)) in \(target)."
                             : "Nothing opened \(DoRequest.displayURL(url))."
        case .runShortcut(let name):
            return succeeded ? "Ran the shortcut \"\(name)\"."
                             : "Shortcuts did not take the run request for \"\(name)\"."
        case .email(let address):
            return succeeded ? "Opened a new message to \(address)."
                             : "Nothing opened a new message."
        case .addRoutine(let title, let cadence, _):
            return succeeded ? "Added \"\(title)\", \(cadence.inSentence)."
                             : "The routine was not added."
        case .removeRoutine(let title):
            return succeeded ? "Removed \"\(title)\"."
                             : "There is no routine called \"\(title)\"."
        case .addReminder(let text, let timing):
            return succeeded ? "Reminder armed — \(text) \(timing.phrase)."
                             : "That reminder was not armed."
        case .cancelReminder(let text):
            return succeeded ? "Cancelled \"\(text)\"."
                             : "Nothing is waiting called \"\(text)\"."
        case .reveal(let path):
            // Names the folder it opened, because with asking off this runs unannounced and the
            // spoken line is the only report that anything happened at all.
            return succeeded ? "Showed \(revealLabel(path)) in Finder."
                             : "Finder did not open \(revealLabel(path))."
        case .runCommand(let argv):
            // Says the program, not the whole line: the user already read the line on the card, and
            // what he needs back is whether it worked.
            //
            // Three states, because a command that is *meant* to keep running has always been the
            // common case here — `caffeinate -di -t 21600` is "keep my Mac awake for six hours", and
            // "caffeinate finished" spoken over a hold that has four hours left on it is the same
            // class of lie as a press reported from an advertised verb that never ran.
            if commandStillRunning {
                return "\(argv[0]) is running and Chunks has stopped watching it."
            }
            return succeeded ? "\(argv[0]) finished."
                             : "\(argv.joined(separator: " ")) did not run."
        }
    }
}
