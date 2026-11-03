// SPDX-License-Identifier: GPL-2.0-only
/*
 * Creates the platform device that wdat_wdt drives, from the firmware's ACPI
 * Watchdog Action Table (WDAT).
 *
 * The kernel does this itself when built with CONFIG_ACPI_WATCHDOG, in
 * drivers/acpi/acpi_watchdog.c; OpenWrt's kernel is built without it. This is
 * acpi_watchdog_init() from Linux 6.12, Copyright (C) 2016 Intel Corporation,
 * by Mika Westerberg, made into a module: the same checks and the same
 * resources, minus the boot option that switches it off and the check for
 * tables that use the RTC's memory, which neither applies here.
 */

#define pr_fmt(fmt) "wdat_acpi: " fmt

#include <linux/acpi.h>
#include <linux/ioport.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/slab.h>

static struct platform_device *wdat_pdev;

static int __init wdat_acpi_init(void)
{
	const struct acpi_wdat_entry *entries;
	const struct acpi_table_wdat *wdat;
	struct list_head resource_list;
	struct resource_entry *rentry;
	struct platform_device *pdev;
	struct resource *resources;
	size_t nresources = 0;
	acpi_status status;
	int i, ret = -ENODEV;

	if (acpi_disabled)
		return -ENODEV;

	status = acpi_get_table(ACPI_SIG_WDAT, 0,
				(struct acpi_table_header **)&wdat);
	if (ACPI_FAILURE(status))
		return -ENODEV;

	/* Watchdog disabled by BIOS */
	if (!(wdat->flags & ACPI_WDAT_ENABLED)) {
		pr_info("the firmware has the watchdog disabled\n");
		goto fail_put_wdat;
	}

	/* Skip legacy PCI WDT devices */
	if (wdat->pci_segment != 0xff || wdat->pci_bus != 0xff ||
	    wdat->pci_device != 0xff || wdat->pci_function != 0xff)
		goto fail_put_wdat;

	INIT_LIST_HEAD(&resource_list);

	entries = (struct acpi_wdat_entry *)(wdat + 1);
	for (i = 0; i < wdat->entries; i++) {
		const struct acpi_generic_address *gas;
		struct resource res = {};
		bool found;

		gas = &entries[i].register_region;

		res.start = gas->address;
		res.end = res.start + ACPI_ACCESS_BYTE_WIDTH(gas->access_width) - 1;
		if (gas->space_id == ACPI_ADR_SPACE_SYSTEM_MEMORY) {
			res.flags = IORESOURCE_MEM;
		} else if (gas->space_id == ACPI_ADR_SPACE_SYSTEM_IO) {
			res.flags = IORESOURCE_IO;
		} else {
			pr_warn("Unsupported address space: %u\n", gas->space_id);
			goto fail_free_resource_list;
		}

		found = false;
		resource_list_for_each_entry(rentry, &resource_list) {
			if (rentry->res->flags == res.flags &&
			    resource_union(rentry->res, &res, rentry->res)) {
				found = true;
				break;
			}
		}

		if (!found) {
			rentry = resource_list_create_entry(NULL, 0);
			if (!rentry) {
				ret = -ENOMEM;
				goto fail_free_resource_list;
			}

			*rentry->res = res;
			resource_list_add_tail(rentry, &resource_list);
			nresources++;
		}
	}

	resources = kcalloc(nresources, sizeof(*resources), GFP_KERNEL);
	if (!resources) {
		ret = -ENOMEM;
		goto fail_free_resource_list;
	}

	i = 0;
	resource_list_for_each_entry(rentry, &resource_list)
		resources[i++] = *rentry->res;

	pdev = platform_device_register_simple("wdat_wdt", PLATFORM_DEVID_NONE,
					       resources, nresources);
	if (IS_ERR(pdev)) {
		ret = PTR_ERR(pdev);
		pr_err("Device creation failed: %pe\n", pdev);
	} else {
		wdat_pdev = pdev;
		ret = 0;
	}

	kfree(resources);

fail_free_resource_list:
	resource_list_free(&resource_list);
fail_put_wdat:
	acpi_put_table((struct acpi_table_header *)wdat);
	return ret;
}

static void __exit wdat_acpi_exit(void)
{
	platform_device_unregister(wdat_pdev);
}

module_init(wdat_acpi_init);
module_exit(wdat_acpi_exit);

MODULE_DESCRIPTION("Platform device for wdat_wdt, from the ACPI WDAT table");
MODULE_LICENSE("GPL");
