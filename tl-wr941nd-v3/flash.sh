#!/bin/sh

# Flashes the built image to the running access point over SSH and waits for it to come
# back at its address in LAN_ADDRESS.
#
# Of the running system only the SSH host key is kept, when it is of the kind the image
# uses (Ed25519), so that the access point keeps its identity. The first-boot scripts set
# up everything else from the image. A backup of the whole configuration is saved first,
# to private/backups/ on this machine. A running system that does not take the SSH key asks
# for its root password, once.
# https://openwrt.org/docs/guide-user/installation/generic.sysupgrade
#
# usage: flash.sh [-y] [-F] [image.bin]
#   -y   do not ask before flashing
#   -F   flash an image the running system does not take as one for itself
#        (sysupgrade -F); see "First flash" in the README before using it
# Settings, from private/.env or, taking precedence, from the environment:
#   ROUTER (the address the access point has now; the one in LAN_ADDRESS by default),
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
FORCE=""
while [ $# -gt 0 ]; do
	case "$1" in
		-y) YES=1 ;;
		-F) FORCE=-F ;;
		*) break ;;
	esac
	shift
done
IMAGE="${1:-${HERE}/binaries/openwrt-${OPENWRT_VERSION}-ath79-tiny-tplink_tl-wr941-v2-squashfs-sysupgrade.bin}"
[ -f "${IMAGE}" ] || { echo "no image found; build one first or name it" >&2; exit 1; }

# Runs a command on the access point at ${HOST}, over the connection in ${MUX} when set
HOST="${ROUTER}"
MUX=""
router() {
	ssh -p "${PORT}" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
		-o ServerAliveInterval=2 -o ServerAliveCountMax=3 \
		${MUX:+-o ControlPath="${MUX}"} \
		${KEY:+-i "${KEY}" -o IdentitiesOnly=yes} \
		${KNOWN_HOSTS:+-o UserKnownHostsFile="${KNOWN_HOSTS}"} \
		"root@${HOST}" "$@"
}

# Every command up to the flash goes over one connection, opened here. A running system
# that does not take the key, such as OpenWrt 19.07 the first time, asks for its root
# password, and only once. 19.07's SSH server only offers an RSA host key signed with SHA-1,
# which OpenSSH no longer accepts unless asked to.
MASTER="$(mktemp -d)/ssh"
trap 'ssh -o ControlPath="${MASTER}" -O exit "root@${ROUTER}" > /dev/null 2>&1; rm -rf "${MASTER%/ssh}"' EXIT
ssh -p "${PORT}" -fN -o ControlMaster=yes -o ControlPath="${MASTER}" -o ControlPersist=yes \
	-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o HostKeyAlgorithms=+ssh-rsa \
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

# The host key comes along when the running system has one of the kind the image uses
echo "Checking the image"
KEEP="$(router '
f=etc/dropbear/dropbear_ed25519_host_key
if [ -s /$f ]; then
	tar czf /tmp/identity.tar.gz -C / $f
	echo kept
else
	rm -f /tmp/identity.tar.gz
fi')"
if [ -n "${KEEP}" ]; then
	OPTIONS="-f /tmp/identity.tar.gz"
else
	OPTIONS="-n"
	echo "The running system has no Ed25519 host key: the access point gets a new one"
fi
router "sysupgrade -T ${FORCE} ${OPTIONS} /tmp/firmware.bin" ||
	{ echo "the running system does not take the image; see \"First flash\" in the README" >&2; exit 1; }

# The whole configuration as the access point has it now, in the format LuCI's backup
# uses, in case the old image has to come back with it. The last five are kept.
BACKUPS="${HERE}/private/backups"
BACKUP="${BACKUPS}/${ROUTER}-$(date +%Y%m%d-%H%M%S).tar.gz"
(
	umask 077
	mkdir -p "${BACKUPS}"
	router 'sysupgrade -b /tmp/backup.tar.gz > /dev/null && cat /tmp/backup.tar.gz && rm -f /tmp/backup.tar.gz' > "${BACKUP}"
)
tar tzf "${BACKUP}" > /dev/null 2>&1 || { echo "the backup did not come through" >&2; rm -f "${BACKUP}"; exit 1; }
echo "Configuration saved to private/backups/$(basename "${BACKUP}")"
ls -1t "${BACKUPS}/${ROUTER}-"*.tar.gz | tail -n +6 | xargs -r rm -f

if [ -z "${YES}" ]; then
	printf "Flash %s now? Its network will be down for a few minutes. [y/N] " "${ROUTER}"
	read -r answer
	[ "${answer}" = "y" ] || { echo "not flashed"; exit 1; }
fi

# The connection drops when the upgrade starts, so a failure here is expected
router "sysupgrade -v ${FORCE} ${OPTIONS} /tmp/firmware.bin" || true

# A new host key would not match the one known for the address
if [ -z "${KEEP}" ] && [ -n "${KNOWN_HOSTS}" ] && [ -f "${KNOWN_HOSTS}" ]; then
	ssh-keygen -R "${NEW}" -f "${KNOWN_HOSTS}" > /dev/null 2>&1 || true
fi

# Back once it runs the release and the first-boot scripts are done. The image takes the
# key, over connections of its own.
echo "Waiting for ${NEW} to come back with OpenWrt ${OPENWRT_VERSION}"
HOST="${NEW}"
MUX=""
start="$(date +%s)"
while [ $(($(date +%s) - start)) -lt 420 ]; do
	sleep 5
	STATE="$(router '. /etc/openwrt_release; echo "${DISTRIB_RELEASE} $(ls /etc/uci-defaults | wc -l)"' 2> /dev/null || true)"
	if [ "${STATE}" = "${OPENWRT_VERSION} 0" ]; then
		echo "Back after $(($(date +%s) - start)) seconds"
		exit 0
	fi
done
echo "${NEW} is not back after 7 minutes" >&2
exit 1
