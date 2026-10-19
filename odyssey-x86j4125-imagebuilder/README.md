# odyssey-x86j4125-imagebuilder

An OpenWrt 25.12 image that turns a [Seeed ODYSSEY-X86J4125](https://wiki.seeedstudio.com/ODYSSEY-X86J4105/)
into a home router. It is built with OpenWrt's
[ImageBuilder](https://openwrt.org/docs/guide-user/additional-software/imagebuilder), using the
[container OpenWrt publishes](https://github.com/openwrt/docker), so nothing is compiled.

What the router does once flashed:

| Area | Setup | Configured in |
|---|---|---|
| Network | LAN `192.168.2.1/24` on the first port, WAN by DHCP on the second, IPv6 off. The WAN is restarted after 10 minutes without internet | `99-uci_config`, `99-watchcat_config` |
| Backup internet | When the ISP WAN stops answering, mwan3 fails the whole network over to a phone tethered over USB, and back when it returns | `99-mwan3_config` |
| DNS and DHCP | unbound with DNSSEC, odhcpd, local names under `.lan` | `99-unbound_config` |
| Ad blocking | adblock on unbound, lists refreshed every night, DNS forced through the router, DNS over TLS to outside cut off, DNS report for every network | `99-adblock_config` |
| Firewall | OpenWrt's firewall plus banIP blocklists, refreshed every night | `99-banip_config` |
| Containers | Docker, with OpenWrt's firewall as the only firewall | `99-docker_config` |
| Home automation | Home Assistant as a container, with a Zigbee stick | `99-homeassistant_config` |
| File sharing | One open SMB folder, `\\odyssey\share` | `99-ksmbd_config` |
| Monitoring | Statistics graphs with history on disk, nlbwmon, the system log kept on disk too, the SSD's health watched and graphed | `99-statistics_config`, `99-nlbwmon_config`, `99-log_config`, `99-smart_config` |
| Access | LuCI over HTTPS only, SSH with keys only; LuCI, Home Assistant and other devices' pages by name under the dynamic DNS one, with a Let's Encrypt certificate | `99-uci_config`, `99-acme_config`, `99-sites_config` |
| VPN | WireGuard server on UDP 51820, found through a dynamic DNS name | `99-wireguard_config`, `99-ddns_config` |
| Wi-Fi | A protected 2.4 GHz network, switched off | `99-wifi_config` |
| CPU | Current Intel microcode, loaded by the boot loader | `GRUB_MICROCODE`, or `99-zz_microcode` |

The scripts are in [files/etc/uci-defaults](files/etc/uci-defaults).
OpenWrt runs each of them once, on the first boot after a flash, so the image defines the
router's whole configuration. The names and addresses on this page are the defaults; what
can be chosen is listed under [Settings](#settings).

## Build

The inputs are all in this folder:

| File | Holds |
|---|---|
| `.env` | The [settings](#settings): everything that can be chosen about the image |
| `private/.env` | Your own values for those settings, and the private ones. Not in the repo |
| `packages.txt` | Packages added to, or removed from, the profile's defaults |
| `extra-packages.txt` | Packages from outside OpenWrt's feeds, each pinned to a download and its SHA-256 |
| `kmods/` | Kernel modules OpenWrt does not ship, built for the release with its SDK: the board's watchdog driver |
| `files/` | Files copied into the image, mainly the first-boot scripts |
| `private/files/` | The same, for files that should not be public. Not in the repo |

With Docker, from this folder:

```
mkdir -p binaries
docker compose run --rm imagebuilder
```

This first runs OpenWrt's SDK container for the same release, which builds the kernel
modules in `kmods/` into `kmods/out/`, and then the ImageBuilder, which puts them into the
image with everything else.

The images land in `binaries/`, next to a `.manifest` listing every package and version that
went in. The one to flash is `openwrt-*-ext4-combined-efi.img.gz`. It is the only kind built
unless `IMAGE_KINDS` asks for more. The downloaded packages stay in `dl/`, so the next build
only downloads what changed; the folder can be deleted at any time.

The containers run as user 1000. If that is not you, give them the folders first with
`mkdir -p dl kmods/out && chown 1000 binaries dl kmods/out`.

Without Docker, extract the SDK and the ImageBuilder for the release in `.env` and run
`SDK_DIR=/path/to/sdk kmods/build.sh`, then `IB_DIR=/path/to/imagebuilder ./build.sh`.

### With a self-built ImageBuilder

This branch builds with an ImageBuilder from OpenWrt's source, for changes not yet in a
release:
- the watchdog driver as `kmod-wdat-wdt`
  ([openwrt/openwrt#25966](https://github.com/openwrt/openwrt/pull/25966));
- the boot loader loading the CPU microcode, set by `GRUB_MICROCODE` in `.env`
  ([openwrt/openwrt#25997](https://github.com/openwrt/openwrt/pull/25997));
- procd's fixes for a service stopped right after it starts, which it otherwise
  force-kills 5 s later ([openwrt/openwrt#26003](https://github.com/openwrt/openwrt/issues/26003));
- the data partition's check at boot in the log, from `block` itself
  ([openwrt/fstools#23](https://github.com/openwrt/fstools/pull/23)).

The source is [MarcoMartins86/openwrt](https://github.com/MarcoMartins86/openwrt), branch
`odyssey-25.12.6`: the release in `.env` with those changes. It is built with the
release's own `config.buildinfo` and `feeds.buildinfo`, from
`downloads.openwrt.org/releases/<version>/targets/x86/64/`, without the SDK
(`CONFIG_SDK`, `CONFIG_SDK_LLVM_BPF`), the toolchain archive (`CONFIG_MAKE_TOOLCHAIN`) and
the kernel's debug files (`CONFIG_COLLECT_KERNEL_DEBUG`), and with no BPF compiler
(`CONFIG_BPF_TOOLCHAIN_NONE`): only `qosify`, `bridger` and `libxdp` need it, none of
them in the image, and building LLVM runs out of memory in WSL's 7 GB. Of the feeds,
only `dmx_usb_module` needs installing, the one kernel module from them in
`packages.txt`.

```
make -C ~/repo/openwrt-25.12 -j12
cd odyssey-x86j4125-imagebuilder
./local-ib.sh ~/repo/openwrt-25.12
IB_DIR="$(pwd)/local-ib" ./build.sh
```

`local-ib.sh` extracts the tree's ImageBuilder into `local-ib/` and copies the tree's
kernel modules into `kmods/out/`, in place of the SDK's. That kernel is not OpenWrt's, so
modules can only come from the tree: `apk add` on the router cannot add OpenWrt's. It also
puts the tree's procd and fstools packages into the ImageBuilder, whose release number is
above OpenWrt's. Every other package comes from the release's repositories as usual.

The images are compressed with `pigz`, on every core. Where it is missing, as in OpenWrt's
container, `build.sh` builds it from its source once and keeps it in `dl/`.

> **Note** A release keeps receiving package updates, so two builds some time apart can
> differ in package versions. Compare the manifests to see what changed.

## Settings

`.env` holds every choice with a default. To change one, put it into `private/.env`, which
is read after `.env` and is not in the repo; this keeps your own values out of a public
fork. The build writes the settings into the image, where the first-boot scripts read them.
Both files are read by the shell, so put a password or token in single quotes
(`WIFI_KEY='…'`): unquoted, the shell acts on characters such as `&`, `;` and spaces, and
inside double quotes still on `$`, `\` and backticks.

| Setting | Default | What it sets |
|---|---|---|
| `OPENWRT_VERSION` | `25.12.6` | OpenWrt release to build |
| `GRUB_MICROCODE` | `intel-ucode/06-7a-08` | Microcode file the boot loader hands to the kernel, with an ImageBuilder that has `CONFIG_GRUB_MICROCODE`; without one, or empty, `99-zz_microcode` sets it up on the first boot |
| `PROFILE` | `generic` | ImageBuilder profile |
| `ROOTFS_PARTSIZE` | `2048` | Root partition size in MB |
| `IMAGE_KINDS` | `ext4 efi` | Images to build: file systems `ext4` and `squashfs`, boot methods `efi` and `bios`, and `targz` for the root file system as an archive. One image per file system and boot method |
| `ROUTER_NAME` | `odyssey` | Host name; the HTTPS certificate is issued to `<name>.lan` |
| `LAN_ADDRESS` | `192.168.2.1/24` | The router's LAN address and the size of the network |
| `IPV6` | `0` | `1` keeps OpenWrt's IPv6 on the WAN and the LAN; `0` switches it off, for a connection without IPv6, and has unbound ask name servers over IPv4 only |
| `TIMEZONE` | `Europe/Lisbon` | Time zone, by the name LuCI lists |
| `WAN_DNS_CLIENTS` | empty | Network on the WAN side whose devices may use the router's DNS; empty keeps DNS closed there |
| `BACKUP_WAN` | `1` | `1` fails the network over to a USB-tethered phone when the ISP WAN is down (mwan3); `0` keeps the backup interface but not the automatic failover |
| `WIFI_SSID` | `odyssey-admin` | Name of the Wi-Fi network that is kept switched off |
| `VPN_PORT` | `51820` | UDP port of the WireGuard server |
| `VPN_ADDRESS` | `10.8.0.1/24` | The server's address in the range VPN devices get |
| `ADBLOCK_FEEDS` | 17 feeds | Adblock's blocklists. Adblock merges them into one list without repeats |
| `ADBLOCK_HAGEZI_CATEGORIES` | `multi-pro threat-intelligence.medium doh` | Categories taken from the hagezi feed |
| `ADBLOCK_STEVENBLACK_CATEGORIES` | `standard` | Categories taken from the stevenblack feed |
| `ADBLOCK_UTCAPITOLE_CATEGORIES` | ads and security | Categories taken from the utcapitole feed |
| `ADBLOCK_REFRESH_HOUR` | `5` | Hour of the night at which adblock downloads its lists again; empty never does |
| `ADBLOCK_REPORT_MB` | `100` | MB of DNS traffic kept in memory for adblock's DNS report, `10` to `100` in steps of 10 |
| `ADBLOCK_MAP` | `1` | Map of blocked domains in the DNS report, which sends their addresses to ip-api.com |
| `BANIP_FEEDS` | 5 feeds | banIP's blocklists |
| `BANIP_REFRESH_HOUR` | `4` | Hour of the night at which banIP checks its feeds for newer lists, at half past; empty never does |
| `GUEST_SHARE` | `share` | Network name of the open SMB folder; empty switches file sharing off |
| `LETSENCRYPT` | `1` | A Let's Encrypt certificate for the names under `DDNS_HOST`, on DuckDNS, and the [sites by name](#sites-by-name); empty for none, `staging` for Let's Encrypt's test service |
| `SITES` | (empty) | More [sites by name](#sites-by-name): `name=address` pairs, separated by spaces |
| `HOME_ASSISTANT` | `1` | Home Assistant as a container; `0` leaves it out |
| `HOME_ASSISTANT_NAME` | `ha` | Its name under `DDNS_HOST`, with the certificate |
| `ZIGBEE_DEVICE` | `/dev/ttyUSB0` | Zigbee stick handed to Home Assistant; empty for none |
| `CONTAINER_UPDATE_DAY` | `15` | Day of the month on which the containers get their newest images; empty for never |
| `LUCI_THEME` | `argon` | Theme LuCI starts with |

Private settings, which only make sense in `private/.env`:

| Setting | What it sets |
|---|---|
| `DDNS_PROVIDER`, `DDNS_HOST`, `DDNS_TOKEN` | Dynamic DNS: the provider (`duckdns.org`, or another of the names in `/usr/share/ddns/default` on the router), the name that follows the home's public address, and its token. Without them dynamic DNS stays off |
| `DDNS_USER` | Account name, for providers that ask for one next to the token |
| `WIFI_KEY` | Password of the Wi-Fi network, 8 to 63 characters, which every flash brings back. Without it the first boot makes one up, which flashes keep |
| `KEY`, `KNOWN_HOSTS` | For `flash.sh`: the SSH private key to log in with, and the file holding the router's host key |
| `ROUTER`, `PORT` | For `flash.sh`: where to reach the router, if not at the address in `LAN_ADDRESS` on port 22 |

## SSH access

SSH only accepts keys, so put the public keys allowed to log in as root into
`private/files/etc/dropbear/authorized_keys` before building. Without it the router can only
be managed from LuCI.

## Backup internet

When the ISP connection drops, the router can fall back to a phone's mobile data, tethered
over a USB cable, so the whole network stays online without touching each device. It is set
up in [files/etc/uci-defaults/99-mwan3_config](files/etc/uci-defaults/99-mwan3_config) and
turned on by `BACKUP_WAN` (see [Settings](#settings)).

- **The phone** becomes the `wwan` interface, in the WAN firewall zone. An Android phone:
  plug it in and turn on **USB tethering** in its settings. An iPhone: turn on **Personal
  Hotspot**, plug it in, and tap **Trust** the first time; `usbmuxd` pairs it, and a flash
  keeps the pairing. Images carry
  the drivers for both (RNDIS/CDC and `ipheth`). The kernel names the tether `usb0` on some
  phones and `eth2` on others (iOS does), so a hotplug script
  ([30-phone-tether](files/etc/hotplug.d/net/30-phone-tether)) binds whichever one appears,
  matched by driver so it never touches the real LAN/WAN ports.
- **mwan3** watches both links by pinging `1.1.1.1` and `8.8.8.8` through each. The ISP WAN
  is preferred; five misses in a row (about 40 seconds, not a single blip) fail the network
  over to the phone, and five good replies bring it back. This catches an ISP that is down
  while the WAN cable's link stays up — the case a plain cable-based failover misses, and the
  one watchcat only restarts the WAN for. Each restart brings the WAN up counted as down, so
  it has to answer before it takes the network back from the phone; a dead ISP never does.
- **DNS rides through it.** unbound restarts only for LAN changes, so watchcat's restarts of
  the WAN leave it running. When mwan3 finds a link working again, a hook
  ([96-unbound](files/etc/hotplug.d/iface/96-unbound)) clears what unbound learned while
  there was no internet; otherwise every lookup could fail for up to 15 minutes.
- **While the ISP is up the phone is a standby** and carries no traffic. On failover the
  whole network uses the phone's data, so watch a metered plan; `BACKUP_WAN=0` keeps the
  interface ready but leaves the switch-over to be done by hand in LuCI (Network → Load
  Balancing).
- **Check it** with `mwan3 status` and `mwan3 interfaces` over SSH. To test, pull the WAN
  cable with the phone tethered: the network should keep working within half a minute.

## VPN

The router runs a WireGuard server. Devices connecting to it get an address in
`10.8.0.0/24` and reach the router, the LAN and, if they send everything through the tunnel,
the internet. They use the router's DNS, so ad blocking applies to them as well.

- **Dynamic DNS**: so that devices find the router from outside, a name at a dynamic DNS
  provider follows the home's public address. Put the provider, the name and its token into
  `private/.env` before building, for [DuckDNS](https://www.duckdns.org) as
  `DDNS_PROVIDER=duckdns.org`, `DDNS_HOST=name.duckdns.org` and `DDNS_TOKEN=...`. Without
  them dynamic DNS stays off.
- **Behind another router**: forward the VPN's UDP port to this one.
- **Adding a device**: in LuCI under Network → Interfaces → wg0 → Edit → Peers, choose
  Add peer, then Generate new key pair, and give it the next free address under Allowed IPs
  (`10.8.0.2/32`, `10.8.0.3/32`, ...). Generate configuration… then shows a QR code for the
  WireGuard app. As DNS server for the device use `10.8.0.1`, and as endpoint the dynamic DNS
  name, or a name under it that is not one of the [sites](#sites-by-name), such as
  `vpn.name.duckdns.org`.

## Sites by name

With dynamic DNS on DuckDNS, the router gets a [Let's Encrypt](https://letsencrypt.org)
certificate for every name under its DuckDNS one, and serves its sites by those names,
without a browser warning, from the LAN and the VPN:

| Name | Site |
|---|---|
| `odyssey.name.duckdns.org` | LuCI; the name is `ROUTER_NAME` |
| `ha.name.duckdns.org` | Home Assistant; the name is `HOME_ASSISTANT_NAME` |
| Each one in `SITES` | Another device's web page, such as `xeroca=https://192.168.2.50` for a printer |

`LETSENCRYPT=` (empty) leaves all of it out, and LuCI keeps port 443 to itself.

- **How**: acme.sh proves the name to Let's Encrypt with a DNS record it sets at DuckDNS, so
  nothing is opened to the outside. It asks for the certificate when the WAN first comes up,
  and renews it when due, after 60 of its 90 days, checking every night and whenever the WAN
  comes up. DuckDNS holds one such record at a time, so the certificate covers the names under
  the DuckDNS one (`*.name.duckdns.org`), not that name itself.
- **nginx** takes ports 80 and 443 and passes each name on to its site. LuCI's own web server
  moves to port 8443, where it stays reachable directly, at `https://192.168.2.1:8443`, should
  nginx fail. A device in `SITES` keeps its own certificate; browsers only see the router's.
- **The names in the LAN and the VPN** lead to the router; everyone else gets the home's
  public address, where nothing is open. VPN devices connect to the VPN by a name the router
  leaves alone, such as `vpn.name.duckdns.org`: DuckDNS answers every name under its own with
  the home's address, and a device asking through the tunnel cannot lose its way back.
- **Flashing** keeps the account and the certificate, which live on the data partition, so
  a flash does not ask Let's Encrypt for a new one.
- **`odyssey.lan` and the address** still open LuCI, with a browser warning. If renewals stop,
  for example without DuckDNS, the certificate expires after 90 days, and every name shows the
  warning.
- **Home Assistant** needs two things set once, in its own settings under Settings → System →
  Network → HTTP server:
  - SSL/TLS: SSL certificate path `/config/ssl/fullchain.pem`, SSL key path
    `/config/ssl/privkey.pem`. The router keeps both files current, and restarts it after
    every renewal.
  - Reverse proxy: switch on Trust X-Forwarded-For, and add `127.0.0.1` and `::1` under
    Trusted proxies. Without that it refuses what comes through nginx.

  Save, and confirm the change within 5 minutes of its restart, or it rolls back. Until then
  `https://ha.name.duckdns.org:8123` reaches it directly. Afterwards, point the companion app
  and its Home Assistant URL for the local network at `https://ha.name.duckdns.org`.
- **Trying it out**: `LETSENCRYPT=staging` asks Let's Encrypt's test service, whose
  certificates browsers do not trust, without counting against its limit of 5 identical
  certificates a week.

## Containers

Every folder in `files/etc/compose` is a Docker Compose project. The router brings them up
at boot (`/etc/init.d/compose`): a project already running as defined is left alone, a
changed one is recreated, and a missing image is downloaded first. A blank disk therefore
ends up with the containers running, without anything done by hand.

[Home Assistant](https://www.home-assistant.io) is the one project so far, reachable at
`http://odyssey.lan:8123`, or `https://ha.name.duckdns.org` with the
[sites by name](#sites-by-name). Its settings are in `/mnt/data/homeassistant/config` on the data
partition. It is handed the Zigbee stick named in `ZIGBEE_DEVICE` and does not start while
that device is missing; with the setting empty it runs without one. `HOME_ASSISTANT=0`
leaves it out altogether.

Once a month, on the day in `CONTAINER_UPDATE_DAY` at 04:00, `/etc/init.d/compose update`
downloads the newest images of the projects' tags and recreates the containers that use
them; it also works by hand. The image an update replaces stays for about two months, to
go back to. A restart or a flash updates nothing, as the images are kept on the data
partition.

## Test

`test/smoke.sh` boots the built image in QEMU and checks that the first boot did its job.
Then it powers the VM off and checks that the data partition was unmounted cleanly. It needs
`qemu-system-x86`, `ovmf`, `sfdisk` and `debugfs`, and exits with 0 when every check passes.
The virtual router emulates the real one's processor, so without `GRUB_MICROCODE` its first
boot also prepares the processor's microcode and restarts once, as the router does after a
flash. Its WAN port
gets an address but no internet, unless `WAN=online` is set: a fresh VM would otherwise
download every adblock list and the Home Assistant image at every boot, from the address of
the network the machine is on. CI sets it, as those downloads come from GitHub's network
there.

`test/watchdog.sh` checks the hardware watchdog in the same virtual router: procd has to be
feeding it, and once procd lets go, the watchdog has to reset the VM by itself. It takes
about three minutes, so the smoke test only checks the feeding. The VM gets a copy of the
router's ACPI watchdog table, made by `test/wdat-table.py` for QEMU's emulation of the same
chip.

To look around by hand, `test/start.sh` starts the same virtual router and
`test/ser.py sh 60 '<command>'` runs a command on its console. SSH is forwarded to port 2222
and LuCI to port 8080 on `127.0.0.1`.

## Checks and updates

Every pull request, and every change to `main`, is built on GitHub with the settings in
`.env` and booted for `test/smoke.sh` ([build.yml](../.github/workflows/build.yml)). That build
uses no secrets, so its image has none of the private settings; the image to flash is built
on your own machine as above. The run keeps the image's package list and the console of the
test boot.

[Renovate](https://docs.renovatebot.com/) opens a pull request when a new OpenWrt release
has its ImageBuilder container, and when the build's GitHub actions get new versions, so
every update is built and tested before it is merged ([renovate.json](../renovate.json)). It
needs the [Renovate app](https://github.com/apps/renovate) installed on the repository.

- A new release of a package in `extra-packages.txt` only shows up on Renovate's dependency
  dashboard, an issue it keeps open in the repository. The file names and checksums change
  with it and have to be filled in by hand, so its pull request is opened from there when
  wanted.
- Home Assistant is not tracked. It follows its `stable` tag, and the router moves to the
  newest image once a month (see [Containers](#containers)).

Within a release OpenWrt keeps updating packages, security fixes among them, and the router
only gets them with a new image. So every Monday the same build and test run on `main`, and
when its package list differs from the previous good build there, an issue labelled
`package-updates` lists what changed; while one is open, later changes are added to it.
Close it once the router is flashed. GitHub pauses scheduled runs in a repository that has
seen no activity for 60 days; Actions lets you switch them on again.

## Flash

For a router already running this image:

```
./flash.sh
```

It uploads the image built for `OPENWRT_VERSION` (or the one named after it, as in
`./flash.sh binaries/<file>.img.gz`), checks it, and upgrades the router over SSH. Upload over
a wired link: the 150 MB image can swamp a slow Wi-Fi hop on the way. Docker is stopped first,
so that containers shut down cleanly; they start again by themselves after the flash. The
SSH key and known-hosts file come from `private/.env`, see [Settings](#settings).

Before that it saves a backup of the router's whole configuration to `private/backups/`, the
last five per router. To go back, flash the previous image and restore the backup with
`sysupgrade -r <file>` on the router, or in LuCI under System → Backup / Flash Firmware.

What a flash keeps and what it replaces:

| | |
|---|---|
| Kept | Root password, SSH host keys, HTTPS certificate, the Wi-Fi password, the VPN key and its devices, the tethered iPhone's pairing, everything on the data partition |
| Replaced | The whole configuration, which the first-boot scripts write again |

Without `GRUB_MICROCODE`, the router restarts once more by itself after the flash, to
load the CPU microcode.

For a first install, or to recover a router that does not boot, write the image from a live
Linux USB stick instead (`F7` at power on opens the boot menu):

```
gzip -dc openwrt-*-ext4-combined-efi.img.gz | dd of=/dev/sda bs=4M
```

A fresh install has no root password. Set one in LuCI under System → Administration; later
flashes carry it over.

## Disk layout

| Partition | Size | Use |
|---|---|---|
| Boot | 16 MB | Boot loader and kernel |
| Root | 2 GB | The system. Fixed size, rewritten by every flash |
| Data | From the 4 GB mark to the end of the disk | Docker, statistics history, the system log, adblock's and banIP's lists, the shared folder. Mounted at `/mnt/data` |

The data partition is created on the first boot and only formatted if it does not already
exist, so it survives reflashing. Every boot checks it with e2fsck before mounting it, the
first one after a flash included: a quick look when it is clean, a full check with repairs when the kernel has found an error on
it. The report goes to the system log under `e2fsck`. Every Sunday at 03:30 both partitions hand the SSD their
free space (TRIM), so that it stops keeping deleted data around. The root partition keeps its size so that an upgrade finds
the layout unchanged and leaves the rest of the disk alone. The gap up to the 4 GB mark lets
the root partition grow later without moving the data.

## Good to know

- **Wi-Fi** is off. The built-in Intel card only works as an access point on 2.4 GHz. To
  switch it on: `uci set wireless.default_radio0.disabled=0; uci commit wireless; wifi up`.
  Its password is `WIFI_KEY` from `private/.env`, or one the first boot made up; LuCI shows
  it, and it is in `/etc/odyssey/wifi.key`.
- **Docker** does not manage firewall rules here. Containers on Docker's default network
  reach the internet; a compose project needs `network_mode: bridge` or `host`, because the
  firewall does not know the networks compose creates. On reboot and poweroff, Docker is
  stopped first (`shutdown` in `/etc/init.d/compose`) and gives each container up to 20
  seconds to shut down. Just before the data partition is unmounted, `/etc/init.d/release_data`
  ends whatever still uses it, such as a container slower than that or adblock in the middle
  of a refresh, says so in the system log, and makes the partition read-only, so that it is
  left clean.
- **Themes**: LuCI starts with Argon. Footstrap and the stock ones are installed next to
  it; pick another in LuCI under System → System → Language and Style. Argon's login page
  keeps a local background. System → Argon Config switches on online wallpapers, picks the
  login layout and colours, and takes an uploaded background, logo or browser icon; flashes
  keep all of it. Argon 3 includes that page, so `luci-app-argon-config` is not installed. After
  an update, the browser may need a forced reload (Ctrl+F5) to show its icons.
- **Behind another router**: its devices do not pass through this one, but they can still
  use its DNS and get the ad blocking. Set `WAN_DNS_CLIENTS` to their network and make the
  other router hand out this router's WAN address as DNS server. Nothing forces them to use
  it: a device that brings its own DNS, or takes the one the other router announces over
  IPv6, goes around it.
- **Encrypted DNS**: DNS over TLS (port 853) to a service outside is cut off on the LAN and
  the VPN, as it would go around the ad blocking. Most devices then fall back to plain DNS.
  An Android phone with a provider's name under Private DNS does not: it reports "Private
  DNS server cannot be accessed" and has no internet here until that setting is back on
  Automatic. DNS over HTTPS cannot be told apart by its port; the `doh_blocklist` feed and
  hagezi's `doh` category block the names of its providers instead.
- **Settings LuCI adds by itself**: LuCI stores some defaults only when a page or dialog is
  saved, and they then appear as changes nobody asked for. `99-zy_luci_defaults` writes them
  beforehand, without changing how the router behaves. Two settings are more than cosmetic
  and sit in the scripts of their services: without `enabled` in the unbound configuration,
  saving LuCI's page for it stops the DNS server, and without `use_ipv6` in a dynamic DNS
  service, saving its dialog removes the service's settings.
- **Watchdog**: the board's chipset has a hardware watchdog that restarts it when the
  system stops answering, and its firmware describes it in an ACPI WDAT table. OpenWrt's
  kernel has no driver that reads that table, so `kmods/wdat-wdt` builds Linux's own
  (`wdat_wdt`, copied unchanged from Linux 6.12.94) as a separate module. procd feeds the
  watchdog every 5 s; when the system stops feeding it for 30 s, the board restarts.
  `ubus call system watchdog` shows it as `running`.
- **System log**: besides the 1 MB in memory that LuCI shows under Status → System Log,
  every line goes to `/mnt/data/log/messages` as it is logged, and survives a restart, a
  power cut or the watchdog. Past 1 MB the file becomes `messages.old`, so the two keep one
  to two weeks. Only the lines from before the log service starts at boot, mostly the
  kernel's, stay in memory alone (`dmesg`), as does all of the first boot after a flash,
  which restarts before that point to load the microcode. Each line costs about 17 KB of
  disk writes, as it is written out on its own; about 20 MB a day here.
- **Statistics** are collected in memory and written to disk every 15 minutes, as each write
  touches every graph's file. The graphs can be that much behind.
- **Internet watch**: watchcat pings 1.1.1.1 and 8.8.8.8 over the WAN port every 30 seconds.
  When neither has answered for 10 minutes, it restarts the WAN interface, as unplugging and
  plugging its cable would, and again every 10 minutes while the internet stays away. Nothing
  else restarts. It cannot help when the ISP's box in front of the router has lost its own
  connection; that box needs restarting then. During an outage it logs every failed ping.
- **SSD health**: smartd reads the SSD's own health record (SMART) every 30 minutes. It
  writes to the system log when a counter that points to failing flash goes up, or when the
  temperature reaches 60 °C (critical from 70 °C). Statistics → Graphs → Disk Health shows
  the temperature, the data written over the disk's life, how often each flash block has
  been erased on average, which is the actual wear, and the errors, which stay at 0 on a
  healthy disk. `smartctl -x /dev/sda` shows everything the disk reports. The SSD counts the
  data written in GiB; the router adds about 150 MB a day.
- **A new OpenWrt release** means changing `OPENWRT_VERSION` in `.env`, building, running
  the smoke test and flashing. When it moves to a new kernel series, the copy of
  `wdat_wdt.c` in `kmods/wdat-wdt/src` may need replacing with that kernel's.
