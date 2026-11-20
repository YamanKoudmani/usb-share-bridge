#!/command/with-contenv bashio
# shellcheck shell=bash

source /usr/share/usb-bridge/common.sh
usbb::init_logging

if usbb::discover; then
    usbb::log info "Initial discovery complete; the bridge service will attach the devices."
else
    # Non-fatal: the monitor loop retries discovery until the server answers.
    usbb::log warning "Initial discovery failed - will keep retrying in the monitor loop."
fi
exit 0
