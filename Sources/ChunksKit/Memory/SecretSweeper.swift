import Foundation

/// Stops credentials reaching Chunks' memory file.
///
/// Memory is a plain-text file the user can read and edit, which is the whole point —
/// but that also means anything written there is trivially exfiltrated if memory ever
/// ends up in a prompt, a screenshot, a bug report, or a git commit. The model is asked
/// to "remember" things, and a user who reads an API key aloud is exactly the case that
/// would otherwise persist it forever.
///
/// This runs on **every** proposed fact before it is written. The model proposes; the
/// app disposes. Rejected facts are reported, never silently dropped.
public enum SecretSweeper {

    public enum Verdict: Equatable {
        /// Nothing suspicious.
        case clean
        /// A credential-shaped string was found. `reason` is safe to show the user.
        case rejected(reason: String)
        /// No credential, but the text reads like it is about one — worth a nudge.
        case warned(reason: String)

        public var isAcceptable: Bool { if case .rejected = self { return false }; return true }
    }

    /// Token shapes we refuse outright. Each is a real prefix used by a real provider.
    private static let hardPatterns: [(name: String, regex: NSRegularExpression)] = [
        ("OpenAI-style key (sk-)",            try! NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9_\-]{16,}"#)),
        ("Anthropic key (sk-ant-)",           try! NSRegularExpression(pattern: #"\bsk-ant-[A-Za-z0-9_\-]{16,}"#)),
        ("OpenCode key (oc_sk_)",             try! NSRegularExpression(pattern: #"\boc_sk_[A-Za-z0-9_\-]{16,}"#)),
        ("GitHub token (ghp_/gho_/ghs_)",     try! NSRegularExpression(pattern: #"\bgh[pousr]_[A-Za-z0-9]{16,}"#)),
        ("GitLab token (glpat-)",             try! NSRegularExpression(pattern: #"\bglpat-[A-Za-z0-9_\-]{16,}"#)),
        ("AWS access key id (AKIA/ASIA)",    try! NSRegularExpression(pattern: #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#)),
        ("Google API key (AIza)",            try! NSRegularExpression(pattern: #"\bAIza[A-Za-z0-9_\-]{20,}"#)),
        ("Slack token (xox*)",               try! NSRegularExpression(pattern: #"\bxox[baprs]-[A-Za-z0-9\-]{10,}"#)),
        ("Firebase / FCM key",               try! NSRegularExpression(pattern: #"\bAAAA[A-Za-z0-9_\-]{20,}"#)),
        ("JSON Web Token",                    try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}"#)),
        ("Private key block",                 try! NSRegularExpression(pattern: #"-----BEGIN[A-Z ]*PRIVATE KEY-----"#)),
        ("Bearer token in a URL/header",     try! NSRegularExpression(pattern: #"[Bb]earer\s+[A-Za-z0-9_\-\.=]{24,}"#)),
    ]

    /// Long unbroken runs. Conservative about *what counts* as one: a hyphenated slug
    /// like `very-long-descriptive-project-name-final-v2` is 43 chars but is not a
    /// credential, so a bare length test produced false rejections. 32 is the floor;
    /// `looksRandom` then requires all three character classes.
    private static let entropyPattern = try! NSRegularExpression(pattern: #"\b[A-Za-z0-9+/=_\-]{32,}\b"#)

    /// Words that suggest the fact is *about* a credential. Not a rejection on its own —
    /// "my password manager is 1Password" is a perfectly good thing to remember.
    private static let sensitiveWords = [
        "password", "passwd", "api key", "apikey", "secret", "token", "credential",
        "private key", "access key", "auth token", "bearer", "session id", "cookie",
        "otp", "2fa code", "recovery code", "seed phrase", "mnemonic",
    ]

    public static func inspect(_ text: String) -> Verdict {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        for (name, regex) in hardPatterns {
            if regex.firstMatch(in: text, range: full) != nil {
                return .rejected(reason: "looks like a \(name)")
            }
        }

        if let m = entropyPattern.firstMatch(in: text, range: full) {
            let run = ns.substring(with: m.range)
            // Only treat it as suspicious if it also looks random, not like a filename
            // or a long identifier the user would recognise.
            if looksRandom(run) {
                return .rejected(reason: "contains a \(run.count)-character high-entropy string")
            }
        }

        let lowered = text.lowercased()
        let hits = sensitiveWords.filter { lowered.contains($0) }
        if !hits.isEmpty {
            return .warned(reason: "mentions \(hits.prefix(2).joined(separator: " and ")) — confirm that's safe to keep")
        }

        return .clean
    }

    /// Cheap entropy heuristic. Requires **all three** character classes (upper, lower,
    /// digit) — a run missing one is almost always a slug, filename, or CamelCase
    /// identifier rather than a key.
    ///
    /// Biased toward rejection: a false positive merely refuses a write the user can
    /// re-add by hand, while a false negative writes a live credential into a plain-text
    /// file forever.
    private static func looksRandom(_ s: String) -> Bool {
        guard s.count >= 32 else { return false }
        let hasUpper = s.contains { $0.isUppercase }
        let hasLower = s.contains { $0.isLowercase }
        let hasDigit = s.contains { $0.isNumber }
        return hasUpper && hasLower && hasDigit
    }

    /// Mask a string for logging: keeps a short prefix so the user can identify which
    /// credential it was, without the value ever reaching a log file.
    public static func mask(_ secret: String) -> String {
        guard secret.count > 8 else { return "***" }
        return "\(secret.prefix(4))…\(secret.suffix(2)) (\(secret.count) chars)"
    }
}
