#!/bin/sh
# Boots the built image in QEMU and checks that the first boot did its job:
# every first-boot script ran, the data partition exists and is mounted, and the
# router can be reached. Then powers it off and checks the data partition was
# unmounted cleanly. Exit status 0 means every check passed.
#
# usage: [IMG=path] smoke.sh
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

# The first boot ends by restarting once, to load the processor's microcode
python3 "$Q/ser.py" wait 300 'Linux version' 'Please press Enter to activate this console' \
	'reboot: Restarting system' 'Linux version' 'Please press Enter to activate this console' || exit 1

# Give the services a moment, then collect what is wrong in $f.
# Kept as short commands: the serial console cuts lines off at about 500 characters.
OUT="$(python3 "$Q/ser.py" sh 180 \
	'dmesg -n 1; i=0; while [ $i -lt 30 ] && ! /etc/init.d/uhttpd running; do sleep 2; i=$((i+1)); done; f=""' \
	'[ -z "$(ls /etc/uci-defaults)" ] || f="$f first-boot-scripts-left"' \
	'[ ! -e /etc/wifi.env ] && [ -s /etc/odyssey/wifi.key ] || f="$f wifi-password"' \
	'grep -q " /mnt/data " /proc/mounts || f="$f data-partition-not-mounted"' \
	'[ "$(lsblk -n -o LABEL /dev/sda3)" = data ] || f="$f data-partition-label"' \
	'[ -z "'"${GUEST_SHARE}"'" ] || [ -d /mnt/data/share ] || f="$f share-folder"' \
	'for s in dropbear uhttpd odhcpd; do /etc/init.d/$s running || f="$f $s-not-running"; done' \
	'[ "$(uci -q get network.lan.ipaddr)" = '"${LAN_ADDRESS}"' ] || f="$f lan-address"' \
	'[ "'"${IPV6}"'" = 1 ] || [ -z "$(ip -6 addr show dev br-lan scope global)" ] || f="$f lan-ipv6"' \
	'i=0; while [ $i -lt 15 ] && [ "$(wg show wg0 listen-port 2>/dev/null)" != '"${VPN_PORT}"' ]; do sleep 2; i=$((i+1)); done' \
	'[ $i -lt 15 ] || f="$f vpn-not-listening"' \
	'i=0; while [ $i -lt 30 ] && ! grep -q "init complete" /mnt/data/log/messages; do sleep 2; i=$((i+1)); done' \
	'[ $i -lt 30 ] || f="$f log-file"' \
	'/etc/init.d/compose enabled || f="$f containers-not-enabled"' \
	'grep -q "initrd /boot/intel-ucode.img" /boot/grub/grub.cfg || f="$f microcode"' \
	'grep -q fstrim /etc/crontabs/root && fstrim / && fstrim /mnt/data || f="$f trim"' \
	'ubus call system watchdog | grep -q "\"running\"" || f="$f watchdog"' \
	'[ -L /etc/rc.d/K01compose ] && [ -L /etc/rc.d/K88release_data ] || f="$f shutdown-steps"' \
	'/etc/init.d/smartd running && [ -n "$(ls /tmp/smartd/*.ata.state)" ] || f="$f smartd"' \
	'[ "$(uci -q get fstab.@global[0].check_fs)" = 1 ] && logread | grep -q "e2fsck: data: clean" || f="$f fsck"' \
	'/etc/init.d/watchcat running && [ "$(uci -q get watchcat.wan.mode)" = restart_iface ] || f="$f watchcat"' \
	'[ "$(uci -q get banip.global.ban_backupdir)" = /mnt/data/banip/backup ] || f="$f banip-backups"' \
	'[ -z "'"${BANIP_REFRESH_HOUR}"'" ] || grep -q "banip reload" /etc/crontabs/root || f="$f no-banip-refresh"' \
	'A="'"${LETSENCRYPT:+${DDNS_HOST}}"'"; S="'"${ROUTER_NAME}"'.$A"; L='"${LAN_ADDRESS%/*}"'' \
	'[ -z "$A" ] || { [ "$(uci -q get acme.router.domains)" = "*.$A" ] && [ -L /etc/acme ] && [ -L /etc/ssl/acme ]; } || f="$f acme"' \
	'[ -z "$A" ] || { nslookup "$S" $L | grep -q "Address.* $L$" && nslookup "$S" '"${VPN_ADDRESS%/*}"' | grep -q "Address.* $L$"; } || f="$f inside-dns"' \
	'[ -z "$A" ] || { ! nslookup "vpn.$A" $L | grep -q "Address.* $L$" && ! nslookup "$A" $L | grep -q "Address.* $L$"; } || f="$f public-names-overridden"' \
	'[ -z "$A" ] || { /etc/init.d/nginx running && [ "$(curl -sk -o /dev/null -w "%{http_code}" --resolve "$S:443:127.0.0.1" "https://$S/")" = 200 ]; } || f="$f luci-by-name"' \
	'[ -z "$A" ] || { [ "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/)" = 301 ] && [ "$(curl -sk -o /dev/null -w "%{http_code}" https://127.0.0.1:8443/)" = 200 ]; } || f="$f web-ports"' \
	'i=0; while [ $i -lt 40 ] && [ ! -f /mnt/data/rrd/'"${ROUTER_NAME}"'/diskhealth-sda/temperature.rrd ]; do sleep 2; i=$((i+1)); done' \
	'[ $i -lt 40 ] || f="$f disk-health-graph"' \
	'[ -z "'"${CONTAINER_UPDATE_DAY}"'" ] || grep -q "compose update" /etc/crontabs/root || f="$f no-container-update"' \
	'if [ -z "$f" ]; then echo "SMOKE PASS"; else echo "SMOKE FAIL:$f"; fi')"
case "$OUT" in
	*"SMOKE PASS"*) f="" ;;
	*"SMOKE FAIL:"*) f="$(echo "$OUT" | sed -n 's/^SMOKE FAIL://p')" ;;
	*) f=" no-answer" ;;
