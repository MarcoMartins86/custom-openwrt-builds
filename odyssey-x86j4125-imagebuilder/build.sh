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
[ -f "${HERE}/private/.env" ] && . "${HERE}/private/.env"

# What the first-boot scripts get to know. Anything else in the two files stays
# on this side of the build.
SETTINGS="ROUTER_NAME LAN_ADDRESS TIMEZONE WAN_DNS_CLIENTS WIFI_SSID VPN_PORT VPN_ADDRESS
	ADBLOCK_FEEDS ADBLOCK_UTC_CATEGORIES ADBLOCK_MAP BANIP_FEEDS GUEST_SHARE
	HOME_ASSISTANT ZIGBEE_DEVICE LUCI_THEME"
for name in ROUTER_NAME LAN_ADDRESS TIMEZONE WIFI_SSID VPN_PORT VPN_ADDRESS LUCI_THEME; do
	eval "value=\${${name}}"
	[ -n "${value}" ] || { echo "${name} is empty; set it in .env or private/.env" >&2; exit 1; }
done
# Dynamic DNS is all or nothing
if [ -n "${DDNS_PROVIDER}${DDNS_HOST}${DDNS_TOKEN}" ]; then
	for name in DDNS_PROVIDER DDNS_HOST DDNS_TOKEN; do
		eval "value=\${${name}}"
		[ -n "${value}" ] || { echo "${name} is missing; dynamic DNS needs DDNS_PROVIDER, DDNS_HOST and DDNS_TOKEN in private/.env" >&2; exit 1; }
	done
fi

# Prints the named settings in a form the shell can read back
write_env() {
	for name in "$@"; do
		eval "value=\${${name}}"
		printf "%s='%s'\n" "${name}" "$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")"
	done
}

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

# The settings travel in the image as /etc/build.env, which the first-boot scripts read
write_env ${SETTINGS} > "${FILES}/etc/build.env"
# The dynamic DNS settings are private and only stay there until the first boot
if [ -n "${DDNS_PROVIDER}" ]; then
	write_env DDNS_PROVIDER DDNS_HOST DDNS_USER DDNS_TOKEN > "${FILES}/etc/ddns.env"
	chmod 600 "${FILES}/etc/ddns.env"
fi

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
