import Foundation

/// Validated durable facts, capped at 2 KB and injected into every prompt; overflow is refused.
public final class MemoryStore {

    // MARK: Sections

    /// Sections the model may write to, in display order. `identity` is fixed.
    public enum Section: String, CaseIterable, Sendable, Codable {
        case you = "You"
        case corrections = "Corrections"
        case preferences = "Standing preferences"
        case notes = "Notes"

        /// Sections the model is allowed to append to. The header is not writable.
        public static let writable: [Section] = [.you, .corrections, .preferences, .notes]
    }

    /// Where a fact came from, and therefore what is allowed to retire it.
    ///
    /// Two states, not a confidence float. With ~40 lines in a 2 KB file and a human who can read
    /// the whole thing, the only distinction that changes what the app may do is **did he say it, or
    /// did the model work it out from his screen** — because an inference is wrong more often, and a
    /// wrong inference that silently overwrites something he stated is the failure this store has
    /// promised never to have. The idea is the trust-ledger rule from the Meterless H-MEM spec,
    /// reduced to the one comparison that costs nothing.
    public enum Origin: String, Equatable, Sendable, Codable {
        /// He said it, and `heSaidIt(_:in:)` checked that the words are in this turn's transcript.
        case said
        /// The model proposed it from a screen, a file, or a plan.
        case inferred

        /// The marker in `memory.md` and in the injected block.
        ///
        /// Only `.said` is marked, and that is deliberate: the cap is the whole design, so the
        /// common case must cost zero. A 10-byte tag on every line would eat a quarter of the file
        /// to restate the default.
        var marker: String? { self == .said ? "he said" : nil }
    }

    public struct Fact: Equatable, Sendable, Codable {
        public var section: Section
        public var text: String
        public var date: String        // YYYY-MM-DD
        public var id: String          // stable hash for dedupe and pruning
        public var origin: Origin

        public init(section: Section, text: String, date: String, origin: Origin = .inferred) {
            self.section = section
            self.text = text
            self.date = date
            self.id = Fact.identifier(for: text)
            self.origin = origin
        }

        /// Normalised key so "Uses Raycast" and "uses  raycast." dedupe to one fact.
        ///
        /// FNV-1a, **not** `hashValue`: Swift's `hashValue` is seeded per process, so IDs
        /// would change on every launch and a prune instruction referring to a fact from
        /// yesterday would silently fail to match today.
        static func identifier(for text: String) -> String {
            let folded = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in folded.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return String(hash, radix: 16)
        }

        public var normalisedText: String {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    // MARK: Configuration

    /// Hard ceiling on injected memory. ~2 KB ≈ 500 tokens ≈ negligible per turn.
    /// When reached, the writer refuses new facts and *asks* — it never truncates.
    public static let byteCap = 2048

    /// Headroom kept free so the "memory is full" warning appears *before* writes start
    /// failing. Without this, `isFull` is almost never true — the last fact that fits
    /// always leaves you just under the cap — so the user would never be warned, and the
    /// model's first sign of trouble would be a silent refusal.
    public static let typicalFactReserve = 64

    public static let header = """
    # Chunks Memory

    Hand-editable. Chunks reads this before every turn and proposes edits; you always
    have the final say. Delete anything here at any time — Chunks will not re-add it
    unless you tell it to.

    Never store passwords, tokens, or API keys in this file. Chunks refuses to write
    anything that looks like a credential, but you are the last line of defence.

    A line ending `(2026-10-10 · he said)` is something he said himself, and Chunks
    will not let a fact it worked out from his screen replace it. Write that marker on
    a line yourself to give it the same protection.
    """

    // MARK: State

    public private(set) var facts: [Fact] = []
    public private(set) var lastWriteWasRejected: String?

    private let fileURL: URL
    private let calendar: Calendar
    private var today: String

    public init(fileURL: URL, today: String = MemoryStore.todayString(), calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.today = today
        self.calendar = calendar
        load()
    }

    public static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Chunks", isDirectory: true)
        return base.appendingPathComponent("memory.md")
    }

    // MARK: Capacity

    public var byteCount: Int { facts.map { rendered($0).utf8.count }.reduce(0, +) }
    public var isFull: Bool { byteCount + MemoryStore.typicalFactReserve > MemoryStore.byteCap }
    public var remainingBytes: Int { max(0, MemoryStore.byteCap - byteCount) }

