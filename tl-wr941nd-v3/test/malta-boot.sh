#!/bin/sh
# Boots the image's root file system on QEMU's MIPS Malta board, the nearest QEMU has to the
# device: the same processor family, but with OpenWrt's Malta kernel for the release in
# place of the device's own, its builds of the kernel modules the image has, and the
# device's 32 MB of memory. Then checks that the first boot ran, that the services started
# and that no script missed a command, and reports how much memory is left.
#
# The Malta kernel needs about 6 MB more memory than the device's, so the services have less
# room here than on the device; the report also gives an estimate for the device. What only
# the device shows: its kernel, switch and Wi-Fi, and hostapd, which needs the radio.
# Exit status 0 means every check passed.
#
# usage: malta-boot.sh   (after build.sh, whose tools it uses; needs qemu-system-mips)
Q="$(cd "$(dirname "$0")" && pwd)"
. "$Q/malta-lib.sh"
malta_file "${KERNEL##*/}" && malta_packages $(malta_kmods) || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
LOG="$Q/malta-serial.log"
malta_root "${WORK}"
cat > "${WORK}/root/usr/libexec/malta-report" << 'EOF'
echo "--- left: $(ls /etc/uci-defaults | xargs)"
for s in dropbear log network sysntpd; do
	/etc/init.d/$s running && echo "--- service $s running" || echo "--- service $s stopped"
done
echo "--- modules loaded: $(lsmod | tail -n +2 | wc -l)"
echo "--- modules: $(lsmod | tail -n +2 | cut -d' ' -f1 | xargs)"
echo "--- swaps"
cat /proc/swaps
echo "--- meminfo"
grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Shmem|Slab|SUnreclaim|SwapTotal|SwapFree):' /proc/meminfo
# A process's own memory (RssAnon) is what ending it gives back; the rest of what it has
# resident is program code it shares
echo "--- processes, own and resident KB"
for d in /proc/[0-9]*; do
	r="$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' $d/status 2> /dev/null)"
	[ -n "$r" ] || continue
	a="$(sed -n 's/^RssAnon:[[:space:]]*\([0-9]*\).*/\1/p' $d/status)"
	echo "$a $r $(tr '\0' ' ' < $d/cmdline | cut -c1-60)"
done | grep -v -E ' (/etc/rc.d/S99zz_report|sh /usr/libexec/malta-report|sort|sed|cat|sleep|grep|awk|cut|tr)( |$)' | sort -rn
# Fill /tmp, which is memory, with the image's own programs, about as compressible as what a
# process would swap out, a megabyte at a time until 2 MB went to zram or less than 1 MB is
# left
kb() { sed -n "s/^$1: *\([0-9]*\) kB$/\1/p" /proc/meminfo; }
: > /tmp/pressure
n=0
while [ $n -lt 30 ]; do
	cat /usr/sbin/hostapd /lib/libc.so >> /tmp/pressure
	[ $(($(kb SwapTotal) - $(kb SwapFree))) -ge 2048 ] && break
	[ "$(kb MemAvailable)" -lt 1024 ] && break
	n=$((n + 1))
done
echo "--- pressure: $(($(wc -c < /tmp/pressure) / 1024)) KB written"
echo "--- pressure MemAvailable: $(kb MemAvailable) kB"
echo "--- pressure swapped: $(($(kb SwapTotal) - $(kb SwapFree))) kB"
for s in dropbear log network sysntpd; do
	/etc/init.d/$s running || echo "--- pressure stopped $s"
done
rm -f /tmp/pressure
echo "--- log"
logread
EOF
malta_report "${WORK}" 60

echo "Booting on QEMU's Malta board with 32 MB; the report comes after about two minutes"
if ! malta_boot "${WORK}" "${LOG}" 32M; then
	echo "--- no report; the end of the console:"
	tr -d '\r' < "${LOG}" | tail -n 30
	echo "MALTA BOOT FAIL: no-report"
	tr -d '\r' < "${LOG}" | grep -q -i 'out of memory' && echo "(the kernel ran out of memory)"
	exit 1
