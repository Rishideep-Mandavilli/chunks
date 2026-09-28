import Foundation

/// Chunks' long-term memory of the user.
///
/// Two tiers, because they have completely different mechanics:
///
/// - **Memory** — facts about *you*: projects, preferences, corrections. Hard-capped,
///   injected into **every** prompt. Must stay small enough that injecting it is free.
/// - **Notebook** — concepts Chunks has explained. Unbounded, **never auto-injected**,
///   searched on demand. Would destroy the prompt budget if it were.
///
/// Storage is plain markdown on purpose: readable, greppable, hand-editable, git-friendly.
/// No database, no migration, no opaque store. If Chunks is deleted, this file survives
/// and stays yours.
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

    public struct Fact: Equatable, Sendable, Codable {
        public var section: Section
        public var text: String
        public var date: String        // YYYY-MM-DD
        public var id: String          // stable hash for dedupe and pruning

        public init(section: Section, text: String, date: String) {
            self.section = section
            self.text = text
            self.date = date
            self.id = Fact.identifier(for: text)
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
            out.append(contentsOf: inSection.map { "  (\($0.date)) \($0.text)" })
        }
        return out.joined(separator: "\n")
    }

    // MARK: Writing

    public enum WriteOutcome: Equatable {
        case added(Fact)
        case duplicate(Fact)
        case rejectedAsSecret(reason: String)
        case refusedFull(remainingBytes: Int)
        case rejectedMalformed(reason: String)
    }

    /// The only way facts enter the store. Enforces, in order:
    /// secret rejection → malformed rejection → dedupe → capacity → timestamp.
    @discardableResult
    public func propose(section: Section, text: String, date: String? = nil) -> WriteOutcome {
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

        // 3. Dedupe.
        let candidate = Fact(section: section, text: trimmed, date: date ?? today)
        if facts.contains(where: { $0.id == candidate.id }) {
            return .duplicate(candidate)
        }

        // 4. Capacity. Ask, never truncate.
        let cost = rendered(candidate).utf8.count
        if byteCount + cost > MemoryStore.byteCap {
            return .refusedFull(remainingBytes: remainingBytes)
        }

        facts.append(candidate)
        save()
        return .added(candidate)
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

    /// Adopt facts the user typed by hand. Same validation as the model path.
    public func adopt(_ parsed: [Fact]) -> [WriteOutcome] {
        parsed.map { propose(section: $0.section, text: $0.text, date: $0.date) }
    }

    // MARK: Serialisation

    private func rendered(_ f: Fact) -> String { "- \(f.text) (\(f.date))" }

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
        let lineRE = try! NSRegularExpression(pattern: #"^-\s+(.*?)\s*\((\d{4}-\d{2}-\d{2})\)\s*$"#)

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
            guard !body.isEmpty, body != "_(empty)_" else { continue }
            out.append(Fact(section: section, text: body, date: date))
        }
        return out
    }
}
