#!/command/with-contenv bashio
# shellcheck shell=bash

source /usr/share/usb-bridge/common.sh
usbb::init_logging

if [ "${USBBRIDGE_SKIP_MODULES:-0}" = "1" ]; then
    usbb::log info "Test mode: assuming the vhci-hcd kernel module is loaded."
elif lsmod 2>/dev/null | grep -q '^vhci_hcd'; then
    usbb::log info "vhci-hcd kernel module is loaded."
elif modprobe vhci-hcd 2>/dev/null; then
    usbb::log info "Loaded the vhci-hcd kernel module."
else
    usbb::log error "vhci-hcd kernel module is not available. Update Home Assistant OS to a current version, then restart this add-on."
    bashio::exit.nok
fi

# There is no /dev/vhci character device: the usbip client drives the
# virtual host controller through sysfs. Confirm the control interface;
# warn (not fail) since the exact sysfs path can vary between kernels.
VHCI_SYSFS="${USBBRIDGE_VHCI_SYSFS:-/sys/devices/platform/vhci}"
if [ -d "${VHCI_SYSFS}" ]; then
    usbb::log info "USB/IP virtual host controller ready (sysfs: ${VHCI_SYSFS})."
else
    usbb::log warning "vhci sysfs path ${VHCI_SYSFS} not found - the kernel may expose it elsewhere. usbip attach will report clearly if the controller is truly unavailable."
fi
