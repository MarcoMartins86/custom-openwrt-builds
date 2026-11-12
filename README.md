# custom-openwrt-builds

Custom [OpenWrt](https://openwrt.org) images, built from the files in this repo. Each folder
holds one router's build: its settings, packages, first-boot scripts and tests, and a README
on how to build, test and flash it.

| Folder | Router |
|---|---|
| [asus-wl-320ge](asus-wl-320ge) | An [ASUS WL-320gE](https://openwrt.org/toh/asus/wl-320g) as a Wi-Fi access point, bridged into the main router's network or extending an existing Wi-Fi as a repeater over the air, on OpenWrt 25.12 in 4 MB of flash and 16 MB of memory: stateless, with hostapd on its own, a patched b43 for access-point-and-station at once, and a trimmed kernel. Built from OpenWrt's source |
| [seeed-odyssey-x86j4125](seeed-odyssey-x86j4125) | A [Seeed ODYSSEY-X86J4125](https://wiki.seeedstudio.com/ODYSSEY-X86J4105/) as a home router, on OpenWrt 25.12: ad blocking, a VPN, Docker with Home Assistant, sites by name with a Let's Encrypt certificate. Built with OpenWrt's ImageBuilder, nothing compiled |
| [tl-wpa7510-v2](tl-wpa7510-v2) | The extender of a [TP-Link TL-WPA7510 v2](https://www.tp-link.com/support/download/tl-wpa7510-kit/) powerline kit as a dual-band Wi-Fi access point bridged into the main router's network over the powerline, on OpenWrt's development version with a port for the device that OpenWrt does not have yet: a trimmed kernel, WPA2 on both bands, and a daemon that loads the powerline chip. Built from the source of a fork of OpenWrt |
| [tl-wr941nd-v3](tl-wr941nd-v3) | A [TP-Link TL-WR941ND v3](https://openwrt.org/toh/tp-link/tl-wr941nd) as a Wi-Fi access point bridged into the main router's network, on OpenWrt 25.12 in 4 MB of flash and 32 MB of memory, which OpenWrt stopped building images for after 19.07: stateless, with a trimmed kernel and fixes for its switch and bridge. Built from OpenWrt's source |

Shared by the builds:

- **[.github/workflows](.github/workflows):** one workflow per build, which builds and tests
  every pull request and every change to `main` that touches that build's folder.
- **[renovate.json](renovate.json):** [Renovate](https://docs.renovatebot.com) watches the
  versions a build depends on and opens a pull request for each new one.
