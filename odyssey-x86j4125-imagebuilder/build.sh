#!/bin/sh

# Builds the firmware image with OpenWrt's ImageBuilder.
# https://openwrt.org/docs/guide-user/additional-software/imagebuilder
#
# Meant to run inside the ImageBuilder container (see docker-compose.yml), where
# this directory is mounted at /work and the ImageBuilder lives in /builder.
# To run it without a container, point IB_DIR at an extracted ImageBuilder of the
# version given in .env.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/.env"

# The build system breaks on PATH entries with spaces, which WSL inherits from Windows
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

cd "${IB_DIR:-/builder}"
# Newer containers ship a script that downloads the ImageBuilder on first use
[ -d ./scripts ] || ./setup.sh

# files/ is public. private/files/ is not in the repo and holds what should stay
# out of it, such as the SSH keys allowed to log in.
FILES="$(mktemp -d)"
trap 'rm -rf "${FILES}"' EXIT
cp -a "${HERE}/files/." "${FILES}/"
[ -d "${HERE}/private/files" ] && cp -a "${HERE}/private/files/." "${FILES}/"
# git does not keep the modes dropbear insists on
if [ -f "${FILES}/etc/dropbear/authorized_keys" ]; then
	chmod 700 "${FILES}/etc/dropbear"
	chmod 600 "${FILES}/etc/dropbear/authorized_keys"
fi
# git clients on Windows drop the executable bit, which these need
for d in etc/init.d usr/libexec; do
	[ -d "${FILES}/${d}" ] && chmod 755 "${FILES}/${d}"/*
done
# holds the dynamic DNS token until the first boot
[ -f "${FILES}/etc/ddns.env" ] && chmod 600 "${FILES}/etc/ddns.env"

# Packages from outside OpenWrt's feeds go into the folder the ImageBuilder
# indexes by itself. The ones fetched last time are cleared first, so a changed
# version does not leave the old file behind.
[ -f packages/.extra ] && xargs -r rm -f < packages/.extra
: > packages/.extra
sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "${HERE}/extra-packages.txt" | while read -r sum url; do
	file="packages/$(basename "${url}")"
	wget -q -O "${file}" "${url}"
	echo "${file}" >> packages/.extra
	echo "${sum}  ${file}" | sha256sum -c -
done

PACKAGES="$(sed -e 's/#.*//' "${HERE}/packages.txt" | xargs)"

make image \
	PROFILE="${PROFILE}" \
	PACKAGES="${PACKAGES}" \
	FILES="${FILES}" \
	ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE}" \
	BIN_DIR="${HERE}/binaries"
