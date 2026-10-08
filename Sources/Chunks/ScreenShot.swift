import ChunksKit
import Foundation

/// `Chunks --shot [path]` — write what is on the screen right now to a file, and leave.
///
/// The reason this exists is that Chunks is the only process on this Mac with the Screen
/// Recording grant that matters: a screenshot taken from a terminal belongs to the terminal, and
/// macOS then hands back an image of the wallpaper with other apps' windows removed. That image
/// looks like a result and is not one — the same class of plausible-but-wrong number that
/// invariant 1 was written about. Capturing from inside the bundle is the only way to see what the
/// app itself can see, which is how the notch card and the cursor overlay get verified at all.
///
/// Read-only by design: it captures, writes one file, and exits. It draws nothing and presses
/// nothing.
enum ScreenShot {
    static var isRequested: Bool { CommandLine.arguments.contains("--shot") }

    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let path = requestedPath()
        print("shot: writing \(path)")

        guard let display = CaptureEngine.mainDisplay() else {
            Log.write("shot: no main display")
            Log.flush()
            exit(1)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            Log.write("shot: the capture never returned — screen recording is probably not granted")
            Log.flush()
            exit(1)
        }

        Task { @MainActor in
            do {
                let captured = try await CaptureEngine().capture(display: display, shapes: [])
                let image = captured.composited(with: [], display: display)
                guard let png = ScreenCapture(image: image, globalRect: captured.globalRect).png() else {
                    Log.write("shot: could not encode the capture as PNG")
                    Log.flush()
                    exit(1)
                }
                try png.write(to: URL(fileURLWithPath: path))
                Log.write("shot: wrote \(path) \(image.width)x\(image.height)px "
                    + "(\(png.count / 1024) KB)")
                Log.flush()
                exit(0)
            } catch {
                Log.write("shot: capture failed — \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                Log.flush()
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func requestedPath() -> String {
        guard let index = CommandLine.arguments.firstIndex(of: "--shot") else { return defaultPath }
        let next = index + 1
        guard CommandLine.arguments.indices.contains(next) else { return defaultPath }
        let candidate = CommandLine.arguments[next]
        return candidate.hasPrefix("-") ? defaultPath : candidate
    }

    private static var defaultPath: String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("screen.png").path
    }
}
