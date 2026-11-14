import Foundation
import Darwin
import ChunksKit

/// The app's end of the Chrome bridge: a local Unix socket the native-messaging host connects to.
///
/// Local-only by construction. There is no network listener and no cloud component — the socket is a
/// file in Application Support, the host is a process Chrome spawns that pipes the extension's stdio
/// to this socket, and every act that crosses it still travels the same PolicyGate → card →
/// ConsentGate chain as a press. The bridge is a *driver*, not a permission.
///
/// All mutable state lives on the main actor; the accept/read threads only hop frames across, the
/// same discipline every other callback in this app follows.
@MainActor
final class WebBridge {
    static let shared = WebBridge()

    /// The socket the host connects to. Kept short enough for `sockaddr_un.sun_path` (104 bytes).
    nonisolated static var socketPath: String {
        NSHomeDirectory() + "/Library/Application Support/Chunks/bridge.sock"
    }

    private(set) var isConnected = false
    private(set) var latestSnapshot: PageSnapshot?

    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var readBuffer = Data()
    private var pending: [String: CheckedContinuation<BridgeReply, Never>] = [:]
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        let path = Self.socketPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)   // a stale socket from a previous run would make bind fail

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { Log.write("bridge: could not create socket"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cPath = path.utf8CString
        guard cPath.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Log.write("bridge: socket path too long"); close(listenFD); listenFD = -1; return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: cPath.count) { dest in
                for i in 0..<cPath.count { dest[i] = cPath[i] }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard bound == 0, listen(listenFD, 1) == 0 else {
            Log.write("bridge: bind/listen failed errno=\(errno)"); close(listenFD); listenFD = -1; return
        }
        Log.write("bridge: listening at \(path)")

        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                Task { @MainActor [weak self] in self?.adopt(client) }
            }
        }
    }

    private func adopt(_ fd: Int32) {
        // One host at a time: a second connection is a stale host, so it is closed rather than
        // interleaved with the live one.
        if clientFD >= 0 { close(fd); return }
        clientFD = fd
        isConnected = true
        readBuffer = Data()
        Log.write("bridge: host connected")
        Thread.detachNewThread { [weak self] in self?.readLoop(fd) }
    }

    private nonisolated func readLoop(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            let data = Data(chunk[0..<n])
            Task { @MainActor [weak self] in self?.ingest(data, fd: fd) }
        }
        Task { @MainActor [weak self] in self?.drop(fd) }
    }

    private func ingest(_ data: Data, fd: Int32) {
        guard fd == clientFD else { return }
        readBuffer.append(data)
        while let (reply, consumed) = WebBridgeFraming.decode(BridgeReply.self, from: readBuffer) {
            readBuffer.removeFirst(consumed)
            handle(reply)
        }
        // A corrupt stream that never yields a whole frame must not grow without bound; a real
        // frame is far under the ceiling, so an over-ceiling buffer is garbage, not a partial.
        if readBuffer.count > 1_000_000 {
            readBuffer = Data()
            Log.write("bridge: dropped an over-size corrupt read buffer")
        }
    }

    private func drop(_ fd: Int32) {
        guard fd == clientFD else { return }
        close(fd)
        clientFD = -1
        isConnected = false
        latestSnapshot = nil
        // Anything still waiting is answered honestly rather than left to hang the turn.
        for (id, cont) in pending {
            cont.resume(returning: BridgeReply(id: id, ok: false, message: "The Chrome bridge disconnected."))
        }
        pending.removeAll()
        Log.write("bridge: host disconnected")
    }

    private func handle(_ reply: BridgeReply) {
        if let snapshot = reply.snapshot { latestSnapshot = snapshot }
        if let cont = pending.removeValue(forKey: reply.id) {
            cont.resume(returning: reply)
        }
    }

    // MARK: - Requests

    /// Send one command and wait for its reply, bounded so a dead page cannot hang a turn.
    func request(action: BridgeCommand.Action, url: String? = nil, query: String? = nil,
                 text: String? = nil, timeout: Double = 8) async -> BridgeReply {
        let id = UUID().uuidString
        guard isConnected, clientFD >= 0 else {
            return BridgeReply(id: id, ok: false, message: "The Chrome bridge is not connected.")
        }
        let command = BridgeCommand(id: id, action: action, url: url, query: query, text: text)
        guard let frame = WebBridgeFraming.encode(command) else {
            return BridgeReply(id: id, ok: false, message: "The bridge could not encode that request.")
        }
        let fd = clientFD
        return await withCheckedContinuation { cont in
            pending[id] = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let stale = self.pending.removeValue(forKey: id) else { return }
                stale.resume(returning: BridgeReply(id: id, ok: false,
                                                    message: "The page did not answer in time."))
            }
            // The write must never run on the main actor: if the host stops draining (its own
            // stdout to Chrome is blocked), a synchronous write fills the socket buffer and hangs
            // the run loop forever — and the timeout above could not fire on a blocked actor.
            // Off-main, a stalled peer costs one parked thread, not the UI (QA P1).
            Task.detached { [weak self] in
                let written = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                guard written != frame.count else { return }
                Task { @MainActor [weak self] in
                    guard let self, let c = self.pending.removeValue(forKey: id) else { return }
                    c.resume(returning: BridgeReply(id: id, ok: false,
                                                    message: "The Chrome bridge did not accept the request."))
                }
            }
        }
    }

    /// Ask the active tab for a fresh snapshot and cache it. A read — never offered as a question.
    @discardableResult
    func refreshSnapshot() async -> PageSnapshot? {
        let reply = await request(action: .snapshot)
        return reply.snapshot
    }
}