import AppKit
import SwiftUI
import ChunksKit

/// `--render-face <path>` draws every notch mood offscreen to a PNG so the face can be judged before
/// it ever animates on the user's screen (3.6 lands behind a render state first). Read-only: it never
/// shows a window, never plays sound, never touches the live notch.
enum FaceRenderProbe {
    static var renderPath: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--render-face"),
              i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    private struct Grid: View {
        let cols = 5
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Chunks — notch moods")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.ink)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(86), spacing: 8), count: cols),
                          spacing: 14) {
                    ForEach(NotchMood.allCases, id: \.self) { mood in
                        VStack(spacing: 6) {
                            NotchFace(mood: mood, size: 40)
                            Text(mood.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(DS.Colors.inkMuted)
                        }
                        .frame(width: 86)
                    }
                }
            }
            .padding(16)
            .frame(width: 470, height: 220, alignment: .topLeading)
            .background(DS.Colors.ground)
        }
    }

    @MainActor
    static func run(to path: String) {
        let host = NSHostingView(rootView: Grid())
        host.frame = NSRect(x: 0, y: 0, width: 470, height: 220)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("render-face: could not allocate bitmap"); exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("render-face: could not encode PNG"); exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: path)) }
        catch { print("render-face: write failed \(error)"); exit(1) }
        print("render-face: wrote \(png.count / 1024) KB, \(NotchMood.allCases.count) moods, to \(path)")
        exit(0)
    }
}