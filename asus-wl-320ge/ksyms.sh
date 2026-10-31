#!/bin/sh

# Lists in ksyms-keep.txt the kernel symbols the modules of the last build use, the ones
# built outside the kernel tree included (mac80211, b43...). build.sh has the kernel keep
# these exported and drop the rest. A module that needs one the list does not have stops
# the build: build once with NO_TRIM=1, then run this, then build again.
#
# usage: ksyms.sh   (on this machine, after build.sh)

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
NM="$(ls "${HERE}"/openwrt/staging_dir/toolchain-*/bin/*-nm 2> /dev/null | head -n 1)"
KDIR="$(ls -d "${HERE}"/openwrt/build_dir/target-*/linux-bcm47xx_legacy 2> /dev/null)"
[ -x "${NM}" ] && [ -d "${KDIR}" ] || { echo "no build in openwrt/; run build.sh first" >&2; exit 1; }
{
	echo "# Kernel symbols the image's modules use, built outside the kernel tree included (mac80211,"
	echo "# b43...): the kernel keeps these exported and drops the rest (TRIM_UNUSED_KSYMS in"
	echo "# kernel.config). Made from a build's modules by ksyms.sh; a module needing one that is"
	echo "# missing stops the build."
	find "${KDIR}" -name '*.ko' | xargs "${NM}" -u | awk '$1 == "U" { print $2 }' | sort -u
} > "${HERE}/ksyms-keep.txt"
echo "$(grep -vc '^#' "${HERE}/ksyms-keep.txt") symbols in ksyms-keep.txt"
