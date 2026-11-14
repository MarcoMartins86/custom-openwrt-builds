#!/bin/sh

# Boots the built image from memory on the running extender, to try it before flashing it.
# kexec, in the running image, starts the image's kernel in place of its own; the flash keeps
# what it holds, so a restart or a power cut brings the flashed image back. Once the image
# from memory runs, flash.sh flashes the image the same way as from any other OpenWrt.
#
# The running image has to have kexec, which images from this folder have. An image that
# runs from memory itself is first restarted into the flashed one, as both do not fit in
# memory. It waits for the extender to come back at its address in LAN_ADDRESS, running the
# image's revision from memory, with the host key in private/known_hosts.
#
# usage: try.sh
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

[ -f "${HERE}/binaries/revision" ] || { echo "no image found; build one first" >&2; exit 1; }
REVISION="$(cat "${HERE}/binaries/revision")"
IMAGE="${HERE}/binaries/openwrt-ramips-mt7620-tplink_tl-wpa7510-v2-initramfs-kexec.elf"
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

# Every command up to the start of the new kernel goes over one connection, opened here
MASTER="$(mktemp -d)/ssh"
disconnect() {
	ssh -o ControlPath="${MASTER}" -O exit "root@${ROUTER}" > /dev/null 2>&1 || true
	MUX=""
}
connect() {
	ssh -p "${PORT}" -fN -o ControlMaster=yes -o ControlPath="${MASTER}" -o ControlPersist=yes \
		-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
		-o ServerAliveInterval=2 -o ServerAliveCountMax=3 \
		${KEY:+-i "${KEY}" -o IdentitiesOnly=yes} \
		${KNOWN_HOSTS:+-o UserKnownHostsFile="${KNOWN_HOSTS}"} \
		"root@${ROUTER}"
	MUX="${MASTER}"
}
trap 'disconnect; rm -rf "${MASTER%/ssh}"' EXIT
connect

router '[ -e /sys/kernel/kexec_loaded ] && command -v kexec > /dev/null' ||
	{ echo "the running image has no kexec; flash an image from this folder first" >&2; exit 1; }

# An image that runs from memory keeps its whole root file system there, and kexec then runs
# out of memory for the image to try. Restarted, the extender runs the flashed image again.
if ! router 'grep -q " / overlay " /proc/mounts'; then
	echo "The extender runs an image from memory; restarting it into the flashed image first"
	BOOT="$(router 'cat /proc/sys/kernel/random/boot_id')"
	router 'reboot' || true
	disconnect
	start="$(date +%s)"
	while :; do
		[ $(($(date +%s) - start)) -lt 300 ] ||
			{ echo "${ROUTER} is not back from its restart after 5 minutes" >&2; exit 1; }
		sleep 5
		STATE="$(router 'echo "$(cat /proc/sys/kernel/random/boot_id) $(ls /etc/uci-defaults | wc -l) $(grep -c " / overlay " /proc/mounts)"' 2> /dev/null || true)"
		case "${STATE}" in
		"${BOOT} "*) ;;
		*" 0 1") break ;;
		esac
	done
	echo "Back on the flashed image after $(($(date +%s) - start)) seconds"
	connect
fi

# A powerline pairing made with the pair button lives in /etc/bcmplcd/param, which the image
# from memory starts without. It gets a copy, which keeps the extender in its network should
# the chip start again meanwhile, and which flash.sh keeps from there. The copy here holds the
# network key, so it stays in the temporary directory that goes at the end.
PARAM="${MASTER%/ssh}/param"
if router '[ -s /etc/bcmplcd/param ]'; then
	router 'cat /etc/bcmplcd/param' > "${PARAM}"
	chmod 600 "${PARAM}"
fi

echo "Uploading $(basename "${IMAGE}") to ${ROUTER}"
router 'cat > /tmp/kexec.elf' < "${IMAGE}"
LOCAL="$(sha256sum < "${IMAGE}" | cut -d' ' -f1)"
REMOTE="$(router 'sha256sum < /tmp/kexec.elf' | cut -d' ' -f1)"
[ "${LOCAL}" = "${REMOTE}" ] || { echo "checksum mismatch after upload" >&2; exit 1; }

# The kernel takes the command line of the running one. Before it starts, the radios and the
# network stop, so that no device writes into memory the new kernel uses; that runs on its
# own, as it takes the connection down.
router 'kexec -l /tmp/kexec.elf --command-line="$(cat /proc/cmdline)" > /dev/null && rm /tmp/kexec.elf' || {
	router 'rm -f /tmp/kexec.elf' || true
	echo "kexec did not load the image; the extender keeps running its own" >&2
	exit 1
}
echo "Starting it"
router 'printf "%s\n" "wifi down; sleep 3; /etc/init.d/network stop; sleep 2; kexec -e" > /tmp/kexec.sh
	setsid sh /tmp/kexec.sh > /dev/null 2>&1 < /dev/null &'

# Back once it runs the image's revision from memory, and the first-boot scripts are done.
# It takes the key over connections of its own, and has to show the host key the build gave
# it.
echo "Waiting for ${NEW} to come back with ${REVISION} running from memory"
HOST="${NEW}"
MUX=""
KNOWN_HOSTS="${HERE}/private/known_hosts"
STRICT=yes
start="$(date +%s)"
while [ $(($(date +%s) - start)) -lt 300 ]; do
	sleep 5
	STATE="$(router '. /etc/openwrt_release; echo "${DISTRIB_REVISION} $(ls /etc/uci-defaults | wc -l) $(grep -c " / overlay " /proc/mounts)"' 2> /dev/null || true)"
	if [ "${STATE}" = "${REVISION} 0 0" ]; then
		echo "Running from memory after $(($(date +%s) - start)) seconds. ./flash.sh flashes it;"
		echo "a restart brings back the flashed image."
		# bcmplcd reads the file when it starts
		if [ -s "${PARAM}" ]; then
			router 'mkdir -p /etc/bcmplcd && umask 077 && cat > /etc/bcmplcd/param &&
				/etc/init.d/bcmplcd restart' < "${PARAM}" &&
				echo "The powerline pairing came along." ||
				echo "The powerline pairing did not come along; flash.sh will not keep it." >&2
		fi
		exit 0
	fi
done
echo "${NEW} is not back after 5 minutes; a restart brings back the flashed image" >&2
exit 1
