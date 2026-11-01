import Foundation

/// What a batch of memory writes means, phrased for the user.
///
/// Invariant 3 says a rejected fact is *reported*, never dropped quietly, and the HUD footnote
/// is where that reporting lands. Deciding the wording here rather than in the shell keeps it
/// unit-testable and keeps `WriteOutcome`'s meaning in one place: the shell applies the
/// proposal and shows whatever this returns.
///
/// Returns `nil` for "nothing worth interrupting you about" — which deliberately excludes a
/// turn where the only outcome is that the app already knew the fact, and includes one where
/// it did not, because a "remembered" that changed nothing must not look like a success.
public enum MemoryReport {

    public static func line(for outcomes: [MemoryStore.WriteOutcome], pruned: Int,
                            refusedPrunes: [MemoryStore.Fact] = []) -> String? {
        var added: [String] = []
        var replaced: [String] = []
        var secrets = 0
        var malformed = 0
        var duplicates = 0
        var supersedeRefusals: [String] = []
        var fullRemaining: Int?

        for outcome in outcomes {
            switch outcome {
            case .added(let fact): added.append(fact.text)
            case .replaced(let old, let new): replaced.append("\"\(old.text)\" → \"\(new.text)\"")
            case .duplicate: duplicates += 1
            case .rejectedAsSecret: secrets += 1
            case .rejectedMalformed: malformed += 1
            case .refusedFull(let remaining): fullRemaining = remaining
            case .refusedSupersede(let reason): supersedeRefusals.append(reason)
            }
        }

        var parts: [String] = []
        if let one = added.first, added.count == 1 {
            parts.append("Remembered: \(one)")
        } else if !added.isEmpty {
            parts.append("Remembered \(added.count) things")
        }
        // A replacement is the interesting event in a capped file — it is the only way a correction
        // lands without asking him to delete something first — so it is said out loud rather than
        // folded into "Remembered".
        if let one = replaced.first, replaced.count == 1 {
            parts.append("Updated \(one)")
        } else if !replaced.isEmpty {
            parts.append("Updated \(replaced.count) facts")
        }
        if pruned > 0 {
            parts.append(pruned == 1 ? "Forgot that" : "Forgot \(pruned) things")
        }
        if !refusedPrunes.isEmpty {
            parts.append("Did not forget \"\(refusedPrunes[0].text)\" — he said that one, "
                + "so only he can delete it")
        }
        if secrets > 0 {
            parts.append("Refused \(secrets) secret\(secrets == 1 ? "" : "s") — keys never reach disk")
        }
        if let remaining = fullRemaining {
            parts.append("Memory is full — \(remaining) bytes left, delete something")
        }
        if malformed > 0 {
            parts.append("Skipped \(malformed) unreadable fact\(malformed == 1 ? "" : "s")")
        }
        // Last, because a refusal is the thing he needs to read even when the turn also wrote
        // something: invariant 3's rule is that nothing is dropped quietly.
        parts.append(contentsOf: supersedeRefusals)

        guard !parts.isEmpty else {
            return duplicates > 0 ? "Already knew that." : nil
        }
        return parts.joined(separator: " · ")
    }
}
