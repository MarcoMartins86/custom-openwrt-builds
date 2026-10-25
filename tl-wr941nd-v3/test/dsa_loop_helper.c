// SPDX-License-Identifier: GPL-2.0
/*
 * For test/malta-network.sh: puts the kernel's DSA test switch (dsa_loop) on the fixed MDIO
 * bus, with the TL-WR941ND v3's port names. dsa_loop_bdinfo does that with board info,
 * which has to come before the bus registers; on the Malta kernel the bus is built in and
 * registers at boot, so the device is added to it here instead. The test switch reads each
 * port's PHY from that bus at the port's number, and the bus emulates four; the v3 has five
 * ports, so it gets a fifth.
 */
#include <linux/module.h>
#include <linux/phy.h>
#include <linux/phy_fixed.h>
#include <linux/platform_data/dsa.h>
#include "dsa_loop.h"

static struct dsa_loop_pdata dsa_loop_pdata = {
	.cd = {
		.port_names[0] = "wan",
		.port_names[1] = "lan1",
		.port_names[2] = "lan2",
		.port_names[3] = "lan3",
		.port_names[4] = "lan4",
		.port_names[DSA_LOOP_CPU_PORT] = "cpu",
	},
	.name = "DSA mockup driver",
	.enabled_ports = 0x1f,
	.netdev = "eth0",
};

static struct fixed_phy_status dsa_loop_helper_phy = {
	.link = 1,
	.speed = SPEED_100,
	.duplex = DUPLEX_FULL,
};

/* What board info sets up: the device goes to the driver of its name */
static int dsa_loop_helper_match(struct device *dev, const struct device_driver *drv)
{
	return !strcmp(to_mdio_device(dev)->modalias, drv->name);
}

static int __init dsa_loop_helper_init(void)
{
	struct mdio_device *mdiodev;
	struct mii_bus *bus;
	int ret;

	ret = fixed_phy_add(PHY_POLL, 4, &dsa_loop_helper_phy);
	if (ret)
		return ret;

	bus = mdio_find_bus("fixed-0");
	if (!bus)
		return -ENODEV;
	mdiodev = mdio_device_create(bus, 31);
	put_device(&bus->dev);
	if (IS_ERR(mdiodev))
		return PTR_ERR(mdiodev);
	strscpy(mdiodev->modalias, "dsa-loop", sizeof(mdiodev->modalias));
	mdiodev->dev.platform_data = &dsa_loop_pdata;
	mdiodev->bus_match = dsa_loop_helper_match;
	ret = mdio_device_register(mdiodev);
	if (ret)
		mdio_device_free(mdiodev);
	return ret;
}
module_init(dsa_loop_helper_init);
MODULE_LICENSE("GPL");
