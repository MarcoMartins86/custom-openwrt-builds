# tl-wpa7510-v2

An OpenWrt image that turns the extender of a [TP-Link TL-WPA7510 v2](https://www.tp-link.com/support/download/tl-wpa7510-kit/)
powerline kit into a Wi-Fi access point bridged into the main router's network over the
powerline. The extender has a MediaTek MT7620A with 2.4 GHz Wi-Fi, an MT7610E for 5 GHz,
64 MB of memory and 8 MB of flash, and a Broadcom BCM60350 powerline chip with the
Ethernet socket behind it.

OpenWrt does not support this device yet. The image is built from a fork of OpenWrt that
adds it, on the branch [`ramips-tl-wpa7510-v2`](https://github.com/MarcoMartins86/openwrt/tree/ramips-tl-wpa7510-v2):
the device itself, `bcmplcd`, which loads the powerline chip's firmware at every start
and keeps its settings, and `bcmplc`, which pairs it. The build pins a commit of that
branch.

What the extender does once flashed:

| Area | Setup | Configured in |
|---|---|---|
| Network | The Ethernet socket, the powerline and both Wi-Fi networks are one bridge in the main router's network, which hands out the addresses, so the devices on it show up there like any other. The extender itself is at `192.168.2.4/24`, with `192.168.2.1` as gateway and DNS. No DHCP or DNS server, no firewall, no IPv6 | `99-uci_config` |
| Wi-Fi | The same network on both radios, with WPA2: 2.4 GHz at 20 MHz and 5 GHz at 80 MHz, on the channels set in `.env` | `99-wifi_config` |
| Powerline | `bcmplcd` loads the chip at every start, from the chip's partitions on the flash, which hold the pairing made with the stock firmware. The pair button pairs anew | the fork's `bcmplcd` |
| Access | SSH with keys only, and a host key that comes with the image | `99-uci_config`, `build.sh` |
| Settings | Kept on the flash as usual, but `flash.sh` starts every flash from the image's settings | `flash.sh` |

The scripts are in [files/etc/uci-defaults](files/etc/uci-defaults). OpenWrt runs each of them
on the first boot after a flash. The names and addresses on this page are the defaults;
what can be chosen is listed under [Settings](#settings).

## Build

The inputs are all in this folder:

| File | Holds |
|---|---|
| `.env` | The [settings](#settings): everything that can be chosen about the image, and the fork's commit to build |
| `private/.env` | Your own values for those settings, and the private ones. Not in the repo |
| `openwrt.config` | OpenWrt's build configuration, as far as it differs from the device's defaults: the packages left out, and the options of the kernel, Wi-Fi, SSH and command-line tools |
| `kernel.config` | Kernel options on top of those OpenWrt builds the device's kernel with |
| `patches/` | Changes to OpenWrt's source: IPv6 made optional again |
| `ksyms-keep.txt` | The kernel exports the image's modules use, which the kernel keeps; it drops the rest. `ksyms.sh` makes it from a build's modules |
| `files/` | Files copied into the image: the first-boot scripts |
| `private/files/` | The same, for files that should not be public: the SSH keys allowed in, and the extender's host key, which the first build makes. Not in the repo |

On a Linux machine [set up for building OpenWrt](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem):

```
./build.sh
```

Or with Docker, in OpenWrt's SDK container, which brings every tool the build needs:

```
docker compose run --rm builder
```

`build.sh` checks out the fork at the commit in `.env` into `openwrt/`, applies `patches/`
and `kernel.config`, configures the build from `openwrt.config`, and builds everything, the
toolchain first. The first build takes about 15 minutes on 20 cores and fills about 10 GB;
later ones only redo what changed. The source archives stay in `dl/`. Both folders can be
deleted at any time.

The build stops when `make defconfig` or the kernel leaves out a line of `openwrt.config` or
`kernel.config`, as both drop what they cannot set without a word. It ends by printing the
size of kernel and root file system against the 5,952 KB firmware partition, and what that
leaves for the settings.

It also stops when a module needs a kernel export that `ksyms-keep.txt` does not list, as
can happen after a newer commit or a module added to the image. Then build once with
`NO_TRIM=1`, which keeps all the exports, run `./ksyms.sh` to list the ones the modules use
now, and build again.

The first build makes the extender's SSH host key, in `private/files/etc/dropbear/`, and
adds its public half to `private/known_hosts` for the extender's address. Later builds keep
using it, so the extender keeps its identity from one image to the next.

The images land in `binaries/`, with OpenWrt's names, next to a `.manifest` listing every
package and version that went in, and `revision`, OpenWrt's revision of the build:

| Image | For |
|---|---|
| `openwrt-*-squashfs-factory.bin` | The first flash, from TP-Link's web page |
| `openwrt-*-squashfs-sysupgrade.bin` | Flashing from OpenWrt, by `flash.sh` |
| `openwrt-*-initramfs-kernel.bin` | Booting from memory with the boot loader, for recovery |

> **Note** The images hold the Wi-Fi password and the SSH host key. Do not hand them out.

The container runs as user 1000. If that is not you, give it the folders first with
`mkdir -p binaries dl openwrt private && chown 1000 binaries dl openwrt private`. `JOBS` sets
how many jobs run at once, one per core by default, `AUTOREMOVE=1` deletes each package's
build files once it is built, for a machine short of disk space, and `NO_TRIM=1` keeps all
the kernel's exports.

## Settings

`.env` holds every choice with a default. To change one, put it into `private/.env`, which
is read after `.env` and is not in the repo; this keeps your own values out of a public
fork. The build writes the settings into the image, where the first-boot scripts read them.
Both files are read by the shell, so put the Wi-Fi password in single quotes
(`WIFI_KEY='…'`): unquoted, the shell acts on characters such as `&`, `;` and spaces, and
inside double quotes still on `$`, `\` and backticks.

| Setting | Default | What it sets |
|---|---|---|
| `OPENWRT_GIT`, `OPENWRT_BRANCH`, `OPENWRT_COMMIT` | the fork, its branch with the port, a commit of it | The source to build |
| `SDK_TAG` | `ramips-mt7620-main` | OpenWrt's SDK container for `docker compose`, for its tools only |
| `AP_NAME` | `wpa7510` | Host name |
| `LAN_ADDRESS` | `192.168.2.4/24` | The extender's address and the size of the network. It has to be outside the range the main router hands out |
| `GATEWAY` | `192.168.2.1` | The main router: way to the internet and DNS server |
| `TIMEZONE`, `TIMEZONE_RULE` | `Europe/Lisbon`, `WET0WEST,M3.5.0/1,M10.5.0` | Time zone, and the rule behind it, which is the last line of `/usr/share/zoneinfo/<name>` on most Linux systems |
| `WIFI_SSID` | `OpenWrt` | Name of the Wi-Fi network, on both radios |
| `WIFI_COUNTRY` | `PT` | Country code, which decides the channels and power allowed |
| `WIFI_CHANNEL_2G` | `auto` | `1` to `13`, or `auto` for the quietest one when the extender starts |
| `WIFI_CHANNEL_5G`, `WIFI_HTMODE_5G` | `auto`, `VHT80` | `36` to `64` or `100` to `140`, or `auto`, and the width: `VHT20`, `VHT40` or `VHT80`. Channels 36 to 48 need no radar detection; the others make the extender listen for radar for a minute before it sends. The radio sends at most 13 dBm on 36 to 64 and 10 dBm above |

Private settings, which only make sense in `private/.env`:

| Setting | What it sets |
|---|---|
| `WIFI_KEY` | The Wi-Fi password, 8 to 63 characters. Without it the image comes with Wi-Fi switched off |
| `KEY`, `KNOWN_HOSTS` | For `flash.sh`: the SSH private key to log in with, and the file holding the host key of the system running before the flash. After the flash, `flash.sh` checks the extender by the host key in `private/known_hosts` |
| `ROUTER`, `PORT` | For `flash.sh`: where to reach the extender, if not at the address in `LAN_ADDRESS` on port 22 |

## SSH access

SSH only accepts keys once there are any, so put the public keys allowed to log in as root
into `private/files/etc/dropbear/authorized_keys` before building. They have to be Ed25519
keys: RSA and ECDSA are left out of the image. Without the file, SSH takes the root
password, which a fresh image does not have.

The extender's own host key comes with the image (see [Build](#build)). To check it from
another machine, use `private/known_hosts`, as in
`ssh -o UserKnownHostsFile=private/known_hosts root@192.168.2.4`.

## Size

The firmware partition is 5,952 KB: the stock firmware's kernel and root file system, and
the 192 KB the stock layout leaves unused after them. Kernel and root file system have to
fit it, and what they leave holds the settings. Everything above it (TP-Link's settings, the
powerline chip's firmware and parameters, the MAC address and the Wi-Fi calibration) stays
as it is.

With OpenWrt's defaults for the device the image does not fit; without the packages of a
router (DHCP and DNS server, firewall, PPP) it leaves 151 KB. What got it to 1.8 MB,
measured on the device's branch, in bytes:

| Change | Kernel | Root file system |
|---|---|---|
| Without the packages of a router | 2,924,347 | 3,016,072 |
| Kernel without BPF, ethtool's netlink interface, System V IPC, multipath TCP, key rings, swap, core dumps, debugging, multicast routing and snooping, policy routing, parallel flash, other vendors' firmware layouts, regulators, USB and partition tables; Wi-Fi without mesh and debugging files; hostapd-basic-mbedtls instead of wpad-basic-mbedtls | −580,491 | −222,264 |
| Kernel exports kept only for the image's modules (`ksyms-keep.txt`); command-line tools nothing uses; SSH with Ed25519 only and without its client; no urngd | −219,096 | −48,636 |
| No package manager, and with it no TLS library; no IPv6; hostapd-mini, WPA2 only | −150,553 | −540,788 |
| **The image now** | **1,974,207** | **2,204,384** |

That leaves 1,916,257 bytes, 1.8 MB, for the settings.

Measured and left out, each on its own:

| Change | Saves | Costs |
|---|---|---|
| Kernel compiled for size (`-Os`) | 347 KB | Some processor speed, which Wi-Fi and the bridge use |
| Kernel without its symbol table | 160 KB | Crash reports with addresses instead of function names |
| No process sandboxing (ujail, seccomp, namespaces) | 103 KB | ntpd and hostapd run without it |
| Squashfs blocks of 1 MB instead of 256 KB | 75 KB | A few MB of memory for the blocks the kernel keeps unpacked |
| Kernel without traffic control | 11 KB | fq_codel on the Ethernet side |

## Checks and updates

Every pull request and every change to `main` that touches this folder is built on GitHub in
the SDK container, with the settings in `.env`
([tl-wpa7510-v2.yml](../.github/workflows/tl-wpa7510-v2.yml)). That build uses no secrets, so
its image has none of the private settings; the image to flash is built on your own machine
as above. The run keeps the image's package list.

The build is pinned to a commit of the fork, so two builds of it are the same. To move to a
newer one, put its commit into `OPENWRT_COMMIT`; once OpenWrt supports the device, the build
can move to OpenWrt's own source and releases.

## Flash

For an extender already running OpenWrt:

```
./flash.sh
```

It uploads the image, checks it, and upgrades the extender over SSH, then waits for it to
come back with the image's revision and the host key in `private/known_hosts`. The SSH key
and known-hosts file come from `private/.env`, see [Settings](#settings). The running
system's settings are not kept; a pairing made with the pair button since the last flash is
lost with them, and the chip goes back to the pairing in its flash partition.

### First flash

From TP-Link's firmware, in its web page (tried with firmware 2.0.5, Build 20240306, EU):

1. Open the extender's web page and log in, and go to its Firmware Upgrade page.
2. Choose `openwrt-ramips-mt7620-tplink_tl-wpa7510-v2-squashfs-factory.bin` from
   `binaries/`, click Upgrade and confirm. **Keep the file name short**: the web page drops
   an upload whose file name has 69 characters or more, and then says "Wrong file". OpenWrt's
   name for the image has 63; OpenWrt's release images, named `openwrt-<version>-ramips-…`,
   have to be renamed first.
3. The extender writes the image and restarts into OpenWrt, a few minutes in all. It comes
   up at `LAN_ADDRESS`, with the settings of the build and the extender's host key, so
   `flash.sh` takes it from there.

The web page takes the image as TP-Link's own: same format and checksum, and a support list
with the unit's model. That list names the EU model (`special_id:45550000`); a unit made for
another region refuses the image. The web page writes OpenWrt's kernel and root file system
and its own partition table entries for them, and leaves the rest of the flash alone.

Once OpenWrt runs, save a copy of the flash's partitions: they hold the only copy of the
unit's MAC addresses, Wi-Fi calibration and powerline parameters.

```
for p in $(ssh root@192.168.2.4 "sed -n 's/^\(mtd[0-9]*\):.*/\1/p' /proc/mtd"); do
	ssh root@192.168.2.4 "cat /dev/${p}" > "${p}.bin"
done
```

### Recovery

When a flash does not boot, the boot loader can boot the image from memory, but only over
the serial port: nothing in it checks a button. It needs a 3.3 V USB serial adapter.

1. The serial port is four pads in a row on the board: TX, RX, GND, 3.3 V. Wire the
   adapter's RXD to TX, its TXD to RX and GND to GND, and leave 3.3 V unconnected. 115200
   baud, 8N1.
2. Put this machine on the Ethernet socket with a TFTP server holding
   `openwrt-*-initramfs-kernel.bin`, and let UDP port 69 through its firewall.
3. Power the extender on. Each boot loader stage shows a menu for a second; press `4` to get
   the `MT7620 #` prompt. Type slowly: whole lines sent at once lose characters.
4. Load the powerline chip, which the Ethernet socket is behind, then boot the image from
   memory:

   ```
   plcboot
   setenv ipaddr 192.168.2.4
   setenv serverip <this machine's address>
   tftpboot 0x82000000 openwrt-…-initramfs-kernel.bin
   bootm 0x82000000
   ```

   `plcboot` ends with `plcboot res: success`; without it, `tftpboot` only prints `T T T`.
5. The image from memory comes up with the settings of this build, at `LAN_ADDRESS`, and
   with the extender's host key. Run `KNOWN_HOSTS=private/known_hosts ./flash.sh`.

### Back to TP-Link's firmware

This takes the stock firmware from a backup of the whole flash made before OpenWrt: its
`0x60000` to `0x630000`, 6,094,848 bytes, which hold TP-Link's kernel and root file system.
The stock firmware's serial console takes `root` with the password `sohoadmin`, and
`tftp -p -l /dev/mtdblock0 -r backup-8MB.bin <TFTP server>` sends the whole flash to a TFTP
server that takes uploads; pull it twice and compare. Then, from OpenWrt:

```
dd if=backup-8MB.bin of=stock.bin bs=64k skip=6 count=93
ssh root@192.168.2.4 'cat > /tmp/stock.bin' < stock.bin
ssh root@192.168.2.4 sysupgrade -F -n /tmp/stock.bin
```

`-F` because the file has none of OpenWrt's image information. This was tried from an
extender flashed with `flash.sh`, which leaves TP-Link's partition table alone, not yet after
an install from the web page, which changes it.

## Good to know

- **The powerline chip has no flash of its own.** After every power cut it waits for its
  firmware, and until `bcmplcd` has sent it, the Ethernet socket and the powerline carry
  nothing, although the socket shows a link. The chip keeps running across a restart of the
  extender.
- **Pairing**: the pair button starts a pairing with another adapter, and a second press
  ends it; `bcmplc status` shows how it went, and `bcmplc info` the adapters in the network.
- **No LuCI and no package manager**: everything comes with a new image.
- **The boot crash**: the MT7620's processor core can return from an interrupt to a wrong
  address when the kernel runs code in its first 32 KB, which OpenWrt's kernels for this
  chip did at the time of writing. The fork keeps the kernel's code out of there.
