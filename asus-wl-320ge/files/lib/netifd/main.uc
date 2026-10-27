// netifd manages the wired network only; the access point comes from /etc/init.d/ap.
// Replaces netifd's version, which loads the Wi-Fi scripts into netifd.
netifd.cb = {
	hotplug: function() {},
	config_init: function() {},
	config_start: function() {},
	check_interfaces: function() {},
};
