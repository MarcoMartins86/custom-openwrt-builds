#!/bin/sh

# Flashes the built image to a running router over SSH and waits for it to come back.
#
# The router keeps its identity across the flash: root password, SSH host keys,
# HTTPS certificate, and whatever the first-boot scripts keep under /etc/odyssey.
# Its configuration is not kept; the first-boot scripts regenerate it. The data
# partition is left alone.
# https://openwrt.org/docs/guide-user/installation/generic.sysupgrade
#
# usage: flash.sh [-y] [image.img.gz]
#   -y   do not ask before flashing
# Settings come from the environment or from private/flash.env:
#   ROUTER (192.168.2.1), PORT (22), KEY (an SSH private key), KNOWN_HOSTS (a file)

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/.env"
[ -f "${HERE}/private/flash.env" ] && . "${HERE}/private/flash.env"

ROUTER="${ROUTER:-192.168.2.1}"
PORT="${PORT:-22}"

YES=""
[ "$1" = "-y" ] && { YES=1; shift; }
IMAGE="${1:-$(ls "${HERE}"/binaries/openwrt-*-ext4-combined-efi.img.gz 2>/dev/null | head -1)}"
[ -f "${IMAGE}" ] || { echo "no image found; build one first or name it" >&2; exit 1; }

# Runs a command on the router
router() {
	ssh -p "${PORT}" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
		-o ServerAliveInterval=2 -o ServerAliveCountMax=3 \
		${KEY:+-i "${KEY}" -o IdentitiesOnly=yes} \
		${KNOWN_HOSTS:+-o UserKnownHostsFile="${KNOWN_HOSTS}"} \
		"root@${ROUTER}" "$@"
}

echo "Uploading $(basename "${IMAGE}") to ${ROUTER}"
router 'cat > /tmp/firmware.img.gz' < "${IMAGE}"
LOCAL="$(sha256sum < "${IMAGE}" | cut -d' ' -f1)"
REMOTE="$(router 'sha256sum < /tmp/firmware.img.gz' | cut -d' ' -f1)"
[ "${LOCAL}" = "${REMOTE}" ] || { echo "checksum mismatch after upload" >&2; exit 1; }

echo "Collecting the identity files and checking the image"
router '
mkdir -p /etc/odyssey
grep "^root:" /etc/shadow | cut -d: -f2 > /etc/odyssey/root.hash
chmod 600 /etc/odyssey/root.hash
KEEP=""
for f in etc/odyssey etc/dropbear/dropbear_ed25519_host_key etc/dropbear/dropbear_rsa_host_key \
	etc/uhttpd.crt etc/uhttpd.key etc/wireguard; do
	[ -e "/$f" ] && KEEP="$KEEP $f"
done
tar czf /tmp/identity.tar.gz -C / $KEEP
sysupgrade -T -f /tmp/identity.tar.gz /tmp/firmware.img.gz
'

if [ -z "${YES}" ]; then
	printf "Flash %s now? Its network will be down for a few minutes. [y/N] " "${ROUTER}"
	read -r answer
	[ "${answer}" = "y" ] || { echo "not flashed"; exit 1; }
fi

# The connection drops when the upgrade starts, so a failure here is expected
router 'sysupgrade -v -f /tmp/identity.tar.gz /tmp/firmware.img.gz' || true

python3 "${HERE}/wait-router.py" --release "${OPENWRT_VERSION}" --host "${ROUTER}" --port "${PORT}" \
	${KEY:+--key "${KEY}"} ${KNOWN_HOSTS:+--known-hosts "${KNOWN_HOSTS}"}
