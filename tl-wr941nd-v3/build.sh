#!/bin/sh

# Builds the firmware image from OpenWrt's source.
# https://openwrt.org/docs/guide-developer/toolchain/use-buildsystem
#
# Meant to run inside OpenWrt's SDK container for the release (see docker-compose.yml),
# which brings every tool the build needs, with this directory mounted at /work. It runs
# the same on a Linux machine set up for building OpenWrt:
# https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem
#
# The source is kept in openwrt/ next to this script and the downloads in dl/, so that
# the next build only redoes what changed. Neither is in the repo.
#
# Settings, from the environment:
#   JOBS          how many jobs to run at once; one per processor core by default
#   AUTOREMOVE=1  delete each package's build files once it is built, for a machine
#                 short of disk space. A full build needs about 10 GB without it.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/.env"
[ -f "${HERE}/private/.env" ] && . "${HERE}/private/.env"

# What the first-boot scripts get to know. Anything else in the two files stays on this
# side of the build.
SETTINGS="AP_NAME LAN_ADDRESS GATEWAY TIMEZONE TIMEZONE_RULE WIFI_SSID WIFI_COUNTRY WIFI_CHANNEL"
for name in OPENWRT_VERSION OPENWRT_GIT ${SETTINGS}; do
	eval "value=\${${name}}"
	[ -n "${value}" ] || { echo "${name} is empty; set it in .env or private/.env" >&2; exit 1; }
done
case "${WIFI_CHANNEL}" in
	auto|[1-9]|1[0-3]) ;;
	*) echo "WIFI_CHANNEL has to be 1 to 13, or auto" >&2; exit 1 ;;
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

# The source at the release's tag. A checkout from an earlier build is moved there, which
# also undoes the changes below, and keeps what it built. The clone has the history, which
# OpenWrt numbers some packages by, but only the files of the commits checked out.
SRC="${HERE}/openwrt"
TAG="v${OPENWRT_VERSION}"
if [ -d "${SRC}/.git" ]; then
	git -C "${SRC}" rev-parse -q --verify "refs/tags/${TAG}" > /dev/null ||
		git -C "${SRC}" fetch origin tag "${TAG}"
	git -C "${SRC}" -c advice.detachedHead=false checkout -f "${TAG}"
else
	git -c advice.detachedHead=false clone --filter=blob:none --branch "${TAG}" "${OPENWRT_GIT}" "${SRC}"
fi
for patch in "${HERE}"/patches/*.patch; do
	git -C "${SRC}" apply "${patch}"
done
cat "${HERE}/kernel.config" >> "${SRC}/target/linux/ath79/tiny/config-default"
# Fixes for the kernel join OpenWrt's own pending kernel patches. The copies from an earlier
# build are the only files there that are not OpenWrt's, and go first.
PENDING="${SRC}/target/linux/generic/pending-$(sed -n 's/^KERNEL_PATCHVER:=//p' "${SRC}/target/linux/ath79/Makefile")"
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

# files/ is public. private/files/ is not in the repo and holds what should stay out of
# it, such as the SSH keys allowed to log in.
rm -rf files
cp -a "${HERE}/files" files
[ -d "${HERE}/private/files" ] && cp -a "${HERE}/private/files/." files/
# git does not keep the modes dropbear insists on
if [ -f files/etc/dropbear/authorized_keys ]; then
	chmod 700 files/etc/dropbear
	chmod 600 files/etc/dropbear/authorized_keys
fi
# The settings travel in the image as /etc/build.env, which the first-boot scripts read.
# The Wi-Fi password goes apart and only stays until the first boot has used it, but the
# image itself keeps it: do not hand the image out.
write_env ${SETTINGS} > files/etc/build.env
if [ -n "${WIFI_KEY}" ]; then
	(umask 077; write_env WIFI_KEY > files/etc/wifi.env)
fi

# An image left from an earlier build would hide that this one came out too big
OUT=bin/targets/ath79/tiny
NAME=openwrt-ath79-tiny-tplink_tl-wr941-v2
rm -f "${OUT}/${NAME}"*

make -j"${JOBS}" download
make -j"${JOBS}" || {
	echo "The build failed. Once more on one core, showing every command, to find the error:" >&2
	make -j1 V=s
}

KCONFIG="$(ls build_dir/target-*/linux-ath79_tiny/linux-*/.config)"
MISSING="$(config_missing "${HERE}/kernel.config" "${KCONFIG}")"
[ -z "${MISSING}" ] || { printf "The kernel left out of kernel.config:\n%s\n" "${MISSING}" >&2; exit 1; }

# The TP-Link image tool keeps 256 KB of the 3,840 KB it allows for the settings, and
# makes no image when kernel and root file system do not fit the rest
KERNEL="$(stat -c %s build_dir/target-*/linux-ath79_tiny/tplink_tl-wr941-v2-kernel.bin)"
ROOTFS="$(stat -c %s build_dir/target-*/linux-ath79_tiny/root.squashfs)"
LIMIT=$((0x3c0000 - 0x40000 - 512))
echo "Kernel ${KERNEL} bytes, root file system ${ROOTFS}: $((KERNEL + ROOTFS)) of ${LIMIT}"
if [ ! -f "${OUT}/${NAME}-squashfs-sysupgrade.bin" ]; then
	echo "No image: kernel and root file system are $((KERNEL + ROOTFS - LIMIT)) bytes too big" >&2
	exit 1
fi
# The settings get what the image leaves of the firmware partition
SIZE="$(stat -c %s "${OUT}/${NAME}-squashfs-sysupgrade.bin")"
echo "$(((LIMIT - KERNEL - ROOTFS) / 1024)) KB to spare, $(((0x3d0000 - SIZE) / 1024)) KB of flash left for the settings"

mkdir -p "${HERE}/binaries"
for file in "${OUT}/${NAME}"*; do
	cp "${file}" "${HERE}/binaries/openwrt-${OPENWRT_VERSION}-${file##*/openwrt-}"
done
cd "${HERE}/binaries"
sha256sum "openwrt-${OPENWRT_VERSION}-"*.bin > sha256sums
ls -l "openwrt-${OPENWRT_VERSION}-"*
