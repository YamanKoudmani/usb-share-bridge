#!/command/with-contenv bashio
# shellcheck shell=bash

source /usr/share/usb-bridge/common.sh
usbb::init_logging
usbb::load_config

SERVER="$(usbb::config_default server "")"
if [ -z "${SERVER}" ]; then
    bashio::exit.nok "Option 'server' is required - set it in the add-on options."
fi

DEVICES_JSON="$(usbb::config_devices_json)"
DEVICE_COUNT="$(jq -r 'length' <<< "${DEVICES_JSON}")"
if [ "${DEVICE_COUNT}" -eq 0 ]; then
    bashio::exit.nok "Option 'devices' is empty - add at least one device (VID:PID or bus id)."
fi

while IFS=$'\t' read -r name id; do
    if [ -z "$id" ]; then
        bashio::exit.nok "Device '$name' has no id - set a VID:PID like 0bda:2838 or a bus id like 1-1."
    fi
    if ! usbb::is_vidpid "$id" && ! usbb::is_busid "$id"; then
        bashio::exit.nok "Device '$name' has invalid id '$id' - expected VID:PID like 0bda:2838 or bus id like 1-1."
    fi
done < <(jq -r '(. // [])[] | [(.name // "?"), (.id // "")] | @tsv' <<< "${DEVICES_JSON}")

usbb::log info "Configuration OK: ${DEVICE_COUNT} device(s) against server ${SERVER}."

# Reachability probe (non-fatal): plain TCP connect to the USB/IP port.
HOST="${SERVER%%:*}"
PORT="${SERVER##*:}"
if [ "${PORT}" = "${SERVER}" ]; then
    PORT=3240
fi
if timeout 3 bash -c "exec 3<>/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
    usbb::log info "Server ${SERVER} is reachable on TCP ${PORT}."
else
    usbb::log warning "Server ${SERVER} is not reachable on TCP ${PORT} yet - the monitor loop will keep retrying."
fi
