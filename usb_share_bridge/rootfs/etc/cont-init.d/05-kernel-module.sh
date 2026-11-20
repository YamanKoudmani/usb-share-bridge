#!/command/with-contenv bashio
# shellcheck shell=bash

source /usr/share/usb-bridge/common.sh
usbb::init_logging

if [ "${USBBRIDGE_SKIP_MODULES:-0}" = "1" ]; then
    usbb::log info "Test mode: skipping kernel module checks."
    exit 0
fi

if lsmod 2>/dev/null | grep -q '^vhci_hcd'; then
    usbb::log info "vhci-hcd kernel module is loaded."
elif modprobe vhci-hcd 2>/dev/null; then
    usbb::log info "Loaded the vhci-hcd kernel module."
else
    usbb::log error "vhci-hcd kernel module is not available. Update Home Assistant OS to a current version, then restart this add-on."
    bashio::exit.nok
fi

if [ ! -e /dev/vhci ]; then
    usbb::log error "/dev/vhci is missing - the container cannot reach the virtual USB host controller."
    bashio::exit.nok
fi

usbb::log info "USB/IP client ready (/dev/vhci present)."
