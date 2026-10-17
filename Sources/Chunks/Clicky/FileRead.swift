import Foundation
import ChunksKit

/// The disk side of `[READ:…]`.
///
/// `ReadRequest` decides *whether*; this decides *what came back*. The split exists so the policy
/// can be tested without a file system — the cases that matter are a `..` that escapes the root and
/// a symlink into `~/.ssh`, and neither should need to be created on a real Mac to prove the rule.
@MainActor
enum FileRead {

    struct Content {
        let path: String
        let text: String
        /// Which part of a larger file this is, phrased for the model. `nil` means the whole file,
        /// which is the common case and the one that needs no caveat.
        let slice: String?
    }

    enum Failure: Equatable, Error {
        /// The policy said no. `Refusal.description` is the sentence the user hears.
        case refused(ReadRequest.Refusal)
        /// The policy said yes and the disk disagreed.
        case unreadable(String)

        var description: String {
            switch self {
            case .refused(let why): return why.description
            case .unreadable(let detail): return "Chunks could not read that file: \(detail)."
            }
        }
    }

    /// Extensions whose interesting end is the last one. A log is read backwards because the
    /// failure is always at the bottom; a source file is read forwards because that is where the
    /// declarations are.
    static let tailExtensions: Set<String> = ["log", "out", "txt", "csv", "jsonl", "trace"]

    static func perform(_ request: ReadRequest,
                        home: String = NSHomeDirectory()) -> Result<Content, Failure> {
        // First pass: the typed path, standardised. This is what the allow-list is checked against.
        guard case .success(let candidate) = request.resolved(homeDirectory: home) else {
            return .failure(.refused(refusal(of: request, home: home)))
        }
        // Second pass: where the link actually lands. A file inside `~/Documents` that points at
        // `~/.ssh/id_rsa` passes the first check and must fail the second, so the resolved target
        // is fed back through the same policy rather than a weaker copy of it.
        let landed = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        switch request.resolved(homeDirectory: home, symlinksResolved: landed) {
        case .failure(let why): return .failure(.refused(why))
        case .success(let path):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return .failure(.unreadable("there is no file at that path"))
            }
            guard !isDirectory.boolValue else {
                // Said apart from "no such file" because "read my Downloads folder" is a real
                // thing to ask by voice, and telling the user the file is missing would send him
                // looking for something that was there all along.
                return .failure(.unreadable("that is a folder, not a file"))
            }
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                return .failure(.unreadable("it is not readable by this app"))
            }
            defer { try? handle.close() }
            let size = Int((try? handle.seekToEnd()) ?? 0)
            try? handle.seek(toOffset: 0)

            // A file longer than one turn is sliced, not refused, and the slice is chosen by what
            // the file is for. `ReadRequest.maxBytes` refused `context.md` outright on the first
            // real run of this probe — and the question that motivates the feature at all, "why
            // did my build fail", has its answer at the *end* of a log. Refusing the big file is
            // the same as refusing the question.
            let wantsTail = FileRead.tailExtensions.contains((path as NSString).pathExtension.lowercased())
            let data: Data
            let slice: String?
            if size <= ReadRequest.maxBytes {
                data = (try? handle.read(upToCount: size)) ?? Data()
                slice = nil
            } else if wantsTail {
                try? handle.seek(toOffset: UInt64(size - ReadRequest.maxBytes))
                data = (try? handle.read(upToCount: ReadRequest.maxBytes)) ?? Data()
                slice = "the last \(data.count / 1000) KB of a \(size / 1000) KB file"
            } else {
                data = (try? handle.read(upToCount: ReadRequest.maxBytes)) ?? Data()
                slice = "the first \(data.count / 1000) KB of a \(size / 1000) KB file"
            }

            guard !data.contains(0) else { return .failure(.refused(.binary)) }
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(.unreadable("it is not UTF-8 text"))
            }
            return .success(Content(path: path, text: text, slice: slice))
        }
    }

    private static func refusal(of request: ReadRequest, home: String) -> ReadRequest.Refusal {
        if case .failure(let why) = request.resolved(homeDirectory: home) { return why }
        return .outsideAllowedDirectories
    }
}

/// `--probe-read <path> [<path> …]` — run the whole read path against the real disk and say what
/// each path got.
///
/// Exists because the policy is testable in the abstract and the disk is not: whether this app can
/// actually open a file under ~/Documents is a question about TCC, symlinks and encodings, and the
/// last feature that "obviously worked" in review failed on the first byte read.
@MainActor
enum FileReadProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-read") }

    /// Both sinks, always. An app launched by `open` has no readable stdout, so a probe that only
    /// prints is a probe nobody can read — the lesson is already written up for `--probe-stt`.
    private static func out(_ line: String) {
        print(line)
        Log.write(line)
    }

    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let paths = CommandLine.arguments.drop(while: { $0 != "--probe-read" }).dropFirst()
        guard !paths.isEmpty else {
            out("probe-read: give it at least one path")
            Log.flush()
            exit(2)
        }
        var failures = 0
        for raw in paths {
            let request = ReadRequest(path: raw, question: "probe")
            switch FileRead.perform(request) {
            case .success(let content):
                let firstLine = content.text.split(separator: "\n", omittingEmptySubsequences: true)
                    .first.map(String.init) ?? "(empty)"
                out("probe-read: \(raw) → READ \(content.text.utf8.count) bytes, "
                    + "resolved \(content.path), first line \"\(firstLine.prefix(48))\"")
            case .failure(let failure):
                failures += 1
                out("probe-read: \(raw) → REFUSED (\(failure.description))")
            }
        }
        Log.flush()
        exit(failures == paths.count ? 1 : 0)
    }
}
