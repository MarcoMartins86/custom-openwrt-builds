# The ACPI watchdog (WDAT) driver as a separate kernel module package, built with
# OpenWrt's SDK for the release's kernel. OpenWrt's kernel leaves out both parts:
#   wdat_wdt.c   Linux's driver, copied unchanged from Linux 6.12.94
#                (drivers/watchdog/wdat_wdt.c)
#   wdat_acpi.c  the part that turns the firmware's table into the device the
#                driver binds to, from drivers/acpi/acpi_watchdog.c
# Both load at boot, from /etc/modules-boot.d, so that procd finds the watchdog
# and keeps it fed.

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=wdat-wdt
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define KernelPackage/wdat-wdt
  SUBMENU:=Other modules
  TITLE:=ACPI Watchdog Action Table (WDAT) watchdog
  DEPENDS:=@TARGET_x86
  FILES:=$(PKG_BUILD_DIR)/wdat_acpi.ko $(PKG_BUILD_DIR)/wdat_wdt.ko
  AUTOLOAD:=$(call AutoLoad,50,wdat_acpi wdat_wdt,1)
endef

define KernelPackage/wdat-wdt/description
 Hardware watchdog described by the firmware's ACPI WDAT table, as on boards
 with Intel Apollo Lake and Gemini Lake processors.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(KERNEL_MAKE) M="$(PKG_BUILD_DIR)" modules
endef

$(eval $(call KernelPackage,wdat-wdt))
