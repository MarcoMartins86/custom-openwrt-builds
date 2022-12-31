# syntax=docker/dockerfile:1
FROM dorowu/ubuntu-desktop-lxde-vnc:focal
# Image with a limited browser noVNC at http://127.0.0.1
# or for a complete one use client like 'xtigervncviewer' at port :5900
# https://stackoverflow.com/questions/40658095/how-to-open-ubuntu-gui-inside-a-docker-image

ARG OPENWRT_VERSION
ARG PACKAGES_INSTALL
ARG FOLDER_NAME=openwrt-imagebuilder-$OPENWRT_VERSION-x86-64.Linux-x86_64
ARG ARCHIVE_NAME=$FOLDER_NAME.tar.xz

# Update keys or else 'apt update' fails
RUN curl -sSL https://dl.google.com/linux/linux_signing_key.pub | apt-key add && \
	apt update && \
	apt upgrade -y && \
    apt install -y --no-install-recommends $PACKAGES_INSTALL && \
	apt autoclean -y && \
	apt autoremove -y && \
	rm -rf /var/lib/apt/lists/*

EXPOSE 80
EXPOSE 5900

WORKDIR /root/Desktop

RUN curl -L -o $ARCHIVE_NAME https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/x86/64/$ARCHIVE_NAME && \
	tar -xJf $ARCHIVE_NAME && \
	rm $ARCHIVE_NAME && \
	mv -v $FOLDER_NAME openwrt-imagebuilder

WORKDIR /root/Desktop/openwrt-imagebuilder
