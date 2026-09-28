import AppKit
import ChunksKit

/// Process entry point.
///
/// `@main` (rather than a top-level `main.swift`) so the launch path is properly
/// MainActor-isolated — AppKit requires it and Swift 6 will hard-error on it.
@main
struct ChunksMain {
    @MainActor static func main() {
        NSApplicationBridge.shared.run()
    }
}

/// Owns the AppKit application lifecycle for Chunks.
///
/// Chunks is a menu-bar app: no Dock icon, no main window. Everything the user sees
/// (status item, control panel, annotation overlay) is an `NSPanel` we place ourselves.
@MainActor
final class NSApplicationBridge {
    static let shared = NSApplicationBridge()

    private var app: NSApplication!
    private var statusItem: NSStatusItem?

    private init() {}

    func run() {
        app = NSApplication.shared
        // Accessory, not regular: no Dock tile, no app menu.
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Chunks")
            button.imagePosition = .imageLeading
            button.title = "Chunks"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        NSLog("[Chunks] status item clicked — panel wiring lands in Phase 1")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplicationBridge.shared.installStatusItem()
        NSLog("[Chunks] launched")
    }
}
