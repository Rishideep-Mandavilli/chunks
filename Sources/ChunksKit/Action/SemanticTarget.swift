import Foundation

/// A control named in the operating system's own vocabulary, instead of pointed at in a picture.
///
/// This is the seam between two ways of acting on a Mac, and the difference is not elegance:
///
/// * A coordinate is a guess about an image. It is wrong when the window moves, when the display
///   is rescaled, when the model's aim is off by a row of pixels, and it is *unknowable* for a
///   window that is not on screen yet — which is why a multi-step plan used to need one spoken
///   command per step.
/// * `app=WhatsApp role=button name=Send` is a statement about the accessibility tree. It survives
///   a layout change, it works on a window that has only just opened, and it is checkable: either
///   exactly one element answers to it or the request is refused.
///
/// Coordinates stay supported. Chromium and Electron publish unnamed groups for their web content,
/// so a purely semantic assistant could not touch a web page at all — the pixel path is the
/// fallback for the parts of the screen that have no name, not a legacy to delete.
public struct SemanticTarget: Equatable, Sendable {

    /// The application, as its own name says it: "WhatsApp", "Finder", "Xcode".
    public var app: String

    /// An Accessibility role, lowercased and without the `AX` prefix: `button`, `textfield`,
    /// `checkbox`, `menuitem`, `link`. Optional, because a name is often unique on its own and the
    /// model should not be forced to guess a role it cannot see.
    public var role: String?

    /// What the control is called — its title, its description, or the words on it.
    public var name: String

    public init(app: String, role: String? = nil, name: String) {
        self.app = app
        self.role = role
        self.name = name
    }

    /// The sentence the confirm card and the log both show, so what the user agreed to and what
    /// Chunks went looking for cannot drift apart.
    public var questionPhrase: String {
        let rolePart = role.map { " \($0)" } ?? ""
        return "the\(rolePart) \"\(name)\" in \(app)"
    }

    /// The minimum agreement between a name the model wrote and a name the app publishes.
    ///
    /// Two, not one: `nameScore` gives 1 to a single shared token, and with no pixel to corroborate
    /// the guess, "the claude thing" matching one word of a control in another app is not a licence
    /// to press it. Inside a window the aim actually landed on, 1 is enough because the pixel is
    /// the evidence; here there is no pixel.
    public static let minNameScore = 2

    /// Words people use for the same field, when the app's own word is not one of them.
    ///
    /// A vision model reads the placeholder on the screen and writes what it sees; the element
    /// publishes something else — WhatsApp's composer says "Type a message" on screen and
    /// `Compose message` in its accessibility tree. Rather than refuse a request that named the
    /// right box in the wrong words, a field lookup tries the group's other members.
    ///
    /// Fields only, never press targets: a wrong field is caught twice over — the card names the
    /// field it found, and nothing is typed until the app says that field has focus — whereas a
    /// wrong *press* is an action. An alias group is also only tried when the exact name found
    /// nothing, so it can never displace a correct answer.
    public static let fieldAliasGroups: [[String]] = [
        ["message box", "compose message", "type a message", "write a message", "new message",
         "message field", "input"],
        ["search box", "search field", "search", "spotlight", "find"],
        ["address bar", "address and search bar", "omnibox", "url bar"],
        ["comment box", "add a comment", "write a comment", "leave a comment"],
        ["subject", "subject line"],
        ["to field", "recipients", "to"],
    ]

    /// The other names this field might be published under, in the order to try them.
    ///
    /// Empty when the name is not in a group, which is the ordinary case: the table is there for
    /// the handful of controls every app renames, not as a general thesaurus.
    public static func fieldAliasVariants(of name: String) -> [String] {
        let wanted = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let group = fieldAliasGroups.first(where: { $0.contains(wanted) }) else { return [] }
        return group.filter { $0 != wanted }
    }

    // MARK: - Parsing

    /// `app=WhatsApp name="Dad chat"` — key order does not matter, quotes are optional, and
    /// anything unrecognisable returns nil so the tag reaches the user as text.
    ///
    /// Failing closed on a malformed semantic target is deliberate: the fallback for a bad
    /// `[ACT:x,y:label]` is a visible tag, and the fallback for a half-parsed semantic one would
    /// otherwise be a press on whatever the remaining words happen to match.
    public static func parse(_ body: String) -> SemanticTarget? {
        let (fields, tail) = scanFields(body)
        // A named-control aim has no coordinates in it, so anything the scanner could not read as a
        // field means this is not a semantic body — it is the pixel form, or it is broken.
        guard tail.isEmpty, let app = fields["app"], let name = fields["name"] else { return nil }
        return SemanticTarget(app: app, role: fields["role"]?.lowercased(), name: name)
    }

