import Foundation

/// A keystroke Chunks can be asked to press, and what it is allowed to do.
///
/// This is the widened 3.10. The original task said "drive VS Code by name", and the reason it cannot
/// stay that small is measured on this machine: an Electron editor publishes **no Accessibility tree at
/// all** — `--probe-fields Qoder` reads 220 elements and finds 0 fields, where Terminal, a native app,
/// publishes its `AXTextArea` in 372. So anything that aims at a control inside an editor is blind
/// exactly where the developers work, and it would have needed a per-toolkit resolver for Electron,
/// for JetBrains' Swing, for Xcode's AppKit and for whatever renders through Metal.
///
/// A keystroke does not care. It goes to the focused element of the focused application, which is the
/// same route the `write` path already uses for `[TYPE:]`, and it is why this works in every IDE and
/// every app rather than in the one it was named for. What it costs is that the target of a key act is
/// an **app and its focus**, not an element the card can quote — so the two things this file owns are
/// the vocabulary (which key, which modifiers, how many times) and the judgement (what that key can do
/// to his machine). The judgement is the part that has to be right: `⌘Q` is one keystroke away from
/// closing the app he was working in, and `ctrl+C` in a terminal is one keystroke away from stopping a
/// build.
///
/// The key codes are not remembered from anywhere. They were printed out of this machine's own
/// `Carbon.HIToolbox` (`kVK_*`) and transcribed below, because the letters and digits are not
/// alphabetical and a table typed from memory is a table that presses the wrong key silently — the
/// category of bug invariant 1 exists for.
public enum KeyAction {

    /// `(keyCode, needsFunctionModifier)`. `needsFunctionModifier` is set for the keys that share a
    /// physical row with the media controls — home, end, page up and down, forward delete, help —
    /// which AppKit only honours when `fn` is held.
    public static let keyCodes: [String: (UInt16, Bool)] = [
        "'": (39, false),
        ",": (43, false),
        "-": (27, false),
        ".": (47, false),
        "/": (44, false),
        "0": (29, false),
        "1": (18, false),
        "2": (19, false),
        "3": (20, false),
        "4": (21, false),
        "5": (23, false),
        "6": (22, false),
        "7": (26, false),
        "8": (28, false),
        "9": (25, false),
        ";": (41, false),
        "=": (24, false),
        "[": (33, false),
        "\\": (42, false),
        "]": (30, false),
        "`": (50, false),
        "a": (0, false),
        "b": (11, false),
        "backspace": (51, false),
        "c": (8, false),
        "capslock": (57, false),
        "command": (55, false),
        "control": (59, false),
        "d": (2, false),
        "del": (117, false),
        "delete": (51, false),
        "down": (125, false),
        "e": (14, false),
        "end": (119, true),
        "enter": (36, false),
        "esc": (53, false),
        "escape": (53, false),
        "f": (3, false),
        "f1": (122, false),
        "f10": (109, false),
        "f11": (103, false),
        "f12": (111, false),
        "f2": (120, false),
        "f3": (99, false),
        "f4": (118, false),
        "f5": (96, false),
        "f6": (97, false),
        "f7": (98, false),
        "f8": (100, false),
        "f9": (101, false),
        "forwarddelete": (117, true),
        "g": (5, false),
        "h": (4, false),
        "help": (114, true),
        "home": (115, true),
        "i": (34, false),
        "j": (38, false),
        "k": (40, false),
        "l": (37, false),
        "left": (123, false),
        "m": (46, false),
        "n": (45, false),
        "newline": (36, false),
        "o": (31, false),
        "option": (58, false),
        "p": (35, false),
        "pagedown": (121, true),
        "pageup": (116, true),
        "q": (12, false),
        "r": (15, false),
        "return": (36, false),
        "right": (124, false),
        "s": (1, false),
        "shift": (56, false),
        "space": (49, false),
        "t": (17, false),
        "tab": (48, false),
        "u": (32, false),
        "up": (126, false),
        "v": (9, false),
        "w": (13, false),
        "x": (7, false),
        "y": (16, false),
        "z": (6, false),
    ]

    /// The four modifiers a person names, plus `function`, which this type adds itself rather than
    /// letting him hold it by hand: nobody says "fn and home", they say "home".
    public struct Modifiers: OptionSet, Equatable, Sendable, CustomStringConvertible {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)

        public var description: String {
            var out: [String] = []
            if contains(.control) { out.append("⌃") }
            if contains(.option) { out.append("⌥") }
            if contains(.shift) { out.append("⇧") }
            if contains(.command) { out.append("⌘") }
            if contains(.function) { out.append("fn") }
            return out.isEmpty ? "" : out.joined()
        }

