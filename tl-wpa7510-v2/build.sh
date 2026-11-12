#!/bin/sh

# Builds the firmware image from the source of OpenWrt with the port for this device.
# https://openwrt.org/docs/guide-developer/toolchain/use-buildsystem
#
# Meant to run inside OpenWrt's SDK container (see docker-compose.yml), which brings every
# tool the build needs, with this directory mounted at /work. It runs the same on a Linux
# machine set up for building OpenWrt:
# https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem
#
# The source is kept in openwrt/ next to this script and the downloads in dl/, so that
# the next build only redoes what changed. Neither is in the repo.
#
# Settings, from the environment:
#   JOBS          how many jobs to run at once; one per processor core by default
#   AUTOREMOVE=1  delete each package's build files once it is built, for a machine
#                 short of disk space. A full build needs about 10 GB without it.
#   NO_TRIM=1     keep all the kernel's exports: for when a module needs one ksyms-keep.txt
#                 does not list, which stops the build. ksyms.sh then lists them anew.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/.env"
[ -f "${HERE}/private/.env" ] && . "${HERE}/private/.env"

# What the first-boot scripts get to know. Anything else in the two files stays on this
# side of the build.
SETTINGS="AP_NAME LAN_ADDRESS GATEWAY TIMEZONE TIMEZONE_RULE WIFI_SSID WIFI_COUNTRY
	WIFI_CHANNEL_2G WIFI_CHANNEL_5G WIFI_HTMODE_5G"
for name in OPENWRT_GIT OPENWRT_BRANCH OPENWRT_COMMIT ${SETTINGS}; do
	eval "value=\${${name}}"
	[ -n "${value}" ] || { echo "${name} is empty; set it in .env or private/.env" >&2; exit 1; }
done
case "${WIFI_CHANNEL_2G}" in
	auto|[1-9]|1[0-3]) ;;
	*) echo "WIFI_CHANNEL_2G has to be 1 to 13, or auto" >&2; exit 1 ;;
esac
case "${WIFI_CHANNEL_5G}" in
	auto|36|40|44|48|52|56|60|64|100|104|108|112|116|120|124|128|132|136|140) ;;
	*) echo "WIFI_CHANNEL_5G has to be one of 36 to 64 or 100 to 140, or auto" >&2; exit 1 ;;
esac
case "${WIFI_HTMODE_5G}" in
	VHT20|VHT40|VHT80) ;;
	*) echo "WIFI_HTMODE_5G has to be VHT20, VHT40 or VHT80" >&2; exit 1 ;;
esac
if [ -n "${WIFI_KEY}" ]; then
	[ "${#WIFI_KEY}" -ge 8 ] && [ "${#WIFI_KEY}" -le 63 ] ||
		{ echo "WIFI_KEY has to be 8 to 63 characters" >&2; exit 1; }
else
	echo "No WIFI_KEY in private/.env: the image comes with Wi-Fi switched off"
fi

# Prints the named settings in a form the shell can read back
write_env() {
	for name in "$@"; do
		eval "value=\${${name}}"
		printf "%s='%s'\n" "${name}" "$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")"
	done
}

# Prints the lines of an OpenWrt or kernel configuration ($1) that did not make it into
# the configuration that came out ($2)
config_missing() {
	grep -E '^(CONFIG_|# CONFIG_[^ ]+ is not set$)' "$1" | while read -r line; do
		case "${line}" in
			"# "*)
				name="${line#\# }"
				name="${name%% *}"
				if grep -q "^${name}=" "$2"; then echo "${line}"; fi
				;;
			*) grep -qxF "${line}" "$2" || echo "${line}" ;;
		esac
	done
}

# The build system breaks on PATH entries with spaces, which WSL inherits from Windows
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
JOBS="${JOBS:-$(nproc)}"

# The source at the pinned commit of the port's branch. A checkout from an earlier build is
# moved there, which also undoes the changes below, and keeps what it built. The clone has
# the history, which OpenWrt numbers its version and some packages by, but only the files
# of the commits checked out.
SRC="${HERE}/openwrt"
if [ -d "${SRC}/.git" ]; then
	git -C "${SRC}" cat-file -e "${OPENWRT_COMMIT}^{commit}" 2> /dev/null ||
		git -C "${SRC}" fetch origin "${OPENWRT_BRANCH}"
