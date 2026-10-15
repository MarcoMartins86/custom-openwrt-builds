#!/bin/sh

# Builds the kernel module packages in kmods/ with OpenWrt's SDK, for the kernel
# of the release in .env. build.sh then puts them into the image.
#
# Meant to run inside the SDK container (the sdk service in docker-compose.yml),
# where this directory's parent is mounted at /work and the SDK lives in
# /builder. To run it without a container, point SDK_DIR at an extracted SDK of
# the version given in .env.

set -e

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${HERE}/kmods/out"

# The build system breaks on PATH entries with spaces, which WSL inherits from Windows
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

cd "${SDK_DIR:-/builder}"
# Newer containers ship a script that downloads the SDK on first use
[ -d ./scripts ] || ./setup.sh

make defconfig > /dev/null
# The folder is emptied rather than replaced, as it may belong to someone else
mkdir -p "${OUT}"
rm -f "${OUT}"/*.apk
for dir in "${HERE}"/kmods/*/; do
	[ -f "${dir}Makefile" ] || continue
	name="$(basename "${dir}")"
	rm -rf "package/${name}"
	cp -a "${dir}" "package/${name}"
	make "package/${name}/compile"
done
find bin/targets -name 'kmod-*.apk' -exec cp {} "${OUT}/" \;
ls -l "${OUT}"
