# syntax=docker/dockerfile:1
FROM dorowu/ubuntu-desktop-lxde-vnc:focal
# Image with a limited browser noVNC at http://127.0.0.1
# or for a complete one use client like 'xtigervncviewer' at port :5900
# https://stackoverflow.com/questions/40658095/how-to-open-ubuntu-gui-inside-a-docker-image

ARG OPENWRT_VERSION 
ARG PACKAGES_INSTALL
ENV FORCE_UNSAFE_CONFIGURE=1
ENV TINI_SUBREAPER=true

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

# Download the sources selecting a specific code revision
RUN git clone https://git.openwrt.org/openwrt/openwrt.git --branch v$OPENWRT_VERSION --depth 1

WORKDIR /root/Desktop/openwrt

# Update the feeds
RUN ./scripts/feeds update -a
RUN ./scripts/feeds install -a

COPY ./odyssey-x86j4125-code/config/config /root/Desktop/openwrt/.config
COPY ./odyssey-x86j4125-code/config/kconfig /root/Desktop/openwrt/target/linux/x86/config-5.10
COPY ./odyssey-x86j4125-code/files/ /root/Desktop/openwrt/files/
# Firmware from here https://github.com/pkshih/linux-firmware
COPY ./odyssey-x86j4125-code/kernel_firmware/ /root/Desktop/openwrt/kernel_firmware/

# https://openwrt.org/docs/guide-developer/toolchain/use-buildsystem
# Let's compile to cache this step that takes much time
RUN make -j $(nproc) defconfig download clean world

# Copy the binary to another folder so then we make a link in the docker-compose.yml 
RUN mkdir -p /root/Desktop/openwrt/.bin/targets/x86 && \ 
    cp -r /root/Desktop/openwrt/bin/targets/x86/64 /root/Desktop/openwrt/.bin/targets/x86
	
# Extract the imagebuilder to Desktop
RUN tar -xJf /root/Desktop/openwrt/bin/targets/x86/64/openwrt-imagebuilder-x86-64.Linux-x86_64.tar.xz && \
	mv -v openwrt-imagebuilder-x86-64.Linux-x86_64 /root/Desktop/openwrt-imagebuilder

# Write a script for building imagebuilder
RUN echo $'#!/bin/sh \n\
make clean image FILES="files" PACKAGES="${PACKAGES}"' > /root/Desktop/openwrt-imagebuilder/build.sh