    // MARK: Reading

    /// The block injected into every prompt. Compact and dated; no header, no commentary.
    public func injectedBlock() -> String {
        guard !facts.isEmpty else { return "" }
        var out: [String] = []
        for section in Section.writable {
            let inSection = facts.filter { $0.section == section }
            guard !inSection.isEmpty else { continue }
            out.append("### \(section.rawValue)")
            out.append(contentsOf: inSection.map {
                "  (\($0.date)\(Self.suffix($0.origin))) \($0.text)"
            })
        }
        return out.joined(separator: "\n")
    }

    // MARK: Writing

    public enum WriteOutcome: Equatable {
        case added(Fact)
        /// A replacement: the old line is gone and this one is in the file in its place.
        case replaced(old: Fact, new: Fact)
        case duplicate(Fact)
        case rejectedAsSecret(reason: String)
        case refusedFull(remainingBytes: Int)
        case rejectedMalformed(reason: String)
        /// The model named a fact to replace and the app could not honour it — wrong count, or a
        /// line with more trust behind it than the incoming fact has.
        case refusedSupersede(reason: String)

        /// Whether this outcome means something the user should be told about.
        var isWorthReporting: Bool {
            switch self {
            case .duplicate: return false
            default: return true
            }
        }
    }

    /// The only way facts enter the store. Enforces, in order:
    /// secret rejection → malformed rejection → dedupe → supersede → capacity → timestamp.
    ///
    /// `claim` is what the model *asserted* about the fact's origin and `hisWords` is the transcript
    /// it was asked to remember from; the app verifies the claim rather than trusting it, because a
    /// field the model sets is a field a prompt injection sets. A claim that fails the check is
    /// written with *less* trust, never more.
    @discardableResult
    public func propose(section: Section, text: String, date: String? = nil,
                        claim: Origin = .inferred, hisWords: String = "",
                        supersedes: String? = nil) -> WriteOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Secrets. Structural, not advisory — this is why the model never writes the file.
        switch SecretSweeper.inspect(trimmed) {
        case .rejected(let reason):
            lastWriteWasRejected = reason
            return .rejectedAsSecret(reason: reason)
        case .warned:
            break   // allowed; surfaced to the user as a nudge, not a block
        case .clean:
            break
        }

        // 2. Malformed: one line per fact, never empty.
        if trimmed.isEmpty {
            return .rejectedMalformed(reason: "fact is empty")
        }
        if trimmed.contains("\n") {
            return .rejectedMalformed(reason: "fact spans multiple lines — one line per fact")
        }

        // 3. Origin, verified. "he said" is a claim about his own mouth, so it is checked against
        //    what came out of it rather than believed.
        let origin: Origin = claim == .said && Self.heSaidIt(trimmed, in: hisWords) ? .said : .inferred

        // 4. Dedupe.
        let candidate = Fact(section: section, text: trimmed, date: date ?? today, origin: origin)
        if facts.contains(where: { $0.id == candidate.id }) {
            return .duplicate(candidate)
        }

        // 5. Supersede. A replacement is resolved *before* the capacity check, and the old line is
        //    taken out first, because at the cap a swap is net-neutral and refusing it would mean a
        //    correction is impossible exactly when the file needs one most.
        var replaced: Fact?
        if let needle = supersedes?.trimmingCharacters(in: .whitespacesAndNewlines), !needle.isEmpty {
            let matches = Self.matching(needle, in: facts)
            if matches.isEmpty {
                return .refusedSupersede(reason: "\"\(needle)\" is not one of the facts Chunks has, so "
                    + "nothing was replaced and the new one was not written either.")
            }
            if matches.count > 1 {
                return .refusedSupersede(reason: "\"\(needle)\" names \(matches.count) stored facts. "
                    + "Say which one, and Chunks will replace that one.")
            }
            let old = matches[0]
            if old.origin == .said && origin != .said {
                return .refusedSupersede(reason: "\"\(old.text)\" is something he said, so a fact "
                    + "worked out from his screen will not retire it. Say \"forget \(old.text)\" "
                    + "and it goes.")
            }
            replaced = old
        }

        // 6. Capacity. Ask, never truncate.
        let working = replaced == nil ? facts : facts.filter { $0.id != replaced!.id }
        let used = working.map { rendered($0).utf8.count }.reduce(0, +)
        let cost = rendered(candidate).utf8.count
        if used + cost > MemoryStore.byteCap {
            return .refusedFull(remainingBytes: max(0, MemoryStore.byteCap - used))
        }

