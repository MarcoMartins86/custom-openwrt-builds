#!/bin/sh
# Boots the built image in QEMU and checks that the hardware watchdog restarts it:
# procd has to be feeding the watchdog, and once told to stop, the VM has to be
# reset without a restart of its own. Takes about three minutes; the smoke test
# only checks that procd feeds it. Exit status 0 means the watchdog did its job.
#
# usage: [IMG=path] watchdog.sh
Q="$(cd "$(dirname "$0")" && pwd)"
. "$Q/../.env"
[ -f "$Q/../private/.env" ] && . "$Q/../private/.env"

stop() {
	python3 "$Q/ser.py" sh 30 'sync; poweroff' > /dev/null 2>&1
	python3 "$Q/waitoff.py" 60
	rm -f "$Q/disk.img" "$Q/vars.fd" "$Q/serial.sock" "$Q/monitor.sock" "$Q/qemu.pid" "$Q/wdat.bin"
}

"$Q/start.sh" 8G sata || exit 1
trap stop EXIT

# The first boot ends by restarting once, to load the processor's microcode,
# unless the image brings it for the boot loader already
if [ -n "${GRUB_MICROCODE}" ]; then
	python3 "$Q/ser.py" wait 300 'Linux version' 'Please press Enter to activate this console' || exit 1
else
	python3 "$Q/ser.py" wait 300 'Linux version' 'Please press Enter to activate this console' \
		'reboot: Restarting system' 'Linux version' 'Please press Enter to activate this console' || exit 1
fi

# Without "magicclose", procd lets go of the watchdog without stopping it
OUT="$(python3 "$Q/ser.py" sh 60 'dmesg -n 1; sleep 5; ubus call system watchdog | grep -q "\"running\"" && echo "WATCHDOG FED"' \
	'ubus call system watchdog "{\"stop\": true}" > /dev/null; echo "WATCHDOG LEFT"')"
echo "$OUT" | grep -E '^WATCHDOG (FED|LEFT)$'
echo "$OUT" | grep -q '^WATCHDOG FED$' || { echo "WATCHDOG FAIL: not fed"; exit 1; }

# QEMU's TCO resets on the second expiry of the 30 s timeout. A restart of the
# system's own would print "reboot: Restarting system" first.
python3 "$Q/ser.py" wait 150 'Linux version' || { echo "WATCHDOG FAIL: no reset"; exit 1; }
if awk '/WATCHDOG LEFT/ { left = 1 } left' "$Q/serial.log" | grep -q 'reboot: Restarting system'; then
	echo "WATCHDOG FAIL: the system restarted itself"
	exit 1
fi
python3 "$Q/ser.py" wait 120 'Please press Enter to activate this console' > /dev/null || exit 1
echo "WATCHDOG PASS"
