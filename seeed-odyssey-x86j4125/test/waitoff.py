#!/usr/bin/env python3
"""Wait for the test VM to exit; kill it if it has not within the timeout."""
import os
import signal
import sys
import time

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "qemu.pid")
timeout = float(sys.argv[1]) if len(sys.argv) > 1 else 60
try:
    pid = int(open(path).read())
except (OSError, ValueError):
    sys.exit(0)
start = time.time()
while time.time() - start < timeout:
    try:
        os.kill(pid, 0)
    except OSError:
        sys.exit(0)
    time.sleep(1)
os.kill(pid, signal.SIGKILL)
print("VM did not power off; killed")