        /// The words VoiceOver and the card's accessibility label get. Symbols alone are a caption
        /// nobody can read out.
        public var spoken: String {
            var out: [String] = []
            if contains(.control) { out.append("control") }
            if contains(.option) { out.append("option") }
            if contains(.shift) { out.append("shift") }
            if contains(.command) { out.append("command") }
            if contains(.function) { out.append("function") }
            return out.joined(separator: " ")
        }
    }

    public struct Combo: Equatable, Sendable {
        public let key: String
        public let keyCode: UInt16
        /// Whether this key only exists with `fn` held, so the driver knows to say so.
        public let needsFunction: Bool
        public let modifiers: Modifiers
        public let times: Int

        public var display: String {
            let prefix = modifiers.description
            let named = KeyAction.spokenName(key)
            // Uppercase when a modifier is held, because that is what every macOS menu shows: ⌘S,
            // ⇧⌘P. A lowercase letter beside a glyph reads like a different key than the one the app
            // advertises, and he is comparing it against the menu.
            let shown = (prefix.isEmpty || named.count > 1) ? named : named.uppercased()
            let base = prefix.isEmpty ? shown : prefix + shown
            return times > 1 ? "\(base) ×\(times)" : base
        }
    }

    /// What a key is allowed to be. The three-way split is the existing one: a routine act runs when
    /// asking is off, a permanent act is asked whatever the switch says, and a forbidden act is
    /// refused. Invariant 8's argument applies unchanged to the keyboard — "don't ask" is a standing
    /// instruction about routine editing, never an instruction to quit an app on a model's say-so.
    public enum Kind: Equatable, Sendable {
        case routine
        case command(reason: String)
        case refused(reason: String)
    }

    /// The most a single act may repeat. A model that writes `backspace x100000` is not asking to
    /// delete a file; it is asking for a freeze, and the keystroke loop has no other bound.
    public static let maxRepeat = 200

    // MARK: - Reading what was asked

    /// Parse a key body: `cmd+s`, `shift+down x3`, `backspace`, `ctrl+c`, `option+shift+right x10`.
    ///
    /// Fails to `nil` rather than guessing. A key action that could not be read must reach the card as
    /// the raw text it is — the fail-open rule every tag in this protocol follows, because a mistyped
    /// `[KEY:` that silently became `k` would delete a character from his file.
    public static func parse(_ body: String) -> Combo? {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        // The repetition suffix first, so a trailing `x` cannot be read as the letter x.
        var times = 1
        if let split = repetitionSplit(in: text) {
            guard split.count > 0 else { return nil }
            times = min(split.count, maxRepeat)
            text = split.head
        }
        guard !text.isEmpty else { return nil }

        let parts = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 1, !parts.contains(where: \.isEmpty) else { return nil }

        var modifiers = Modifiers()
        for modifier in parts.dropLast() {
            // Only the modifier names may appear before the last `+`. A key name that contains a
            // plus — `cmd++` — is refused rather than guessed at, because the guess would be a
            // keystroke nobody asked for.
            guard let flag = modifierFlag(modifier) else { return nil }
            modifiers.insert(flag)
        }
        guard let last = parts.last else { return nil }
        if parts.count == 1, modifierFlag(last) != nil {
            // A bare `cmd` is not a key. It would post nothing and report that it had.
            return nil
        }
        let key = normalise(last)
        guard let entry = keyCodes[key] else { return nil }
        return Combo(key: key, keyCode: entry.0, needsFunction: entry.1,
                     modifiers: modifiers, times: times)
    }

    /// Split `shift+down x3` into its head and its count. Returns nil when there is no suffix.
    private static func repetitionSplit(in text: String)
    -> (head: String, count: Int)? {
        guard let marker = text.lastIndex(where: { $0 == "x" || $0 == "\u{00D7}" }) else { return nil }
        let digits = text[text.index(after: marker)...].filter { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        // Everything before the marker must end with whitespace or be a `+`-separated run: `excel`
        // is not "e, c, x with a count of ell".
        let before = text[text.startIndex..<marker]
        guard before.isEmpty || before.last == " " else { return nil }
        guard let parsed = Int(digits), parsed > 0 else { return nil }
        return (before.trimmingCharacters(in: .whitespaces), parsed)
    }

    private static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command,
        "ctrl": .control, "control": .control,
        "opt": .option, "option": .option, "alt": .option,
        "shift": .shift, "fn": .function, "function": .function,
    ]

    private static func modifierFlag(_ name: String) -> Modifiers? { modifierNames[name] }

    /// The names a person actually says, folded onto the ones the SDK uses.
    private static func normalise(_ name: String) -> String {
        switch name {
        case "backspace": return "delete"          // Apple's `Delete` key IS backspace.
        case "del": return "forwarddelete"
        case "enter", "newline", "linefeed": return "return"
        case "esc": return "escape"
        case "page up": return "pageup"
        case "page down": return "pagedown"
        case "arrow left", "arrowleft": return "left"
        case "arrow right", "arrowright": return "right"
        case "arrow up", "arrowup": return "up"
        case "arrow down", "arrowdown": return "down"
        case "caps", "capslock": return "capslock"
        default: return name
        }
    }

    /// The word the card shows for a key. `⌫` for backspace would be a caption; he reads words.
    public static func spokenName(_ key: String) -> String {
        switch key {
        case "delete": return "backspace"
        case "forwarddelete": return "delete"
        case "return": return "return"
        case "escape": return "escape"
        case "pageup": return "page up"
        case "pagedown": return "page down"
        case "left": return "left"
        case "right": return "right"
        case "up": return "up"
        case "down": return "down"
        case "space": return "space"
        default: return key
        }
    }

    // MARK: - Judging it

    /// Decide what may be done with this key, given what currently has the focus.
    ///
    /// `focusedRole` is not decoration. The same `return` is a newline in a multiline editor and the
    /// Send button in a one-line composer — the distinction the `[TYPE:]` newline policy already makes
    /// for the same reason, and the reason a key act must ask for the role rather than assume it.
    public static func classify(_ combo: Combo, focusedRole: String?) -> Kind {
        let mods = combo.modifiers

        // A state toggle outside the document. Caps lock changes his whole machine, not the file,
        // and there is no undo for it; uppercase goes through shift, which this table already does.
        if combo.key == "capslock" {
            return .refused(reason: "Caps lock is a switch on his keyboard, not an edit. Type the "
                + "capital with shift instead.")
        }
        // Quitting already has a verb, and it is an always-asked one. Letting the key route reach the
        // same effect without the same sentence is how two doors stop agreeing about what is allowed.
        if mods.contains(.command), mods.contains(.option), combo.key == "escape" {
            return .refused(reason: "Force quitting an app is not something Chunks presses.")
        }
        if mods.contains(.command), combo.key == "q" {
            return .refused(reason: "To quit an app, say so — Chunks asks about that with its own "
                + "verb, where the cost is named.")
        }

        // Any command combination is an application command, and what it does is the app's business,
        // not ours: ⌘S writes to disk, ⌘P opens a palette that can run anything, ⌘⇧+3 takes a
        // screenshot of whatever is on screen. Asked whatever the switch says.
        if mods.contains(.command) {
            return .command(reason: "A ⌘ combination runs a command inside the app, and what that "
                + "command does is not something Chunks can predict.")
        }
        // Control combinations in a terminal are signals — ⌃C stops a process, ⌃D closes a session.
        if mods.contains(.control) {
            return .command(reason: "A control combination can stop a process or close a session.")
        }
        // `return` in a single-line field submits. That is the permanent-act class, by name.
        if combo.key == "return" {
            guard let focusedRole else {
                // Unknown fails toward asking — the rule `PolicyGate` already applies to an element
                // it cannot read. It is the common case here rather than an edge: an Electron editor
                // publishes no tree at all, so "what has the focus" is unanswerable exactly in the
                // apps this feature is for, and a Return into a chat composer is a sent message.
                return .command(reason: "Chunks cannot see which field has the focus, so it cannot "
                    + "say whether return makes a newline or submits it.")
            }
            if isSingleLineField(focusedRole) {
                return .command(reason: "The field that has the focus is a single line, so return "
                    + "submits it rather than breaking it.")
            }
        }
        return .routine
    }

    /// The roles that submit on return instead of making a newline. `AXTextArea` is multiline and is
    /// deliberately NOT in this set — the same split `newlinePolicy` makes for `[TYPE:]`.
    static func isSingleLineField(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXTextField" || role == "AXSearchField" || role == "AXComboBox"
            || role == "AXPasswordBox" || role == "AXSecureTextField"
    }

    // MARK: - Saying it

    /// The card's question. It names the app, because a keystroke lands wherever the caret is and the
    /// only honest thing to approve is which application is about to receive it.
    public static func question(for combo: Combo, appName: String) -> String {
        "Press \(combo.display) in \(appName)?"
    }

    /// The line after it happened, spoken as well as written — the rule every act already follows:
    /// something he can neither hear nor find in the record is indistinguishable from a key press
    /// that never occurred.
    public static func outcome(for combo: Combo, appName: String) -> String {
        "Pressed \(combo.display) in \(appName)."
    }
}
