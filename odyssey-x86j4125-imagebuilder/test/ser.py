#!/usr/bin/env python3
"""Drive the serial console of the QEMU test VM over its unix socket.

  ser.py wait TIMEOUT REGEX [REGEX...]   wait for each regex in turn
  ser.py sh TIMEOUT CMD [CMD...]         run shell commands on the console
"""
import os
import re
import select
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# Opened from its own folder: a socket path may not be longer than 107 bytes,
# and a checkout can sit deeper than that (GitHub's runners do)
SOCK = "serial.sock"
ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]|\r")
# Kernel messages share the console and can land in the middle of a command's
# output, right behind its end marker for one. They are left out of that output.
KMSG = re.compile(rb"\[ *[0-9]+\.[0-9]+\] [^\n]*\n")
PROMPT = rb"root@[^:\n]+:[^\n]*# $"


def clean(data, kmsg=False):
    data = ANSI.sub(b"", data)
    return (KMSG.sub(b"", data) if kmsg else data).decode("utf-8", "replace")


def read_until(sock, regex, deadline, buf=b"", kmsg=False):
    rx = re.compile(regex, re.M)
    while True:
        m = rx.search(clean(buf, kmsg).encode())
        if m:
            return buf, True
        left = deadline - time.time()
        if left <= 0:
            return buf, False
        if select.select([sock], [], [], min(left, 5))[0]:
            data = sock.recv(65536)
            if not data:
                return buf, False
            buf += data


def main():
    mode, timeout, args = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
    os.chdir(HERE)
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(SOCK)
    deadline = time.time() + timeout
    start = time.time()

    if mode == "wait":
        for regex in args:
            buf, ok = read_until(sock, regex.encode(), deadline)
            print(f"[{time.time() - start:5.0f}s] {'matched' if ok else 'TIMEOUT'}: {regex}")
            if not ok:
                print("--- last output ---")
                print(clean(buf)[-3000:])
                sys.exit(1)
        return

    # activate the console and get a prompt
    sock.sendall(b"\n")
    buf, ok = read_until(sock, PROMPT, min(deadline, time.time() + 30))
    if not ok:
        print("no shell prompt; last output:\n" + clean(buf)[-2000:])
        sys.exit(1)
    for n, cmd in enumerate(args):
        end = f"__END_{n}__"
        # the quotes keep the echoed command line from matching the marker
        sock.sendall(f'{cmd}; echo "__E""ND_{n}__"\n'.encode())
        buf, ok = read_until(sock, end.encode(), deadline, kmsg=True)
        out = clean(buf, kmsg=True)
        out = out.split("\n", 1)[1] if "\n" in out else out
        print(f"### {cmd}")
        print(out.split(end)[0].rstrip() if ok else out + "\n[TIMEOUT]")
        read_until(sock, PROMPT, time.time() + 5)


main()
