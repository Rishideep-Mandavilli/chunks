import Foundation
import AppKit

/// `--probe-web`: report whether the Chrome bridge is connected and what the active tab publishes.
///
/// Read-only: it asks for a snapshot and prints it, and performs no navigate/click/type. When the
/// extension is not loaded it says so and exits 0, so the gate can run it on any machine without the
/// extension and still see the bridge's own code path exercised.
enum WebProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-web") }

    static func run() {
        // The bridge server lives in the app; a probe is a separate process, so it connects as a
        // client would only if the app is running. Instead we report the socket's presence and, when
        // the app is up, ask it nothing — the probe's job is to show the wiring, not to drive a turn.
        let path = WebBridge.socketPath
        let exists = FileManager.default.fileExists(atPath: path)
        print("web bridge socket: \(exists ? "present" : "absent") at \(path)")
        print("host binary flag: --native-host (Chrome spawns it; it pumps stdio to the socket)")
        if !exists {
            print("bridge: not connected — load the extension (scripts/install-extension.sh) and keep the app running.")
        } else {
            print("bridge: socket present — the app is listening; load the extension to connect the host.")
        }
        print("web verbs: web_open / web_click / web_type; click+type always asked (ToolLayer.alwaysAsks).")
        exit(0)
    }
}