esac

# Shutting down has to unmount the data partition, which leaves its journal with
# nothing to recover. Docker keeps its files there and is the one to watch.
python3 "$Q/ser.py" sh 30 'poweroff' > /dev/null 2>&1
python3 "$Q/waitoff.py" 120
START="$(sfdisk -J "$Q/disk.img" | python3 -c 'import json, sys
print(next(p["start"] for p in json.load(sys.stdin)["partitiontable"]["partitions"] if p.get("name") == "data"))')"
DATA="$Q/disk.img?offset=$((START * 512))"
FEATURES="$(debugfs -R features "$DATA" 2>/dev/null)"
case "$FEATURES" in
	# The disk is thrown away, so its journal can be replayed to read the log below
	*needs_recovery*) f="$f unclean-shutdown"; e2fsck -p "$DATA" > /dev/null 2>&1 ;;
	*has_journal*) ;;
	*) f="$f data-partition-unreadable" ;;
esac
# What the shutdown logged, from the VM's log file on that partition: how long
# Docker took to stop, and anything that had to be ended. All of it when the
# partition was left unclean.
SHUTDOWN="$(debugfs -R "cat /log/messages" "$DATA" 2>/dev/null | sed -n '/procd: - shutdown -/,$p' | cut -c26-200)"
echo "$SHUTDOWN" | grep -q "compose: Docker" || f="$f docker-not-stopped"
case "$f" in
	*unclean-shutdown*) echo "--- shutdown, from the VM's log:"; echo "$SHUTDOWN" ;;
	*) echo "$SHUTDOWN" | grep -E "compose: Docker|release_data:" ;;
esac

if [ -z "$f" ]; then echo "SMOKE PASS"; else echo "SMOKE FAIL:$f"; exit 1; fi
