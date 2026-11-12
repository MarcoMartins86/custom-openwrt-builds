#!/bin/sh

# Flashes the built image to the running extender over SSH and waits for it to come back
# at its address in LAN_ADDRESS, running the image's revision.
#
# The settings of the running system are not kept: every setting comes with the image, the
# SSH host key too, which private/known_hosts holds. The running system can also be the
# image that boots from memory, which is how the first flash goes; see the README.
# https://openwrt.org/docs/guide-user/installation/generic.sysupgrade
#
# usage: flash.sh [-y] [image.bin]
#   -y   do not ask before flashing
# Settings, from private/.env or, taking precedence, from the environment:
#   ROUTER (the address the extender has now; the one in LAN_ADDRESS by default),
#   PORT (22), KEY (an SSH private key), KNOWN_HOSTS (a file)

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
given_ROUTER="${ROUTER}" given_PORT="${PORT}" given_KEY="${KEY}" given_KNOWN_HOSTS="${KNOWN_HOSTS}"
. "${HERE}/.env"
[ -f "${HERE}/private/.env" ] && . "${HERE}/private/.env"

NEW="${LAN_ADDRESS%/*}"
ROUTER="${given_ROUTER:-${ROUTER:-${NEW}}}"
PORT="${given_PORT:-${PORT:-22}}"
KEY="${given_KEY:-${KEY}}"
KNOWN_HOSTS="${given_KNOWN_HOSTS:-${KNOWN_HOSTS}}"

YES=""
if [ "$1" = "-y" ]; then
	YES=1
	shift
fi
[ -f "${HERE}/binaries/revision" ] || { echo "no image found; build one first" >&2; exit 1; }
REVISION="$(cat "${HERE}/binaries/revision")"
IMAGE="${1:-${HERE}/binaries/openwrt-ramips-mt7620-tplink_tl-wpa7510-v2-squashfs-sysupgrade.bin}"
[ -f "${IMAGE}" ] || { echo "${IMAGE} not found" >&2; exit 1; }

# Runs a command on the extender at ${HOST}, over the connection in ${MUX} when set
HOST="${ROUTER}"
MUX=""
router() {
	ssh -p "${PORT}" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking="${STRICT:-accept-new}" \
		-o ServerAliveInterval=2 -o ServerAliveCountMax=3 \
		${MUX:+-o ControlPath="${MUX}"} \
		${KEY:+-i "${KEY}" -o IdentitiesOnly=yes} \
		${KNOWN_HOSTS:+-o UserKnownHostsFile="${KNOWN_HOSTS}"} \
		"root@${HOST}" "$@"
}

# Every command up to the flash goes over one connection, opened here
MASTER="$(mktemp -d)/ssh"
# After a flash the connection is gone, and a command failing in here would end the script
# with its status
trap 'ssh -o ControlPath="${MASTER}" -O exit "root@${ROUTER}" > /dev/null 2>&1 || true; rm -rf "${MASTER%/ssh}"' EXIT
ssh -p "${PORT}" -fN -o ControlMaster=yes -o ControlPath="${MASTER}" -o ControlPersist=yes \
	-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
	-o ServerAliveInterval=2 -o ServerAliveCountMax=3 \
	${KEY:+-i "${KEY}" -o IdentitiesOnly=yes} \
	${KNOWN_HOSTS:+-o UserKnownHostsFile="${KNOWN_HOSTS}"} \
	"root@${ROUTER}"
MUX="${MASTER}"

echo "Uploading $(basename "${IMAGE}") to ${ROUTER}"
router 'cat > /tmp/firmware.bin' < "${IMAGE}"
LOCAL="$(sha256sum < "${IMAGE}" | cut -d' ' -f1)"
REMOTE="$(router 'sha256sum < /tmp/firmware.bin' | cut -d' ' -f1)"
[ "${LOCAL}" = "${REMOTE}" ] || { echo "checksum mismatch after upload" >&2; exit 1; }

echo "Checking the image"
router "sysupgrade -T -n /tmp/firmware.bin" ||
	{ echo "the running system does not take the image" >&2; exit 1; }

if [ -z "${YES}" ]; then
	printf "Flash %s now? Its network will be down for a few minutes. [y/N] " "${ROUTER}"
	read -r answer
	[ "${answer}" = "y" ] || { echo "not flashed"; exit 1; }
fi

# The connection drops when the upgrade starts, so a failure here is expected
router "sysupgrade -v -n /tmp/firmware.bin" || true

# Back once it runs the image's revision and the first-boot scripts are done. The image
# takes the key, over connections of its own, and has to show the host key the build gave
# it.
echo "Waiting for ${NEW} to come back with ${REVISION}"
HOST="${NEW}"
MUX=""
KNOWN_HOSTS="${HERE}/private/known_hosts"
STRICT=yes
start="$(date +%s)"
while [ $(($(date +%s) - start)) -lt 420 ]; do
	sleep 5
	STATE="$(router '. /etc/openwrt_release; echo "${DISTRIB_REVISION} $(ls /etc/uci-defaults | wc -l)"' 2> /dev/null || true)"
	if [ "${STATE}" = "${REVISION} 0" ]; then
		echo "Back after $(($(date +%s) - start)) seconds"
		exit 0
	fi
done
echo "${NEW} is not back after 7 minutes" >&2
exit 1
