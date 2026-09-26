#!/usr/bin/env python3
"""Minimal zmx IPC client for observer.bats.

Speaks the daemon's wire format directly so the tests exercise the observer
protocol the way an embedding app would, without a TTY:

  frame   = header(8) + payload
  header  = tag u8 | len u32 LE | 3 padding bytes   (packed struct{u8,u32})
  Observe       (15) payload: scrollback_rows u32
  ObserveState  (16) payload: rows u16, cols u16, flags u16, reserved u16, vt bytes
  ObserveResize (17) payload: rows u16, cols u16

Every subcommand prints plain `key value...` lines for bats to match and
exits non-zero on a timeout or protocol surprise.
"""

import socket
import struct
import sys
import time

INPUT, OUTPUT, RESIZE, INIT = 0, 1, 2, 7
OBSERVE, OBSERVE_STATE, OBSERVE_RESIZE = 15, 16, 17
TIMEOUT = 5.0


def connect(path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(TIMEOUT)
    sock.connect(path)
    return sock


def send(sock, tag, payload=b""):
    sock.sendall(struct.pack("<BI3x", tag, len(payload)) + payload)


def size_payload(rows, cols):
    return struct.pack("<HH", rows, cols)


class Reader:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def next_frame(self, deadline):
        while True:
            if len(self.buf) >= 8:
                tag, length = struct.unpack_from("<BI", self.buf, 0)
                if len(self.buf) >= 8 + length:
                    payload = self.buf[8 : 8 + length]
                    self.buf = self.buf[8 + length :]
                    return tag, payload
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("no frame before deadline")
            self.sock.settimeout(remaining)
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("daemon closed the connection")
            self.buf += chunk

    def wait_for(self, wanted, seen=None):
        """Returns the payload of the next `wanted` frame; records other tags."""
        deadline = time.monotonic() + TIMEOUT
        while True:
            tag, payload = self.next_frame(deadline)
            if tag == wanted:
                return payload
            if seen is not None:
                seen.append(tag)


def observe(sock, reader, scrollback_rows, seen=None):
    send(sock, OBSERVE, struct.pack("<I", scrollback_rows))
    payload = reader.wait_for(OBSERVE_STATE, seen)
    rows, cols, flags, reserved = struct.unpack_from("<HHHH", payload, 0)
    return rows, cols, flags, reserved, payload[8:]


def cmd_leader_init(path, rows, cols):
    """Attach as a real client, claim the lead, size the PTY, disconnect."""
    sock = connect(path)
    reader = Reader(sock)
    send(sock, INIT, size_payload(int(rows), int(cols)))
    # setLeader answers with an empty Resize request, queued after the
    # ioctl in the same handler: once it arrives the PTY has the new size.
    reader.wait_for(RESIZE)
    sock.close()
    print("leader ok")


def cmd_state(path, scrollback_rows, body_out=None):
    sock = connect(path)
    reader = Reader(sock)
    rows, cols, flags, reserved, body = observe(sock, reader, int(scrollback_rows))
    print(f"state {rows} {cols} flags={flags} reserved={reserved} body={len(body)}")
    if body_out:
        with open(body_out, "wb") as f:
            f.write(body)
    sock.close()


def cmd_mischief(path, marker):
    """Observe, then try every way a client could steer the PTY."""
    sock = connect(path)
    reader = Reader(sock)
    seen = []
    rows, cols, *_ = observe(sock, reader, 0, seen)
    print(f"before {rows} {cols}")
    send(sock, INPUT, f"echo {marker}\r".encode())
    send(sock, INIT, size_payload(5, 20))
    send(sock, RESIZE, size_payload(6, 21))
    # The daemon handles a client's frames in order, so the resync reply
    # proves the three frames above were already processed.
    rows, cols, *_ = observe(sock, reader, 0, seen)
    print(f"after {rows} {cols}")
    # A client promoted to leader would have been asked for its size.
    print(f"resize_requests {seen.count(RESIZE)}")
    print(f"observe_resizes {seen.count(OBSERVE_RESIZE)}")
    sock.close()


def cmd_watch_resize(path, rows1, cols1, rows2, cols2):
    """An observer watches a leader attach and then resize."""
    observer = connect(path)
    oreader = Reader(observer)
    rows, cols, *_ = observe(observer, oreader, 0)
    print(f"state {rows} {cols}")

    leader = connect(path)
    lreader = Reader(leader)
    send(leader, INIT, size_payload(int(rows1), int(cols1)))
    lreader.wait_for(RESIZE)
    r, c = struct.unpack("<HH", oreader.wait_for(OBSERVE_RESIZE))
    print(f"resize {r} {c}")

    send(leader, RESIZE, size_payload(int(rows2), int(cols2)))
    r, c = struct.unpack("<HH", oreader.wait_for(OBSERVE_RESIZE))
    print(f"resize {r} {c}")

    # A resync reports the size the observer was just told about.
    rows, cols, *_ = observe(observer, oreader, 0)
    print(f"resynced {rows} {cols}")
    leader.close()
    observer.close()


def cmd_output(path, needle):
    """Observe, then wait for `needle` to arrive in the live Output stream."""
    sock = connect(path)
    reader = Reader(sock)
    observe(sock, reader, 0)
    print("observing", flush=True)
    stream = b""
    deadline = time.monotonic() + TIMEOUT
    while needle.encode() not in stream:
        tag, payload = reader.next_frame(deadline)
        if tag == OUTPUT:
            stream += payload
    print("output ok")
    sock.close()


COMMANDS = {
    "leader-init": cmd_leader_init,
    "state": cmd_state,
    "mischief": cmd_mischief,
    "watch-resize": cmd_watch_resize,
    "output": cmd_output,
}

if __name__ == "__main__":
    try:
        COMMANDS[sys.argv[1]](*sys.argv[2:])
    except (TimeoutError, EOFError, socket.timeout) as err:
        print(f"error {err}", file=sys.stderr)
        sys.exit(2)
