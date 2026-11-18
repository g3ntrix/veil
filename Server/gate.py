#!/usr/bin/env python3
"""Veil gate: forwards Veil traffic to the local core and answers Veil health checks.

usage: gate.py [LISTEN_PORT=2100] [TARGET_PORT=2095]
       gate.py --version
"""
import errno
import selectors
import socket
import sys
import time

VERSION = 2
PROBE = b"\xffVEILPROBE\x01"
PONG = b"\xffVEILPONG\x01"

if len(sys.argv) > 1 and sys.argv[1] == "--version":
    print(VERSION)
    sys.exit(0)

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 2100
TARGET = ("127.0.0.1", int(sys.argv[2]) if len(sys.argv) > 2 else 2095)
BUF = 4 << 20

def core_listening():
    """True when something holds the core port (binding it fails with EADDRINUSE)."""
    t = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        t.bind(TARGET)
        return False
    except OSError as e:
        return e.errno == errno.EADDRINUSE
    finally:
        t.close()

S = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
S.bind(("0.0.0.0", LISTEN_PORT))
H = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
H.connect(TARGET)
for s in (S, H):
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, BUF)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, BUF)
    s.setblocking(False)

sel = selectors.DefaultSelector()
sel.register(S, selectors.EVENT_READ, "s")
sel.register(H, selectors.EVENT_READ, "h")
print("veil gate v%d listening on UDP %d -> %s:%d" % (VERSION, LISTEN_PORT, TARGET[0], TARGET[1]), flush=True)

last = None
hy_state, hy_checked = False, 0.0
while True:
    for key, _ in sel.select():
        try:
            if key.data == "s":
                for _ in range(64):
                    try:
                        d, a = S.recvfrom(65535)
                    except BlockingIOError:
                        break
                    if d.startswith(PROBE) and len(d) == len(PROBE) + 8:
                        now = time.time()
                        if now - hy_checked > 5:
                            hy_state, hy_checked = core_listening(), now
                        info = ("v=%d;hy=%d" % (VERSION, 1 if hy_state else 0)).encode()
                        S.sendto(PONG + d[len(PROBE):] + info, a)
                        continue
                    last = a
                    H.send(d)
            else:
                for _ in range(64):
                    try:
                        d = H.recv(65535)
                    except (BlockingIOError, ConnectionRefusedError):
                        break
                    if last:
                        S.sendto(d, last)
        except Exception:
            pass
