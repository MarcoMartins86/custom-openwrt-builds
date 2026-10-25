#!/bin/sh
# Tests the image's network on QEMU's MIPS Malta board before a flash: that the switch's
# ports come up and join the bridge, that the bridge gets the access point's address, and
# that a Wi-Fi client reaches that address.
#
# The device's switch cannot be emulated, but the kernel's test switch (dsa_loop) takes the
# same way through DSA and phylink as its MV88E6060, which 25.12.6 broke. Both are built
# from the image's kernel source with OpenWrt's Malta SDK, and the test switch gets the
# v3's port names. The first boot takes Malta for the v3, so that the image's board scripts
# make the v3's network. Two virtual radios (mac80211_hwsim) stand in for its Wi-Fi: the
# access point on one, with a test password; on the other, in a network namespace of its
# own, a client that joins it and pings the access point.
# Exit status 0 means every check passed.
#
# usage: malta-network.sh   (after build.sh, whose tools it uses; needs qemu-system-mips)
Q="$(cd "$(dirname "$0")" && pwd)"
. "$Q/malta-lib.sh"
PACKAGES="kmod-mac80211-hwsim kmod-pcnet32 kmod-mii ip-tiny libmnl0 iw-full wpa-supplicant-mini"
malta_file "${KERNEL##*/}" && malta_packages $(malta_kmods) ${PACKAGES} || exit 1
SDK="$(sed -n 's/.* \*\(openwrt-sdk-.*\.tar\.zst\)$/\1/p' "${DL}/sha256sums")"
malta_file "${SDK}" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
LOG="$Q/malta-network-serial.log"

# The SDK's kernel tree, compiler and the libraries its tools run with
mkdir "${WORK}/sdk"
tar --zstd -xf "${DL}/${SDK}" -C "${WORK}/sdk" --strip-components=1 --wildcards \
	'*/build_dir/target-*/linux-malta_be/linux-*' '*/staging_dir/toolchain-*' '*/staging_dir/host/lib' || exit 1
KD="$(ls -d "${WORK}"/sdk/build_dir/target-*/linux-malta_be/linux-*)"
TC="$(ls -d "${WORK}"/sdk/staging_dir/toolchain-*)"
build() {
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin STAGING_DIR="${WORK}/sdk/staging_dir" \
		make -s -C "${KD}" M="$1" ARCH=mips CROSS_COMPILE="${TC}/bin/mips-openwrt-linux-musl-" modules \
		> "$1/build.log" 2>&1 || { cat "$1/build.log" >&2; echo "$1 did not build" >&2; exit 1; }
}

# From the image's kernel source: phylink, DSA with its untagged format, and the test switch
M="${WORK}/modules"
mkdir -p "$M/phylink" "$M/dsa" "$M/loop"
cp "${LINUX}"/drivers/net/phy/phylink.c "${LINUX}"/drivers/net/phy/sfp.h "${LINUX}"/drivers/net/phy/swphy.h "$M/phylink/"
echo 'obj-m := phylink.o' > "$M/phylink/Makefile"
cp "${LINUX}"/net/dsa/*.c "${LINUX}"/net/dsa/*.h "$M/dsa/"
{
	echo 'obj-m := dsa_core.o tag_none.o'
	sed -n '/^dsa_core-y/,/^$/p' "${LINUX}/net/dsa/Makefile"
	grep '^CFLAGS_trace.o' "${LINUX}/net/dsa/Makefile"
} > "$M/dsa/Makefile"
cp "${LINUX}"/drivers/net/dsa/dsa_loop.c "${LINUX}"/drivers/net/dsa/dsa_loop.h "$Q/dsa_loop_helper.c" "$M/loop/"
echo 'obj-m := dsa_loop.o dsa_loop_helper.o' > "$M/loop/Makefile"
for m in phylink dsa loop; do
	build "$M/$m"
done

malta_root "${WORK}" ${PACKAGES}
cp "$M"/*/*.ko "${WORK}/root"/lib/modules/*/
printf '%s\n' 'mac80211_hwsim radios=2' pcnet32 tag_none dsa_loop dsa_loop_helper > "${WORK}/root/etc/modules.d/zz-malta-network"

# The first boot takes Malta for the v3: right after the system reads the board's name, a
# step puts the v3's in its place. Malta has no flash for the board scripts to read the MAC
# addresses from, so the empty ones are taken out again.
printf '%s\n' \
	'set_v3_board() {' \
	'	echo tplink,tl-wr941-v2 > /tmp/sysinfo/board_name' \
	'	echo "TP-Link TL-WR941N/ND v2/v3" > /tmp/sysinfo/model' \
	'}' \
	'boot_hook_add preinit_main set_v3_board' > "${WORK}/root/lib/preinit/03_set_v3_board"
printf '%s\n' \
	'drop_empty_macaddr() {' \
	"	sed -i \"/option macaddr ':'/d\" /etc/config/network" \
	'}' \
	'boot_hook_add preinit_main drop_empty_macaddr' > "${WORK}/root/lib/preinit/83_drop_empty_macaddr"

# The radios set up beforehand as the v3's single 2.4 GHz one: the virtual ones also offer
# 5 and 6 GHz, and OpenWrt gives every access point the country of the last radio listed.
# A fixed channel, as they cannot scan for one, and a test password in place of the image's.
for n in 0 1; do
	printf '%s\n' \
		"config wifi-device 'radio$n'" \
		"	option type 'mac80211'" \
		"	option phy 'phy$n'" \
		"	option band '2g'" \
		"	option channel '6'" \
		"	option htmode 'HT20'" \
		"	option country 'PT'" \
		"" \
		"config wifi-iface 'default_radio$n'" \
		"	option device 'radio$n'" \
		"	option network 'lan'" \
		"	option mode 'ap'" \
		"	option ssid 'OpenWrt'" \
		"	option encryption 'none'" \
		"	option disabled '1'" \
		""
done > "${WORK}/root/etc/config/wireless"
sed -i "s/^WIFI_CHANNEL=.*/WIFI_CHANNEL='6'/" "${WORK}/root/etc/build.env"
(umask 077; echo "WIFI_KEY='malta-test-password'" > "${WORK}/root/etc/wifi.env")