else
	git clone --filter=blob:none --branch "${OPENWRT_BRANCH}" "${OPENWRT_GIT}" "${SRC}"
fi
git -C "${SRC}" -c advice.detachedHead=false checkout -f "${OPENWRT_COMMIT}"
for patch in "${HERE}"/patches/*.patch; do
	git -C "${SRC}" apply "${patch}"
done
# The kernel options, with the path of the exports to keep, which depends on where this
# directory is
KERNEL_CONFIG="$(mktemp)"
if [ "${NO_TRIM}" = 1 ]; then
	sed 's/^CONFIG_TRIM_UNUSED_KSYMS=y$/# CONFIG_TRIM_UNUSED_KSYMS is not set/' "${HERE}/kernel.config" > "${KERNEL_CONFIG}"
else
	cat "${HERE}/kernel.config" > "${KERNEL_CONFIG}"
	echo "CONFIG_UNUSED_KSYMS_WHITELIST=\"${HERE}/ksyms-keep.txt\"" >> "${KERNEL_CONFIG}"
fi
KERNEL_VERSION="$(sed -n 's/^KERNEL_PATCHVER:=//p' "${SRC}/target/linux/ramips/Makefile")"
cat "${KERNEL_CONFIG}" >> "${SRC}/target/linux/ramips/mt7620/config-${KERNEL_VERSION}"
# Fixes for the kernel join OpenWrt's own pending kernel patches. The copies from an earlier
# build are the only files there that are not OpenWrt's, and go first.
PENDING="${SRC}/target/linux/generic/pending-${KERNEL_VERSION}"
git -C "${SRC}" clean -fq -- "${PENDING}"
cp "${HERE}"/kernel-patches/*.patch "${PENDING}/"

# Every package comes from OpenWrt's own tree, so the package feeds are left out
mkdir -p "${HERE}/dl"
[ -L "${SRC}/dl" ] || ln -s ../dl "${SRC}/dl"
cd "${SRC}"

cp "${HERE}/openwrt.config" .config
[ "${AUTOREMOVE}" = 1 ] && echo "CONFIG_AUTOREMOVE=y" >> .config
make defconfig > /dev/null
MISSING="$(config_missing "${HERE}/openwrt.config" .config)"
[ -z "${MISSING}" ] || { printf "make defconfig left out of openwrt.config:\n%s\n" "${MISSING}" >&2; exit 1; }

make -j"${JOBS}" download

# The extender's SSH host key, made once and kept in private/, so that it stays the same
# from one image to the next and flash.sh can check the extender by it after a flash.
# Dropbear only reads its own format, so its key tool is built for this machine from the
# source just downloaded. Its public half goes to private/known_hosts.
HOSTKEY="${HERE}/private/files/etc/dropbear/dropbear_ed25519_host_key"
if [ ! -s "${HOSTKEY}" ]; then
	echo "Making the extender's SSH host key"
	TOOL="$(mktemp -d)"
	tar -xjf "$(ls dl/dropbear-*.tar.bz2 | tail -n 1)" -C "${TOOL}" --strip-components=1
	(cd "${TOOL}" && ./configure --disable-zlib --disable-syslog > /dev/null && make -s dropbearkey > /dev/null)
	mkdir -p "$(dirname "${HOSTKEY}")"
	(umask 077; "${TOOL}/dropbearkey" -t ed25519 -f "${HOSTKEY}" > /dev/null)
	echo "${LAN_ADDRESS%/*} $("${TOOL}/dropbearkey" -y -f "${HOSTKEY}" | grep '^ssh-ed25519' | cut -d' ' -f1-2)" \
		>> "${HERE}/private/known_hosts"
	rm -rf "${TOOL}"
fi

# files/ is public. private/files/ is not in the repo and holds what should stay out of
# it: the SSH keys allowed to log in, and the host key.
rm -rf files
cp -a "${HERE}/files" files
[ -d "${HERE}/private/files" ] && cp -a "${HERE}/private/files/." files/
# git does not keep the modes dropbear insists on
chmod 700 files/etc/dropbear
chmod 600 files/etc/dropbear/*
# The settings travel in the image as /etc/build.env, which the first-boot scripts read.
# The Wi-Fi password goes apart and only stays until the boot has used it, but the image
# itself keeps it, as it does the host key: do not hand the image out.
write_env ${SETTINGS} > files/etc/build.env
if [ -n "${WIFI_KEY}" ]; then
	(umask 077; write_env WIFI_KEY > files/etc/wifi.env)
fi

# An image left from an earlier build would hide that this one came out too big
OUT=bin/targets/ramips/mt7620
NAME=openwrt-ramips-mt7620-tplink_tl-wpa7510-v2
rm -f "${OUT}/${NAME}"*

make -j"${JOBS}" || {
	echo "The build failed. Once more on one core, showing every command, to find the error:" >&2
	make -j1 V=s
}

KCONFIG="$(ls build_dir/target-*/linux-ramips_mt7620/linux-*/.config)"
MISSING="$(config_missing "${HERE}/kernel.config" "${KCONFIG}")"
[ -z "${MISSING}" ] || { printf "The kernel left out of kernel.config:\n%s\n" "${MISSING}" >&2; exit 1; }

