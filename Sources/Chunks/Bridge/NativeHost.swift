import Foundation
import Darwin

/// `Chunks --native-host`: the process Chrome spawns for the extension's native-messaging port.
///
/// It is a dumb, local pump: Chrome's stdio pipe on one side, the app's Unix socket on the other,
/// both speaking the same 4-byte-length + JSON frame, so bytes cross without re-encoding. It holds no
/// state and makes no decision — every act still goes through the app's consent chain. It exits when
/// Chrome closes the pipe, and it never starts the GUI.
enum NativeHost {
    static func run() -> Never {
        let sock = connect()
        guard sock >= 0 else { exit(1) }

        // socket → stdout (the extension reads replies and pushed snapshots here).
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(sock, &buffer, buffer.count)
                if n <= 0 { break }
                var written = 0
                while written < n {
                    let w = buffer.withUnsafeBytes { base in
                        write(1, base.baseAddress! + written, n - written)
                    }
                    if w <= 0 { exit(0) }
                    written += w
                }
            }
            exit(0)
        }

        // stdin → socket (the app's commands arrive here). When Chrome closes the pipe, we are done.
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(0, &buffer, buffer.count)
            if n <= 0 { break }
            var written = 0
            while written < n {
                let w = buffer.withUnsafeBytes { base in
                    write(sock, base.baseAddress! + written, n - written)
                }
                if w <= 0 { exit(0) }
                written += w
            }
        }
        exit(0)
    }

    private static func connect() -> Int32 {
        let path = WebBridge.socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cPath = path.utf8CString
        guard cPath.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return -1 }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: cPath.count) { dest in
                for i in 0..<cPath.count { dest[i] = cPath[i] }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        if result != 0 { close(fd); return -1 }
        return fd
    }
}