    /// The `key=value` fields at the head of a body, and the text that stopped the scan.
    ///
    /// `parse` wants only the fields; `ActionRequest` wants the remainder as well, because the model
    /// sometimes qualifies a *pixel* aim with an app — `app=Qoder x=400,50:file title`, measured
    /// 2026-10-25 — and there the `x=…` is the aim, not a field it invented.
    static func scanFields(_ body: String) -> (fields: [String: String], tail: String) {
        var rest = Substring(body.trimmingCharacters(in: .whitespacesAndNewlines))
        var fields: [String: String] = [:]
        let allowed = ["app", "role", "name"]

        /// One `key="value"` pair. Quoted values may contain anything; a bare one runs to the next
        /// field, not to the next space.
        func takePair() -> (key: String, value: String)? {
            while rest.first == " " { rest = rest.dropFirst() }
            guard !rest.isEmpty else { return nil }
            guard let equals = rest.firstIndex(of: "=") else { return nil }
            let key = rest[..<equals].lowercased().trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: equals)...]
            guard let first = rest.first else { return nil }
            if first == "\"" || first == "'" {
                rest = rest.dropFirst()
                guard let closing = rest.firstIndex(of: first) else { return nil }
                let value = String(rest[..<closing])
                rest = rest[rest.index(after: closing)...]
                return value.isEmpty ? nil : (key, value)
            }

            // `app=Google Chrome name=Send` names a two-word application and `name=Dad chat` a
            // contact called two words. Cutting a bare value at the first space failed both: the
            // leftover word was read as a field name, that name was unknown, and the whole tag
            // closed — measured 2026-10-18 with `--probe-semantic app=Google Chrome …`, which the
            // prompt explicitly tells the model to write the app's own name. A bare value therefore
            // keeps taking words until one looks like `key=`, which is the only boundary this
            // grammar actually has.
            let words = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let head = words.first else { return nil }
            var value = head
            var next = words.index(after: words.startIndex)
            while next < words.endIndex, !SemanticTarget.looksLikeField(words[next]) {
                value += " " + words[next]
                next += 1
            }
            rest = Substring(words[next...].joined(separator: " "))
            return value.isEmpty ? nil : (key, value)
        }

        // Field order is not the model's problem to solve: `app=WhatsApp name=Send` and
        // `name=Send app=WhatsApp` are the same request, and a parser that insists on one of them
        // fails on the more likely input.
        while !rest.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let equals = rest.firstIndex(of: "=") else { return (fields, String(rest)) }
            let key = rest[..<equals].lowercased().trimmingCharacters(in: .whitespaces)
            if !allowed.contains(key) { return (fields, String(rest)) }
            guard let pair = takePair() else { return (fields, "") }
            fields[pair.key] = pair.value
        }
        return (fields, "")
    }

    /// Whether a loose word opens a field: `role=`, `name=x`, `app=`.
    ///
    /// Only letters before the `=`, so a control called "50%=off" or a time like "9:30=late" stays
    /// part of the value instead of being read as a key the model invented.
    static func looksLikeField(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "=") else { return false }
        let key = word[..<equals]
        return !key.isEmpty && key.allSatisfy(\.isLetter)
    }

    /// Does a published role answer to the one the model named?
    ///
    /// Soft on purpose, and only in one direction: `textfield` accepts `AXTextArea` and
    /// `AXSearchField`, because Catalyst puts the field-ness in the subrole and Chromium renames
    /// things per release. A role the model invented ("submit") matches nothing and the request is
    /// refused — a wrong role must not silently widen the search to every control in the app.
    ///
    /// The last test is containment, and it is there for the roles apps compose: a bookmark menu
    /// publishes `AXPopUpButton` and a hyperlink publishes `AXHyperlink`, so a model that says
    /// `role=button` or `role=link` about something the user can see is right, and refusing it on
    /// the exact string would be Chunks losing a press over vocabulary.
    public func roleMatches(_ published: String) -> Bool {
        guard let role else { return true }
        let publishedLower = published.lowercased()
        if publishedLower == role || publishedLower == "ax" + role { return true }
        let families: [[String]] = [
            ["button", "axbutton"], ["textfield", "axtextfield", "axtextarea", "axsearchfield"],
            ["checkbox", "axcheckbox"], ["menuitem", "axmenuitem"],
            ["link", "axlink"], ["table", "axtable", "axoutline"],
        ]
        let mine = families.first { $0.contains(role) }
        if mine?.contains(publishedLower) == true { return true }
        // Only the role words a model is told about may stretch this way, so an invented role still
        // matches nothing.
        return ["button", "link", "menu", "list", "text"].contains(role) && publishedLower.contains(role)
    }
}
