'use strict';
'require baseclass';

// The SSD's health, as /usr/libexec/disk-health hands it to collectd
return baseclass.extend({
	title: _('Disk Health'),

	rrdargs(graph, host, plugin, plugin_instance, dtype) {
		return [{
			title: "%H: Temperature of %pi",
			vlabel: "Celsius",
			number_format: "%3.0lf",
			alt_autoscale: true,
			data: {
				types: [ "temperature" ],
				options: {
					temperature: { color: "ff0000", title: "Temperature", noarea: true }
				}
			}
		}, {
			title: "%H: Data written to %pi over its life",
			vlabel: "GiB",
			number_format: "%5.0lf GiB",
			alt_autoscale: true,
			data: {
				instances: { count: [ "written" ] },
				options: {
					count_written: { color: "0000ff", title: "Written", noarea: true }
				}
			}
		}, {
			title: "%H: Wear and errors of %pi",
			vlabel: "Count",
			number_format: "%5.0lf",
			data: {
				instances: { count: [ "wear", "errors" ] },
				options: {
					count_wear: { color: "00a000", title: "Erases per block", noarea: true, overlay: true },
					count_errors: { color: "ff0000", title: "Errors", noarea: true, overlay: true }
				}
			}
		}];
	}
});
