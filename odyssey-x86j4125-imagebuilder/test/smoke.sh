#!/bin/sh
# Boots the built image in QEMU and checks that the first boot did its job:
# every first-boot script ran, the data partition exists and is mounted, and the
# router can be reached. Exit status 0 means every check passed.
#
# usage: [IMG=path] smoke.sh
Q="$(cd "$(dirname "$0")" && pwd)"
. "$Q/../.env"
[ -f "$Q/../private/.env" ] && . "$Q/../private/.env"

stop() {
	python3 "$Q/ser.py" sh 30 'sync; poweroff' > /dev/null 2>&1
	python3 "$Q/waitoff.py" 60
	rm -f "$Q/disk.img" "$Q/vars.fd" "$Q/serial.sock" "$Q/monitor.sock" "$Q/qemu.pid"
}

"$Q/start.sh" 8G sata || exit 1
trap stop EXIT

# The first boot ends by restarting once, to load the processor's microcode
python3 "$Q/ser.py" wait 300 'Linux version' 'Please press Enter to activate this console' \
	'reboot: Restarting system' 'Linux version' 'Please press Enter to activate this console' || exit 1

# Give the services a moment, then collect what is wrong in $f.
# Kept as short commands: the serial console cuts lines off at about 500 characters.
OUT="$(python3 "$Q/ser.py" sh 180 \
	'dmesg -n 1; i=0; while [ $i -lt 30 ] && ! /etc/init.d/uhttpd running; do sleep 2; i=$((i+1)); done; f=""' \
	'[ -z "$(ls /etc/uci-defaults)" ] || f="$f first-boot-scripts-left"' \
	'grep -q " /mnt/data " /proc/mounts || f="$f data-partition-not-mounted"' \
	'[ "$(lsblk -n -o LABEL /dev/sda3)" = data ] || f="$f data-partition-label"' \
	'[ -z "'"${GUEST_SHARE}"'" ] || [ -d /mnt/data/share ] || f="$f share-folder"' \
	'for s in dropbear uhttpd odhcpd; do /etc/init.d/$s running || f="$f $s-not-running"; done' \
	'[ "$(uci -q get network.lan.ipaddr)" = '"${LAN_ADDRESS}"' ] || f="$f lan-address"' \
	'[ "'"${IPV6}"'" = 1 ] || [ -z "$(ip -6 addr show dev br-lan scope global)" ] || f="$f lan-ipv6"' \
	'i=0; while [ $i -lt 15 ] && [ "$(wg show wg0 listen-port 2>/dev/null)" != '"${VPN_PORT}"' ]; do sleep 2; i=$((i+1)); done' \
	'[ $i -lt 15 ] || f="$f vpn-not-listening"' \
	'/etc/init.d/compose enabled || f="$f containers-not-enabled"' \
	'grep -q "initrd /boot/intel-ucode.img" /boot/grub/grub.cfg || f="$f microcode"' \
	'grep -q fstrim /etc/crontabs/root && fstrim / && fstrim /mnt/data || f="$f trim"' \
	'[ -z "'"${CONTAINER_UPDATE_DAY}"'" ] || grep -q "compose update" /etc/crontabs/root || f="$f no-container-update"' \
	'if [ -z "$f" ]; then echo "SMOKE PASS"; else echo "SMOKE FAIL:$f"; fi')"
echo "$OUT" | grep -E '^SMOKE (PASS|FAIL)'
echo "$OUT" | grep -q '^SMOKE PASS$'
