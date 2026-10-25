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
. "$Q/../.env"
[ -f "$Q/../private/.env" ] && . "$Q/../private/.env"
SRC="$Q/../openwrt"
ROOT="$(ls -d "${SRC}"/build_dir/target-*/root-ath79 2> /dev/null)"
VMLINUX="$(ls "${SRC}"/build_dir/target-*/linux-ath79_tiny/linux-*/vmlinux 2> /dev/null)"
SIZE="$(ls "${SRC}"/staging_dir/toolchain-*/bin/*-size 2> /dev/null | head -n 1)"
HOST="${SRC}/staging_dir/host/bin"
[ -f "${ROOT}/etc/build.env" ] && [ -f "${VMLINUX}" ] && [ -x "${SIZE}" ] && [ -x "${HOST}/apk" ] ||
	{ echo "no image files in openwrt/build_dir; run build.sh first" >&2; exit 1; }

# OpenWrt's Malta kernel for the release, checked against the release's checksums, and its
# builds of the image's kernel modules. They are kept in dl/, and only used here.
URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/malta/be"
DL="$Q/../dl/malta-${OPENWRT_VERSION}"
KERNEL="${DL}/openwrt-${OPENWRT_VERSION}-malta-be-vmlinux.elf"
mkdir -p "${DL}"
if [ ! -f "${KERNEL}" ]; then
	wget -q -O "${DL}/sha256sums" "${URL}/sha256sums" &&
		wget -q -O "${KERNEL}.new" "${URL}/${KERNEL##*/}" &&
		[ "$(sha256sum < "${KERNEL}.new" | cut -d' ' -f1)" = \
			"$(sed -n "s/ \*${KERNEL##*/}\$//p" "${DL}/sha256sums")" ] &&
		mv "${KERNEL}.new" "${KERNEL}" ||
		{ echo "the Malta kernel did not download or does not match its checksum" >&2; rm -f "${KERNEL}.new"; exit 1; }
fi
KMODS="$(ls "${ROOT}"/lib/apk/packages/kmod-*.list | sed 's/.*\/\(kmod-.*\)\.list$/\1/')"
LIST=""
for pkg in ${KMODS}; do
	[ -f "${DL}/${pkg}.apk" ] && continue
	if [ -z "${LIST}" ]; then
		DIR="$(wget -q -O - "${URL}/kmods/" | sed -n 's/.*href="\([0-9][^"]*\)\/".*/\1/p' | head -n 1)"
		LIST="$(wget -q -O - "${URL}/kmods/${DIR}/")"
	fi
	file="$(echo "${LIST}" | sed -n "s/.*href=\"\(${pkg}-[0-9][^\"]*\.apk\)\".*/\1/p" | head -n 1)"
	[ -n "${file}" ] && wget -q -O "${DL}/${pkg}.apk" "${URL}/kmods/${DIR}/${file}" ||
		{ echo "${pkg} for the Malta kernel did not download" >&2; rm -f "${DL}/${pkg}.apk"; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
LOG="$Q/malta-serial.log"

# The image's root file system, with the Malta kernel's modules in place of the device's
cp -a "${ROOT}" "${WORK}/root"
rm -f "${WORK}/root"/lib/modules/*/*.ko "${WORK}/root"/etc/modules.d/* "${WORK}/root"/etc/modules-boot.d/*
for pkg in ${KMODS}; do
	mkdir "${WORK}/${pkg}"
	"${HOST}/apk" extract --allow-untrusted --destination "${WORK}/${pkg}" "${DL}/${pkg}.apk" > /dev/null
	cp "${WORK}/${pkg}"/lib/modules/*/*.ko "${WORK}/root"/lib/modules/*/ 2> /dev/null
	cp "${WORK}/${pkg}"/etc/modules.d/* "${WORK}/root/etc/modules.d/" 2> /dev/null
done
# Once the services have settled, the report goes to the console and the VM ends
cat > "${WORK}/root/etc/init.d/zz_report" << 'EOF'
#!/bin/sh /etc/rc.common
START=99
start() {
	(
		sleep 60
		{
			echo "=== REPORT"
			echo "--- left: $(ls /etc/uci-defaults | xargs)"
			for s in dropbear log network sysntpd; do
				/etc/init.d/$s running && echo "--- service $s running" || echo "--- service $s stopped"
			done
			echo "--- modules loaded: $(lsmod | tail -n +2 | wc -l)"
			echo "--- swaps"
			cat /proc/swaps
			echo "--- meminfo"
			grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Shmem|Slab|SUnreclaim|SwapTotal|SwapFree):' /proc/meminfo
			echo "--- processes, resident KB"
			for d in /proc/[0-9]*; do
				r="$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' $d/status 2> /dev/null)"
				[ -n "$r" ] && echo "$r $(cat $d/comm)"
			done | grep -v -E ' (S99zz_report|sort|sed|cat|sleep|grep)$' | sort -rn
			# Fill /tmp, which is memory, with the image's own programs, about as
			# compressible as what a process would swap out, a megabyte at a time until
			# 2 MB went to zram or less than 1 MB is left
			kb() { sed -n "s/^$1: *\\([0-9]*\\) kB$/\\1/p" /proc/meminfo; }
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
			echo "=== END"
		} > /dev/console 2>&1
		reboot
	) &
}
EOF
chmod 755 "${WORK}/root/etc/init.d/zz_report"
ln -s ../init.d/zz_report "${WORK}/root/etc/rc.d/S99zz_report"
# Owned by root, as on the device, with the build's fakeroot and mkfs.ext4
STAGING_DIR_HOST="${HOST%/bin}" PATH="${HOST}:${PATH}" "${HOST}/fakeroot" -- sh -c \
	'chown -R 0:0 "$1/root" && mkfs.ext4 -q -F -L rootfs -d "$1/root" "$1/disk.img" 64M' - "${WORK}" || exit 1

echo "Booting on QEMU's Malta board with 32 MB; the report comes after about two minutes"
timeout 600 qemu-system-mips -M malta -cpu 24Kc -m 32M -display none -monitor none -no-reboot \
	-serial "file:${LOG}" -kernel "${KERNEL}" -nic user,model=pcnet \
	-drive "file=${WORK}/disk.img,format=raw,if=ide" \
	-append "root=/dev/sda rootfstype=ext4 rootwait console=ttyS0 panic=-1"
REPORT="$(tr -d '\r' < "${LOG}" | sed -n '/^=== REPORT$/,/^=== END$/p')"
if ! echo "${REPORT}" | grep -q '^=== END$'; then
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
DEVICE_KERNEL="$(static "${VMLINUX}")"
AVAILABLE="$(kb MemAvailable)"
echo "--- memory on Malta, KB"
echo "${REPORT}" | sed -n '/^--- meminfo$/,/^--- processes/p' | sed '1d;$d'
echo "--- largest processes, resident KB"
echo "${REPORT}" | sed -n '/^--- processes/,/^--- pressure/p' | sed '1d;$d' | head -n 10
echo "$(echo "${REPORT}" | sed -n 's/^--- modules loaded: //p') kernel modules loaded"
echo "--- kernels, KB: Malta ${MALTA_KERNEL}, the device ${DEVICE_KERNEL}"
echo "Available on the device, estimated: $((AVAILABLE + MALTA_KERNEL - DEVICE_KERNEL)) KB"
echo "--- under pressure: $(echo "${REPORT}" | sed -n 's/^--- pressure: //p') to /tmp"
echo "${REPORT}" | sed -n 's/^--- pressure \(MemAvailable\|swapped\): *\([0-9]*\) kB$/\1: \2 kB/p'
[ -z "${OOM}" ] || { echo "--- the kernel ran out of memory:"; echo "${OOM}"; }
[ -z "${MODULES}" ] || { echo "--- kmodloader, with Malta's kernel and its modules:"; echo "${MODULES}"; }
[ -z "${MISSING}" ] || { echo "--- missing commands:"; echo "${MISSING}"; }
if [ -z "$f" ]; then echo "MALTA BOOT PASS"; else echo "MALTA BOOT FAIL:$f"; exit 1; fi
