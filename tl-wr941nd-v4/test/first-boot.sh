#!/bin/sh
# Runs the image's first-boot scripts the way the access point runs them on its first
# boot, and checks the settings they leave. The device cannot be emulated, but the
# scripts only need OpenWrt's tools: they run in OpenWrt's rootfs container for the
# release, with this device's board scripts and the image's /etc from the build, and
# test/wifi in place of the radio. Exit status 0 means every check passed.
#
# usage: first-boot.sh   (after build.sh)
Q="$(cd "$(dirname "$0")" && pwd)"
. "$Q/../.env"
[ -f "$Q/../private/.env" ] && . "$Q/../private/.env"
ROOT="$(ls -d "$Q"/../openwrt/build_dir/target-*/root-ath79 2> /dev/null)"
KCONFIG="$(ls "$Q"/../openwrt/build_dir/target-*/linux-ath79_tiny/linux-*/.config 2> /dev/null)"
[ -f "${ROOT}/etc/build.env" ] && [ -f "${KCONFIG}" ] ||
	{ echo "no image files in openwrt/build_dir; run build.sh first" >&2; exit 1; }

# Kept as short commands, one per check, collecting what is wrong in $f. The Wi-Fi
# password is compared there and never printed.
OUT="$(docker run --rm -i --entrypoint /bin/sh \
	-v "${ROOT}/etc:/image/etc:ro" -v "$Q/wifi:/image/wifi:ro" -v "${KCONFIG}:/image/kernel.config:ro" \
	"ghcr.io/openwrt/rootfs:x86-64-v${OPENWRT_VERSION}" << 'EOS'
# The device, as its board scripts describe it to OpenWrt
mkdir -p /tmp/sysinfo
echo tplink,tl-wr941-v4 > /tmp/sysinfo/board_name
echo "TP-Link TL-WR941ND v4" > /tmp/sysinfo/model
rm -rf /etc/board.d /etc/uci-defaults /etc/config/network /etc/config/system /etc/board.json
cp -a /image/etc/board.d /image/etc/uci-defaults /etc/
cp -p /image/etc/config/dropbear /etc/config/
cp -p /image/etc/build.env /etc/
[ -f /image/etc/wifi.env ] && cp -p /image/etc/wifi.env /etc/
[ -d /image/etc/dropbear ] && mkdir -p /etc/dropbear && cp -a /image/etc/dropbear/. /etc/dropbear/
cp /image/wifi /sbin/wifi
chmod 755 /sbin/wifi
board_detect > /dev/null
config_generate > /dev/null
LAN_PORTS="$(jsonfilter -i /etc/board.json -e '@.network.lan.ports[*]' -e '@.network.lan.device' | xargs)"
# The first boot: OpenWrt's boot script applies the defaults, before the radio's
# settings are necessarily there
eval "$(sed -n '/^uci_apply_defaults()/,/^}/p' /image/etc/init.d/boot)"
uci_apply_defaults > /dev/null 2>&1
cd /
. /image/etc/build.env
WIFI_KEY=""
[ -f /image/etc/wifi.env ] && . /image/etc/wifi.env
f=""
[ -z "$(ls /etc/uci-defaults)" ] || f="$f first-boot-scripts-left:$(ls /etc/uci-defaults | tr '\n' ,)"
BRIDGE="$(uci show network | sed -n "s/^\(network\.[^.]*\)\.name='br-lan'$/\1/p")"
PORTS=" $(uci -q get "$BRIDGE.ports") "
case "$PORTS" in *" eth0 "*) ;; *) f="$f wan-port-not-bridged" ;; esac
for p in $LAN_PORTS; do
	case "$PORTS" in *" $p "*) ;; *) f="$f lan-port-$p-not-bridged" ;; esac
done
# A port on a VLAN of the switch, such as eth1.1, needs the kernel's VLAN support
case "$PORTS" in
	*.*) grep -q '^CONFIG_VLAN_8021Q=y' /image/kernel.config || f="$f kernel-without-vlans" ;;
esac
[ "$(uci -q get network.lan.device)" = br-lan ] || f="$f lan-device"
uci -q get network.wan > /dev/null && f="$f wan-left"
uci -q get network.wan6 > /dev/null && f="$f wan6-left"
[ "$(uci -q get network.lan.proto)" = static ] || f="$f lan-proto"
[ "$(uci -q get network.lan.ipaddr)" = "$LAN_ADDRESS" ] || f="$f lan-address"
[ "$(uci -q get network.lan.gateway)" = "$GATEWAY" ] || f="$f gateway"
[ "$(uci -q get network.lan.dns)" = "$GATEWAY" ] || f="$f dns"
uci -q get network.lan.ip6assign > /dev/null && f="$f lan-ipv6"
uci -q get network.globals.ula_prefix > /dev/null && f="$f ula-prefix"
[ "$(uci -q get system.@system[0].hostname)" = "$AP_NAME" ] || f="$f hostname"
[ "$(uci -q get system.@system[0].timezone)" = "$TIMEZONE_RULE" ] || f="$f timezone"
if [ -s /etc/dropbear/authorized_keys ]; then A=off; else A=on; fi
[ "$(uci -q get dropbear.main.PasswordAuth)$(uci -q get dropbear.main.RootPasswordAuth)" = "$A$A" ] || f="$f ssh-password-$A"
[ "$(uci -q get wireless.radio0.country)" = "$WIFI_COUNTRY" ] || f="$f wifi-country"
[ "$(uci -q get wireless.radio0.channel)" = "$WIFI_CHANNEL" ] || f="$f wifi-channel"
[ "$(uci -q get wireless.default_radio0.network)" = lan ] || f="$f wifi-network"
[ "$(uci -q get wireless.default_radio0.ssid)" = "$WIFI_SSID" ] || f="$f wifi-ssid"
[ "$(uci -q get wireless.default_radio0.encryption)" = psk2 ] || f="$f wifi-encryption"
[ "$(uci -q get wireless.default_radio0.key)" = "$WIFI_KEY" ] || f="$f wifi-key"
if [ -n "$WIFI_KEY" ]; then D=0; else D=1; fi
[ "$(uci -q get wireless.default_radio0.disabled)" = "$D" ] || f="$f wifi-switch"
[ -e /etc/wifi.env ] && f="$f wifi-password-file-left"
ls /image/etc/rc.d | grep -q "^S[0-9]*zram$" || f="$f zram-not-started"
echo "--- settings made:"
uci show network | grep -E '^network\.(lan|@device\[[0-9]\])\.'
uci show system | grep -E '\.(hostname|zonename|timezone)='
uci show dropbear | grep -E 'Auth='
uci show wireless | grep -v '\.key='
if [ -z "$f" ]; then echo "FIRST BOOT PASS"; else echo "FIRST BOOT FAIL:$f"; fi
EOS
)"
echo "${OUT}"
case "${OUT}" in
	*"FIRST BOOT PASS"*) exit 0 ;;
	*) exit 1 ;;
esac
