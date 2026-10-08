import Foundation

/// Writes what the app is doing to a file the developer can read.
///
/// Added while chasing "the app looks alive but nothing happens", where the answer was
/// four separate bugs and the only way to see any of them was to guess. `NSLog` goes to
/// the unified log, which requires a live `log stream` in another terminal and shows
/// nothing at all after the fact — useless when the symptom is "press the hotkey and
/// nothing happens" and the press is over.
///
/// Plain lines, appended, capped. Not a logging framework: a dependency-free file the user
/// can attach to a bug report is worth more here than structured output.
enum Log {

    /// `~/Library/Logs/Chunks/chunks.log`, or `$CHUNKS_LOG` when set.
    ///
    /// A stable path rather than a temp file so a user can be asked for it directly. Temp
    /// files get cleaned, and by the time anyone looks the evidence is gone.
    static let fileURL: URL = {
        if let override = ProcessInfo.processInfo.environment["CHUNKS_LOG"] {
            return URL(fileURLWithPath: override)
        }
        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("chunks.log")
    }()

    /// Rotate at 1 MB so an app left running for a week does not fill the disk.
    private static let maximumBytes = 1_048_576

    /// One line fit to show a user, specific when the error knows why it failed.
    ///
    /// `BrainError` and `ChunksError` describe their cause in human terms ("No Gemini API key
    /// set. Add one from the Chunks menu.", "503 high demand"). `localizedDescription` on
    /// those types does not: they are not `NSError`s, so it comes back as
    /// "The operation couldn’t be completed. (Chunks.BrainError error 1.)" — which is the
    /// message a user would get without this. Hence the explicit match on the two types that
    /// know something, with `localizedDescription` as the fallback for everything else.
    static func userMessage(for error: Error) -> String {
        let described: String
        switch error {
        case let brain as BrainError: described = brain.description
        case let chunks as ChunksError: described = chunks.description
        default: described = error.localizedDescription
        }

        let oneLine = described
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return "Something went wrong." }
        guard oneLine.count > 120 else { return oneLine }

        // Cut at a word boundary so the card does not end mid-token.
        let clipped = String(oneLine.prefix(120))
        let lastSpace = clipped.lastIndex(of: " ") ?? clipped.endIndex
        return String(clipped[..<lastSpace]).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let queue = DispatchQueue(label: "app.chunks.log", qos: .utility)

    static func write(_ message: String) {
        let line = formatted(message)
        queue.async {
            rotateIfNeeded()
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
        // Also to the unified log, so `log stream` still works for someone who prefers it.
        NSLog("%@", line)
    }

    /// Blocks until every queued line has reached the file.
    ///
    /// `write` is deliberately off the calling path, so a process that exits immediately after
    /// its last log call loses that call — and the lines a diagnostic writes last are the ones
    /// that carry its answer. Any code that is about to `exit()` calls this first.
    static func flush() {
        queue.sync {}
    }

    private static func formatted(_ message: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        return "\(stamp)  [\(Thread.isMainThread ? "main" : "bg")]  \(message)"
    }

    private static func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int, size > maximumBytes else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Truncate the log, so a new test run starts from a clean slate.
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func path() -> String { fileURL.path }
}
