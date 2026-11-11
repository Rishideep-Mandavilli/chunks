#!/opt/homebrew/bin/python3
"""Chunks native-messaging host: a plain stdio <-> Unix-socket pump.

Deliberately NOT the GUI app binary. Chrome spawns this as a child with a minimal
environment; a plain interpreter process starts reliably there, where the AppKit
app binary did not. It holds no state and makes no decision - every act is still
consented in the app. Both sides speak the same 4-byte-length + JSON frame, so
bytes cross without re-encoding. Exits when Chrome closes the pipe.
"""
import os
import socket
import sys
import threading

SOCK = os.path.join(os.path.expanduser("~"),
                    "Library/Application Support/Chunks/bridge.sock")


def pump(src_read, dst_write):
    try:
        while True:
            data = src_read(65536)
            if not data:
                break
            dst_write(data)
    except OSError:
        pass
    finally:
        os._exit(0)


def main():
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(SOCK)
    except OSError:
        sys.exit(1)

    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    # socket -> stdout (replies / pushed snapshots to the extension)
    def out(data):
        stdout.write(data)
        stdout.flush()
    t = threading.Thread(target=pump, args=(sock.recv, out), daemon=True)
    t.start()

    # stdin -> socket (commands from the app). When Chrome closes the pipe, exit.
    pump(stdin.read, sock.sendall)


if __name__ == "__main__":
    main()