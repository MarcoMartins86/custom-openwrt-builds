#!/bin/sh
# Boot the built image in QEMU, to test the first-boot scripts without the hardware.
# The VM emulates the router's own processor, so that it boots the same on every host.
# Serial console: serial.sock (log: serial.log), driven by ser.py.
# SSH and LuCI's HTTP port are forwarded to 127.0.0.1:2222 and 127.0.0.1:8080.
#
# usage: [IMG=path] [MEM=megabytes] [KEEP=1] [LAN=slirp|dgram] start.sh [disk-size] [sata|nvme|mmc]
#   KEEP=1     reuse the existing disk instead of starting from a fresh copy of the image
#   CPU=host   hand the host's processor to the VM through KVM, where there is KVM: faster,
#              but the first boot then differs between hosts (see below)
#   LAN=dgram  wire the lan NIC to lan.sock/lan-peer.sock for dhcp_probe.py
set -e
Q="$(cd "$(dirname "$0")" && pwd)"
. "$Q/../.env"
[ -f "$Q/../private/.env" ] && . "$Q/../private/.env"
# the router's LAN address and the first three numbers of its network, taken as a /24
LANIP="${LAN_ADDRESS%/*}"
LANNET="${LANIP%.*}"
IMG=${IMG:-$(ls "$Q"/../binaries/openwrt-*-ext4-combined-efi.img.gz 2>/dev/null | head -1)}
SIZE=${1:-8G}
BUS=${2:-sata}
cd "$Q"

[ -f "$IMG" ] || { echo "no image found; build one first or set IMG" >&2; exit 1; }

[ -f qemu.pid ] && kill "$(cat qemu.pid)" 2>/dev/null || true
rm -f qemu.pid serial.sock monitor.sock lan.sock

if [ -z "$KEEP" ] || [ ! -f disk.img ]; then
	rm -f serial.log
	# OpenWrt images carry trailing metadata, which makes gzip exit 2 with a warning
	gzip -dc "$IMG" > disk.img 2>/dev/null || [ $? -eq 2 ]
	qemu-img resize -q -f raw disk.img "$SIZE"
	cp /usr/share/OVMF/OVMF_VARS_4M.fd vars.fd
fi

# The router has an Intel Celeron J4125. QEMU's nearest model, given that chip's
# family, model and stepping, makes the first boot find the router's microcode and
# restart once to load it, as on the router. With the host's processor that restart
# would depend on the host: Intel or AMD, and whether microcode exists for it. The
# features at the end are ones QEMU's emulator cannot provide.
if [ "${CPU}" = host ] && [ -w /dev/kvm ]; then
	ACCEL="-accel kvm -cpu host"
else
	ACCEL="-accel tcg,thread=multi -cpu Denverton,family=6,model=122,stepping=8,-tsc-deadline,-spec-ctrl,-arch-capabilities,-ssbd,-xsavec"
fi

case "$BUS" in
	sata) DISK="-device ide-hd,drive=d0,bus=ide.0" ;;
	nvme) DISK="-device nvme,drive=d0,serial=test0" ;;
	mmc)  DISK="-device sdhci-pci -device sd-card,drive=d0" ;;
	*) echo "unknown bus $BUS" >&2; exit 1 ;;
esac

case "${LAN:-slirp}" in
	slirp) LANDEV="user,id=lan,net=${LANNET}.0/24,host=${LANNET}.2,dhcpstart=${LANNET}.200,hostfwd=tcp:127.0.0.1:2222-${LANIP}:22,hostfwd=tcp:127.0.0.1:8080-${LANIP}:80" ;;
	# full paths: QEMU leaves this folder when it goes to the background
	dgram) LANDEV="dgram,id=lan,local.type=unix,local.path=$Q/lan.sock,remote.type=unix,remote.path=$Q/lan-peer.sock" ;;
	*) echo "unknown LAN $LAN" >&2; exit 1 ;;
esac

# each igb sits on its own root port, as its SR-IOV functions need a whole bus
# first NIC = eth0 = lan (LAN_ADDRESS after first boot), second = eth1 = wan (DHCP from QEMU)
qemu-system-x86_64 \
	-machine q35 $ACCEL -smp 4 -m ${MEM:-2048} \
	-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
	-drive if=pflash,format=raw,file=vars.fd \
	-drive file=disk.img,format=raw,if=none,id=d0 $DISK \
	-netdev "$LANDEV" \
	-device pcie-root-port,id=rp1,chassis=1 -device igb,netdev=lan,bus=rp1,mac=52:54:00:00:02:01 \
	-netdev user,id=wan \
	-device pcie-root-port,id=rp2,chassis=2 -device igb,netdev=wan,bus=rp2,mac=52:54:00:00:02:02 \
	-chardev socket,id=ser0,path=serial.sock,server=on,wait=off,logfile=serial.log,logappend=on \
	-serial chardev:ser0 \
	-monitor unix:monitor.sock,server,nowait \
	-display none -daemonize -pidfile qemu.pid

echo "started pid $(cat qemu.pid), disk $SIZE on $BUS, lan ${LAN:-slirp}"
