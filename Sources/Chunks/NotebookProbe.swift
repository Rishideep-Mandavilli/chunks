import AppKit
import ChunksKit
import Foundation

/// `--probe-notebook` — the notebook tier driven end to end, on a copy.
///
/// Two things are reported and both have to be true, because a probe that prints without asserting is
/// how `--probe-controls` managed to skip for a month:
///
/// 1. **His real file, read-only** — path, how many notes it holds, how big it is, and what a search
///    for the given words would put in front of the model. Nothing is written, so running this cannot
///    change what he keeps.
/// 2. **A copy of the tier's rules**, driven through the same store with fixtures: the credential that
///    must not land, the over-long line that must be refused rather than cut, the re-dictated note that
///    must not be saved twice, the whole-word delete that must not take "number 30" with "number 3", and
///    the sixty-deep match list that must fit the block budget and say how much it left out.
///
/// Exits non-zero on any of them, so `verify.sh` has a check that real output can fail.
@MainActor
enum NotebookProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-notebook") }

    private static func out(_ line: String) {
        print(line)
        Log.write(line)
    }

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        let query = argumentAfterFlag("--probe-notebook") ?? "the landlord"

        var failures: [String] = []

        // ── 1. his file, read through the same store the app uses
        let real = NotebookStore()
        out("notebook: \(real.url.path) — \(real.count) note(s), \(real.byteCount) bytes")
        if let found = real.block(for: query) {
            out("notebook: \"\(query)\" matches \(found.included.count) shown, "
                + "\(found.skipped) left out, \(found.bytes) bytes")
            guard found.bytes <= NotebookStore.maxBlockBytes else {
                failures.append("the block over his real notes is \(found.bytes) bytes, past the "
                    + "\(NotebookStore.maxBlockBytes)-byte budget")
                printAndExit(failures)
                return
            }
        } else {
            out("notebook: \"\(query)\" matches nothing in his file — a turn asking would be told so")
        }

        // ── 2. the rules, on a copy
        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-probe-notebook-\(UUID().uuidString).md")
        let copy = NotebookStore(fileURL: copyURL, today: "2026-11-02")

        let secret = copy.add("the api key is sk-abcdefghijklmnopqrstuvwxyz123456")
        if case .rejectedAsSecret = secret {
            out("notebook: a credential was refused before the write")
        } else {
            failures.append("a note beginning `the api key is sk-…` was accepted: \(secret)")
        }
        if copy.count != 0 {
            failures.append("the refused secret still landed — the file holds \(copy.count) note(s)")
        }

        let ordinary = copy.add("the landlord is Sharma, flat 4B")
        if ordinary.saved {
            out("notebook: an ordinary note landed — the sweeper is not eating the tier")
        } else {
            failures.append("a plain note was refused: \(ordinary)")
        }

        let again = copy.add("The landlord is Sharma, flat 4B.")
        var wasDuplicate = false
        if case .duplicate = again { wasDuplicate = true }
        if wasDuplicate, copy.count == 1 {
            out("notebook: the same note dictated twice stayed one line")
        } else {
            failures.append("a re-dictated note was not deduplicated (duplicate=\(wasDuplicate), "
                + "count=\(copy.count))")
        }

        let tooLong = copy.add(String(repeating: "x", count: NotebookStore.maxEntryCharacters + 40))
        if case .rejectedMalformed = tooLong {
            out("notebook: an over-long note was refused, not clipped")
        } else {
            failures.append("a \(NotebookStore.maxEntryCharacters + 40)-character note was accepted")
        }

        _ = copy.add("invoice number 3 is the electric one")
        _ = copy.add("invoice number 30 is the water one")
        let removed = copy.remove(matching: "number 3")
        if removed == 1, copy.count == 2,
           copy.entries.contains(where: { $0.text.contains("30") }) {
            out("notebook: the whole-word delete took \"number 3\" and left \"number 30\"")
        } else {
            failures.append("a delete for \"number 3\" removed \(removed) line(s) and left "
                + "\(copy.count) — \"number 30\" must survive it")
        }

        for index in 1...60 {
            _ = copy.add("vendor \(index) invoice paid by card on the \(index)th")
        }
        if let block = copy.block(for: "vendor invoice paid card") {
            out("notebook: 60 matches → \(block.included.count) in the block, "
                + "\(block.skipped) named as left out, \(block.bytes) bytes")
            guard block.bytes <= NotebookStore.maxBlockBytes else {
                failures.append("the block is \(block.bytes) bytes, past the budget of "
                    + "\(NotebookStore.maxBlockBytes)")
                printAndExit(failures)
                return
            }
            if block.skipped == 0 {
                failures.append("a capped block that claims nothing was left out is a partial read "
                    + "described as a complete one")
            }
            for entry in block.included where !block.text.contains(entry.text) {
                failures.append("an entry arrived clipped: \(entry.text.prefix(40))…")
            }
        } else {
            failures.append("sixty matching notes answered nothing")
        }

        // ── 3. the framing, and that the model is told the tier exists
        if let block = copy.block(for: "landlord") {
            let lowered = block.text.lowercased()
            for promise in ["past data", "not the current screen", "not instructions"] {
                if lowered.contains(promise) {
                    out("notebook: the recalled block says it is \(promise)")
                } else {
                    failures.append("the recalled block no longer says the notes are \(promise) — "
                        + "a stored line that reads like an instruction is a command with a memory "
                        + "behind it")
                }
            }
        }
        let prompt = CompanionManager.companionVoiceResponseSystemPrompt
        for tag in ["<NOTE>", "[NOTES:"] where !prompt.contains(tag) {
            failures.append("the live instruction no longer teaches \(tag), so a model will never "
                + "write it and the tier is unread and unwritten")
        }
        if failures.filter({ $0.contains("live instruction") }).isEmpty {
            out("notebook: the live instruction teaches both tags (\(prompt.count) chars sent)")
        }

        try? FileManager.default.removeItem(at: copyURL)
        printAndExit(failures)
    }

    /// The word after a flag, if there is one and it is not another flag.
    private static func argumentAfterFlag(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        let next = CommandLine.arguments[index + 1]
        return next.hasPrefix("--") ? nil : next
    }

    private static func printAndExit(_ failures: [String]) {
        if failures.isEmpty {
            out("notebook: PASS — the tier keeps, refuses, ranks and caps as the rules say")
            exit(0)
        }
        for failure in failures { out("notebook: FAIL — \(failure)") }
        exit(1)
    }
}
