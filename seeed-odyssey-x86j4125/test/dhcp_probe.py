#!/usr/bin/env python3
"""Minimal DHCP client for the VM's LAN NIC, over QEMU's dgram netdev (LAN=dgram).

Start it before start.sh: it owns lan-peer.sock, which QEMU sends the NIC's frames to.
It repeats DISCOVER until the router answers, then completes REQUEST/ACK.
"""
import os
import select
import socket
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# Used from their own folder, as socket paths are limited to 107 bytes
LOCAL = "lan-peer.sock"
REMOTE = "lan.sock"
MAC = bytes.fromhex("525400000299")
HOSTNAME = b"testclient"
XID = 0x0DD5EED1
NAMES = {1: "netmask", 3: "router", 6: "dns", 15: "domain", 51: "lease", 54: "server"}


def csum(data):
    total = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def frame(msgtype, extra=b""):
    bootp = struct.pack("!BBBBIHH4s4s4s4s16s64s128s4s", 1, 1, 6, 0, XID, 0, 0x8000,
                        b"", b"", b"", b"", MAC, b"", b"", b"\x63\x82\x53\x63")
    opts = (bytes([53, 1, msgtype]) + bytes([61, 7, 1]) + MAC
            + bytes([12, len(HOSTNAME)]) + HOSTNAME + bytes([55, 4, 1, 3, 6, 15]) + extra + b"\xff")
    payload = (bootp + opts).ljust(300, b"\0")
    udp = struct.pack("!HHHH", 68, 67, 8 + len(payload), 0) + payload
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0, 64, 17, 0, bytes(4), b"\xff" * 4)
    ip = ip[:10] + struct.pack("!H", csum(ip)) + ip[12:]
    return b"\xff" * 6 + MAC + b"\x08\x00" + ip + udp


def parse(pkt):
    """Return (msgtype, yiaddr, options) for a DHCP reply to us, else None."""
    if len(pkt) < 282 or pkt[12:14] != b"\x08\x00" or pkt[23] != 17:
        return None
    ihl = (pkt[14] & 0x0F) * 4
    udp = pkt[14 + ihl:]
    if struct.unpack("!HH", udp[:4]) != (67, 68):
        return None
    bootp = udp[8:]
    if bootp[0] != 2 or struct.unpack("!I", bootp[4:8])[0] != XID:
        return None
    opts, raw, i = {}, bootp[240:], 0
    while i < len(raw) and raw[i] != 255:
        if raw[i] == 0:
            i += 1
            continue
        opts[raw[i]] = raw[i + 2:i + 2 + raw[i + 1]]
        i += 2 + raw[i + 1]
    return opts.get(53, b"\0")[0], bootp[16:20], opts


def show(label, yiaddr, opts):
    parts = [f"ip={socket.inet_ntoa(yiaddr)}"]
    for code, name in NAMES.items():
        if code not in opts:
            continue
        val = opts[code]
        if code == 51:
            val = f"{struct.unpack('!I', val)[0]}s"
        elif code == 15:
            val = val.decode()
        else:
            val = ",".join(socket.inet_ntoa(val[j:j + 4]) for j in range(0, len(val), 4))
        parts.append(f"{name}={val}")
    print(f"{label}: " + " ".join(parts), flush=True)


def exchange(sock, pkt, want, deadline):
    """Send pkt every 3 s until a reply of type `want` arrives."""
    while time.time() < deadline:
        try:
            sock.sendto(pkt, REMOTE)
        except OSError:
            pass  # QEMU not up yet
        until = time.time() + 3
        while time.time() < until:
            if not select.select([sock], [], [], max(0, until - time.time()))[0]:
                break
            reply = parse(sock.recv(65536))
            if reply and reply[0] == want:
                return reply
            if reply and reply[0] == 6:
                print("got DHCPNAK", flush=True)
    return None


def main():
    timeout = float(sys.argv[1]) if len(sys.argv) > 1 else 180
    os.chdir(HERE)
    if os.path.exists(LOCAL):
        os.unlink(LOCAL)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(LOCAL)
    start, deadline = time.time(), time.time() + timeout

    offer = exchange(sock, frame(1), 2, deadline)
    if not offer:
        sys.exit(f"no DHCPOFFER within {timeout:.0f}s")
    _, yiaddr, opts = offer
    print(f"[{time.time() - start:4.0f}s] ", end="")
    show("OFFER", yiaddr, opts)

    request = frame(3, bytes([50, 4]) + yiaddr + bytes([54, 4]) + opts[54])
    ack = exchange(sock, request, 5, min(deadline, time.time() + 20))
    if not ack:
        sys.exit("no DHCPACK")
    print(f"[{time.time() - start:4.0f}s] ", end="")
    show("ACK", ack[1], ack[2])


main()