cat > "${WORK}/root/usr/libexec/malta-report" << 'EOF'
. /etc/build.env
IP=/usr/libexec/ip-tiny
echo "--- left: $(ls /etc/uci-defaults | xargs)"
echo "--- interfaces: $(ls /sys/class/net | xargs)"
echo "--- bridge ports: $(ls /sys/class/net/br-lan/brif 2> /dev/null | xargs)"
echo "--- bridge address: $(ip -4 addr show br-lan | sed -n 's/.*inet \([0-9./]*\).*/\1/p')"
echo "--- switch set up: $(dmesg | grep -c 'DSA: tree 0 setup')"
echo "--- switch errors: $(dmesg | grep -c -E 'failed to connect to PHY|setting up PHY')"
echo "--- access point: $(iw dev phy0-ap0 info 2> /dev/null | sed -n 's/^[[:space:]]*ssid //p')"
# The client: the second radio in a network namespace of its own, so that what it sends to
# the access point's address goes over the air
printf 'network={\n\tssid=%s\n\tpsk="%s"\n\tkey_mgmt=WPA-PSK\n}\n' \
	"$(printf '%s' "${WIFI_SSID}" | hexdump -v -e '/1 "%02x"')" \
	"$(uci -q get wireless.default_radio0.key)" > /tmp/client.conf
$IP netns add client
iw phy phy1 set netns name client
$IP netns exec client env IP="$IP" AP="${LAN_ADDRESS%/*}" CLIENT="${LAN_ADDRESS%.*}.250/${LAN_ADDRESS#*/}" sh -c '
	$IP link set lo up
	iw phy phy1 interface add sta0 type managed && $IP link set sta0 up
	wpa_supplicant -B -i sta0 -c /tmp/client.conf > /dev/null 2>&1
	i=0
	while [ $i -lt 30 ] && ! iw dev sta0 link | grep -q "^Connected"; do sleep 1; i=$((i + 1)); done
	echo "--- client: $(iw dev sta0 link | head -n 1)"
	$IP addr add "$CLIENT" dev sta0
	ping -c 3 -W 2 "$AP" > /dev/null 2>&1
	echo "--- ping: $?"
'
rm -f /tmp/client.conf
EOF
malta_report "${WORK}" 60

echo "Booting on QEMU's Malta board with a test switch and two virtual radios"
if ! malta_boot "${WORK}" "${LOG}" 64M; then
	echo "--- no report; the end of the console:"
	tr -d '\r' < "${LOG}" | tail -n 30
	echo "MALTA NETWORK FAIL: no-report"
	exit 1
fi

value() { echo "${REPORT}" | sed -n "s/^--- $1: //p"; }
f=""
[ -z "$(value left)" ] || f="${f} first-boot-scripts-left:$(value left)"
for p in wan lan1 lan2 lan3 lan4; do
	case " $(value interfaces) " in *" $p "*) ;; *) f="${f} no-port-$p" ;; esac
done
for p in wan lan1 lan2 lan3 lan4 phy0-ap0; do
	case " $(value 'bridge ports') " in *" $p "*) ;; *) f="${f} $p-not-bridged" ;; esac
done
[ "$(value 'bridge address')" = "${LAN_ADDRESS}" ] || f="${f} bridge-address"
[ "$(value 'switch set up')" = 1 ] && [ "$(value 'switch errors')" = 0 ] || f="${f} switch-not-set-up"
[ "$(value 'access point')" = "${WIFI_SSID}" ] || f="${f} no-access-point"
case "$(value client)" in Connected*) ;; *) f="${f} client-not-connected" ;; esac
[ "$(value ping)" = 0 ] || f="${f} access-point-not-reachable"

echo "${REPORT}" | grep -E '^--- (interfaces|bridge|switch|access point|client|ping)'
if [ -z "$f" ]; then echo "MALTA NETWORK PASS"; else echo "MALTA NETWORK FAIL:$f"; exit 1; fi