fi

kb() { echo "${REPORT}" | sed -n "s/^$1: *\([0-9]*\) kB$/\1/p"; }
f=""
LEFT="$(echo "${REPORT}" | sed -n 's/^--- left: //p')"
[ -z "${LEFT}" ] || f="${f} first-boot-scripts-left:${LEFT}"
for s in $(echo "${REPORT}" | sed -n 's/^--- service \(.*\) stopped$/\1/p'); do
	f="${f} ${s}-not-running"
done
echo "${REPORT}" | grep -q '^/dev/zram0 ' || f="${f} no-zram"
# Crypto modules nothing on the image uses, which it leaves on the flash (files/etc/modules.d)
for m in $(echo "${REPORT}" | sed -n 's/^--- modules: //p'); do
	case " cmac crypto_acompress drbg geniv hmac jitterentropy_rng lzo lzo_rle rng seqiv sha3_generic sha512_generic " in
		*" ${m} "*) f="${f} module-${m}-loaded" ;;
	esac
done
# A script that calls a command the image left out
MISSING="$(echo "${REPORT}" | sed -n '/^--- log$/,$p' | grep -E ': not found$|applet not found')"
MODULES="$(echo "${REPORT}" | sed -n '/^--- log$/,$p' | grep -E 'kmodloader: .*(fail|missing|could not)')"
# Filling memory has to go to zram, without the kernel ending anything
OOM="$(tr -d '\r' < "${LOG}" | grep -i -E 'out of memory|invoked oom-killer' | sort -u)"
[ -z "${OOM}" ] || f="${f} out-of-memory"
for s in $(echo "${REPORT}" | sed -n 's/^--- pressure stopped //p'); do
	f="${f} ${s}-stopped-under-pressure"
done
[ "$(echo "${REPORT}" | sed -n 's/^--- pressure swapped: \([0-9]*\) kB$/\1/p')" -gt 0 ] ||
	f="${f} nothing-swapped-under-pressure"
[ -z "${MISSING}" ] || f="${f} missing-commands"

# The kernel's own size counts outside MemTotal, so the device's smaller kernel leaves that
# much more. The modules are the same, and loaded on both.
static() { "${SIZE}" "$@" | awk 'NR > 1 { s += $1 + $2 + $3 } END { print int(s / 1024) }'; }
MALTA_KERNEL="$(static "${KERNEL}")"
DEVICE_KERNEL="$(static "${LINUX}/vmlinux")"
AVAILABLE="$(kb MemAvailable)"
echo "--- memory on Malta, KB"
echo "${REPORT}" | sed -n '/^--- meminfo$/,/^--- processes/p' | sed '1d;$d'
echo "--- largest processes, own and resident KB"
echo "${REPORT}" | sed -n '/^--- processes/,/^--- pressure/p' | sed '1d;$d' | head -n 14
echo "$(echo "${REPORT}" | sed -n 's/^--- modules loaded: //p') kernel modules loaded: $(echo "${REPORT}" | sed -n 's/^--- modules: //p')"
echo "--- kernels, KB: Malta ${MALTA_KERNEL}, the device ${DEVICE_KERNEL}"
echo "Available on the device, estimated: $((AVAILABLE + MALTA_KERNEL - DEVICE_KERNEL)) KB"
echo "--- under pressure: $(echo "${REPORT}" | sed -n 's/^--- pressure: //p') to /tmp"
echo "${REPORT}" | sed -n 's/^--- pressure \(MemAvailable\|swapped\): *\([0-9]*\) kB$/\1: \2 kB/p'
[ -z "${OOM}" ] || { echo "--- the kernel ran out of memory:"; echo "${OOM}"; }
[ -z "${MODULES}" ] || { echo "--- kmodloader, with Malta's kernel and its modules:"; echo "${MODULES}"; }
[ -z "${MISSING}" ] || { echo "--- missing commands:"; echo "${MISSING}"; }
if [ -z "$f" ]; then echo "MALTA BOOT PASS"; else echo "MALTA BOOT FAIL:$f"; exit 1; fi
