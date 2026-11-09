import Foundation
import ChunksKit

/// The disk side of `[READ:…]`.
///
/// `ReadRequest` decides *whether*; this decides *what came back*. The split exists so the policy
/// can be tested without a file system — the cases that matter are a `..` that escapes the root and
/// a symlink into `~/.ssh`, and neither should need to be created on a real Mac to prove the rule.
enum FileRead {

    struct Content {
        let path: String
        let text: String
        /// Which part of a larger file this is, phrased for the model. `nil` means the whole file,
        /// which is the common case and the one that needs no caveat.
        let slice: String?
        /// JPEG bytes, when the file is read by looking at it rather than by decoding it.
        ///
        /// Carried here so both doors do the same thing: the automatic attach already sends a photo
        /// as pixels, while the model's own `[READ:x.png]` came back with "that is not a text file"
        /// — one capability, two answers, depending on who asked.
        var image: Data? = nil
    }

    enum Failure: Equatable, Error {
        /// The policy said no. `Refusal.description` is the sentence the user hears.
        case refused(ReadRequest.Refusal)
        /// The policy said yes and the disk disagreed.
        case unreadable(String)
        /// A document opened and had nothing in it to read — a scan, or a file too large to open.
        case document(DocumentReading.Failure)
        /// No complete line fits, or complete lines are not valid UTF-8.
        case input(ReadInputBudget.Failure)

        var description: String {
            switch self {
            case .refused(let why): return why.description
            case .unreadable(let detail): return "Chunks could not read that file: \(detail)."
            case .document(let why): return why.description
            case .input(let why): return why.description
            }
        }
    }

    /// Extensions whose interesting end is the last one. A log is read backwards because the
    /// failure is always at the bottom; a source file is read forwards because that is where the
    /// declarations are.
    static let tailExtensions: Set<String> = ["log", "out", "txt", "csv", "jsonl", "trace"]

    static func perform(_ request: ReadRequest,
                        home: String = NSHomeDirectory()) -> Result<Content, Failure> {
        let result = performUnchecked(request, home: home)
        // A name can look ordinary while the content is a key: sweep the extracted words for real
        // provider token shapes before they enter a model request (AUDIT.md D-03). Only the hard
        // patterns — the entropy heuristic would refuse his build logs full of sha256 sums. Pixels
        // are not swept here; a photographed key is refused by the name rule, not by OCR we do not do.
        guard case .success(let content) = result, !content.text.isEmpty else { return result }
        if case .rejected(let reason) = SecretSweeper.inspectTokens(content.text) {
            Log.write("read: content refused — \(reason)")
            return .failure(.refused(.secretStore))
        }
        return result
    }