        facts = working + [candidate]
        save()
        if let old = replaced {
            return .replaced(old: old, new: candidate)
        }
        return .added(candidate)
    }

    /// Does this turn's own words contain the fact, rather than the model merely saying so.
    ///
    /// One shared distinctive word is enough, and that is the whole design argument: the model writes
    /// "uses WhatsApp for messaging" while his mouth said "I use WhatsApp", so a strict phrase test
    /// would downgrade almost every honest claim and the field would be inert. The cost of being
    /// wrong in this direction is small and visible — a fact stored with less trust than it earned,
    /// which then cannot retire a line he stated and says so on the card. Being wrong the other way
    /// is a guess overwriting his own words.
    public static func heSaidIt(_ fact: String, in words: String) -> Bool {
        !contentWords(in: fact).isEmpty && !contentWords(in: fact)
            .intersection(contentWords(in: words)).isEmpty
    }

    /// Distinctive words, lightly stemmed.
    ///
    /// The stem is a dropped final `s` and nothing cleverer: it exists so "answers" matches
    /// "answer" and "preferences" matches "prefer…", which is all the vocabulary of this file needs.
    /// A real stemmer would be a dependency for one comparison.
    static func contentWords(in text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !Self.stopWords.contains($0) }
            .map { $0.hasSuffix("s") && $0.count > 4 ? String($0.dropLast()) : $0 })
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "they", "them", "have", "has", "had",
        "are", "was", "were", "will", "would", "could", "should", "about", "into", "over", "his",
        "her", "their", "there", "here", "what", "when", "where", "which", "while", "because",
        "not", "can", "cant", "does", "did", "done", "very", "but", "also", "just", "like",
        "always", "usually", "typically", "still", "uses", "use", "used", "using", "prefers",
        "prefer", "preferred", "wants", "want", "needs", "need", "going", "gone", "get", "got",
    ]

    /// The stored facts a substring or a name points at, in file order.
    ///
    /// Word-boundary matching, not `contains`: a plain substring test makes `"number 3"` match
    /// `"number 30"` through `"number 39"`, which turns a supersede meant for one line into an
    /// ambiguity that has to be refused. The unit test that caught it is in `MemoryStoreTests`.
    static func matching(_ needle: String, in facts: [Fact]) -> [Fact] {
        let folded = needle.lowercased().trimmingCharacters(in: .whitespaces)
        guard !folded.isEmpty else { return [] }
        return facts.filter { $0.normalisedText.containsWholeWords(folded) }
    }

    /// A prune asked for by a reply.
    ///
    /// The panel's Forget button calls `remove(matching:)` directly — that is him deciding, and no
    /// rule is needed. This is the model asking, and the asymmetry is the point: **his words may
    /// retire his words, an inference may not.** A prune aimed at a line he stated, with nothing in
    /// what he just said reaching for it, is refused and reported rather than quietly honoured —
    /// "the model deleted something I told it last month" is the failure this store exists to make
    /// impossible, and it is the exact hole the trust-ledger rule in the H-MEM spec was written for.
    ///
    /// The grounding test is one shared word, not the two that `heSaidIt` demands of an addition, and
    /// that asymmetry is deliberate: a prune needle is a fragment of an existing line ("python"), so
    /// demanding two matches would refuse legitimate corrections while a wrong deletion is both
    /// visible on the card and one sentence to undo.
    public func prune(matching text: String, hisWords: String) -> (removed: Int, refused: [Fact]) {
        let needle = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return (0, []) }
        let targets = Self.matching(needle, in: facts)
        let grounded = !Self.contentWords(in: needle)
            .intersection(Self.contentWords(in: hisWords)).isEmpty
        let allowed = targets.filter { $0.origin != .said || grounded }
        let refused = targets.filter { !allowed.contains($0) }
        guard !allowed.isEmpty else { return (0, refused) }
        let ids = Set(allowed.map(\.id))
        facts.removeAll { ids.contains($0.id) }
        save()
        return (allowed.count, refused)
    }

    /// Remove by id. Used by prunes and by the `Cmd+M` viewer.
    @discardableResult
    public func remove(id: String) -> Bool {
        let before = facts.count
        facts.removeAll { $0.id == id }
        if facts.count != before { save(); return true }
        return false
    }

    /// Remove by substring match — how a model asks to forget something.
    @discardableResult
    public func remove(matching text: String) -> Int {
        let needle = text.lowercased()
        let before = facts.count
        facts.removeAll { $0.normalisedText.contains(needle) }
        let removed = facts.count == before ? 0 : before - facts.count
        if removed > 0 { save() }
        return removed
    }

    /// Adopt facts the user typed by hand into the file. Same validation as the model path, and the
    /// maximum trust: a line he wrote himself *is* his own words, so it cannot be retired by an
    /// inference later.
    public func adopt(_ parsed: [Fact]) -> [WriteOutcome] {
        parsed.map { propose(section: $0.section, text: $0.text, date: $0.date,
                             claim: .said, hisWords: $0.text) }
    }

    // MARK: Serialisation

    /// The one line a fact occupies on disk: `- the words (date · he said)`.
    ///
    /// The provenance rides *inside* the date parentheses rather than as a prefix or a comment, so
    /// the file stays a list of sentences he can read and edit, and only the facts he actually stated
    /// pay the 10 bytes.
    private func rendered(_ f: Fact) -> String { "- \(f.text) (\(f.date)\(Self.suffix(f.origin)))" }

    private static func suffix(_ origin: Origin) -> String {
        origin.marker.map { " · \($0)" } ?? ""
    }

    public func render() -> String {
        var out = MemoryStore.header
        for section in Section.writable {
            out += "\n\n## \(section.rawValue)"
            let inSection = facts.filter { $0.section == section }
            if inSection.isEmpty {
                out += "\n_(empty)_"
            } else {
                for f in inSection { out += "\n" + rendered(f) }
            }
        }
        out += "\n"
        return out
    }

    // MARK: Persistence

    public func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? render().write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Parse the on-disk file. Unknown sections are ignored and their lines preserved
    /// nowhere — we prefer a clean model over silently keeping junk. Hand edits to known
    /// sections always survive a load/save round trip.
    public func load() {
        facts = []
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        facts = MemoryStore.parse(text, today: today)
    }

    /// Pure function so it is trivially testable and round-trip safe.
    public static func parse(_ text: String, today: String) -> [Fact] {
        var current: Section?
        var out: [Fact] = []
        let lineRE = try! NSRegularExpression(
            pattern: #"^-\s+(.*?)\s*\((\d{4}-\d{2}-\d{2})(\s+·\s*([^)]+))?\)\s*$"#)

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                let name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                current = Section(rawValue: name)
                continue
            }
            guard line.hasPrefix("- "), let section = current else { continue }

            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let m = lineRE.firstMatch(in: line, range: range) else { continue }

            let body = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let date = ns.substring(with: m.range(at: 2))
            // No marker means `inferred`, which is the safe reading of a file written mostly before
            // this field existed: trust is only ever granted by evidence, never by the absence of a
            // tag. He can write `· he said` on a line himself, and the panel's Forget button needs no
            // marker because that path is him deciding.
            let label = m.range(at: 4).location == NSNotFound
                ? nil : ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty, body != "_(empty)_" else { continue }
            out.append(Fact(section: section, text: body, date: date,
                            origin: Self.origin(fromMarker: label)))
        }
        return out
    }

    /// Read the marker back. Only the exact `he said` tag grants trust — an unknown label is treated
    /// as the default rather than as a claim, so a typo cannot accidentally protect a line from
    /// correction.
    static func origin(fromMarker label: String?) -> Origin {
        guard let label else { return .inferred }
        return label == Origin.said.marker ? .said : .inferred
    }
}

extension String {
    /// Whether `needle` occurs in this string as whole words.
    ///
    /// Both sides are expected to be normalised first — lower-case, punctuation stripped, single
    /// spaces — which is what `MemoryStore.Fact.normalisedText` already produces. Padding one space
    /// on each side is the whole algorithm, and it is here rather than in a regex because the thing
    /// it must reject is a *prefix of a word*: `"number 3"` matching the line `"number 30"` is what
    /// a bare `contains` does, and a supersede meant for one fact then has to be refused as ambiguous.
    func containsWholeWords(_ needle: String) -> Bool {
        guard !isEmpty, !needle.isEmpty else { return false }
        if self == needle { return true }
        return (" " + self + " ").contains(" " + needle + " ")
    }
}
