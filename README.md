# custom-openwrt-builds

Custom [OpenWrt](https://openwrt.org) images, built from the files in this repo. Each folder
holds one router's build: its settings, packages, first-boot scripts and tests, and a README
on how to build, test and flash it.

| Folder | Router |
|---|---|
| [odyssey-x86j4125-imagebuilder](odyssey-x86j4125-imagebuilder) | A [Seeed ODYSSEY-X86J4125](https://wiki.seeedstudio.com/ODYSSEY-X86J4105/) as a home router, on OpenWrt 25.12: ad blocking, a VPN, Docker with Home Assistant, sites by name with a Let's Encrypt certificate. Built with OpenWrt's ImageBuilder, nothing compiled |

Shared by the builds:

- **[.github/workflows](.github/workflows):** builds and tests every pull request and every
  change to `main`.
- **[renovate.json](renovate.json):** [Renovate](https://docs.renovatebot.com) watches the
  versions a build depends on and opens a pull request for each new one.
