#!/bin/sh

# Flashes the built image to a running router over SSH and waits for it to come back.
#
# The router keeps its identity across the flash: root password, SSH host keys,
# HTTPS certificate, the VPN key with the devices allowed to connect, and whatever
# the first-boot scripts keep under /etc/odyssey.
# Its configuration is not kept; the first-boot scripts regenerate it. The data
# partition is left alone. A backup of the whole configuration is saved first, to
# private/backups/ on this machine.
# https://openwrt.org/docs/guide-user/installation/generic.sysupgrade
#
# usage: flash.sh [-y] [image.img.gz]
#   -y   do not ask before flashing
#   the image is the one in binaries/ for OPENWRT_VERSION unless named
# Settings, from private/.env or, taking precedence, from the environment:
#   ROUTER (the address in LAN_ADDRESS), PORT (22), KEY (an SSH private key),
#   KNOWN_HOSTS (a file)

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
given_ROUTER="${ROUTER}" given_PORT="${PORT}" given_KEY="${KEY}" given_KNOWN_HOSTS="${KNOWN_HOSTS}"
. "${HERE}/.env"
[ -f "${HERE}/private/.env" ] && . "${HERE}/private/.env"

ROUTER="${given_ROUTER:-${ROUTER:-${LAN_ADDRESS%/*}}}"
PORT="${given_PORT:-${PORT:-22}}"
KEY="${given_KEY:-${KEY}}"
KNOWN_HOSTS="${given_KNOWN_HOSTS:-${KNOWN_HOSTS}}"

YES=""
[ "$1" = "-y" ] && { YES=1; shift; }
# binaries/ keeps the images of earlier releases too, so pick the one the router is
# then waited for
IMAGE="${1:-$(ls "${HERE}"/binaries/openwrt-"${OPENWRT_VERSION}"-*-ext4-combined-efi.img.gz 2>/dev/null | head -1)}"
[ -f "${IMAGE}" ] || { echo "no ${OPENWRT_VERSION} image found; build one first or name it" >&2; exit 1; }

# Runs a command on the router
router() {
	# A keepalive that survives a slow or busy link: the upload can fill one for long
	# enough that a short timeout drops the session mid-transfer. 60 s still ends the
	# call promptly if the link dies, and the router takes longer than that to reboot.
	ssh -p "${PORT}" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
		-o ServerAliveInterval=10 -o ServerAliveCountMax=6 \
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
# The VPN key and its devices live in the network configuration. Save them where
# the first boot looks for them.
if uci -q get network.wg0.private_key > /dev/null; then
	mkdir -p /etc/wireguard
	chmod 700 /etc/wireguard
	(
		umask 077
		uci -q get network.wg0.private_key > /etc/wireguard/server.key
		uci export network | awk "/^config /{keep=(\$2==\"wireguard_wg0\")} keep" > /etc/wireguard/peers
	)
fi
KEEP=""
for f in etc/odyssey etc/dropbear/dropbear_ed25519_host_key etc/dropbear/dropbear_rsa_host_key \
	etc/uhttpd.crt etc/uhttpd.key etc/wireguard; do
	[ -e "/$f" ] && KEEP="$KEEP $f"
done
tar czf /tmp/identity.tar.gz -C / $KEEP
sysupgrade -T -f /tmp/identity.tar.gz /tmp/firmware.img.gz
'

# The whole configuration as the router has it now, in the format LuCI's backup uses,
# in case the old image has to come back with it. The last five per router are kept.
BACKUPS="${HERE}/private/backups"
BACKUP="${BACKUPS}/${ROUTER}-$(date +%Y%m%d-%H%M%S).tar.gz"
(
	umask 077
	mkdir -p "${BACKUPS}"
	router 'sysupgrade -b -' > "${BACKUP}"
)
tar tzf "${BACKUP}" > /dev/null 2>&1 || { echo "the backup did not come through" >&2; rm -f "${BACKUP}"; exit 1; }
echo "Configuration saved to private/backups/$(basename "${BACKUP}")"
ls -1t "${BACKUPS}/${ROUTER}-"*.tar.gz | tail -n +6 | xargs -r rm -f

if [ -z "${YES}" ]; then
	printf "Flash %s now? Its network will be down for a few minutes. [y/N] " "${ROUTER}"
	read -r answer
	[ "${answer}" = "y" ] || { echo "not flashed"; exit 1; }
fi

# Containers get time to shut down first: the upgrade ends whatever is still
# running after four seconds. Stopping the Docker service rather than the
# containers leaves them set to start again after the flash.
# The connection drops when the upgrade starts, so a failure here is expected
router '
if [ -x /etc/init.d/dockerd ] && /etc/init.d/dockerd running; then
	PIDS="$(docker ps -q | xargs -r docker inspect -f "{{.State.Pid}}")"
	/etc/init.d/dockerd stop
	i=0
	while [ $i -lt 60 ] && [ -n "$(for p in $PIDS; do [ -d /proc/$p ] && echo $p; done)" ]; do sleep 1; i=$((i+1)); done
	echo "Containers stopped after ${i}s"
fi
sysupgrade -v -f /tmp/identity.tar.gz /tmp/firmware.img.gz' || true

python3 "${HERE}/wait-router.py" --release "${OPENWRT_VERSION}" --host "${ROUTER}" --port "${PORT}" \
	${KEY:+--key "${KEY}"} ${KNOWN_HOSTS:+--known-hosts "${KNOWN_HOSTS}"}