# Kernel and root file system share the 5,952 KB firmware partition; OpenWrt makes no image
# when they do not fit, and what they leave holds the settings
KERNEL="$(stat -c %s build_dir/target-*/linux-ramips_mt7620/tplink_tl-wpa7510-v2-kernel.bin)"
ROOTFS="$(stat -c %s build_dir/target-*/linux-ramips_mt7620/root.squashfs)"
LIMIT=$((5952 * 1024))
echo "Kernel ${KERNEL} bytes, root file system ${ROOTFS}: $((KERNEL + ROOTFS)) of ${LIMIT}"
if [ ! -f "${OUT}/${NAME}-squashfs-sysupgrade.bin" ]; then
	echo "No image: kernel and root file system are $((KERNEL + ROOTFS - LIMIT)) bytes too big" >&2
	exit 1
fi
echo "$(((LIMIT - KERNEL - ROOTFS) / 1024)) KB left for the settings"

# The images keep OpenWrt's names: TP-Link's web page drops an upload whose file name has
# 69 characters or more, and OpenWrt's factory image name has 63. OpenWrt's revision, which
# the extender reports once flashed, goes into a file of its own.
REVISION="$(cat "${OUT}/version.buildinfo")"
mkdir -p "${HERE}/binaries"
rm -f "${HERE}/binaries/openwrt-"*
cp "${OUT}/${NAME}"* "${HERE}/binaries/"
echo "${REVISION}" > "${HERE}/binaries/revision"

# The image that boots from memory, in the form kexec starts it on the running extender
# (try.sh): the kernel as the boot loader leaves it unpacked in memory, with the device tree
# right after it, where the kernel looks for it, in an ELF file that loads both at the
# kernel's address and starts the kernel at its entry point
KDIR="$(ls -d build_dir/target-*/linux-ramips_mt7620)"
TOOLS="$(cd staging_dir/toolchain-*/bin && pwd)"
symbol() {
	"${TOOLS}"/*-openwrt-linux-nm "${KDIR}/vmlinux-initramfs.debug" | awk -v s="$1" '$3 == s { print $1 }'
}
TEXT="$(symbol _text)"
ENTRY="$(symbol kernel_entry)"
DTB_AT="$(symbol __appended_dtb)"
if [ $((0x${TEXT} + $(stat -c %s "${KDIR}/vmlinux-initramfs"))) -ne $((0x${DTB_AT})) ]; then
	echo "The kernel does not end where it looks for its device tree; no image for kexec" >&2
	exit 1
fi
KEXEC_TMP="$(mktemp -d)"
cat "${KDIR}/vmlinux-initramfs" "${KDIR}"/image-*.dtb > "${KEXEC_TMP}/kernel.bin"
cat > "${KEXEC_TMP}/kernel.ld" << EOF
OUTPUT_FORMAT("elf32-tradlittlemips")
OUTPUT_ARCH(mips)
PHDRS { image PT_LOAD FLAGS(7); }
SECTIONS
{
	. = 0x${TEXT};
	.image : { *(.data) } :image
	/DISCARD/ : { *(*) }
}
EOF
(cd "${KEXEC_TMP}" && "${TOOLS}"/*-openwrt-linux-ld -T kernel.ld -b binary kernel.bin \
	-e "0x${ENTRY}" -o "${HERE}/binaries/${NAME}-initramfs-kexec.elf")
rm -rf "${KEXEC_TMP}"

cd "${HERE}/binaries"
sha256sum "${NAME}"*.bin "${NAME}"*.elf > sha256sums
echo "OpenWrt ${REVISION}"
ls -l "${NAME}"*
