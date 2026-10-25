# tl-wr941nd-v4

An OpenWrt 25.12 image that turns a [TP-Link TL-WR941ND v4](https://openwrt.org/toh/tp-link/tl-wr941nd)
into a Wi-Fi access point bridged into the main router's network. The device has 4 MB of
flash and 32 MB of memory, and OpenWrt stopped building images for such devices after 19.07
([4/32 warning](https://openwrt.org/supported_devices/432_warning)). This image is built from
OpenWrt's source instead, with everything an access point does without left out, so that it
fits; see [Size](#size).

What the access point does once flashed:

| Area | Setup | Configured in |
|---|---|---|
| Network | Every port, the WAN port too, and the Wi-Fi are one bridge in the main router's network, which hands out the addresses, so the devices on it show up there like any other. The access point itself is at `192.168.2.2/24`, with `192.168.2.1` as gateway and DNS. No DHCP or DNS server, no firewall, no IPv6 | `99-uci_config` |
| Wi-Fi | One 2.4 GHz network with WPA2, on the channel the access point finds quietest when it starts | `99-wifi_config` |
| Access | SSH with keys only | `99-uci_config` |
| Memory | Swap compressed in memory (zram), up to half the 32 MB, for when it runs short | OpenWrt's `zram-swap` |

The scripts are in [files/etc/uci-defaults](files/etc/uci-defaults). OpenWrt runs each of them
once, on the first boot after a flash, so the image defines the access point's whole
configuration. The names and addresses on this page are the defaults; what can be chosen is
listed under [Settings](#settings).

The intended wiring: the WAN port to a LAN port of the main router, and the devices to the
four LAN ports and the Wi-Fi.

## Build

The inputs are all in this folder:

| File | Holds |
|---|---|
| `.env` | The [settings](#settings): everything that can be chosen about the image |
| `private/.env` | Your own values for those settings, and the private ones. Not in the repo |
| `openwrt.config` | OpenWrt's build configuration, as far as it differs from the device's defaults: the packages left out, and the options of the kernel, Wi-Fi, SSH and command-line tools |
| `kernel.config` | Kernel options on top of those OpenWrt builds the device's kernel with |
| `patches/` | Changes to OpenWrt's source: IPv6 made optional again |
| `files/` | Files copied into the image, mainly the first-boot scripts |
| `private/files/` | The same, for files that should not be public, such as the SSH keys allowed in. Not in the repo |

With Docker, from this folder:

```
docker compose run --rm builder
```

`build.sh` runs in OpenWrt's SDK container for the release, which brings every tool OpenWrt's
build needs. It checks out OpenWrt's source at the release's tag into `openwrt/`, applies
`patches/` and `kernel.config`, configures the build from `openwrt.config`, and builds
everything, the toolchain first. The first build takes about 15 minutes on 20 cores and
fills about 10 GB; later ones only redo what changed. The source archives stay in `dl/`.
Both folders can be deleted at any time.

The build stops when `make defconfig` or the kernel leaves out a line of `openwrt.config` or
`kernel.config`, as both drop what they cannot set without a word. It ends by printing the
size of kernel and root file system against the most the image can hold, and stops when
they do not fit.

The images land in `binaries/`, next to a `.manifest` listing every package and version that
went in:

| Image | For flashing from |
|---|---|
| `openwrt-*-squashfs-sysupgrade.bin` | OpenWrt, by `flash.sh` |
| `openwrt-*-squashfs-factory.bin` | TP-Link's own firmware, in its web interface |

> **Note** The image holds the Wi-Fi password. Do not hand it out.

The container runs as user 1000. If that is not you, give it the folders first with
`mkdir -p binaries dl openwrt && chown 1000 binaries dl openwrt`. `JOBS` sets how many jobs
run at once, one per core by default, and `AUTOREMOVE=1` deletes each package's build files
once it is built, for a machine short of disk space.

Without Docker, on a Linux machine [set up for building OpenWrt](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem),
run `./build.sh`.

## Settings

`.env` holds every choice with a default. To change one, put it into `private/.env`, which
is read after `.env` and is not in the repo; this keeps your own values out of a public
fork. The build writes the settings into the image, where the first-boot scripts read them.

| Setting | Default | What it sets |
|---|---|---|
| `OPENWRT_VERSION` | `25.12.6` | OpenWrt release to build |
| `OPENWRT_GIT` | OpenWrt's GitHub repository | Where the source comes from |
| `AP_NAME` | `wr941` | Host name |
| `LAN_ADDRESS` | `192.168.2.2/24` | The access point's address and the size of the network. It has to be outside the range the main router hands out |
| `GATEWAY` | `192.168.2.1` | The main router: way to the internet and DNS server |
| `TIMEZONE`, `TIMEZONE_RULE` | `Europe/Lisbon`, `WET0WEST,M3.5.0/1,M10.5.0` | Time zone, and the rule behind it, which is the last line of `/usr/share/zoneinfo/<name>` on most Linux systems |
| `WIFI_SSID` | `OpenWrt` | Name of the Wi-Fi network |
| `WIFI_COUNTRY` | `PT` | Country code, which decides the channels and power allowed |
| `WIFI_CHANNEL` | `auto` | `1` to `13`, or `auto` for the quietest one when the access point starts |

Private settings, which only make sense in `private/.env`:

| Setting | What it sets |
|---|---|
| `WIFI_KEY` | The Wi-Fi password, 8 to 63 characters. Without it the image comes with Wi-Fi switched off |
| `KEY`, `KNOWN_HOSTS` | For `flash.sh`: the SSH private key to log in with, and the file holding the access point's host key |
| `ROUTER`, `PORT` | For `flash.sh`: where to reach the access point, if not at the address in `LAN_ADDRESS` on port 22 |

## SSH access

SSH only accepts keys once there are any, so put the public keys allowed to log in as root
into `private/files/etc/dropbear/authorized_keys` before building. They have to be Ed25519
keys: RSA is left out of the image. Without the file, SSH takes the root password, which a
fresh image does not have.

## Size

The flash holds the boot loader (128 KB), the firmware partition (3,904 KB) and the radio's
calibration data (64 KB). TP-Link's image tool takes at most 3,840 KB of the partition and
keeps 256 KB of that for the settings, so kernel and root file system together have to fit
**3,669,504 bytes**. When they do not, OpenWrt's build makes no image and says nothing; the
build here stops instead. Whatever the image leaves of the partition holds the settings.

With OpenWrt's defaults for the device, kernel and root file system come to 5,484,389 bytes.
What got them down, measured on 25.12.6, in KB of 1,024 bytes:

| Change | Kernel | Root file system |
|---|---|---|
| Left out what an access point does without: the package manager, DHCP and DNS server, firewall, IPv6 address services, PPP, the boot loader tools, mesh and radar detection for Wi-Fi | −8 | −1,140 |
| Left out package signing and process sandboxing | −4 | −21 |
| hostapd-mini, an access point with WPA2 only and no crypto library, for wpad-basic-mbedtls | | −404 |
| Kernel without IPv6, BPF, ethtool's netlink interface, debugging, multicast routing, VLAN filtering in the bridge, System V IPC, parallel flash, other vendors' firmware layouts and another chip's serial port (`kernel.config`) | −386 | −4 |
| Kernel without voltage regulators and bit-banged MDIO, with the small-memory allocator and tables | −24 | |
| Command-line tools nothing uses, SSH with Ed25519 instead of RSA and without its client, no urngd | | −33 |
| Added swap compressed in memory (zram), with the kernel's swap support | +16 | +21 |
| **The image now** | **1,504** | **1,865** |

That leaves 215 KB to spare, and 511 KB of flash for the settings, which the image
takes in steps of 64 KB.

Measured and left for later releases, which tend to grow:

| Change | Saves | Costs |
|---|---|---|
| Kernel without its messages | 75 KB | No kernel log at all, so no driver or Wi-Fi errors in `logread` |
| Squashfs blocks of 128, 256 or 1,024 KB instead of 64 | 62, 98 or 160 KB | Memory: the kernel keeps a few blocks unpacked |
| No `iw` | 39 KB | OpenWrt's Wi-Fi setup uses it for the transmit power and antenna settings |
| No package records under `/lib/apk` | 30 KB | `sysupgrade` reads them to find the settings to keep; `/etc/sysupgrade.conf` would have to list those |
| Kernel without stack protection | 6 KB | A safeguard against memory corruption |
| Less flash kept for the settings | up to 192 KB | A patch to the image tool's reserve, and less room for settings |

WPA3 (as WPA2/WPA3 mixed) fits too, with hostapd-basic-mbedtls and an mbedtls cut down to
what it needs, but with only 26 KB to spare.

## Test

The device cannot be emulated, so nothing boots the image before it is flashed.
`test/first-boot.sh` checks what can be checked without it: it runs the image's first-boot
scripts the way the first boot does, in OpenWrt's rootfs container for the release, with
the device's board scripts and the image's `/etc` taken from the build, and checks the
settings they leave. `test/wifi` stands in for the radio there. It needs Docker, runs after
`build.sh`, and exits with 0 when every check passes.

What only the device can show: that the kernel, the switch and the Wi-Fi driver work, and
how much of the 32 MB of memory is left.

## Checks and updates

Every pull request and every change to `main` that touches this folder is built on GitHub
with the settings in `.env`, and checked with `test/first-boot.sh`
([tl-wr941nd-v4.yml](../.github/workflows/tl-wr941nd-v4.yml)). That build uses no secrets, so
its image has none of the private settings; the image to flash is built on your own machine
as above. The run keeps the image's package list.

[Renovate](https://docs.renovatebot.com/) opens a pull request when a new OpenWrt release has
its SDK container ([renovate.json](../renovate.json)). The build then shows whether the new
release still fits; see [Size](#size) for what is left to cut.

The build is pinned to the release's tag, so two builds of the same release are the same.
Package fixes between releases only come with the next release.

## Flash

For an access point already running this image:

```
./flash.sh
```

It uploads the image, checks it, and upgrades the access point over SSH, then waits for it
to come back with the new release. Before that it saves a backup of the whole configuration
to `private/backups/`, the last five. The SSH key and known-hosts file come from
`private/.env`, see [Settings](#settings).

What a flash keeps and what it replaces:

| | |
|---|---|
| Kept | The SSH host key |
| Replaced | The whole configuration, which the first-boot scripts write again |

### First flash

From OpenWrt 19.07, which this kind of device last got images for:

1. Connect its WAN port to the main router and this machine to one of its LAN ports.
2. `flash.sh` logs in with keys only. If 19.07 takes your key, put it in LuCI under
   System → Administration → SSH-Keys and run `ROUTER=<its address now> ./flash.sh`. Its SSH
   server may not know Ed25519 keys, as small devices leave them out; then flash with its
   root password instead:
   ```
   scp -O binaries/openwrt-*-sysupgrade.bin root@<its address now>:/tmp/firmware.bin
   ssh root@<its address now> sysupgrade -n /tmp/firmware.bin
   ```
3. 19.07's settings do not carry over. After the flash the access point is at `LAN_ADDRESS`,
   in the main router's network, with a new SSH host key. This machine needs a new address
   from the main router: unplug its cable and plug it back in.

The image lists `tl-wr741nd`, OpenWrt's old name for this board, among the devices it is
for, so that 19.07 takes it. If 19.07 still refuses it, check the name it uses in
`/tmp/sysinfo/board_name`; `flash.sh -F` flashes the image anyway.

From TP-Link's firmware, flash `openwrt-*-squashfs-factory.bin` in its web interface.

A flash that does not boot can only be recovered over the serial port, with a 3.3 V USB
serial adapter on the board's header and the boot loader's TFTP; see the
[device page](https://openwrt.org/toh/tp-link/tl-wr941nd). Have one at hand before flashing a
new release.

## Good to know

- **No LuCI**: there is no room for it. Settings are changed over SSH with `uci`, and are
  lost with the next flash unless they go into the image.
- **No package manager**: everything comes with a new image.
- **The system log** is only kept in memory, and read with `logread`.
- **Memory**: 32 MB is tight. The access point runs no more than the kernel, procd, netifd,
  hostapd, dropbear and logd. When it runs short, the kernel swaps to zram, which compresses
  what it swaps out and keeps it in memory; `free` and `cat /proc/swaps` show how much is
  in use. It only delays running out: if zram keeps filling up, something has to go.
