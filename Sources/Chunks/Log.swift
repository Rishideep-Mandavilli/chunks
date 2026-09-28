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