    private static func performUnchecked(_ request: ReadRequest,
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
            // A picture is read by looking at it. Resized to the capture's own ceiling first, so a
            // 12 MB phone photo costs what a screenshot costs and nothing else.
            if ReadRequest.isImage(path) {
                guard let data = FileAttachment.jpeg(fromFileAt: path) else {
                    return .failure(.unreadable("it is a picture this Mac could not decode"))
                }
                return .success(Content(path: path, text: "", slice: nil, image: data))
            }
            // A document is read through an extractor, not through a handle. Its bytes are a
            // container, and the question that motivated it — "what does clause 9 say" — has its
            // answer in the text layer underneath them.
            if ReadRequest.isDocument(path) {
                return DocumentRead.perform(request, path: path)
            }
            // A Word or RTF file is a container too, and reading its bytes answers "is this text?"
            // with no — a .docx is a zip, which is full of zero bytes, and the refusal that came back
            // was "that is not a text file" about a document with nothing but text in it.
            if ReadRequest.isOfficeDocument(path) {
                return OfficeRead.perform(request, path: path)
            }
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                return .failure(.unreadable("it is not readable by this app"))
            }
            defer { try? handle.close() }
            let wantsTail = FileRead.tailExtensions.contains((path as NSString).pathExtension.lowercased())
            do {
                let size = Int(try handle.seekToEnd())
                let count = min(size, ReadRequest.maxBytes)
                let offset = wantsTail ? size - count : 0
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: count) ?? Data()
                guard data.count == count else {
                    return .failure(.unreadable("the file changed while it was being read; try again"))
                }
                // The disk window and model budget are separate limits. Boundary fragments are
                // removed as bytes by the pure selector, before any UTF-8 decoding happens.
                return selectText(data, path: path, fromTail: wantsTail,
                                  startsAtFileStart: offset == 0,
                                  endsAtFileEnd: offset + data.count == size)
            } catch {
                return .failure(.unreadable(error.localizedDescription))
            }
        }
    }

    static func selectText(_ data: Data, path: String, fromTail: Bool,
                           startsAtFileStart: Bool, endsAtFileEnd: Bool) -> Result<Content, Failure> {
        guard !data.contains(0) else { return .failure(.refused(.binary)) }
        return ReadInputBudget.selectLines(data: data, path: path, fromTail: fromTail,
                                           startsAtFileStart: startsAtFileStart,
                                           endsAtFileEnd: endsAtFileEnd)
            .map { Content(path: path, text: $0.text, slice: $0.slice) }
            .mapError { .input($0) }
    }

    private static func refusal(of request: ReadRequest, home: String) -> ReadRequest.Refusal {
        if case .failure(let why) = request.resolved(homeDirectory: home) { return why }
        return .outsideAllowedDirectories
    }
}

/// A Word, RTF or OpenDocument file, read through the importer TextEdit itself uses.
///
/// `NSAttributedString(url:)` is the only text route for a `.docx` that needs no dependency — a
/// Word file is a zip of XML, so `FileHandle` hands back bytes full of NULs and the honest answer
/// from a byte reader is "that is not a text file", about a document with nothing but text in it.
/// What the importer cannot open is *said* as that, rather than as a binary refusal.
enum OfficeRead {

    static func perform(_ request: ReadRequest,
                        path: String) -> Result<FileRead.Content, FileRead.Failure> {
        let url = URL(fileURLWithPath: path)
        guard let attributed = try? NSAttributedString(url: url, options: [:],
                                                      documentAttributes: nil) else {
            return .failure(.unreadable("Chunks could not open that document — "
                + "it may be an older format or written by something else"))
        }
        let whole = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else {
            return .failure(.unreadable("that document has no text in it"))
        }
        // The importer has already opened the container. Bound its extracted UTF-8 window, then
        // use the same whole-line selection and exact framed budget as plain text.
        let data = Data(whole.utf8.prefix(ReadRequest.maxBytes))
        return FileRead.selectText(data, path: path, fromTail: false, startsAtFileStart: true,
                                   endsAtFileEnd: whole.utf8.count <= ReadRequest.maxBytes)
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
            // Parsed through the same door a spoken turn uses, so a probe can carry a question —
            // and for a long PDF the question is what decides which pages get read.
            let request = ReadRequest.parse(raw) ?? ReadRequest(path: raw, question: "probe")
            switch FileRead.perform(request) {
            case .success(let content):
                if let image = content.image {
                    out("probe-read: \(raw) → READ as an image, \(image.count / 1024) KB of JPEG, "
                        + "resolved \(content.path)")
                    continue
                }
                let firstLine = content.text.split(separator: "\n", omittingEmptySubsequences: true)
                    .first.map(String.init) ?? "(empty)"
                out("probe-read: \(raw) → READ \(content.text.utf8.count) bytes, "
                    + "resolved \(content.path), first line \"\(firstLine.prefix(48))\"")
                // Printed because "which pages of a 60-page PDF did I just send to a model" is the
                // question anyone debugging this has, and it is not answerable from a byte count.
                if let slice = content.slice { out("probe-read:   slice — \(slice)") }
            case .failure(let failure):
                failures += 1
                out("probe-read: \(raw) → REFUSED (\(failure.description))")
            }
        }
        Log.flush()
        exit(failures == paths.count ? 1 : 0)
    }
}
