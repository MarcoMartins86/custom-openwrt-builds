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
| Ad blocking | adblock on unbound, DNS forced through the router, DNS report | `99-adblock_config` |
| Firewall | OpenWrt's firewall plus banIP blocklists | `99-banip_config` |
| Containers | Docker, with OpenWrt's firewall as the only firewall | `99-docker_config` |
| File sharing | One open SMB folder, `\\odyssey\share` | `99-ksmbd_config` |
| Monitoring | Statistics graphs with history on disk, nlbwmon | `99-statistics_config`, `99-nlbwmon_config` |
| Access | LuCI over HTTPS only, SSH with keys only | `99-uci_config` |
| Wi-Fi | A protected 2.4 GHz network, switched off | `99-wifi_config` |
| CPU | Current Intel microcode, loaded by the boot loader | `99-zz_microcode` |

The scripts are in [files/etc/uci-defaults](odyssey-x86j4125-imagebuilder/files/etc/uci-defaults).
OpenWrt runs each of them once, on the first boot after a flash, so the image defines the
router's whole configuration.

### Build

The inputs are all in [odyssey-x86j4125-imagebuilder](odyssey-x86j4125-imagebuilder):

| File | Holds |
|---|---|
| `.env` | OpenWrt release, ImageBuilder profile, root partition size |
| `packages.txt` | Packages added to, or removed from, the profile's defaults |
| `files/` | Files copied into the image, mainly the first-boot scripts |
| `private/files/` | The same, for files that should not be public. Not in the repo |

With Docker:

```
cd odyssey-x86j4125-imagebuilder
mkdir -p binaries
docker compose run --rm imagebuilder
```

The images land in `binaries/`, next to a `.manifest` listing every package and version that
went in. The one to flash is `openwrt-*-ext4-combined-efi.img.gz`.

The container runs as user 1000. If that is not you, give it the folder first with
`chown 1000 binaries`.

Without Docker, extract the ImageBuilder for the release in `.env` and run
`IB_DIR=/path/to/imagebuilder ./build.sh`.

> **Note** A release keeps receiving package updates, so two builds some time apart can
> differ in package versions. Compare the manifests to see what changed.

### SSH access

SSH only accepts keys, so put the public keys allowed to log in as root into
`private/files/etc/dropbear/authorized_keys` before building. Without it the router can only
be managed from LuCI.

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

It uploads the image, checks it, and upgrades the router over SSH. The address, SSH key and
known-hosts file can be set in `private/flash.env` as `ROUTER`, `KEY` and `KNOWN_HOSTS`.

What a flash keeps and what it replaces:

| | |
|---|---|
| Kept | Root password, SSH host keys, HTTPS certificate, the Wi-Fi password, everything on the data partition |
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
| Data | From the 4 GB mark to the end of the disk | Docker, statistics history, the shared folder. Mounted at `/mnt/data` |

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
- **A new OpenWrt release** means changing `OPENWRT_VERSION` in `.env`, building, running
  the smoke test and flashing.
