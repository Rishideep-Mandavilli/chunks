import AppKit
import Foundation

/// Region selection through the tool macOS already ships, instead of a window Chunks owns.
///
/// Why the window lost. The drawing surface was measured twice on the real machine on 2026-10-14.
/// At `.screenSaver` level it was the frontmost window over the point, was key, and received
/// `keyDown` — while not one mouse event reached the app at all. At `.statusBar` the click *did*
/// reach the app and was routed to the cursor buddy's full-screen window instead of the canvas
/// (`leftMouseDown → window #4294967296 inCanvas=false`). Both faults live inside our own window
/// stack, and the user watched eleven rounds of it.
///
/// `/usr/sbin/screencapture -i` is the selector ⌘⇧4 uses. The pointer is owned by a system session,
/// so no Chunks window can out-rank it, nothing of ours sits on the screen afterwards, and his
/// machine cannot be trapped by it — the property the 2026-10-11 lockup made non-negotiable.
///
/// What it gives up is the freehand mark: the answer is a rectangle, not a circle. `AnnotationShape`,
/// `RegionResolver` and the composited-marks path stay in the kit and stay tested, so the marks
/// return with the window once the mouse question is answered.
@MainActor
enum RegionSelector {

    /// The PNG of whatever the user selected, or `nil` when he cancelled or the tool failed.
    static func capture() async -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-region-\(UUID().uuidString.prefix(8)).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let status: Int32 = await withCheckedContinuation { continuation in
            let tool = Process()
            tool.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // `-x` silences the shutter. A file path rather than `-c`, because the user's clipboard
            // is his, not a transport for Chunks' questions.
            tool.arguments = ["-x", "-i", url.path]
            tool.standardError = FileHandle.nullDevice
            tool.terminationHandler = { running in
                continuation.resume(returning: running.terminationStatus)
            }
            // If `run()` throws there is no process, so no `terminationHandler` either: resuming
            // here is the only resume that can happen, and a second one would trap.
            do { try tool.run() } catch { continuation.resume(returning: -1) }
        }

        guard status == 0, let data = try? Data(contentsOf: url), !data.isEmpty else {
            // Escape produces a non-zero exit and no file, which is a cancelled gesture rather than
            // a failure — so the reason is logged and the user is not lectured by a red card.
            let wrote = ((try? Data(contentsOf: url))?.isEmpty == false)
            Log.write("annotate: no region asked — screencapture exited \(status), "
                + "image written: \(wrote)")
            return nil
        }
        return data
    }
}
