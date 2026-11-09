import AppKit
import ChunksKit
import Foundation
import PDFKit

/// The PDFKit half of `[READ:…]`.
///
/// The split is the one `FileRead` already draws: policy in ChunksKit, disk here. What a PDF adds is
/// a third layer, because opening the file and reading its pages are two different failures — a
/// password-protected statement and a scanned one both reach this code, and only one of them has
/// ever had text in it.
///
/// The text goes to the model as text, exactly like a log file. Chunks does not render pages into
/// images here: the card would then be a screenshot of a screenshot, and the vision models answering
/// in seconds are the small ones. When the file *is* a scan, the honest line says so, and the page on
/// screen is what he can show instead.
enum DocumentRead {

    static func perform(_ request: ReadRequest,
                        path: String) -> Result<FileRead.Content, FileRead.Failure> {
        let url = URL(fileURLWithPath: path)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard !DocumentReading.isTooLarge(bytes: bytes) else {
            return .failure(.document(.tooLarge(bytes: bytes)))
        }
        guard let document = PDFDocument(url: url) else {
            return .failure(.unreadable("it is not a PDF this Mac can open"))
        }
        // Checked before the page walk, because an encrypted document answers `pageCount == 0` and
        // "it has no pages" would send him looking for damage in a file that is simply locked.
        guard !document.isEncrypted else {
            return .failure(.unreadable("it is password-protected, so its text is not readable"))
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else { return .failure(.unreadable("it has no pages")) }

        var pages: [String] = []
        pages.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            pages.append(document.page(at: index)?.string ?? "")
        }
        switch DocumentReading.select(pages: pages, question: request.question, path: path) {
        case .failure(let why):
            return .failure(.document(why))
        case .success(let selection):
            return .success(FileRead.Content(path: path, text: selection.text,
                                             slice: selection.slice))
        }
    }

    /// The pages as pictures, for the case where they have no text.
    ///
    /// A scanned PDF is a folder of photographs wearing a document's name, and the models Chunks
    /// reaches can look. So a file with no text layer is not a refusal — it is the same request
    /// arriving as pixels instead of characters, which is what makes "read any file format" true
    /// rather than nearly true.
    ///
    /// Two pages, at the capture's own ceiling: a receipt is one page and a contract's first two
    /// carry its heading, and past that the turn is spending more tokens on a document than on the
    /// screen he was actually asking about.
    static func renderedJPEG(at path: String, maxPages: Int = 2, maxDimension: Int = 1280) -> [Data] {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return [] }
        var out: [Data] = []
        for index in 0..<min(maxPages, document.pageCount) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 1, bounds.height > 1 else { continue }
            let scale = CGFloat(maxDimension) / max(bounds.width, bounds.height)
            let pixels = NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: Int(pixels.width),
                                             pixelsHigh: Int(pixels.height),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            bounds.fill()
            page.draw(with: .mediaBox, to: context.cgContext)
            NSGraphicsContext.restoreGraphicsState()
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                out.append(jpeg)
            }
        }
        return out
    }
}
