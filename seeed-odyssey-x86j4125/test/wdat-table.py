#!/usr/bin/env python3
"""Writes an ACPI WDAT table for the test VM, so that it has a watchdog the way
the router does.

The router's firmware describes the chipset's TCO watchdog with this table, and
kmod-wdat-wdt drives it from there. QEMU's q35 machine emulates the same TCO
watchdog, but has no such table; this one has the same actions as the router's,
moved to the VM's TCO registers, which start at its ACPI I/O base 0x600 + 0x60.

One difference: the router's table reaches each register with a 4-byte access,
which also writes the register next to it. For the reload that is TCO_DAT_OUT,
whose write raises an SMI; the router's firmware handles it, QEMU's resets the
VM. So here each register is reached on its own, with a 2-byte access.

usage: wdat-table.py [tco-base] > wdat.bin    (QEMU: -acpitable file=wdat.bin)
"""
import struct
import sys

base = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0x660

READ_VALUE, WRITE_VALUE, WRITE_COUNTDOWN, PRESERVE = 0, 2, 3, 0x80
SYSTEM_IO, WORD = 1, 2
# action, instruction, bit width, bit offset, register, value, mask
ENTRIES = [
    (1, WRITE_VALUE | PRESERVE, 10, 0, 0x00, 0x4, 0x3FF),         # reset (feed): TCO_RLD
    (6, WRITE_COUNTDOWN | PRESERVE, 10, 0, 0x12, 0x3FF, 0x3FF),   # set countdown: TCO_TMR
    (8, READ_VALUE, 1, 11, 0x08, 0, 1),                           # query running: TCO1_CNT
    (9, WRITE_VALUE | PRESERVE, 1, 11, 0x08, 0, 1),               # set running
    (10, READ_VALUE, 1, 11, 0x08, 1, 1),                          # query stopped
    (11, WRITE_VALUE | PRESERVE, 1, 11, 0x08, 1, 1),              # set stopped
    (32, READ_VALUE, 1, 1, 0x06, 1, 1),                           # query status: TCO2_STS
    (33, WRITE_VALUE | PRESERVE, 1, 1, 0x06, 1, 1),               # clear status
]

body = struct.pack("<IHBBB3xIIIB3xI", 32, 0xFF, 0xFF, 0xFF, 0xFF,
                   600, 1023, 2, 0x81, len(ENTRIES))   # 600 ms steps, enabled
for action, instruction, width, offset, reg, value, mask in ENTRIES:
    body += struct.pack("<BBHBBBBQII", action, instruction, 0,
                        SYSTEM_IO, width, offset, WORD, base + reg, value, mask)

length = 36 + len(body)
header = struct.pack("<4sIBB6s8sI4sI", b"WDAT", length, 1, 0, b"OPENWR",
                     b"TESTWDAT", 1, b"TEST", 1)
table = bytearray(header + body)
table[9] = (-sum(table)) & 0xFF
sys.stdout.buffer.write(bytes(table))
