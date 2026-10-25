# custom-openwrt-builds

Custom [OpenWrt](https://openwrt.org) images, built from the files in this repo. Each folder
holds one router's build: its settings, packages, first-boot scripts and tests, and a README
on how to build, test and flash it.

| Folder | Router |
|---|---|
| [odyssey-x86j4125-imagebuilder](odyssey-x86j4125-imagebuilder) | A [Seeed ODYSSEY-X86J4125](https://wiki.seeedstudio.com/ODYSSEY-X86J4105/) as a home router, on OpenWrt 25.12: ad blocking, a VPN, Docker with Home Assistant, sites by name with a Let's Encrypt certificate. Built with OpenWrt's ImageBuilder, nothing compiled |
| [tl-wr941nd-v4](tl-wr941nd-v4) | A [TP-Link TL-WR941ND v4](https://openwrt.org/toh/tp-link/tl-wr941nd) as a Wi-Fi access point bridged into the main router's network, on OpenWrt 25.12. It has 4 MB of flash and 32 MB of memory, which OpenWrt stopped building images for after 19.07, so this image is built from OpenWrt's source with everything an access point does without left out |

Shared by the builds:

- **[.github/workflows](.github/workflows):** builds and tests the pull requests and the
  changes to `main`: `build.yml` the ODYSSEY's image for every one, `tl-wr941nd-v4.yml` the
  TL-WR941ND's for those that touch its folder.
- **[renovate.json](renovate.json):** [Renovate](https://docs.renovatebot.com) watches the
  versions a build depends on and opens a pull request for each new one.
