# asus-wl-320ge

An OpenWrt 25.12 image that turns an [ASUS WL-320gE](https://openwrt.org/toh/asus/wl-320g) into a
Wi-Fi access point bridged into the main router's network, or a repeater that extends an
existing Wi-Fi over the air with no cable. The WL-320gE has a Broadcom
BCM5352 at 200 MHz, 4 MB of flash, 16 MB of memory, an 802.11g radio and one Ethernet port.
OpenWrt's own images stopped fitting its flash after 17.01, and it stopped building images
for 16 MB devices after 22.03. This image is built from OpenWrt's source instead: stateless,
with everything an access point does without left out, and the kernel and Wi-Fi stack
trimmed to what this device uses. See [Memory](#memory) for how it fits in 16 MB, and how
that was measured.

What the access point does once flashed:

| Area | Setup | Configured in |
|---|---|---|
| Network | The Ethernet port and the Wi-Fi are one bridge in the main router's network, which hands out the addresses. The access point itself is at `192.168.2.3/24`, with `192.168.2.1` as gateway and DNS. No DHCP or DNS server, no firewall, no IPv6 | `99-uci_config` |
| Wi-Fi | One 2.4 GHz network with WPA2 on a fixed channel. hostapd runs on its own from `/etc/hostapd.conf`, which build.sh writes from the settings; OpenWrt's Wi-Fi scripts are not used. The radio's queues are capped at 512 KB of the 16 MB | `build.sh`, `files/etc/init.d/ap` |
| Repeater | With `REPEATER=1`, the access point also joins a Wi-Fi as a client on a second interface (`sta0`), and `relayd` ties that uplink to the bridge, so its clients reach the main router over the air without a cable. The one radio carries both, so the channel has to be the upstream's, and both use the radio's one address: the radio acknowledges frames for that address only | `build.sh`, `files/etc/init.d/repeater` |
| Settings | Stateless: everything comes from the image. `/etc` gets a RAM overlay at every boot and the rest stays the read-only squashfs; nothing writes to the flash outside a firmware upgrade, and a change made on the access point is gone after a restart | `files/lib/preinit/80_mount_root`, `kernel.config` |
| Access | SSH with keys only. The host key is made once by build.sh and comes with the image, so it stays the same | `99-uci_config`, `build.sh` |
| Memory | Swap compressed in memory (zram), a trimmed kernel, small buffers and tables; see [Memory](#memory) | `kernel.config`, `kernel-patches/`, `mac80211-patches/` |

The script in [files/etc/uci-defaults](files/etc/uci-defaults) runs at every boot, on the
settings as the image brings them. The names and addresses on this page are the defaults;
what can be chosen is listed under [Settings](#settings).

## Build

```sh
docker compose run --rm builder
```

This builds OpenWrt from its source in OpenWrt's SDK container, which brings the tools,
and puts the image in `binaries/`, with its checksum. The first build takes about 40
minutes; the next ones only redo what changed. [build.sh](build.sh) does the work:

- clones OpenWrt at the release's tag into `openwrt/`, with the downloads in `dl/`
- applies [patches/](patches) to it, adds [kernel.config](kernel.config) to the kernel's
  options, and copies [kernel-patches/](kernel-patches) and
  [mac80211-patches/](mac80211-patches) among OpenWrt's own patches
- builds with [openwrt.config](openwrt.config), and stops when a line of it, or of
  kernel.config, did not make it into the result
- makes the SSH host key the first time (into `private/`), writes `/etc/hostapd.conf`,
  `/etc/build.env` and, as a repeater, the uplink's `/etc/wpa_supplicant-uplink.conf` from
  the settings, and checks the image fits the 3,904 KB firmware partition

| Patches | What for |
|---|---|
| `patches/0001` | IPv6 can be left out again (OpenWrt 25.12 builds it in) |
| `patches/0002` | hostapd without ucode, which takes about 300 KB of memory in it |
| `patches/0003` | the WL-320gE as a device: the product ID ASUS's firmware asks for, no marker for a settings partition, and b43 available with PCI left out of the kernel |
| `kernel-patches/999-net-bridge-…` | netifd can make a bridge in a kernel without VLAN filtering: it always sends "filtering off", which such a kernel refused, so no bridge came up at all |
| `kernel-patches/999-b44-…` | 64 receive buffers for the Ethernet port instead of 200 (300 KB) |
| `kernel-patches/999-iomap-…`, `999-mm-…`, `999-squashfs-…` | buffers allocated at boot made smaller: a 64 KB zero buffer, 32 KB network page caches, eight squashfs metadata blocks |
| `mac80211-patches/` | 512 Wi-Fi queue flows instead of 4096 (224 KB); 128 b43 transmit slots instead of 256; for the repeater, b43 able to run an access point and a station together on the one radio at one address, which mac80211 is changed to allow: the access point owns the radio whichever comes up first, and group keys stay in software, as the two roles' keys would overwrite each other in the hardware's shared slots |

The kernel keeps only the exports the image's modules use, listed in
[ksyms-keep.txt](ksyms-keep.txt). A module needing one that is not there stops the build;
then build once with `NO_TRIM=1`, run [ksyms.sh](ksyms.sh), and build again.

## Settings

[.env](.env) holds every setting with its default. Your own values, and anything private, go
into `private/.env`, which overrides it and is not in the repo:

| Setting | Default | What for |
|---|---|---|
| `AP_NAME` | `wl320ge` | the access point's name |
| `LAN_ADDRESS` | `192.168.2.3/24` | its address, outside the main router's DHCP range |
| `GATEWAY` | `192.168.2.1` | the main router |
| `TIMEZONE`, `TIMEZONE_RULE` | Lisbon | the time zone |
| `WIFI_SSID`, `WIFI_COUNTRY`, `WIFI_CHANNEL` | `OpenWrt`, `PT`, `11` | the network. The channel is fixed: the Wi-Fi driver cannot survey channels for the access point to pick one |
| `WIFI_KEY` | none | the password, 8 to 63 characters, in `private/.env` only. Without it the image comes with Wi-Fi off |
| `REPEATER`, `UPLINK_SSID`, `UPLINK_BSSID` | off | `REPEATER=1` extends the Wi-Fi above instead of only serving it; `UPLINK_SSID` names the network to join when it is not `WIFI_SSID` (same password), and `UPLINK_BSSID` pins which access point to join. Then `WIFI_CHANNEL` has to be the upstream's, and a `WIFI_KEY` is needed |
| `KEY` | none | for flash.sh: the SSH key to log in with |

`private/files/` is copied into the image last: put the public SSH key allowed to log in at
`private/files/etc/dropbear/authorized_keys`. build.sh adds the host key there, and its public
half to `private/known_hosts`. The image holds the Wi-Fi password and the host key: do not
hand it out.

## SSH access

```sh
ssh -i ~/.ssh/openwrt_router -o UserKnownHostsFile=private/known_hosts root@192.168.2.3
```

`logread` shows the log (32 KB, kept in memory until the next restart), `dmesg` the kernel's.
There is no login on the serial console; the console still shows the kernel's messages, and
OpenWrt's failsafe mode works as usual.

## Size

| Part | Size |
|---|---|
| Kernel, LZMA | 1,120 KB |
| Root file system, squashfs in 4 KB blocks | 2,450 KB |
| Image, with the boot loader's stub | 3,572 KB of 3,904 KB |

The smallest squashfs blocks cost about 500 KB of flash over 32 KB blocks and save about
140 KB of memory; with no settings partition, the flash has the room.

## Memory

Of the 16 MB, the kernel image takes 3,560 KB, its page structures 128 KB; about 12.5 MB is
left for everything else. The access point needs about 10 MB of that once running.

This was measured in QEMU, on its MIPS Malta board, with a build of the same configuration
for it: the same kernel options and patches, programs built for the same instruction set
(no MIPS16, which this CPU does not have), and the guest given as much memory after boot
as the device has. The kernel's allocation profiling (`/proc/allocinfo`) and each
process's memory map then showed where every page went. The image boots as on the device
(squashfs, the `/etc` overlay), with the access point on a virtual radio:

| Memory | Result |
|---|---|
| 16 MB | runs, 2.8 MB free after boot; a 2.7 MB fill of `/tmp` goes to zram and every service keeps running |
| 16 MB, a client joining and pinging | runs: WPA2, 15 of 15 pings |
| 15 MB | runs, 1.5 MB free after boot |
| 14 MB | runs, 1 MB free after boot |

What made the room, largest first:

| Change | Memory saved |
|---|---|
| hostapd without ucode, and netifd without the Wi-Fi scripts | 720 KB, and 200 KB of ucode code no longer loaded |
| Kernel exports trimmed to what the modules use | 585 KB |
| Ethernet receive buffers (b44) | 300 KB |
| TCP source port table (`INET_TABLE_PERTURB_ORDER`) | 255 KB |
| Wi-Fi queue flows (mac80211) | 224 KB |
| `/etc` alone on the RAM overlay | 144 KB |
| Squashfs in 4 KB blocks | 140 KB |
| No jffs2 (stateless), kernel log of 8 KB, PCI left out | 130, 100, 125 KB |
| No time daemon (the time is set once at boot), no console login, 32 KB log | 60, 80, 32 KB |
| Smaller boot-time buffers and tables (patches above, `tcpmhash_entries=16`) | about 200 KB |

The cost: the access point is an appliance. Any change, the Wi-Fi's included, is a new build
and a flash. Changes made over SSH are gone at the next restart.

## Flash

### First flash

From ASUS's firmware, through its web page, with this machine's cable in the access
point's Ethernet port and this machine at an address on `192.168.1.0/24` (ASUS's default
is `192.168.1.1`, login `admin`/`admin`):

```sh
./flash.sh --stock
```

flash.sh checks it is talking to a WL-320gE, asks, and uploads the image. ASUS's firmware
takes it because it carries the WL-320gE's product ID (`patches/0003`). After about two
minutes the access point runs OpenWrt at `192.168.2.3`: move its cable to the main router's
network, and flash.sh waits for it there.

Keep a copy of the stock flash before the first flash: its boot loader, firmware and
settings partitions. The settings partition holds the device's MAC address and radio
calibration, which no download has.

### Recovery

The boot loader (CFE) has a recovery mode of its own, which a failed flash does not touch:
hold the reset button while switching the access point on, and a few seconds after (ASUS
routers of its age show it by a slowly blinking power light). It then takes an image by
TFTP at its old address, `192.168.1.1`, from a machine on `192.168.1.0/24`. Send it this image, or ASUS's firmware to go back.

### Upgrades

Once the access point runs OpenWrt:

```sh
./flash.sh
```

It streams the image over SSH straight into the firmware partition with `mtd` and reboots:
`mtd` checks the image's header as it writes, with stateless settings there is nothing to
keep, and the 16 MB device has no room to stage the image before writing it. Flash over
the Ethernet cable, not through the access point's own Wi-Fi: a connection that drops
halfway leaves half an image, and then only the boot loader's recovery mode takes a new one.

## Good to know

- The access point is 802.11g only, up to 54 Mbps on the air.
- A Wi-Fi network with the same name and password as another access point in the house
  lets devices move between them.
- As a repeater every packet crosses the air twice on the one channel, to the access point
  and on over the uplink, so throughput about halves and latency rises under load: it is
  for reach and light use, not a busy link. It also holds the uplink until the station has joined and the
  gateway answers, so `relayd` routes it at once instead of finding it slowly.
- Without the kernel's VLAN filtering, netifd makes no bridge unless the kernel has
  `kernel-patches/999-net-bridge-accept-vlan-filtering-off.patch`: the access point then
  has no address, and its Wi-Fi accepts clients that can reach nothing.
