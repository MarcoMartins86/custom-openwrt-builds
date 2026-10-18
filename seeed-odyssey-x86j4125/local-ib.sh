#!/bin/sh

# Sets up the ImageBuilder of an OpenWrt tree built on this machine, for build.sh
# to use instead of OpenWrt's container:
#
#   ./local-ib.sh ~/repo/openwrt-25.12
#   IB_DIR="$(pwd)/local-ib" ./build.sh
#
# The tree has to be the release in .env, configured from that release's
# config.buildinfo with its feeds.buildinfo, so that it differs from OpenWrt's
# own build only in its changes. Its kernel is its own, though, and so are the
# kernel modules: the ImageBuilder takes those from the tree, and every other
# package from the release's repositories as usual.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/.env"
[ -f "${HERE}/private/.env" ] && . "${HERE}/private/.env"

TREE="${1:?usage: local-ib.sh <OpenWrt tree>}"
TARGETS="${TREE}/bin/targets/x86/64"
ARCHIVE="$(ls "${TARGETS}/openwrt-imagebuilder-${OPENWRT_VERSION}-x86-64."*.tar.zst 2> /dev/null | head -1)"
[ -f "${ARCHIVE}" ] || { echo "no ImageBuilder for ${OPENWRT_VERSION} in ${TARGETS}; build the tree first" >&2; exit 1; }

IB="${HERE}/local-ib"
rm -rf "${IB}"
mkdir -p "${IB}"
tar -xf "${ARCHIVE}" -C "${IB}" --strip-components=1

# A release keeps the kernel modules in a folder of its own per kernel build,
# which only exists online for OpenWrt's kernel. This kernel's modules, among the
# tree's packages, go in kmods/out instead, which build.sh adds to the image's
# packages.
sed -i '\#/kmods/#d' "${IB}/repositories"
mkdir -p "${HERE}/kmods/out"
rm -f "${HERE}"/kmods/out/*.apk
find "${TARGETS}" -name 'kmod-*.apk' -exec cp -t "${HERE}/kmods/out/" {} +
echo "ImageBuilder in ${IB}, with $(ls "${HERE}"/kmods/out/*.apk | wc -l) kernel modules in kmods/out:"
cat "${IB}/repositories"
