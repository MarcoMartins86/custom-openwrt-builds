# Shared by the tests that boot on QEMU's MIPS Malta board, which source it with Q set to
# their folder: the build's files, OpenWrt's Malta kernel and packages for the release, and
# the steps from the image's root file system to a VM's report.
. "$Q/../.env"
[ -f "$Q/../private/.env" ] && . "$Q/../private/.env"
SRC="$Q/../openwrt"
ROOT="$(ls -d "${SRC}"/build_dir/target-*/root-ath79 2> /dev/null)"
LINUX="$(ls -d "${SRC}"/build_dir/target-*/linux-ath79_tiny/linux-* 2> /dev/null)"
SIZE="$(ls "${SRC}"/staging_dir/toolchain-*/bin/*-size 2> /dev/null | head -n 1)"
HOST="${SRC}/staging_dir/host/bin"
[ -f "${ROOT}/etc/build.env" ] && [ -f "${LINUX}/vmlinux" ] && [ -x "${SIZE}" ] && [ -x "${HOST}/apk" ] ||
	{ echo "no image files in openwrt/build_dir; run build.sh first" >&2; exit 1; }

# OpenWrt's Malta kernel and packages for the release, kept in dl/ and only used here
RELEASE="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}"
URL="${RELEASE}/targets/malta/be"
DL="$Q/../dl/malta-${OPENWRT_VERSION}"
KERNEL="${DL}/openwrt-${OPENWRT_VERSION}-malta-be-vmlinux.elf"
mkdir -p "${DL}"

# Downloads a file of the release's Malta target, checked against the release's checksums
malta_file() {
	[ -f "${DL}/$1" ] && return 0
	[ -s "${DL}/sha256sums" ] || wget -q -O "${DL}/sha256sums" "${URL}/sha256sums" || return 1
	wget -q -O "${DL}/$1.new" "${URL}/$1" &&
		[ "$(sha256sum < "${DL}/$1.new" | cut -d' ' -f1)" = "$(sed -n "s/ \*$1\$//p" "${DL}/sha256sums")" ] &&
		mv "${DL}/$1.new" "${DL}/$1" ||
		{ echo "$1 did not download or does not match its checksum" >&2; rm -f "${DL}/$1.new"; return 1; }
}

# The image's kernel module packages
malta_kmods() {
	ls "${ROOT}"/lib/apk/packages/kmod-*.list | sed 's/.*\/\(kmod-.*\)\.list$/\1/'
}

# Downloads packages by name to dl/<name>.apk: kernel modules from the Malta kernel's own
# folder, the rest from the release's packages for the image's processor
malta_packages() {
	local pkg url list file kmods="" kmods_list="" base_list=""
	for pkg in "$@"; do
		[ -f "${DL}/${pkg}.apk" ] && continue
		case "${pkg}" in
			kmod-*)
				if [ -z "${kmods}" ]; then
					kmods="${URL}/kmods/$(wget -q -O - "${URL}/kmods/" | sed -n 's/.*href="\([0-9][^"]*\)\/".*/\1/p' | head -n 1)"
					kmods_list="$(wget -q -O - "${kmods}/")"
				fi
				url="${kmods}"
				list="${kmods_list}"
				;;
			*)
				url="${RELEASE}/packages/mips_24kc/base"
				[ -n "${base_list}" ] || base_list="$(wget -q -O - "${url}/")"
				list="${base_list}"
				;;
		esac
		file="$(echo "${list}" | sed -n "s/.*href=\"\(${pkg}-[0-9][^\"]*\.apk\)\".*/\1/p" | head -n 1)"
		[ -n "${file}" ] && wget -q -O "${DL}/${pkg}.apk" "${url}/${file}" ||
			{ echo "${pkg} did not download" >&2; rm -f "${DL}/${pkg}.apk"; return 1; }
	done
}

# The image's root file system in $1/root, with the Malta kernel's builds of its kernel
# modules in place of the device's, and the packages given after $1 added. Which modules
# load at boot stays the image's choice.
malta_root() {
	local work="$1" pkg
	shift
	cp -a "${ROOT}" "${work}/root"
	rm -f "${work}/root"/lib/modules/*/*.ko
	for pkg in $(malta_kmods) "$@"; do
		mkdir -p "${work}/pkg/${pkg}"
		"${HOST}/apk" extract --allow-untrusted --destination "${work}/pkg/${pkg}" "${DL}/${pkg}.apk" > /dev/null
		case "${pkg}" in
			kmod-*) cp "${work}/pkg/${pkg}"/lib/modules/*/*.ko "${work}/root"/lib/modules/*/ 2> /dev/null ;;
			*) cp -a "${work}/pkg/${pkg}/usr" "${work}/root/" ;;
		esac
	done
}

# Once the services have settled for $2 seconds, /usr/libexec/malta-report in $1/root
# prints its report to the console, and the VM ends
malta_report() {
	printf '%s\n' \
		'#!/bin/sh /etc/rc.common' \
		'START=99' \
		'start() {' \
		"	( sleep $2" \
		'	  { echo "=== REPORT"; sh /usr/libexec/malta-report; echo "=== END"; } > /dev/console 2>&1' \
		'	  reboot ) &' \
		'}' > "$1/root/etc/init.d/zz_report"
	chmod 755 "$1/root/etc/init.d/zz_report"
	ln -s ../init.d/zz_report "$1/root/etc/rc.d/S99zz_report"
}

# Boots $1/root on the Malta board with $3 of memory, its console in $2, and leaves the
# report in REPORT. Fails when the report did not come to its end.
malta_boot() {
	local work="$1" log="$2" memory="$3"
	# Owned by root, as on the device, with the build's fakeroot and mkfs.ext4
	STAGING_DIR_HOST="${HOST%/bin}" PATH="${HOST}:${PATH}" "${HOST}/fakeroot" -- sh -c \
		'chown -R 0:0 "$1/root" && mkfs.ext4 -q -F -L rootfs -d "$1/root" "$1/disk.img" 64M' - "${work}" || return 1
	# No graphics card, and a network card without its boot ROM: the VM uses neither, and
	# QEMU's packages only bring their ROMs as a recommendation
	timeout 600 qemu-system-mips -M malta -cpu 24Kc -m "${memory}" -display none -vga none -monitor none -no-reboot \
		-serial "file:${log}" -kernel "${KERNEL}" -netdev user,id=lan -device pcnet,netdev=lan,romfile= \
		-drive "file=${work}/disk.img,format=raw,if=ide" \
		-append "root=/dev/sda rootfstype=ext4 rootwait console=ttyS0 panic=-1"
	REPORT="$(tr -d '\r' < "${log}" | sed -n '/^=== REPORT$/,/^=== END$/p')"
	echo "${REPORT}" | grep -q '^=== END$'
}
