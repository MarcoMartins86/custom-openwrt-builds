#!/usr/bin/env python3
"""Wait for the router to come back after a flash, and say when it has settled.

It polls the router over SSH until the expected release is running, the first-boot
scripts are gone and the data partition is mounted. Every state change is printed.
Used by flash.sh.

usage: wait-router.py --release 25.12.5 [--host 192.168.2.1] [--port 22]
                      [--key FILE] [--known-hosts FILE] [--timeout 420]
"""
import argparse
import os
import socket
import subprocess
import sys
import time

STATUS = ('. /etc/openwrt_release; echo "$DISTRIB_RELEASE '
          '$(grep -c " /mnt/data " /proc/mounts) '
          '$(ls /etc/uci-defaults | wc -l) $(cut -d. -f1 /proc/uptime)"')


def port_open(host, port, timeout=1.5):
    try:
        socket.create_connection((host, port), timeout=timeout).close()
        return True
    except OSError:
        return False


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--release", required=True)
    ap.add_argument("--host", default="192.168.2.1")
    ap.add_argument("--port", type=int, default=22)
    ap.add_argument("--key")
    ap.add_argument("--known-hosts")
    ap.add_argument("--timeout", type=float, default=420)
    args = ap.parse_args()
    start = time.time()

    def say(msg):
        print(f"{time.strftime('%H:%M:%S')} [{time.time() - start:4.0f}s] {msg}", flush=True)

    ssh = ["ssh", "-p", str(args.port), "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
           "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR"]
    if args.key:
        ssh += ["-i", args.key, "-o", "IdentitiesOnly=yes"]
    if args.known_hosts:
        ssh += ["-o", f"UserKnownHostsFile={args.known_hosts}"]
    ssh += [f"root@{args.host}", STATUS]

    last, settled = None, False
    while time.time() - start < args.timeout:
        if not port_open(args.host, args.port):
            state = "router not answering on SSH"
        else:
            try:
                res = subprocess.run(ssh, capture_output=True, text=True, timeout=12)
            except subprocess.TimeoutExpired:
                res = None
            if res is None or res.returncode != 0:
                err = (res.stderr.strip().splitlines() or ["?"])[-1] if res else "timed out"
                state = f"SSH port open, login not possible yet ({err[:80]})"
            else:
                parts = res.stdout.split()
                if len(parts) == 4 and parts[1].isdigit():
                    release, data, defaults, uptime = parts[0], int(parts[1]), parts[2], int(parts[3])
                    state = (f"logged in: release {release}, data partition "
                             f"{'mounted' if data else 'NOT mounted'}, {defaults} first-boot scripts left")
                    if release == args.release and data and defaults == "0" and uptime >= 20:
                        say(state + f", up {uptime}s")
                        settled = True
                        break
                else:
                    state = f"logged in, unexpected status: {res.stdout.strip()[:80]}"
        if state != last:
            say(state)
            last = state
        time.sleep(3)

    if not settled:
        say("TIMEOUT: the router did not reach the expected state")
        sys.exit(1)


main()
