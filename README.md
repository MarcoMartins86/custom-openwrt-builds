# custom-openwrt-builds

## odyssey-x86j4125-code

> **Warning** Need Docker with 8Gb of RAM or else compilation might not be successful.

> **Note**
> 
> Use `docker exec -it odyssey-x86j4125-code-ubvnc-odyssey-x86j4125-code-1 [command]` to run commands inside docker container

> Links for getting some context on what needs to be done
> 
> [OpenWRT - Developer Guide - Build system usage](https://openwrt.org/docs/guide-developer/toolchain/use-buildsystem)
>
> [Getting Started with OpenWRT](https://wiki.seeedstudio.com/OpenWrt-Getting-Started/)
>
> [ODYSSEY X86J4105 OpenWRT Installation](https://wiki.seeedstudio.com/ODYSSEY-X86J4105-Installing-openwrt/)
> 
> [Smart Home with Home Assistant on OpenWrt](https://www.seeedstudio.com/blog/2021/10/13/smart-home-with-home-assistant-on-openwrt/)
>


* Run docker with: `docker-compose -f odyssey-x86j4125-code/docker-compose.yml up --build --no-deps`
* Access with `http://localhost:6080` or with a client like `xtigervncviewer` at `http://localhost:5900`
* Need to run `make -j $(nproc) kernel_menuconfig` or else final image will not boot due to changes on kconfig to include more kernel drivers. When menu appears just save file and exit.
* Previous point modified kconfig file, manually discard changes using a merge program, otherwise some options will be asked during compilation. Don't use git to discard the changes, or image will not boot, I think that is due to the fact file date would be restored also. (TODO: investigate if there is some kind of defconfig command and if so if running last step is not needed)
* Run `make -j $(nproc) defconfig download clean world` to build the image. Output will be available at `[repo]/odyssey-x86j4125-code/binaries/code/64`
* Copy OpenWRT to Odyssey with `scp [repo]/odyssey-x86j4125-code/binaries/code/64/openwrt-x86-64-generic-ext4-combined-efi.img.gz root@192.168.2.1:~/openwrt.img.gz`. Change login user if not using the default one.
* Use a boot linux pen on Odissey (check tutorials on how to use the image itself), for doing the middle man to install the image into the Odissey disk itself.
* Then access Odissey `ssh root@192.168.2.1`, again change credentials if not using default, if needed clear the old certificate `ssh-keygen -R 192.168.2.1`, and do:
  * `gzip -d openwrt.img.gz`
  * `dd if=openwrt.img of=/dev/sda`
  * `poweroff` to shutdown and manually boot or `reboot`
  * At power on press `F7` if boot menu is needed to choose an option
  * First time the image runs, it will reboot itself due to a script for resizing the disk to use all remaing free disk space.




