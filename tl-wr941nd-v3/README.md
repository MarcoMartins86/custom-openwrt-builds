# tl-wr941nd-v3

An OpenWrt 25.12 image that turns a [TP-Link TL-WR941ND v3](https://openwrt.org/toh/tp-link/tl-wr941nd)
into a Wi-Fi access point bridged into the main router's network. The v3 has an Atheros
AR9132 with the Wi-Fi built in and a Marvell 88E6060 switch; OpenWrt builds it as
`tplink_tl-wr941-v2`, for the v2 and v3 alike. The device has 4 MB of flash and 32 MB of
memory, and OpenWrt stopped building images for such devices after 19.07
([4/32 warning](https://openwrt.org/supported_devices/432_warning)). This image is built from
OpenWrt's source instead, with everything an access point does without left out, so that it
fits; see [Size](#size).

What the access point does once flashed:

| Area | Setup | Configured in |
|---|---|---|
| Network | Every port, the WAN port too, and the Wi-Fi are one bridge in the main router's network, which hands out the addresses, so the devices on it show up there like any other. The access point itself is at `192.168.2.2/24`, with `192.168.2.1` as gateway and DNS. No DHCP or DNS server, no firewall, no IPv6 | `99-uci_config` |
| Wi-Fi | One 2.4 GHz network with WPA2, on the channel the access point finds quietest when it starts | `99-wifi_config` |
| Access | SSH with keys only | `99-uci_config` |
| Memory | Swap compressed in memory (zram), up to half the 32 MB, for when it runs short. Small kernel and system logs, small file system blocks, and the crypto modules nothing uses left unloaded; see [Memory](#memory) | OpenWrt's `zram-swap`, `99-uci_config`, `files/etc/modules.d` |

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
| `kernel-patches/` | Fixes for the kernel, added to OpenWrt's own: without the phylink one, 25.12.6 sets up none of the switch's ports |
| `files/` | Files copied into the image, mainly the first-boot scripts |
| `private/files/` | The same, for files that should not be public, such as the SSH keys allowed in. Not in the repo |

With Docker, from this folder:

```
docker compose run --rm builder
```

`build.sh` runs in OpenWrt's SDK container for the release, which brings every tool OpenWrt's
build needs. It checks out OpenWrt's source at the release's tag into `openwrt/`, applies
`patches/`, `kernel-patches/` and `kernel.config`, configures the build from `openwrt.config`, and builds
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
Both files are read by the shell, so put the Wi-Fi password in single quotes
(`WIFI_KEY='…'`): unquoted, the shell acts on characters such as `&`, `;` and spaces, and
inside double quotes still on `$`, `\` and backticks.

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
What got them down, measured on 25.12.6, in KB of 1,024 bytes. Most steps were measured on
OpenWrt's profile for the v4, which differs only in its switch; the last change is the v3's:

| Change | Kernel | Root file system |
|---|---|---|
| Left out what an access point does without: the package manager, DHCP and DNS server, firewall, IPv6 address services, PPP, the boot loader tools, mesh and radar detection for Wi-Fi | −8 | −1,140 |
| Left out package signing and process sandboxing | −4 | −21 |
| hostapd-mini, an access point with WPA2 only and no crypto library, for wpad-basic-mbedtls | | −404 |
| Kernel without IPv6, BPF, ethtool's netlink interface, debugging, multicast routing, VLAN filtering in the bridge, System V IPC, parallel flash, other vendors' firmware layouts and another chip's serial port (`kernel.config`) | −386 | −4 |
| Kernel without voltage regulators and bit-banged MDIO, with the small-memory allocator and tables | −24 | |
| Command-line tools nothing uses, SSH with Ed25519 instead of RSA and without its client, no urngd | | −33 |
| Added swap compressed in memory (zram), with the kernel's swap support | +16 | +21 |
| Root file system in blocks of 32 KB instead of 64, for [memory](#memory) | | +81 |
| The v3's switch driver (DSA) with the kernel parts it needs, less VLAN support, which its switch does without | +20 | +56 |
| **The image now** | **1,523** | **2,001** |

That leaves 59 KB to spare, and 319 KB of flash for the settings, which the image
takes in steps of 64 KB.

Measured and left for later releases, which tend to grow:

| Change | Saves | Costs |
|---|---|---|
| Kernel without its messages | 75 KB | No kernel log at all, so no driver or Wi-Fi errors in `logread` |
| Squashfs blocks of 64, 128 or 256 KB instead of 32 | 81, 143 or 179 KB | 160 KB, 480 KB or 1.1 MB of memory: the kernel keeps about five blocks unpacked |
| No `iw` | 39 KB | OpenWrt's Wi-Fi setup uses it for the transmit power and antenna settings |
| No package records under `/lib/apk` | 30 KB | `sysupgrade` reads them to find the settings to keep; `/etc/sysupgrade.conf` would have to list those |
| Kernel without stack protection | 6 KB | A safeguard against memory corruption |
| Less flash kept for the settings | up to 192 KB | A patch to the image tool's reserve, and less room for settings |

WPA3, as WPA2/WPA3 mixed, would take hostapd-basic-mbedtls and an mbedtls cut down to what
it needs: 230 KB, which is 171 KB more than is spare.

## Memory

The 32 MB of memory is the tighter limit, so the image spends flash where that saves memory:

| Change | Memory saved | Flash it costs |
|---|---|---|
| The kernel keeps its messages in 32 KB instead of 128 KB (`kernel.config`), and with them the index it keeps of them. logd keeps a copy, so 32 KB only has to hold what comes before logd starts | 396 KB | none |
| The crypto modules nothing on the image uses stay on the flash instead of loading at every boot: those for random numbers, hashes and IPsec, which WPA2 on this radio does not use, and the compression ones zram does without. `files/etc/modules.d` holds empty lists in place of OpenWrt's; the kernel still loads one when something asks for it | about 144 KB | none |
| The root file system in blocks of 32 KB instead of 64 (`openwrt.config`). The kernel keeps about five blocks unpacked | 160 KB | 81 KB |
| The system log keeps 64 KB instead of 128 KB (`99-uci_config`) | up to 64 KB | none |
| The kernel's small-memory allocator and tables (`kernel.config`) | not measured | none |
| Swap compressed in memory (zram) | what it compresses, when memory runs short | 37 KB |

With everything running, hostapd included, about 11.5 MB is left. That is the Malta test's
estimate of about 12.5 MB, less the Wi-Fi driver's receive buffers, about 0.6 to 1 MB, which
it only allocates for a radio. The daemons themselves hold little of their own: netifd
500 KB, hostapd 400 KB, procd 170 KB, logd 120 KB, and less than 100 KB each for the rest.
The kernel takes most of what is used. For comparison, OpenWrt 19.07 on this device, with a
smaller kernel but all of a router's services, leaves 12.1 MB.

Measured and left for later:

| Change | Saves | Costs |
|---|---|---|
| Wi-Fi transmit queues capped at 1 MB instead of 4 MB, with `iw phy … set txq memory_limit` at every boot | up to 3 MB, under heavy traffic | Little: 1 MB is still about 80 ms of traffic at the radio's full speed |
| Wi-Fi driver with 128 receive buffers instead of 256, by a patch | 0.3 to 0.5 MB | Frames lost at the radio's full speed |
| Kernel without its messages | its code and the 32 KB | No kernel log at all |
| No ntpd, or no login prompt on the serial port | 52 or 44 KB | A clock that is wrong in the logs, or no login with a serial adapter |

## Test

The device itself cannot be emulated: QEMU has no model of its Atheros AR9132 chip, so the
image's kernel cannot boot there. Its programs can, as its processor is a common MIPS one.
Both tests run after `build.sh` and exit with 0 when every check passes:

- **`test/first-boot.sh`** runs the image's first-boot scripts the way the first boot does,
  on the image's own root file system as a container, its MIPS programs under QEMU's user
  mode, with `test/wifi` in place of the radio. It checks the settings they leave: the
  bridge with the WAN port, the address, Wi-Fi, SSH, zram, and VLAN support in the kernel
  should a port need it. A command the image left out makes it fail. It takes seconds.
- **`test/malta-boot.sh`** boots the image's root file system on QEMU's MIPS Malta board with
  32 MB of memory, with OpenWrt's Malta kernel for the release and its builds of the image's
  kernel modules, downloaded to `dl/`. It checks that the first boot ran, that the services
  start and that no script misses a command. Then it fills `/tmp`, which is memory, until
  the kernel swaps to zram, and checks that nothing had to be ended. It reports the memory
  left, and an estimate for the device, whose kernel needs about 6 MB less than Malta's. It
  takes about two minutes and keeps the console in `test/malta-serial.log`.

They need Docker, with QEMU's user mode registered for MIPS programs, and QEMU's MIPS boards;
on Ubuntu: `sudo apt-get install qemu-user-binfmt qemu-system-mips`.

What only the device can show: that its kernel, switch and Wi-Fi driver work.

## Checks and updates

Every pull request and every change to `main` that touches this folder is built on GitHub
with the settings in `.env`, and checked with both [tests](#test)
([tl-wr941nd-v3.yml](../.github/workflows/tl-wr941nd-v3.yml)). That build uses no secrets, so
its image has none of the private settings; the image to flash is built on your own machine
as above. The run keeps the image's package list and the console of the Malta boot.

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
2. Run `ROUTER=<its address now> ./flash.sh`. When 19.07 does not take the SSH key, it asks
   for 19.07's root password, once. 19.07's SSH server only offers an RSA host key signed
   with SHA-1, which `flash.sh` accepts for this one connection.
3. 19.07's settings do not carry over. After the flash the access point is at `LAN_ADDRESS`,
   in the main router's network, with a new SSH host key, and only takes the key. This
   machine needs a new address from the main router: unplug its cable and plug it back in.

OpenWrt's ath79 builds of 19.07 know the board as `tplink,tl-wr941-v2`, the name the image
is built for, so they take it as their own; it also accepts `tl-wr941nd`, the name of the
older ar71xx builds. If the running system still refuses it, check the name it uses in
`/tmp/sysinfo/board_name`; `flash.sh -F` flashes the image anyway.

From TP-Link's firmware, flash `openwrt-*-squashfs-factory.bin` in its web interface.

A flash that does not boot can only be recovered over the serial port, with a 3.3 V USB
serial adapter on the board's header and the boot loader's TFTP; see the
[device page](https://openwrt.org/toh/tp-link/tl-wr941nd). Have one at hand before flashing a
new release.

## Good to know

- **25.12.6 and the switch**: one of OpenWrt's own kernel patches in 25.12.6, "net: phylink:
  introduce internal phylink PCS handling", makes phylink fail every port of a switch whose
  driver has no PCS support, as this one's: the ports never appear, so neither cable nor
  failsafe reaches the access point. 25.12.5 does not have that patch.
  `kernel-patches/737-08-…` restores the check phylink had before; QEMU's Malta board with
  the kernel's test switch, which takes the same path, shows the ports failing without it
  and coming up with it. The same patch breaks Marvell's 88E6171
  ([openwrt#26029](https://github.com/openwrt/openwrt/issues/26029)).
- **No LuCI**: there is no room for it. Settings are changed over SSH with `uci`, and are
  lost with the next flash unless they go into the image.
- **No package manager**: everything comes with a new image.
- **The system log** is only kept in memory, and read with `logread`.
- **Memory**: 32 MB is tight. The access point runs no more than the kernel, procd, netifd,
  hostapd, dropbear and logd, which leave about 11.5 MB free; see [Memory](#memory).
  When it runs short, the kernel swaps to zram, which compresses what it swaps out and
  keeps it in memory; `free` and `cat /proc/swaps` show how much is in use. It only delays
  running out: if zram fills up too, the kernel ends processes, and procd starts them again.
- **`/tmp` is memory**, and ending a process does not free a file there. A file that fills
  memory and zram leaves the kernel ending services over and over until it is deleted.
