#!/bin/sh

# Flashes the built image to the access point and waits for it to come back at its
# address in LAN_ADDRESS.
#
# The first time, from ASUS's firmware (--stock): through its web page's firmware upgrade,
# with the cable from this machine in its Ethernet port and this machine at an address on
# 192.168.1.0/24. Afterwards the access point has its address on the main router's
# network, so its cable goes there instead.
#
# Then, from OpenWrt: over SSH with sysupgrade. The image is stateless, so nothing is kept:
# every setting comes with it, the SSH host key too, which private/known_hosts holds.
# https://openwrt.org/docs/guide-user/installation/generic.sysupgrade
#
# usage: flash.sh [-y] [--stock] [image.trx]
#   -y        do not ask before flashing
#   --stock   flash from ASUS's firmware
# Settings, from private/.env or, taking precedence, from the environment:
#   ROUTER (the address the access point has now; the one in LAN_ADDRESS by default),
#   KEY (an SSH private key), STOCK (192.168.1.1), STOCK_USER and STOCK_PASSWORD (admin)

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
given_ROUTER="${ROUTER}" given_KEY="${KEY}" given_STOCK="${STOCK}"
given_STOCK_USER="${STOCK_USER}" given_STOCK_PASSWORD="${STOCK_PASSWORD}"
. "${HERE}/.env"
[ -f "${HERE}/private/.env" ] && . "${HERE}/private/.env"

NEW="${LAN_ADDRESS%/*}"
ROUTER="${given_ROUTER:-${ROUTER:-${NEW}}}"
KEY="${given_KEY:-${KEY}}"
STOCK="${given_STOCK:-${STOCK:-192.168.1.1}}"
STOCK_USER="${given_STOCK_USER:-${STOCK_USER:-admin}}"
STOCK_PASSWORD="${given_STOCK_PASSWORD:-${STOCK_PASSWORD:-admin}}"
KNOWN_HOSTS="${HERE}/private/known_hosts"

YES=""
FROM_STOCK=""
while [ $# -gt 0 ]; do
	case "$1" in
		-y) YES=1 ;;
		--stock) FROM_STOCK=1 ;;
		*) break ;;
	esac
	shift
done
IMAGE="${1:-${HERE}/binaries/openwrt-${OPENWRT_VERSION}-bcm47xx-legacy-asus_wl-320ge-squashfs.trx}"
[ -f "${IMAGE}" ] || { echo "no image found; build one first or name it" >&2; exit 1; }
[ -s "${KNOWN_HOSTS}" ] || { echo "no private/known_hosts; build.sh writes it with the host key" >&2; exit 1; }

# Runs a command on the access point at ${HOST}, which has to show the host key the build
# gave it
router() {
	# A generous keepalive: the 200 MHz CPU takes tens of seconds to checksum or validate
	# a 3.5 MB image, with no data flowing meanwhile, so a short timeout drops the session
	# mid-command. 60 s still ends the call promptly when the device reboots during a flash.
	ssh -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=yes \
		-o UserKnownHostsFile="${KNOWN_HOSTS}" -o HostKeyAlias="${NEW}" \
		-o ServerAliveInterval=10 -o ServerAliveCountMax=6 \
		${KEY:+-i "${KEY}" -o IdentitiesOnly=yes} \
		"root@${HOST}" "$@"
}

ask() {
	[ -n "${YES}" ] && return 0
	printf "%s [y/N] " "$1"
	read -r answer
	[ "${answer}" = "y" ] || { echo "not flashed"; exit 1; }
}

if [ -n "${FROM_STOCK}" ]; then
	# ASUS's web page names the model and the firmware it runs
	PAGE="$(curl -s -m 10 -u "${STOCK_USER}:${STOCK_PASSWORD}" "http://${STOCK}/Advanced_FirmwareUpgrade_Content.asp")" ||
		{ echo "no ASUS web page at ${STOCK}" >&2; exit 1; }
	MODEL="$(echo "${PAGE}" | grep -o 'value="WL[^"]*"' | head -n 1 | cut -d'"' -f2)"
	[ "${MODEL}" = "WL320gE" ] || { echo "${STOCK} is not a WL-320gE running ASUS's firmware (${MODEL:-no model})" >&2; exit 1; }
	ask "Flash $(basename "${IMAGE}") to the WL-320gE at ${STOCK} through its web page?"
	echo "Uploading; ASUS's firmware writes it and restarts, which takes about two minutes"
	REPLY="$(curl -s -m 300 -u "${STOCK_USER}:${STOCK_PASSWORD}" \
		-F current_page=Basic_Operation_Content.asp -F next_page=Basic_SaveRestart.asp \
		-F action_mode= -F preferred_lang= -F "file=@${IMAGE}" "http://${STOCK}/upgrade.cgi" || true)"
	# What the page says back, without its markup and scripts
	echo "ASUS's firmware answers: $(echo "${REPLY}" | sed -e '/<script/,/<\/script>/d' -e 's/<[^>]*>/ /g' | tr -s ' \t\r\n' ' ' | cut -c1-300)"
	echo "Now move the access point's cable to the main router's network (the access point"
	echo "is at ${NEW} from now on)"
else
	HOST="${ROUTER}"
	# The device has 16 MB of memory and a 6 MB /tmp (in RAM): staging a 3.5 MB image there
	# leaves too little to run sysupgrade and the device thrashes. Instead the image streams
	# straight into the "firmware" partition with mtd, which keeps almost no copy in memory.
	# The settings are stateless, so there is nothing for sysupgrade to preserve. mtd checks
	# the TRX header as it writes, SSH guarantees the bytes arrive intact, and -r reboots.
	router 'command -v mtd >/dev/null && grep -q "\"firmware\"" /proc/mtd' ||
		{ echo "${ROUTER} is not an OpenWrt system with a firmware partition" >&2; exit 1; }
	ask "Flash ${ROUTER} now? Its network will be down for a few minutes."
	echo "Streaming $(basename "${IMAGE}") to ${ROUTER} and rebooting"
	# The connection drops when the write finishes and the device reboots, so a non-zero
	# status here is expected
	router 'mtd -r write - firmware' < "${IMAGE}" || true
fi

# Back once it runs the release and the first-boot scripts are done
echo "Waiting for ${NEW} to come back with OpenWrt ${OPENWRT_VERSION}"
HOST="${NEW}"
start="$(date +%s)"
while [ $(($(date +%s) - start)) -lt 600 ]; do
	sleep 5
	STATE="$(router '. /etc/openwrt_release; echo "${DISTRIB_RELEASE} $(ls /etc/uci-defaults | wc -l)"' 2> /dev/null || true)"
	if [ "${STATE}" = "${OPENWRT_VERSION} 0" ]; then
		echo "Back after $(($(date +%s) - start)) seconds"
		exit 0
	fi
done
echo "${NEW} is not back after 10 minutes" >&2
exit 1
