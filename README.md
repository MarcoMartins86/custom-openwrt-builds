# custom-openwrt-builds

Custom [OpenWrt](https://openwrt.org) images, built from the files in this repo.

## odyssey-x86j4125-imagebuilder

An OpenWrt 25.12 image that turns a [Seeed ODYSSEY-X86J4125](https://wiki.seeedstudio.com/ODYSSEY-X86J4105/)
into a home router. It is built with OpenWrt's
[ImageBuilder](https://openwrt.org/docs/guide-user/additional-software/imagebuilder), using the
[container OpenWrt publishes](https://github.com/openwrt/docker), so nothing is compiled.

What the router does once flashed:

| Area | Setup | Configured in |
|---|---|---|
| Network | LAN `192.168.2.1/24` on the first port, WAN by DHCP on the second | `99-uci_config` |
| DNS and DHCP | unbound with DNSSEC, odhcpd, local names under `.lan` | `99-unbound_config` |
| Ad blocking | adblock on unbound, lists refreshed every night, DNS forced through the router, DNS over TLS to outside cut off, DNS report for every network | `99-adblock_config` |
| Firewall | OpenWrt's firewall plus banIP blocklists | `99-banip_config` |
| Containers | Docker, with OpenWrt's firewall as the only firewall | `99-docker_config` |
| Home automation | Home Assistant as a container, with a Zigbee stick | `99-homeassistant_config` |
| File sharing | One open SMB folder, `\\odyssey\share` | `99-ksmbd_config` |
| Monitoring | Statistics graphs with history on disk, nlbwmon | `99-statistics_config`, `99-nlbwmon_config` |
| Access | LuCI over HTTPS only, SSH with keys only | `99-uci_config` |
| VPN | WireGuard server on UDP 51820, found through a dynamic DNS name | `99-wireguard_config`, `99-ddns_config` |
| Wi-Fi | A protected 2.4 GHz network, switched off | `99-wifi_config` |
| CPU | Current Intel microcode, loaded by the boot loader | `99-zz_microcode` |

The scripts are in [files/etc/uci-defaults](odyssey-x86j4125-imagebuilder/files/etc/uci-defaults).
OpenWrt runs each of them once, on the first boot after a flash, so the image defines the
router's whole configuration. The names and addresses on this page are the defaults; what
can be chosen is listed under [Settings](#settings).

### Build

The inputs are all in [odyssey-x86j4125-imagebuilder](odyssey-x86j4125-imagebuilder):

| File | Holds |
|---|---|
| `.env` | The [settings](#settings): everything that can be chosen about the image |
| `private/.env` | Your own values for those settings, and the private ones. Not in the repo |
| `packages.txt` | Packages added to, or removed from, the profile's defaults |
| `extra-packages.txt` | Packages from outside OpenWrt's feeds, each pinned to a download and its SHA-256 |
| `files/` | Files copied into the image, mainly the first-boot scripts |
| `private/files/` | The same, for files that should not be public. Not in the repo |

With Docker:

```
cd odyssey-x86j4125-imagebuilder
mkdir -p binaries
docker compose run --rm imagebuilder
```

The images land in `binaries/`, next to a `.manifest` listing every package and version that
went in. The one to flash is `openwrt-*-ext4-combined-efi.img.gz`. It is the only kind built
unless `IMAGE_KINDS` asks for more.

The container runs as user 1000. If that is not you, give it the folder first with
`chown 1000 binaries`.

Without Docker, extract the ImageBuilder for the release in `.env` and run
`IB_DIR=/path/to/imagebuilder ./build.sh`. Such a build compresses the images on every core
when `pigz` is installed; the container does not have it and uses one.

> **Note** A release keeps receiving package updates, so two builds some time apart can
> differ in package versions. Compare the manifests to see what changed.

### Settings

`.env` holds every choice with a default. To change one, put it into `private/.env`, which
is read after `.env` and is not in the repo; this keeps your own values out of a public
fork. The build writes the settings into the image, where the first-boot scripts read them.

| Setting | Default | What it sets |
|---|---|---|
| `OPENWRT_VERSION` | `25.12.5` | OpenWrt release to build |
| `PROFILE` | `generic` | ImageBuilder profile |
| `ROOTFS_PARTSIZE` | `2048` | Root partition size in MB |
| `IMAGE_KINDS` | `ext4 efi` | Images to build: file systems `ext4` and `squashfs`, boot methods `efi` and `bios`, and `targz` for the root file system as an archive. One image per file system and boot method |
| `ROUTER_NAME` | `odyssey` | Host name; the HTTPS certificate is issued to `<name>.lan` |
| `LAN_ADDRESS` | `192.168.2.1/24` | The router's LAN address and the size of the network |
| `TIMEZONE` | `Europe/Lisbon` | Time zone, by the name LuCI lists |
| `WAN_DNS_CLIENTS` | empty | Network on the WAN side whose devices may use the router's DNS; empty keeps DNS closed there |
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
| `GUEST_SHARE` | `share` | Network name of the open SMB folder; empty switches file sharing off |
| `HOME_ASSISTANT` | `1` | Home Assistant as a container; `0` leaves it out |
| `ZIGBEE_DEVICE` | `/dev/ttyUSB0` | Zigbee stick handed to Home Assistant; empty for none |
| `LUCI_THEME` | `argon` | Theme LuCI starts with |

Private settings, which only make sense in `private/.env`:

| Setting | What it sets |
|---|---|
| `DDNS_PROVIDER`, `DDNS_HOST`, `DDNS_TOKEN` | Dynamic DNS: the provider (`duckdns.org`, or another of the names in `/usr/share/ddns/default` on the router), the name that follows the home's public address, and its token. Without them dynamic DNS stays off |
| `DDNS_USER` | Account name, for providers that ask for one next to the token |
| `KEY`, `KNOWN_HOSTS` | For `flash.sh`: the SSH private key to log in with, and the file holding the router's host key |
| `ROUTER`, `PORT` | For `flash.sh`: where to reach the router, if not at the address in `LAN_ADDRESS` on port 22 |

### SSH access

SSH only accepts keys, so put the public keys allowed to log in as root into
`private/files/etc/dropbear/authorized_keys` before building. Without it the router can only
be managed from LuCI.

### VPN

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
  WireGuard app. As DNS server for the device use `10.8.0.1`.

### Containers

Every folder in `files/etc/compose` is a Docker Compose project. The router brings them up
at boot (`/etc/init.d/compose`): a project already running as defined is left alone, a
changed one is recreated, and a missing image is downloaded first. A blank disk therefore
ends up with the containers running, without anything done by hand.

[Home Assistant](https://www.home-assistant.io) is the one project so far, reachable at
`http://odyssey.lan:8123`. Its settings are in `/mnt/data/homeassistant/config` on the data
partition. It is handed the Zigbee stick named in `ZIGBEE_DEVICE` and does not start while
that device is missing; with the setting empty it runs without one. `HOME_ASSISTANT=0`
leaves it out altogether.

Nothing updates by itself. `/etc/init.d/compose update` downloads newer images and
recreates the containers that use them.

### Test

`test/smoke.sh` boots the built image in QEMU and checks that the first boot did its job.
It needs `qemu-system-x86` and `ovmf`, and exits with 0 when every check passes.

To look around by hand, `test/start.sh` starts the same virtual router and
`test/ser.py sh 60 '<command>'` runs a command on its console. SSH is forwarded to port 2222
and LuCI to port 8080 on `127.0.0.1`.

### Flash

For a router already running this image:

```
./flash.sh
```

It uploads the image, checks it, and upgrades the router over SSH. Docker is stopped first,
so that containers shut down cleanly; they start again by themselves after the flash. The
SSH key and known-hosts file come from `private/.env`, see [Settings](#settings).

What a flash keeps and what it replaces:

| | |
|---|---|
| Kept | Root password, SSH host keys, HTTPS certificate, the Wi-Fi password, the VPN key and its devices, everything on the data partition |
| Replaced | The whole configuration, which the first-boot scripts write again |

After the flash the router restarts once more by itself, to load the CPU microcode.

For a first install, or to recover a router that does not boot, write the image from a live
Linux USB stick instead (`F7` at power on opens the boot menu):

```
gzip -dc openwrt-*-ext4-combined-efi.img.gz | dd of=/dev/sda bs=4M
```

A fresh install has no root password. Set one in LuCI under System → Administration; later
flashes carry it over.

### Disk layout

| Partition | Size | Use |
|---|---|---|
| Boot | 16 MB | Boot loader and kernel |
| Root | 2 GB | The system. Fixed size, rewritten by every flash |
| Data | From the 4 GB mark to the end of the disk | Docker, statistics history, adblock's lists, the shared folder. Mounted at `/mnt/data` |

The data partition is created on the first boot and only formatted if it does not already
exist, so it survives reflashing. The root partition keeps its size so that an upgrade finds
the layout unchanged and leaves the rest of the disk alone. The gap up to the 4 GB mark lets
the root partition grow later without moving the data.

### Good to know

- **Wi-Fi** is off. The built-in Intel card only works as an access point on 2.4 GHz. To
  switch it on: `uci set wireless.default_radio0.disabled=0; uci commit wireless; wifi up`.
  Its password is in LuCI and in `/etc/odyssey/wifi.key`.
- **Docker** does not manage firewall rules here. Containers on Docker's default network
  reach the internet; a compose project needs `network_mode: bridge` or `host`, because the
  firewall does not know the networks compose creates.
- **Themes**: LuCI starts with Argon. Footstrap and the stock ones are installed next to
  it; pick another in LuCI under System → System → Language and Style. Argon's login page
  keeps a local background; its online wallpapers can be switched on under System → Argon
  Config.
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
- **DNS root keys**: `files/etc/unbound/root.key` holds the keys unbound trusts for DNSSEC,
  taken from [IANA](https://data.iana.org/root-anchors/root-anchors.xml). The copy in
  OpenWrt's package lacks the key the root zone is signed with since 11 October 2026, and
  with that copy every lookup fails as soon as the DNS server restarts. When the root key
  changes again, add its line here.
- **Settings LuCI adds by itself**: LuCI stores some defaults only when a page or dialog is
  saved, and they then appear as changes nobody asked for. `99-zy_luci_defaults` writes them
  beforehand, without changing how the router behaves. Two settings are more than cosmetic
  and sit in the scripts of their services: without `enabled` in the unbound configuration,
  saving LuCI's page for it stops the DNS server, and without `use_ipv6` in a dynamic DNS
  service, saving its dialog removes the service's settings.
- **A new OpenWrt release** means changing `OPENWRT_VERSION` in `.env`, building, running
  the smoke test and flashing.
